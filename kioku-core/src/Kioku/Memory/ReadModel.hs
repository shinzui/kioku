module Kioku.Memory.ReadModel
  ( memoryInlineProjection,
    MemoryRow (..),
    MemoryByIdQuery (..),
    MemoriesByNamespaceQuery (..),
    MemoriesByScopeQuery (..),
    MemoriesBySessionQuery (..),
    MemoriesByTypeQuery (..),
    memoryByIdReadModel,
    memoriesByNamespaceReadModel,
    memoriesByScopeReadModel,
    memoriesBySessionReadModel,
    memoriesByTypeReadModel,
  )
where

import Contravariant.Extras (contrazip2, contrazip3)
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
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..))
import Kioku.Api.Scope (scopeFromColumns, scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (MemoryRecord (..), confidenceToText, memoryTypeToText)
import Kioku.Id (idText)
import Kioku.Memory.Domain
import Kioku.Prelude
import Kiroku.Store.Types (RecordedEvent)

data MemoryRow = MemoryRow
  { memoryId :: !Text,
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

newtype MemoryByIdQuery = MemoryByIdQuery Text

newtype MemoriesByNamespaceQuery = MemoriesByNamespaceQuery Text

data MemoriesByScopeQuery = MemoriesByScopeQuery Text (Maybe Text) (Maybe Text)

newtype MemoriesBySessionQuery = MemoriesBySessionQuery Text

data MemoriesByTypeQuery = MemoriesByTypeQuery Text Text

memoryInlineProjection :: InlineProjection MemoryEvent
memoryInlineProjection =
  InlineProjection
    { name = "kioku-memory-inline",
      apply = applyMemoryEvent
    }

applyMemoryEvent :: MemoryEvent -> RecordedEvent -> Tx.Transaction ()
applyMemoryEvent event _recorded =
  case event of
    MemoryRecorded d -> Tx.statement (recordedRow d) upsertMemoryStmt
    MemorySuperseded d ->
      Tx.statement
        (idText d.memoryId, idText d.supersededBy, d.supersededAt)
        updateMemorySupersededStmt
    MemoryArchived d ->
      Tx.statement (idText d.memoryId, d.archivedAt) updateMemoryArchivedStmt
    MemoryTagsUpdated d ->
      Tx.statement (idText d.memoryId, d.tags, d.updatedAt) updateMemoryTagsStmt
    MemoryConfidenceUpdated d ->
      Tx.statement (idText d.memoryId, confidenceToText d.confidence, d.updatedAt) updateMemoryConfidenceStmt
    MemoryMerged d ->
      Tx.statement (idText d.memoryId, idText d.mergedInto, d.mergedAt) updateMemoryMergedStmt

recordedRow :: MemoryRecordedData -> MemoryRow
recordedRow d =
  MemoryRow
    { memoryId = idText d.memoryId,
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
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = 1,
      shapeHash = "kioku-memory-v1",
      defaultConsistency = Eventual,
      query = \(MemoryByIdQuery mid) -> Tx.statement mid selectMemoryByIdStmt
    }

memoriesByNamespaceReadModel :: ReadModel MemoriesByNamespaceQuery [MemoryRecord]
memoriesByNamespaceReadModel =
  ReadModel
    { name = "kioku-memories-by-namespace",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = 1,
      shapeHash = "kioku-memory-v1",
      defaultConsistency = Eventual,
      query = \(MemoriesByNamespaceQuery ns) -> Tx.statement ns selectActiveByNamespaceStmt
    }

memoriesByScopeReadModel :: ReadModel MemoriesByScopeQuery [MemoryRecord]
memoriesByScopeReadModel =
  ReadModel
    { name = "kioku-memories-by-scope",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = 1,
      shapeHash = "kioku-memory-v1",
      defaultConsistency = Eventual,
      query = \(MemoriesByScopeQuery ns sk sr) -> Tx.statement (ns, sk, sr) selectActiveByScopeStmt
    }

memoriesBySessionReadModel :: ReadModel MemoriesBySessionQuery [MemoryRecord]
memoriesBySessionReadModel =
  ReadModel
    { name = "kioku-memories-by-session",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = 1,
      shapeHash = "kioku-memory-v1",
      defaultConsistency = Eventual,
      query = \(MemoriesBySessionQuery sid) -> Tx.statement sid selectBySessionStmt
    }

memoriesByTypeReadModel :: ReadModel MemoriesByTypeQuery [MemoryRecord]
memoriesByTypeReadModel =
  ReadModel
    { name = "kioku-memories-by-type",
      tableName = "kioku_memories",
      subscriptionName = "kioku-memory-inline",
      version = 1,
      shapeHash = "kioku-memory-v1",
      defaultConsistency = Eventual,
      query = \(MemoriesByTypeQuery ns mt) -> Tx.statement (ns, mt) selectByTypeStmt
    }

memoryRowDecoder :: D.Row MemoryRow
memoryRowDecoder =
  MemoryRow
    <$> D.column (D.nonNullable D.text)
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
  "memory_id, agent_id, session_id, namespace, scope_kind, scope_ref, memory_type, content, priority, confidence, tags::text, status, superseded_by, supersedes, created_at, updated_at"

selectMemoryByIdStmt :: Statement Text (Maybe MemoryRow)
selectMemoryByIdStmt =
  preparable
    ( "SELECT "
        <> memoryRowColumns
        <> " FROM kioku_memories WHERE memory_id = $1"
    )
    (E.param (E.nonNullable E.text))
    (D.rowMaybe memoryRowDecoder)

selectActiveByNamespaceStmt :: Statement Text [MemoryRecord]
selectActiveByNamespaceStmt =
  preparable
    ( "SELECT "
        <> memoryRowColumns
        <> " FROM kioku_memories WHERE status = 'active' AND namespace = $1 ORDER BY created_at DESC"
    )
    (E.param (E.nonNullable E.text))
    (D.rowList memoryRecordDecoder)

selectActiveByScopeStmt :: Statement (Text, Maybe Text, Maybe Text) [MemoryRecord]
selectActiveByScopeStmt =
  preparable
    ( "SELECT "
        <> memoryRowColumns
        <> " FROM kioku_memories WHERE status = 'active' AND namespace = $1 AND ((scope_kind = $2 AND scope_ref = $3) OR ($2 IS NULL AND scope_kind IS NULL AND $3 IS NULL AND scope_ref IS NULL)) ORDER BY priority ASC, created_at DESC"
    )
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.text))
    )
    (D.rowList memoryRecordDecoder)

