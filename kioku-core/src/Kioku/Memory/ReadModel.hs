-- | The @kioku_memories@ projection and every query over it.
--
-- Every row belongs to exactly one memory space, and every statement below names that space
-- first. The predicate is not redundant with the primary key even though @memory_id@ is
-- globally unique: it is what stops a caller holding a leaked id from reading, or a projection
-- from writing, outside the space it was authorized for, and it makes the partition visible in
-- every query a reviewer reads.
module Kioku.Memory.ReadModel
  ( memoryInlineProjection,
    MemoryRow (..),
    MemoryByIdQuery (..),
    MemoriesByNamespaceQuery (..),
    MemoriesByScopeQuery (..),
    MemoriesBySessionQuery (..),
    MemoriesByTypeQuery (..),
    MemorySupersessionChainQuery (..),
    memoryByIdReadModel,
    memoriesByNamespaceReadModel,
    memoriesByNamespaceRowsReadModel,
    memoriesByScopeReadModel,
    memoriesByScopeRowsReadModel,
    memoriesBySessionReadModel,
    memoriesBySessionRowsReadModel,
    memoriesByTypeReadModel,
    memoriesByTypeRowsReadModel,
    memorySupersessionChainReadModel,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Functor.Contravariant ((>$<))
import Data.Generics.Labels ()
import Data.Int (Int32)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text.Encoding qualified as TE
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Projection (InlineProjection (..))
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..), StrongScope (..))
import Kioku.Api.Access (MemorySpaceId)
import Kioku.Api.Scope (scopeFromColumns, scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (MemoryRecord (..), confidenceToText, memoryTypeToText)
import Kioku.Id (idText)
import Kioku.Memory.Domain
import Kioku.Partition (memorySpaceColumn, memorySpaceParam)
import Kioku.Prelude
import Kiroku.Store.Types (RecordedEvent)

data MemoryRow = MemoryRow
  { memorySpaceId :: !MemorySpaceId,
    memoryId :: !Text,
    agentId :: !Text,
    sessionId :: !(Maybe Text),
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text),
    memoryType :: !Text,
    content :: !Text,
    priority :: !Int,
    confidence :: !Text,
    tags :: !(Set Text),
    status :: !Text,
    supersededBy :: !(Maybe Text),
    supersedes :: !(Maybe Text),
    createdAt :: !UTCTime,
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

-- | Every query names its memory space in a field rather than a tuple position, so a call site
-- cannot transpose the partition with the namespace it happens to sit beside.
data MemoryByIdQuery = MemoryByIdQuery
  { memorySpaceId :: !MemorySpaceId,
    memoryId :: !Text
  }

data MemoriesByNamespaceQuery = MemoriesByNamespaceQuery
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text
  }

data MemoriesByScopeQuery = MemoriesByScopeQuery
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text)
  }

data MemoriesBySessionQuery = MemoriesBySessionQuery
  { memorySpaceId :: !MemorySpaceId,
    sessionId :: !Text
  }

data MemoriesByTypeQuery = MemoriesByTypeQuery
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    memoryType :: !Text
  }

data MemorySupersessionChainQuery = MemorySupersessionChainQuery
  { memorySpaceId :: !MemorySpaceId,
    memoryId :: !Text
  }

memoryInlineProjection :: InlineProjection MemoryEvent
memoryInlineProjection =
  InlineProjection
    { name = "kioku-memory-inline",
      apply = applyMemoryEvent
    }

