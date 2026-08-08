-- | The @kioku.sessions@ and @kioku.turns@ projections and every query over them.
--
-- A session belongs to the memory space it was started in, and a turn belongs to its session's
-- space. Both columns are written by the projection from the event payload rather than looked
-- up, and every query below filters on the space as well as on whatever it is keyed by.
module Kioku.Session.ReadModel
  ( sessionInlineProjection,
    SessionRow (..),
    TurnRow (..),
    SessionByIdQuery (..),
    SessionsByNamespaceQuery (..),
    SessionsByScopeQuery (..),
    SessionsByFocusQuery (..),
    SessionsByStartedRangeQuery (..),
    SessionChainQuery (..),
    SessionDelegationChildrenQuery (..),
    AwaitingSessionsByCorrelationKeyQuery (..),
    TurnsBySessionQuery (..),
    sessionByIdReadModel,
    sessionsByNamespaceReadModel,
    sessionsByScopeReadModel,
    sessionsByFocusReadModel,
    sessionsByStartedRangeReadModel,
    sessionChainReadModel,
    sessionDelegationChildrenReadModel,
    awaitingSessionsByCorrelationKeyReadModel,
    turnsBySessionReadModel,
  )
where

import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32)
import Data.Text qualified as Text
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Projection (InlineProjection (..))
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..), StrongScope (..))
import Kioku.Api.Access (MemorySpaceId)
import Kioku.Api.Scope (scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Database.Schema
  ( kiokuSchema,
    sessionsRelation,
    sessionsTable,
    turnsRelation,
    turnsTable,
  )
import Kioku.Id (idText)
import Kioku.Partition (memorySpaceColumn, memorySpaceParam)
import Kioku.Prelude
import Kioku.Session.Domain
import Kiroku.Store.Types (RecordedEvent)

data SessionRow = SessionRow
  { memorySpaceId :: !MemorySpaceId,
    sessionId :: !Text,
    agentId :: !Text,
    focus :: !Text,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text),
    subjectRef :: !(Maybe Text),
    previousSessionId :: !(Maybe Text),
    parentSessionId :: !(Maybe Text),
    delegationDepth :: !Int,
    status :: !Text,
    startedAt :: !UTCTime,
    completedAt :: !(Maybe UTCTime),
    modelUsed :: !(Maybe Text),
    summary :: !(Maybe Text),
    errorMessage :: !(Maybe Text),
    awaitingReason :: !(Maybe Text),
    awaitingCorrelationKey :: !(Maybe Text),
    awaitingDeadline :: !(Maybe UTCTime),
    resumeInput :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data TurnRow = TurnRow
  { memorySpaceId :: !MemorySpaceId,
    turnId :: !Text,
    sessionId :: !Text,
    turnIndex :: !Int,
    role :: !Text,
    content :: !Text,
    toolSummary :: !(Maybe Text),
    promptTokens :: !(Maybe Int),
    outputTokens :: !(Maybe Int),
    recordedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data SessionByIdQuery = SessionByIdQuery
  { memorySpaceId :: !MemorySpaceId,
    sessionId :: !Text
  }

data SessionsByNamespaceQuery = SessionsByNamespaceQuery
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    limit :: !Int
  }

data SessionsByScopeQuery = SessionsByScopeQuery
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text)
  }

data SessionsByFocusQuery = SessionsByFocusQuery
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    focus :: !Text
  }

data SessionsByStartedRangeQuery = SessionsByStartedRangeQuery
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    startedAfter :: !UTCTime,
    startedBefore :: !UTCTime
  }

data SessionChainQuery = SessionChainQuery
  { memorySpaceId :: !MemorySpaceId,
    sessionId :: !Text
  }

data SessionDelegationChildrenQuery = SessionDelegationChildrenQuery
  { memorySpaceId :: !MemorySpaceId,
    parentSessionId :: !Text
  }

data AwaitingSessionsByCorrelationKeyQuery = AwaitingSessionsByCorrelationKeyQuery
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    correlationKey :: !Text
  }