selectBySessionStmt :: Statement Text [MemoryRecord]
selectBySessionStmt =
  preparable
    ( "SELECT "
        <> memoryRowColumns
        <> " FROM kioku_memories WHERE session_id = $1 ORDER BY created_at DESC"
    )
    (E.param (E.nonNullable E.text))
    (D.rowList memoryRecordDecoder)

selectByTypeStmt :: Statement (Text, Text) [MemoryRecord]
selectByTypeStmt =
  preparable
    ( "SELECT "
        <> memoryRowColumns
        <> " FROM kioku_memories WHERE status = 'active' AND namespace = $1 AND memory_type = $2 ORDER BY priority ASC, created_at DESC"
    )
    ( contrazip2
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
    )
    (D.rowList memoryRecordDecoder)

upsertMemoryStmt :: Statement MemoryRow ()
upsertMemoryStmt =
  preparable
    """
    INSERT INTO kioku_memories
      (memory_id, agent_id, session_id, namespace, scope_kind, scope_ref, memory_type, content,
       priority, confidence, tags, status, superseded_by, supersedes, created_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11::jsonb, $12, $13, $14, $15, $16)
    ON CONFLICT (memory_id) DO UPDATE SET
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
  ((\row -> row.memoryId) >$< E.param (E.nonNullable E.text))
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

updateMemorySupersededStmt :: Statement (Text, Text, UTCTime) ()
updateMemorySupersededStmt =
  preparable
    "UPDATE kioku_memories SET status = 'superseded', superseded_by = $2, updated_at = $3 WHERE memory_id = $1"
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

updateMemoryArchivedStmt :: Statement (Text, UTCTime) ()
updateMemoryArchivedStmt =
  preparable
    "UPDATE kioku_memories SET status = 'archived', updated_at = $2 WHERE memory_id = $1"
    (contrazip2 (E.param (E.nonNullable E.text)) (E.param (E.nonNullable E.timestamptz)))
    D.noResult

updateMemoryTagsStmt :: Statement (Text, Set Text, UTCTime) ()
updateMemoryTagsStmt =
  preparable
    "UPDATE kioku_memories SET tags = $2::jsonb, updated_at = $3 WHERE memory_id = $1"
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (encodeTags >$< E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

updateMemoryConfidenceStmt :: Statement (Text, Text, UTCTime) ()
updateMemoryConfidenceStmt =
  preparable
    "UPDATE kioku_memories SET confidence = $2, updated_at = $3 WHERE memory_id = $1"
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult

updateMemoryMergedStmt :: Statement (Text, Text, UTCTime) ()
updateMemoryMergedStmt =
  preparable
    "UPDATE kioku_memories SET status = 'merged', superseded_by = $2, updated_at = $3 WHERE memory_id = $1"
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
    )
    D.noResult