-- | Project one memory event.
--
-- Each non-recording event carries the memory space its aggregate is pinned to, and the update
-- statements below match on it as well as on the id. That is not defensive noise: the aggregate
-- refuses a command naming the wrong space, so a mismatch here can only mean the projection and
-- the event stream disagree, and quietly rewriting a row in another space is the one outcome
-- worse than writing nothing.
applyMemoryEvent :: MemoryEvent -> RecordedEvent -> Tx.Transaction ()
applyMemoryEvent event _recorded =
  case event of
    MemoryRecorded d -> Tx.statement (recordedRow d) upsertMemoryStmt
    MemorySuperseded d ->
      Tx.statement
        (MemoryStatusChange d.memorySpaceId (idText d.memoryId) (Just (idText d.supersededBy)) d.supersededAt)
        updateMemorySupersededStmt
    MemoryArchived d ->
      Tx.statement
        (MemoryStatusChange d.memorySpaceId (idText d.memoryId) Nothing d.archivedAt)
        updateMemoryArchivedStmt
    MemoryTagsUpdated d ->
      Tx.statement (MemoryTagsChange d.memorySpaceId (idText d.memoryId) d.tags d.updatedAt) updateMemoryTagsStmt
    MemoryConfidenceUpdated d ->
      Tx.statement
        (MemoryConfidenceChange d.memorySpaceId (idText d.memoryId) (confidenceToText d.confidence) d.updatedAt)
        updateMemoryConfidenceStmt
    MemoryMerged d ->
      Tx.statement
        (MemoryStatusChange d.memorySpaceId (idText d.memoryId) (Just (idText d.mergedInto)) d.mergedAt)
        updateMemoryMergedStmt

-- | The parameters of a retirement: which memory, in which space, retired in favour of what.
data MemoryStatusChange = MemoryStatusChange
  { memorySpaceId :: !MemorySpaceId,
    memoryId :: !Text,
    supersededBy :: !(Maybe Text),
    updatedAt :: !UTCTime
  }

data MemoryTagsChange = MemoryTagsChange
  { memorySpaceId :: !MemorySpaceId,
    memoryId :: !Text,
    tags :: !(Set Text),
    updatedAt :: !UTCTime
  }

data MemoryConfidenceChange = MemoryConfidenceChange
  { memorySpaceId :: !MemorySpaceId,
    memoryId :: !Text,
    confidence :: !Text,
    updatedAt :: !UTCTime
  }

recordedRow :: MemoryRecordedData -> MemoryRow
recordedRow d =
  MemoryRow
    { memorySpaceId = d.memorySpaceId,
      memoryId = idText d.memoryId,
      agentId = d.agentId,
      sessionId = idText <$> d.sessionId,
      namespace = scopeNamespaceText d.scope,
      scopeKind = scopeKindText d.scope,
      scopeRef = scopeRefText d.scope,
      memoryType = memoryTypeToText d.memoryType,
      content = d.content,
      priority = d.priority,
      confidence = confidenceToText d.confidence,
      tags = d.tags,
      status = "active",
      supersededBy = Nothing,
      supersedes = idText <$> d.supersedes,
      createdAt = d.recordedAt,
      updatedAt = d.recordedAt
    }

memoryByIdReadModel :: ReadModel MemoryByIdQuery (Maybe MemoryRow)
memoryByIdReadModel =
  ReadModel
    { name = "kioku-memory-by-id",
      schema = "kiroku",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = memoryReadModelVersion,
      shapeHash = memoryReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectMemoryByIdStmt
    }

memoriesByNamespaceReadModel :: ReadModel MemoriesByNamespaceQuery [MemoryRecord]
memoriesByNamespaceReadModel =
  ReadModel
    { name = "kioku-memories-by-namespace",
      schema = "kiroku",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = memoryReadModelVersion,
      shapeHash = memoryReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectActiveByNamespaceStmt
    }

memoriesByNamespaceRowsReadModel :: ReadModel MemoriesByNamespaceQuery [MemoryRow]
memoriesByNamespaceRowsReadModel =
  ReadModel
    { name = "kioku-memory-rows-by-namespace",
      schema = "kiroku",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = memoryReadModelVersion,
      shapeHash = memoryReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectActiveByNamespaceRowsStmt
    }

memoriesByScopeReadModel :: ReadModel MemoriesByScopeQuery [MemoryRecord]
memoriesByScopeReadModel =
  ReadModel
    { name = "kioku-memories-by-scope",
      schema = "kiroku",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = memoryReadModelVersion,
      shapeHash = memoryReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectActiveByScopeStmt
    }

memoriesByScopeRowsReadModel :: ReadModel MemoriesByScopeQuery [MemoryRow]
memoriesByScopeRowsReadModel =
  ReadModel
    { name = "kioku-memory-rows-by-scope",
      schema = "kiroku",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = memoryReadModelVersion,
      shapeHash = memoryReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectActiveByScopeRowsStmt
    }