data TurnsBySessionQuery = TurnsBySessionQuery
  { memorySpaceId :: !MemorySpaceId,
    sessionId :: !Text
  }

sessionInlineProjection :: InlineProjection SessionEvent
sessionInlineProjection =
  InlineProjection
    { name = "kioku-session-inline",
      apply = applySessionEvent
    }

applySessionEvent :: SessionEvent -> RecordedEvent -> Tx.Transaction ()
applySessionEvent event _recorded =
  case event of
    SessionStarted d -> Tx.statement (startedRow d) upsertSessionStmt
    InteractiveSessionRecorded d -> Tx.statement (interactiveRow d) upsertSessionStmt
    SessionCompleted d ->
      Tx.statement
        SessionCompletion
          { memorySpaceId = d.memorySpaceId,
            sessionId = idText d.sessionId,
            completedAt = d.completedAt,
            modelUsed = d.modelUsed,
            summary = d.summary
          }
        updateSessionCompletedStmt
    SessionFailed d ->
      Tx.statement
        SessionFailure
          { memorySpaceId = d.memorySpaceId,
            sessionId = idText d.sessionId,
            failedAt = d.failedAt,
            errorMessage = d.errorMessage
          }
        updateSessionFailedStmt
    SessionAwaiting d ->
      Tx.statement
        SessionPark
          { memorySpaceId = d.memorySpaceId,
            sessionId = idText d.sessionId,
            reason = d.reason,
            correlationKey = d.correlationKey,
            deadline = d.deadline
          }
        updateSessionAwaitingStmt
    SessionResumed d ->
      Tx.statement
        SessionResumption
          { memorySpaceId = d.memorySpaceId,
            sessionId = idText d.sessionId,
            input = d.input
          }
        updateSessionResumedStmt
    TurnRecorded d -> Tx.statement (turnRow d) insertTurnStmt

-- | The parameters of each lifecycle update, as records rather than tuples, so that the
-- partition is named at every call site instead of being the first of five positional
-- arguments.
data SessionCompletion = SessionCompletion
  { memorySpaceId :: !MemorySpaceId,
    sessionId :: !Text,
    completedAt :: !UTCTime,
    modelUsed :: !(Maybe Text),
    summary :: !(Maybe Text)
  }

data SessionFailure = SessionFailure
  { memorySpaceId :: !MemorySpaceId,
    sessionId :: !Text,
    failedAt :: !UTCTime,
    errorMessage :: !Text
  }

data SessionPark = SessionPark
  { memorySpaceId :: !MemorySpaceId,
    sessionId :: !Text,
    reason :: !Text,
    correlationKey :: !(Maybe Text),
    deadline :: !(Maybe UTCTime)
  }

data SessionResumption = SessionResumption
  { memorySpaceId :: !MemorySpaceId,
    sessionId :: !Text,
    input :: !Text
  }

startedRow :: SessionStartedData -> SessionRow
startedRow d =
  SessionRow
    { memorySpaceId = d.memorySpaceId,
      sessionId = idText d.sessionId,
      agentId = d.agentId,
      focus = d.focus,
      namespace = scopeNamespaceText d.scope,
      scopeKind = scopeKindText d.scope,
      scopeRef = scopeRefText d.scope,
      subjectRef = d.subjectRef,
      previousSessionId = idText <$> d.previousSessionId,
      parentSessionId = idText <$> d.parentSessionId,
      delegationDepth = d.delegationDepth,
      status = "running",
      startedAt = d.startedAt,
      completedAt = Nothing,
      modelUsed = Nothing,
      summary = Nothing,
      errorMessage = Nothing,
      awaitingReason = Nothing,
      awaitingCorrelationKey = Nothing,
      awaitingDeadline = Nothing,
      resumeInput = Nothing
    }

interactiveRow :: InteractiveSessionRecordedData -> SessionRow
interactiveRow d =
  SessionRow
    { memorySpaceId = d.memorySpaceId,
      sessionId = idText d.sessionId,
      agentId = d.agentId,
      focus = d.focus,
      namespace = scopeNamespaceText d.scope,
      scopeKind = scopeKindText d.scope,
      scopeRef = scopeRefText d.scope,
      subjectRef = d.subjectRef,
      previousSessionId = Nothing,
      parentSessionId = Nothing,
      delegationDepth = 0,
      status = "interactive",
      startedAt = d.startedAt,
      completedAt = Nothing,
      modelUsed = Nothing,
      summary = Nothing,
      errorMessage = Nothing,
      awaitingReason = Nothing,
      awaitingCorrelationKey = Nothing,
      awaitingDeadline = Nothing,
      resumeInput = Nothing
    }

turnRow :: TurnRecordedData -> TurnRow
turnRow d =
  TurnRow
    { memorySpaceId = d.memorySpaceId,
      turnId = d.turnId,
      sessionId = idText d.sessionId,
      turnIndex = d.turnIndex,
      role = d.role,
      content = d.content,
      toolSummary = d.toolSummary,
      promptTokens = d.promptTokens,
      outputTokens = d.outputTokens,
      recordedAt = d.recordedAt
    }

sessionByIdReadModel :: ReadModel SessionByIdQuery (Maybe SessionRow)
sessionByIdReadModel =
  ReadModel
    { name = "kioku-session-by-id",
      schema = kiokuSchema,
      tableName = sessionsRelation,
      subscriptionName = "kioku-session-inline",
      version = sessionReadModelVersion,
      shapeHash = sessionReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectSessionByIdStmt
    }

sessionsByNamespaceReadModel :: ReadModel SessionsByNamespaceQuery [SessionRow]
sessionsByNamespaceReadModel =
  ReadModel
    { name = "kioku-sessions-by-namespace",
      schema = kiokuSchema,
      tableName = sessionsRelation,
      subscriptionName = "kioku-session-inline",
      version = sessionReadModelVersion,
      shapeHash = sessionReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectSessionsByNamespaceStmt
    }

sessionsByScopeReadModel :: ReadModel SessionsByScopeQuery [SessionRow]
sessionsByScopeReadModel =
  ReadModel
    { name = "kioku-sessions-by-scope",
      schema = kiokuSchema,
      tableName = sessionsRelation,
      subscriptionName = "kioku-session-inline",
      version = sessionReadModelVersion,
      shapeHash = sessionReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectSessionsByScopeStmt
    }

sessionsByFocusReadModel :: ReadModel SessionsByFocusQuery [SessionRow]
sessionsByFocusReadModel =
  ReadModel
    { name = "kioku-sessions-by-focus",
      schema = kiokuSchema,
      tableName = sessionsRelation,
      subscriptionName = "kioku-session-inline",
      version = sessionReadModelVersion,
      shapeHash = sessionReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectSessionsByFocusStmt
    }

sessionsByStartedRangeReadModel :: ReadModel SessionsByStartedRangeQuery [SessionRow]
sessionsByStartedRangeReadModel =
  ReadModel
    { name = "kioku-sessions-by-started-range",
      schema = kiokuSchema,
      tableName = sessionsRelation,
      subscriptionName = "kioku-session-inline",
      version = sessionReadModelVersion,
      shapeHash = sessionReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectSessionsByStartedRangeStmt
    }

sessionChainReadModel :: ReadModel SessionChainQuery [SessionRow]
sessionChainReadModel =
  ReadModel
    { name = "kioku-session-chain",
      schema = kiokuSchema,
      tableName = sessionsRelation,
      subscriptionName = "kioku-session-inline",
      version = sessionReadModelVersion,
      shapeHash = sessionReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectSessionChainStmt
    }

sessionDelegationChildrenReadModel :: ReadModel SessionDelegationChildrenQuery [SessionRow]
sessionDelegationChildrenReadModel =
  ReadModel
    { name = "kioku-session-delegation-children",
      schema = kiokuSchema,
      tableName = sessionsRelation,
      subscriptionName = "kioku-session-inline",
      version = sessionReadModelVersion,
      shapeHash = sessionReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectDelegationChildrenStmt
    }