memoriesBySessionReadModel :: ReadModel MemoriesBySessionQuery [MemoryRecord]
memoriesBySessionReadModel =
  ReadModel
    { name = "kioku-memories-by-session",
      schema = "kiroku",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = memoryReadModelVersion,
      shapeHash = memoryReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectBySessionStmt
    }

memoriesBySessionRowsReadModel :: ReadModel MemoriesBySessionQuery [MemoryRow]
memoriesBySessionRowsReadModel =
  ReadModel
    { name = "kioku-memory-rows-by-session",
      schema = "kiroku",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = memoryReadModelVersion,
      shapeHash = memoryReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectBySessionRowsStmt
    }

memoriesByTypeReadModel :: ReadModel MemoriesByTypeQuery [MemoryRecord]
memoriesByTypeReadModel =
  ReadModel
    { name = "kioku-memories-by-type",
      schema = "kiroku",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = memoryReadModelVersion,
      shapeHash = memoryReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectByTypeStmt
    }

memoriesByTypeRowsReadModel :: ReadModel MemoriesByTypeQuery [MemoryRow]
memoriesByTypeRowsReadModel =
  ReadModel
    { name = "kioku-memory-rows-by-type",
      schema = "kiroku",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = memoryReadModelVersion,
      shapeHash = memoryReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectByTypeRowsStmt
    }

memorySupersessionChainReadModel :: ReadModel MemorySupersessionChainQuery [MemoryRow]
memorySupersessionChainReadModel =
  ReadModel
    { name = "kioku-memory-supersession-chain",
      schema = "kiroku",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = memoryReadModelVersion,
      shapeHash = memoryReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectSupersessionChainStmt
    }

-- | The registry identity of every memory read model.
--
-- v2 is the memory-space partition: the row carries @memory_space_id@ and every query filters on
-- it. The migration leaves the table data correct for v2 (each pre-existing row is backfilled
-- into the legacy space), so @Kioku.ReadModel.reconcileReadModelRegistry@ can advance the guard
-- without a rebuild.
memoryReadModelVersion :: Int
memoryReadModelVersion = 2

memoryReadModelShapeHash :: Text
memoryReadModelShapeHash = "kioku-memory-v2"

memoryRowDecoder :: D.Row MemoryRow
memoryRowDecoder =
  MemoryRow
    <$> memorySpaceColumn
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> (fromIntegral @Int32 @Int <$> D.column (D.nonNullable D.int4))
    <*> D.column (D.nonNullable D.text)
    <*> (decodeTags <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)

memoryRecordDecoder :: D.Row MemoryRecord
memoryRecordDecoder =
  toRecord <$> memoryRowDecoder

toRecord :: MemoryRow -> MemoryRecord
toRecord row =
  MemoryRecord
    { memoryId = row.memoryId,
      agentId = row.agentId,
      sessionId = row.sessionId,
      scope = scopeFromColumns row.namespace row.scopeKind row.scopeRef,
      memoryType = row.memoryType,
      content = row.content,
      priority = row.priority,
      confidence = row.confidence,
      tags = row.tags,
      status = row.status,
      createdAt = row.createdAt
    }

encodeTags :: Set Text -> Text
encodeTags = TE.decodeUtf8 . BL.toStrict . Aeson.encode

decodeTags :: Text -> Set Text
decodeTags =
  fromMaybe Set.empty . Aeson.decode . BL.fromStrict . TE.encodeUtf8

memoryRowColumns :: Text
memoryRowColumns =
  "memory_space_id, memory_id, agent_id, session_id, namespace, scope_kind, scope_ref, memory_type, content, priority, confidence, tags::text, status, superseded_by, supersedes, created_at, updated_at"