awaitingSessionsByCorrelationKeyReadModel :: ReadModel AwaitingSessionsByCorrelationKeyQuery [SessionRow]
awaitingSessionsByCorrelationKeyReadModel =
  ReadModel
    { name = "kioku-sessions-awaiting-by-correlation-key",
      schema = kiokuSchema,
      tableName = sessionsRelation,
      subscriptionName = "kioku-session-inline",
      version = sessionReadModelVersion,
      shapeHash = sessionReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectAwaitingByCorrelationKeyStmt
    }

turnsBySessionReadModel :: ReadModel TurnsBySessionQuery [TurnRow]
turnsBySessionReadModel =
  ReadModel
    { name = "kioku-turns-by-session",
      schema = kiokuSchema,
      tableName = turnsRelation,
      subscriptionName = "kioku-session-inline",
      version = turnReadModelVersion,
      shapeHash = turnReadModelShapeHash,
      defaultConsistency = Eventual,
      strongScope = EntireLog,
      query = \q -> Tx.statement q selectTurnsBySessionStmt
    }

-- | The registry identity of every session read model.
--
-- The session model reshaped v1 -> v2 (delegation lineage) -> v3 (awaiting park/resume) -> v4
-- (the memory-space partition) -> v5 (the move from @kiroku.kioku_sessions@ to
-- @kioku.sessions@). Turns followed the same last step, v2 -> v3.
--
-- Each step was a migration that left the table data correct for the newer version, so
-- @Kioku.ReadModel.reconcileReadModelRegistry@ advances the guard rather than rebuilding. The
-- last one is not additive in the usual sense — no column changed, the relation moved — but the
-- version still has to advance, because Keiro's registry records no physical relation name and
-- the version is therefore the only thing that can stop a binary compiled before the move from
-- querying a table that is no longer where it thinks it is.
sessionReadModelVersion :: Int
sessionReadModelVersion = 5

sessionReadModelShapeHash :: Text
sessionReadModelShapeHash = "kioku-session-v5"

turnReadModelVersion :: Int
turnReadModelVersion = 3

turnReadModelShapeHash :: Text
turnReadModelShapeHash = "kioku-turn-v3"

sessionRowDecoder :: D.Row SessionRow
sessionRowDecoder =
  SessionRow
    <$> memorySpaceColumn
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> (fromIntegral @Int32 @Int <$> D.column (D.nonNullable D.int4))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.text)

turnRowDecoder :: D.Row TurnRow
turnRowDecoder =
  TurnRow
    <$> memorySpaceColumn
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> (fromIntegral @Int32 @Int <$> D.column (D.nonNullable D.int4))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> (fmap (fromIntegral @Int32 @Int) <$> D.column (D.nullable D.int4))
    <*> (fmap (fromIntegral @Int32 @Int) <$> D.column (D.nullable D.int4))
    <*> D.column (D.nonNullable D.timestamptz)

-- | The projection 'sessionRowDecoder' expects, in its exact order. The partition comes first,
-- so a reviewer reading any session query sees the space before anything it is keyed by.
sessionRowColumnNames :: [Text]
sessionRowColumnNames =
  [ "memory_space_id",
    "session_id",
    "agent_id",
    "focus",
    "namespace",
    "scope_kind",
    "scope_ref",
    "subject_ref",
    "previous_session_id",
    "parent_session_id",
    "delegation_depth",
    "status",
    "started_at",
    "completed_at",
    "model_used",
    "summary",
    "error_message",
    "awaiting_reason",
    "awaiting_correlation_key",
    "awaiting_deadline",
    "resume_input"
  ]

sessionRowColumns :: Text
sessionRowColumns = Text.intercalate ", " sessionRowColumnNames

qualifiedSessionRowColumns :: Text -> Text
qualifiedSessionRowColumns prefix =
  Text.intercalate ", " ((\column -> prefix <> "." <> column) <$> sessionRowColumnNames)

selectSessionByIdStmt :: Statement SessionByIdQuery (Maybe SessionRow)
selectSessionByIdStmt =
  preparable
    ( "SELECT "
        <> sessionRowColumns
        <> " FROM "
        <> sessionsTable
        <> " WHERE memory_space_id = $1 AND session_id = $2"
    )
    ( ((\q -> q.memorySpaceId) >$< memorySpaceParam)
        <> ((\q -> q.sessionId) >$< E.param (E.nonNullable E.text))
    )
    (D.rowMaybe sessionRowDecoder)

selectSessionsByNamespaceStmt :: Statement SessionsByNamespaceQuery [SessionRow]
selectSessionsByNamespaceStmt =
  preparable
    ( "SELECT "
        <> sessionRowColumns
        <> " FROM "
        <> sessionsTable
        <> " WHERE memory_space_id = $1 AND namespace = $2 ORDER BY started_at DESC LIMIT $3"
    )
    ( ((\q -> q.memorySpaceId) >$< memorySpaceParam)
        <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
        <> ((\q -> fromIntegral @Int @Int32 q.limit) >$< E.param (E.nonNullable E.int4))
    )
    (D.rowList sessionRowDecoder)

selectSessionsByScopeStmt :: Statement SessionsByScopeQuery [SessionRow]
selectSessionsByScopeStmt =
  preparable
    ( "SELECT "
        <> sessionRowColumns
        <> " FROM "
        <> sessionsTable
        <> " WHERE memory_space_id = $1 AND namespace = $2\
           \ AND scope_kind IS NOT DISTINCT FROM $3 AND scope_ref IS NOT DISTINCT FROM $4\
           \ ORDER BY started_at DESC"
    )
    ( ((\q -> q.memorySpaceId) >$< memorySpaceParam)
        <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
        <> ((\q -> q.scopeKind) >$< E.param (E.nullable E.text))
        <> ((\q -> q.scopeRef) >$< E.param (E.nullable E.text))
    )
    (D.rowList sessionRowDecoder)

selectSessionsByFocusStmt :: Statement SessionsByFocusQuery [SessionRow]
selectSessionsByFocusStmt =
  preparable
    ( "SELECT "
        <> sessionRowColumns
        <> " FROM "
        <> sessionsTable
        <> " WHERE memory_space_id = $1 AND namespace = $2 AND focus = $3\
           \ ORDER BY started_at DESC"
    )
    ( ((\q -> q.memorySpaceId) >$< memorySpaceParam)
        <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
        <> ((\q -> q.focus) >$< E.param (E.nonNullable E.text))
    )
    (D.rowList sessionRowDecoder)

selectSessionsByStartedRangeStmt :: Statement SessionsByStartedRangeQuery [SessionRow]
selectSessionsByStartedRangeStmt =
  preparable
    ( "SELECT "
        <> sessionRowColumns
        <> " FROM "
        <> sessionsTable
        <> " WHERE memory_space_id = $1 AND namespace = $2\
           \ AND started_at >= $3 AND started_at < $4 ORDER BY started_at DESC"
    )
    ( ((\q -> q.memorySpaceId) >$< memorySpaceParam)
        <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
        <> ((\q -> q.startedAfter) >$< E.param (E.nonNullable E.timestamptz))
        <> ((\q -> q.startedBefore) >$< E.param (E.nonNullable E.timestamptz))
    )
    (D.rowList sessionRowDecoder)