qualifiedMemoryRowColumns :: Text -> Text
qualifiedMemoryRowColumns prefix =
  prefix
    <> ".memory_space_id, "
    <> prefix
    <> ".memory_id, "
    <> prefix
    <> ".agent_id, "
    <> prefix
    <> ".session_id, "
    <> prefix
    <> ".namespace, "
    <> prefix
    <> ".scope_kind, "
    <> prefix
    <> ".scope_ref, "
    <> prefix
    <> ".memory_type, "
    <> prefix
    <> ".content, "
    <> prefix
    <> ".priority, "
    <> prefix
    <> ".confidence, "
    <> prefix
    <> ".tags::text, "
    <> prefix
    <> ".status, "
    <> prefix
    <> ".superseded_by, "
    <> prefix
    <> ".supersedes, "
    <> prefix
    <> ".created_at, "
    <> prefix
    <> ".updated_at"

selectMemoryByIdStmt :: Statement MemoryByIdQuery (Maybe MemoryRow)
selectMemoryByIdStmt =
  preparable
    ( "SELECT "
        <> memoryRowColumns
        <> " FROM kioku_memories WHERE memory_space_id = $1 AND memory_id = $2"
    )
    ( ((\q -> q.memorySpaceId) >$< memorySpaceParam)
        <> ((\q -> q.memoryId) >$< E.param (E.nonNullable E.text))
    )
    (D.rowMaybe memoryRowDecoder)

selectActiveByNamespaceStmt :: Statement MemoriesByNamespaceQuery [MemoryRecord]
selectActiveByNamespaceStmt =
  preparable
    (activeByNamespaceSql memoryRowColumns)
    namespaceQueryEncoder
    (D.rowList memoryRecordDecoder)

selectActiveByNamespaceRowsStmt :: Statement MemoriesByNamespaceQuery [MemoryRow]
selectActiveByNamespaceRowsStmt =
  preparable
    (activeByNamespaceSql memoryRowColumns)
    namespaceQueryEncoder
    (D.rowList memoryRowDecoder)

activeByNamespaceSql :: Text -> Text
activeByNamespaceSql columns =
  "SELECT "
    <> columns
    <> " FROM kioku_memories WHERE status = 'active' AND memory_space_id = $1 AND namespace = $2 ORDER BY priority ASC, created_at DESC"

namespaceQueryEncoder :: E.Params MemoriesByNamespaceQuery
namespaceQueryEncoder =
  ((\q -> q.memorySpaceId) >$< memorySpaceParam)
    <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))

-- | Active memories carrying __exactly__ the given scope, inside one memory space.
--
-- Recall searches namespace-wide for a global scope; scoped reads are exact-scope. The
-- predicate below /requires/ @scope_kind@ and @scope_ref@ to be NULL for a global scope,
-- where 'Kioku.Recall.selectFtsCandidatesStmt' would drop the scope filter entirely and
-- return the whole namespace. Both behaviours are intentional; see docs/user/recall.md. The
-- memory-space predicate is not part of that asymmetry — it never widens, in either query.
selectActiveByScopeStmt :: Statement MemoriesByScopeQuery [MemoryRecord]
selectActiveByScopeStmt =
  preparable
    (activeByScopeSql memoryRowColumns)
    scopeQueryEncoder
    (D.rowList memoryRecordDecoder)

selectActiveByScopeRowsStmt :: Statement MemoriesByScopeQuery [MemoryRow]
selectActiveByScopeRowsStmt =
  preparable
    (activeByScopeSql memoryRowColumns)
    scopeQueryEncoder
    (D.rowList memoryRowDecoder)

activeByScopeSql :: Text -> Text
activeByScopeSql columns =
  "SELECT "
    <> columns
    <> " FROM kioku_memories WHERE status = 'active' AND memory_space_id = $1 AND namespace = $2 AND ((scope_kind = $3 AND scope_ref = $4) OR ($3 IS NULL AND scope_kind IS NULL AND $4 IS NULL AND scope_ref IS NULL)) ORDER BY priority ASC, created_at DESC"

scopeQueryEncoder :: E.Params MemoriesByScopeQuery
scopeQueryEncoder =
  ((\q -> q.memorySpaceId) >$< memorySpaceParam)
    <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\q -> q.scopeRef) >$< E.param (E.nullable E.text))

selectBySessionStmt :: Statement MemoriesBySessionQuery [MemoryRecord]
selectBySessionStmt =
  preparable
    (bySessionSql memoryRowColumns)
    sessionQueryEncoder
    (D.rowList memoryRecordDecoder)