-- | Walk a session's continuation chain backwards through @previous_session_id@, without
-- leaving the memory space it started in.
--
-- The @path@ array makes revisiting a session impossible, so the walk terminates on any
-- data — including a cycle, which 'Kioku.Session.start' now refuses to create but which
-- unchecked lineage (see @validateLineage@) still permits to be constructed out of order.
-- With a plain @UNION ALL@ and no guard, a cycle loops until timeout or OOM. The depth cap
-- is defense in depth, far above any legitimate chain.
--
-- @previous_session_id@ is a bare id with no foreign key, so the recursive arm carries the
-- space predicate too: without it a chain could be walked out of its space by any id written
-- before the partition existed.
--
-- The final @SELECT@ omits @depth@/@path@, so 'sessionRowDecoder' is unchanged.
selectSessionChainStmt :: Statement SessionChainQuery [SessionRow]
selectSessionChainStmt =
  preparable
    ( "WITH RECURSIVE chain AS ("
        <> "SELECT "
        <> sessionRowColumns
        <> ", 1 AS depth, ARRAY[session_id] AS path"
        <> " FROM "
        <> sessionsTable
        <> " WHERE memory_space_id = $1 AND session_id = $2"
        <> " UNION ALL "
        <> "SELECT "
        <> qualifiedSessionRowColumns "s"
        <> ", c.depth + 1, c.path || s.session_id"
        <> " FROM "
        <> sessionsTable
        <> " s INNER JOIN chain c"
        <> " ON s.session_id = c.previous_session_id AND s.memory_space_id = c.memory_space_id"
        <> " WHERE NOT s.session_id = ANY (c.path) AND c.depth < 10000"
        <> ") SELECT "
        <> sessionRowColumns
        <> " FROM chain ORDER BY started_at ASC"
    )
    ( ((\q -> q.memorySpaceId) >$< memorySpaceParam)
        <> ((\q -> q.sessionId) >$< E.param (E.nonNullable E.text))
    )
    (D.rowList sessionRowDecoder)

selectDelegationChildrenStmt :: Statement SessionDelegationChildrenQuery [SessionRow]
selectDelegationChildrenStmt =
  preparable
    ( "SELECT "
        <> sessionRowColumns
        <> " FROM "
        <> sessionsTable
        <> " WHERE memory_space_id = $1 AND parent_session_id = $2\
           \ ORDER BY started_at ASC, session_id ASC"
    )
    ( ((\q -> q.memorySpaceId) >$< memorySpaceParam)
        <> ((\q -> q.parentSessionId) >$< E.param (E.nonNullable E.text))
    )
    (D.rowList sessionRowDecoder)

selectAwaitingByCorrelationKeyStmt :: Statement AwaitingSessionsByCorrelationKeyQuery [SessionRow]
selectAwaitingByCorrelationKeyStmt =
  preparable
    ( "SELECT "
        <> sessionRowColumns
        <> " FROM "
        <> sessionsTable
        <> " WHERE memory_space_id = $1 AND namespace = $2\
           \ AND status = 'awaiting' AND awaiting_correlation_key = $3 ORDER BY started_at DESC"
    )
    ( ((\q -> q.memorySpaceId) >$< memorySpaceParam)
        <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
        <> ((\q -> q.correlationKey) >$< E.param (E.nonNullable E.text))
    )
    (D.rowList sessionRowDecoder)

selectTurnsBySessionStmt :: Statement TurnsBySessionQuery [TurnRow]
selectTurnsBySessionStmt =
  preparable
    ( """
      SELECT memory_space_id, turn_id, session_id, turn_index, role, content, tool_summary,
             prompt_tokens, output_tokens, recorded_at
      FROM
      """
        <> " "
        <> turnsTable
        <> " "
        <> """
           WHERE memory_space_id = $1
             AND session_id = $2
           ORDER BY turn_index ASC
           """
    )
    ( ((\q -> q.memorySpaceId) >$< memorySpaceParam)
        <> ((\q -> q.sessionId) >$< E.param (E.nonNullable E.text))
    )
    (D.rowList turnRowDecoder)