selectBySessionRowsStmt :: Statement MemoriesBySessionQuery [MemoryRow]
selectBySessionRowsStmt =
  preparable
    (bySessionSql memoryRowColumns)
    sessionQueryEncoder
    (D.rowList memoryRowDecoder)

bySessionSql :: Text -> Text
bySessionSql columns =
  "SELECT "
    <> columns
    <> " FROM kioku_memories WHERE memory_space_id = $1 AND session_id = $2 ORDER BY created_at DESC"

sessionQueryEncoder :: E.Params MemoriesBySessionQuery
sessionQueryEncoder =
  ((\q -> q.memorySpaceId) >$< memorySpaceParam)
    <> ((\q -> q.sessionId) >$< E.param (E.nonNullable E.text))

selectByTypeStmt :: Statement MemoriesByTypeQuery [MemoryRecord]
selectByTypeStmt =
  preparable
    (byTypeSql memoryRowColumns)
    typeQueryEncoder
    (D.rowList memoryRecordDecoder)

selectByTypeRowsStmt :: Statement MemoriesByTypeQuery [MemoryRow]
selectByTypeRowsStmt =
  preparable
    (byTypeSql memoryRowColumns)
    typeQueryEncoder
    (D.rowList memoryRowDecoder)

byTypeSql :: Text -> Text
byTypeSql columns =
  "SELECT "
    <> columns
    <> " FROM kioku_memories WHERE status = 'active' AND memory_space_id = $1 AND namespace = $2 AND memory_type = $3 ORDER BY priority ASC, created_at DESC"

typeQueryEncoder :: E.Params MemoriesByTypeQuery
typeQueryEncoder =
  ((\q -> q.memorySpaceId) >$< memorySpaceParam)
    <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.memoryType) >$< E.param (E.nonNullable E.text))

-- | Walk a memory's supersession chain, without leaving the space it started in.
--
-- The space predicate is repeated on the recursive arm, not just the anchor. Supersession
-- lineage is stored as bare ids in @supersedes@ and @superseded_by@, so an id written before
-- the partition existed — or a bug anywhere upstream — could otherwise walk the chain straight
-- into another space and return its content.
selectSupersessionChainStmt :: Statement MemorySupersessionChainQuery [MemoryRow]
selectSupersessionChainStmt =
  preparable
    ( "WITH RECURSIVE chain AS ("
        <> "SELECT "
        <> memoryRowColumns
        <> " FROM kioku_memories WHERE memory_space_id = $1 AND memory_id = $2 "
        <> "UNION "
        <> "SELECT "
        <> qualifiedMemoryRowColumns "m"
        <> " FROM kioku_memories m JOIN chain c ON m.memory_space_id = c.memory_space_id AND ("
        <> "m.memory_id = c.supersedes "
        <> "OR m.supersedes = c.memory_id "
        <> "OR m.memory_id = c.superseded_by "
        <> "OR m.superseded_by = c.memory_id"
        <> ")) SELECT "
        <> memoryRowColumns
        <> " FROM chain ORDER BY created_at ASC, memory_id ASC"
    )
    ( ((\q -> q.memorySpaceId) >$< memorySpaceParam)
        <> ((\q -> q.memoryId) >$< E.param (E.nonNullable E.text))
    )
    (D.rowList memoryRowDecoder)

upsertMemoryStmt :: Statement MemoryRow ()
upsertMemoryStmt =
  preparable
    """
    INSERT INTO kioku_memories
      (memory_space_id, memory_id, agent_id, session_id, namespace, scope_kind, scope_ref,
       memory_type, content, priority, confidence, tags, status, superseded_by, supersedes,
       created_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12::jsonb, $13, $14, $15, $16, $17)
    ON CONFLICT (memory_id) DO UPDATE SET
      memory_space_id = EXCLUDED.memory_space_id,
      agent_id = EXCLUDED.agent_id,
      session_id = EXCLUDED.session_id,
      namespace = EXCLUDED.namespace,
      scope_kind = EXCLUDED.scope_kind,
      scope_ref = EXCLUDED.scope_ref,
      memory_type = EXCLUDED.memory_type,
      content = EXCLUDED.content,
      priority = EXCLUDED.priority,
      confidence = EXCLUDED.confidence,
      tags = EXCLUDED.tags,
      status = EXCLUDED.status,
      superseded_by = EXCLUDED.superseded_by,
      supersedes = EXCLUDED.supersedes,
      updated_at = EXCLUDED.updated_at
    """
    memoryRowEncoder
    D.noResult

memoryRowEncoder :: E.Params MemoryRow
memoryRowEncoder =
  ((\row -> row.memorySpaceId) >$< memorySpaceParam)
    <> ((\row -> row.memoryId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.agentId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.sessionId) >$< E.param (E.nullable E.text))
    <> ((\row -> row.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\row -> row.scopeRef) >$< E.param (E.nullable E.text))
    <> ((\row -> row.memoryType) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.content) >$< E.param (E.nonNullable E.text))
    <> ((fromIntegral @Int @Int32 . \row -> row.priority) >$< E.param (E.nonNullable E.int4))
    <> ((\row -> row.confidence) >$< E.param (E.nonNullable E.text))
    <> ((encodeTags . (\row -> row.tags)) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.status) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.supersededBy) >$< E.param (E.nullable E.text))
    <> ((\row -> row.supersedes) >$< E.param (E.nullable E.text))
    <> ((\row -> row.createdAt) >$< E.param (E.nonNullable E.timestamptz))
    <> ((\row -> row.updatedAt) >$< E.param (E.nonNullable E.timestamptz))

statusChangeEncoder :: E.Params MemoryStatusChange
statusChangeEncoder =
  ((\c -> c.memorySpaceId) >$< memorySpaceParam)
    <> ((\c -> c.memoryId) >$< E.param (E.nonNullable E.text))
    <> ((\c -> c.supersededBy) >$< E.param (E.nullable E.text))
    <> ((\c -> c.updatedAt) >$< E.param (E.nonNullable E.timestamptz))

updateMemorySupersededStmt :: Statement MemoryStatusChange ()
updateMemorySupersededStmt =
  preparable
    "UPDATE kioku_memories SET status = 'superseded', superseded_by = $3, updated_at = $4 WHERE memory_space_id = $1 AND memory_id = $2"
    statusChangeEncoder
    D.noResult

updateMemoryArchivedStmt :: Statement MemoryStatusChange ()
updateMemoryArchivedStmt =
  preparable
    "UPDATE kioku_memories SET status = 'archived', updated_at = $4 WHERE memory_space_id = $1 AND memory_id = $2"
    statusChangeEncoder
    D.noResult

updateMemoryMergedStmt :: Statement MemoryStatusChange ()
updateMemoryMergedStmt =
  preparable
    "UPDATE kioku_memories SET status = 'merged', superseded_by = $3, updated_at = $4 WHERE memory_space_id = $1 AND memory_id = $2"
    statusChangeEncoder
    D.noResult

updateMemoryTagsStmt :: Statement MemoryTagsChange ()
updateMemoryTagsStmt =
  preparable
    "UPDATE kioku_memories SET tags = $3::jsonb, updated_at = $4 WHERE memory_space_id = $1 AND memory_id = $2"
    ( ((\c -> c.memorySpaceId) >$< memorySpaceParam)
        <> ((\c -> c.memoryId) >$< E.param (E.nonNullable E.text))
        <> ((encodeTags . (\c -> c.tags)) >$< E.param (E.nonNullable E.text))
        <> ((\c -> c.updatedAt) >$< E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

updateMemoryConfidenceStmt :: Statement MemoryConfidenceChange ()
updateMemoryConfidenceStmt =
  preparable
    "UPDATE kioku_memories SET confidence = $3, updated_at = $4 WHERE memory_space_id = $1 AND memory_id = $2"
    ( ((\c -> c.memorySpaceId) >$< memorySpaceParam)
        <> ((\c -> c.memoryId) >$< E.param (E.nonNullable E.text))
        <> ((\c -> c.confidence) >$< E.param (E.nonNullable E.text))
        <> ((\c -> c.updatedAt) >$< E.param (E.nonNullable E.timestamptz))
    )
    D.noResult