upsertSessionStmt :: Statement SessionRow ()
upsertSessionStmt =
  preparable
    ( "INSERT INTO "
        <> sessionsTable
        <> "\n"
        <> """
             (memory_space_id, session_id, agent_id, focus, namespace, scope_kind, scope_ref,
              subject_ref, previous_session_id, parent_session_id, delegation_depth, status, started_at,
              completed_at, model_used, summary, error_message,
              awaiting_reason, awaiting_correlation_key, awaiting_deadline, resume_input, updated_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15, $16, $17, $18, $19, $20, $21, NOW())
           ON CONFLICT (session_id) DO UPDATE SET
             memory_space_id = EXCLUDED.memory_space_id,
             agent_id = EXCLUDED.agent_id,
             focus = EXCLUDED.focus,
             namespace = EXCLUDED.namespace,
             scope_kind = EXCLUDED.scope_kind,
             scope_ref = EXCLUDED.scope_ref,
             subject_ref = EXCLUDED.subject_ref,
             previous_session_id = EXCLUDED.previous_session_id,
             parent_session_id = EXCLUDED.parent_session_id,
             delegation_depth = EXCLUDED.delegation_depth,
             status = EXCLUDED.status,
             started_at = EXCLUDED.started_at,
             completed_at = EXCLUDED.completed_at,
             model_used = EXCLUDED.model_used,
             summary = EXCLUDED.summary,
             error_message = EXCLUDED.error_message,
             awaiting_reason = EXCLUDED.awaiting_reason,
             awaiting_correlation_key = EXCLUDED.awaiting_correlation_key,
             awaiting_deadline = EXCLUDED.awaiting_deadline,
             resume_input = EXCLUDED.resume_input,
             updated_at = EXCLUDED.updated_at
           """
    )
    sessionRowEncoder
    D.noResult

sessionRowEncoder :: E.Params SessionRow
sessionRowEncoder =
  ((\row -> row.memorySpaceId) >$< memorySpaceParam)
    <> ((\row -> row.sessionId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.agentId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.focus) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\row -> row.scopeRef) >$< E.param (E.nullable E.text))
    <> ((\row -> row.subjectRef) >$< E.param (E.nullable E.text))
    <> ((\row -> row.previousSessionId) >$< E.param (E.nullable E.text))
    <> ((\row -> row.parentSessionId) >$< E.param (E.nullable E.text))
    <> ((\row -> fromIntegral @Int @Int32 row.delegationDepth) >$< E.param (E.nonNullable E.int4))
    <> ((\row -> row.status) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.startedAt) >$< E.param (E.nonNullable E.timestamptz))
    <> ((\row -> row.completedAt) >$< E.param (E.nullable E.timestamptz))
    <> ((\row -> row.modelUsed) >$< E.param (E.nullable E.text))
    <> ((\row -> row.summary) >$< E.param (E.nullable E.text))
    <> ((\row -> row.errorMessage) >$< E.param (E.nullable E.text))
    <> ((\row -> row.awaitingReason) >$< E.param (E.nullable E.text))
    <> ((\row -> row.awaitingCorrelationKey) >$< E.param (E.nullable E.text))
    <> ((\row -> row.awaitingDeadline) >$< E.param (E.nullable E.timestamptz))
    <> ((\row -> row.resumeInput) >$< E.param (E.nullable E.text))

updateSessionCompletedStmt :: Statement SessionCompletion ()
updateSessionCompletedStmt =
  preparable
    ("UPDATE " <> sessionsTable <> " SET status = 'completed', completed_at = $3, model_used = $4, summary = $5, awaiting_reason = NULL, awaiting_correlation_key = NULL, awaiting_deadline = NULL, updated_at = NOW() WHERE memory_space_id = $1 AND session_id = $2")
    ( ((\c -> c.memorySpaceId) >$< memorySpaceParam)
        <> ((\c -> c.sessionId) >$< E.param (E.nonNullable E.text))
        <> ((\c -> c.completedAt) >$< E.param (E.nonNullable E.timestamptz))
        <> ((\c -> c.modelUsed) >$< E.param (E.nullable E.text))
        <> ((\c -> c.summary) >$< E.param (E.nullable E.text))
    )
    D.noResult

updateSessionFailedStmt :: Statement SessionFailure ()
updateSessionFailedStmt =
  preparable
    ("UPDATE " <> sessionsTable <> " SET status = 'failed', completed_at = $3, error_message = $4, awaiting_reason = NULL, awaiting_correlation_key = NULL, awaiting_deadline = NULL, updated_at = NOW() WHERE memory_space_id = $1 AND session_id = $2")
    ( ((\c -> c.memorySpaceId) >$< memorySpaceParam)
        <> ((\c -> c.sessionId) >$< E.param (E.nonNullable E.text))
        <> ((\c -> c.failedAt) >$< E.param (E.nonNullable E.timestamptz))
        <> ((\c -> c.errorMessage) >$< E.param (E.nonNullable E.text))
    )
    D.noResult

-- | Park the session. @resume_input@ is cleared so a re-park does not leave the previous
-- wait's answer visible on the row.
--
-- @awaiting_deadline@ is advisory only: it is stored for hosts, and kioku does not enforce
-- it (no timer fires, nothing expires). See MasterPlan 2's Decision Log (2026-07-07).
updateSessionAwaitingStmt :: Statement SessionPark ()
updateSessionAwaitingStmt =
  preparable
    ("UPDATE " <> sessionsTable <> " SET status = 'awaiting', awaiting_reason = $3, awaiting_correlation_key = $4, awaiting_deadline = $5, resume_input = NULL, updated_at = NOW() WHERE memory_space_id = $1 AND session_id = $2")
    ( ((\c -> c.memorySpaceId) >$< memorySpaceParam)
        <> ((\c -> c.sessionId) >$< E.param (E.nonNullable E.text))
        <> ((\c -> c.reason) >$< E.param (E.nonNullable E.text))
        <> ((\c -> c.correlationKey) >$< E.param (E.nullable E.text))
        <> ((\c -> c.deadline) >$< E.param (E.nullable E.timestamptz))
    )
    D.noResult

updateSessionResumedStmt :: Statement SessionResumption ()
updateSessionResumedStmt =
  preparable
    ("UPDATE " <> sessionsTable <> " SET status = 'running', resume_input = $3, awaiting_reason = NULL, awaiting_correlation_key = NULL, awaiting_deadline = NULL, updated_at = NOW() WHERE memory_space_id = $1 AND session_id = $2")
    ( ((\c -> c.memorySpaceId) >$< memorySpaceParam)
        <> ((\c -> c.sessionId) >$< E.param (E.nonNullable E.text))
        <> ((\c -> c.input) >$< E.param (E.nonNullable E.text))
    )
    D.noResult

-- | @(session_id, turn_index)@ is the turn's identity; @turn_id@ is an idempotency token
-- that travels with it. The conflict clause updates @turn_id@ as well, so rebuilding the
-- projection from the event stream cannot leave a superseded turn's id attached to the
-- winning event's content.
--
-- The conflict target stays @(session_id, turn_index)@ rather than gaining the space. A
-- session id is globally unique and the aggregate pins each session to exactly one space, so
-- two spaces cannot produce the same pair; widening the key would /weaken/ it by letting one
-- session's turn index be written twice.
insertTurnStmt :: Statement TurnRow ()
insertTurnStmt =
  preparable
    ( "INSERT INTO "
        <> turnsTable
        <> "\n"
        <> """
             (memory_space_id, turn_id, session_id, turn_index, role, content, tool_summary,
              prompt_tokens, output_tokens, recorded_at)
           VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
           ON CONFLICT (session_id, turn_index) DO UPDATE SET
             memory_space_id = EXCLUDED.memory_space_id,
             turn_id = EXCLUDED.turn_id,
             role = EXCLUDED.role,
             content = EXCLUDED.content,
             tool_summary = EXCLUDED.tool_summary,
             prompt_tokens = EXCLUDED.prompt_tokens,
             output_tokens = EXCLUDED.output_tokens,
             recorded_at = EXCLUDED.recorded_at
           """
    )
    turnRowEncoder
    D.noResult

turnRowEncoder :: E.Params TurnRow
turnRowEncoder =
  ((\row -> row.memorySpaceId) >$< memorySpaceParam)
    <> ((\row -> row.turnId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.sessionId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> fromIntegral @Int @Int32 row.turnIndex) >$< E.param (E.nonNullable E.int4))
    <> ((\row -> row.role) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.content) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.toolSummary) >$< E.param (E.nullable E.text))
    <> ((\row -> fmap (fromIntegral @Int @Int32) row.promptTokens) >$< E.param (E.nullable E.int4))
    <> ((\row -> fmap (fromIntegral @Int @Int32) row.outputTokens) >$< E.param (E.nullable E.int4))
    <> ((\row -> row.recordedAt) >$< E.param (E.nonNullable E.timestamptz))
