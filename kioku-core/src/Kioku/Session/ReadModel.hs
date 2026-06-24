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
    TurnsBySessionQuery (..),
    sessionByIdReadModel,
    sessionsByNamespaceReadModel,
    sessionsByScopeReadModel,
    sessionsByFocusReadModel,
    sessionsByStartedRangeReadModel,
    sessionChainReadModel,
    turnsBySessionReadModel,
  )
where

import Contravariant.Extras (contrazip3, contrazip4)
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Projection (InlineProjection (..))
import Keiro.ReadModel (ConsistencyMode (..), ReadModel (..))
import Kioku.Api.Scope (scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Id (idText)
import Kioku.Prelude
import Kioku.Session.Domain
import Kiroku.Store.Types (RecordedEvent)

data SessionRow = SessionRow
  { sessionId :: !Text,
    agentId :: !Text,
    focus :: !Text,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text),
    subjectRef :: !(Maybe Text),
    previousSessionId :: !(Maybe Text),
    status :: !Text,
    startedAt :: !UTCTime,
    completedAt :: !(Maybe UTCTime),
    modelUsed :: !(Maybe Text),
    summary :: !(Maybe Text),
    errorMessage :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data TurnRow = TurnRow
  { turnId :: !Text,
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

newtype SessionByIdQuery = SessionByIdQuery Text

data SessionsByNamespaceQuery = SessionsByNamespaceQuery Text Int

data SessionsByScopeQuery = SessionsByScopeQuery Text (Maybe Text) (Maybe Text)

data SessionsByFocusQuery = SessionsByFocusQuery Text Text

data SessionsByStartedRangeQuery = SessionsByStartedRangeQuery Text UTCTime UTCTime

newtype SessionChainQuery = SessionChainQuery Text

newtype TurnsBySessionQuery = TurnsBySessionQuery Text

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
        (idText d.sessionId, d.completedAt, d.modelUsed, d.summary)
        updateSessionCompletedStmt
    SessionFailed d ->
      Tx.statement
        (idText d.sessionId, d.failedAt, d.errorMessage)
        updateSessionFailedStmt
    TurnRecorded d -> Tx.statement (turnRow d) insertTurnStmt

startedRow :: SessionStartedData -> SessionRow
startedRow d =
  SessionRow
    { sessionId = idText d.sessionId,
      agentId = d.agentId,
      focus = d.focus,
      namespace = scopeNamespaceText d.scope,
      scopeKind = scopeKindText d.scope,
      scopeRef = scopeRefText d.scope,
      subjectRef = d.subjectRef,
      previousSessionId = idText <$> d.previousSessionId,
      status = "running",
      startedAt = d.startedAt,
      completedAt = Nothing,
      modelUsed = Nothing,
      summary = Nothing,
      errorMessage = Nothing
    }

interactiveRow :: InteractiveSessionRecordedData -> SessionRow
interactiveRow d =
  SessionRow
    { sessionId = idText d.sessionId,
      agentId = d.agentId,
      focus = d.focus,
      namespace = scopeNamespaceText d.scope,
      scopeKind = scopeKindText d.scope,
      scopeRef = scopeRefText d.scope,
      subjectRef = d.subjectRef,
      previousSessionId = Nothing,
      status = "interactive",
      startedAt = d.startedAt,
      completedAt = Nothing,
      modelUsed = Nothing,
      summary = Nothing,
      errorMessage = Nothing
    }

turnRow :: TurnRecordedData -> TurnRow
turnRow d =
  TurnRow
    { turnId = d.turnId,
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
      tableName = "kioku_sessions",
      subscriptionName = "kioku-session-inline",
      version = 1,
      shapeHash = "kioku-session-v1",
      defaultConsistency = Eventual,
      query = \(SessionByIdQuery sid) -> Tx.statement sid selectSessionByIdStmt
    }

sessionsByNamespaceReadModel :: ReadModel SessionsByNamespaceQuery [SessionRow]
sessionsByNamespaceReadModel =
  ReadModel
    { name = "kioku-sessions-by-namespace",
      tableName = "kioku_sessions",
      subscriptionName = "kioku-session-inline",
      version = 1,
      shapeHash = "kioku-session-v1",
      defaultConsistency = Eventual,
      query = \q -> Tx.statement q selectSessionsByNamespaceStmt
    }

sessionsByScopeReadModel :: ReadModel SessionsByScopeQuery [SessionRow]
sessionsByScopeReadModel =
  ReadModel
    { name = "kioku-sessions-by-scope",
      tableName = "kioku_sessions",
      subscriptionName = "kioku-session-inline",
      version = 1,
      shapeHash = "kioku-session-v1",
      defaultConsistency = Eventual,
      query = \q -> Tx.statement q selectSessionsByScopeStmt
    }

sessionsByFocusReadModel :: ReadModel SessionsByFocusQuery [SessionRow]
sessionsByFocusReadModel =
  ReadModel
    { name = "kioku-sessions-by-focus",
      tableName = "kioku_sessions",
      subscriptionName = "kioku-session-inline",
      version = 1,
      shapeHash = "kioku-session-v1",
      defaultConsistency = Eventual,
      query = \q -> Tx.statement q selectSessionsByFocusStmt
    }

sessionsByStartedRangeReadModel :: ReadModel SessionsByStartedRangeQuery [SessionRow]
sessionsByStartedRangeReadModel =
  ReadModel
    { name = "kioku-sessions-by-started-range",
      tableName = "kioku_sessions",
      subscriptionName = "kioku-session-inline",
      version = 1,
      shapeHash = "kioku-session-v1",
      defaultConsistency = Eventual,
      query = \q -> Tx.statement q selectSessionsByStartedRangeStmt
    }

sessionChainReadModel :: ReadModel SessionChainQuery [SessionRow]
sessionChainReadModel =
  ReadModel
    { name = "kioku-session-chain",
      tableName = "kioku_sessions",
      subscriptionName = "kioku-session-inline",
      version = 1,
      shapeHash = "kioku-session-v1",
      defaultConsistency = Eventual,
      query = \(SessionChainQuery sid) -> Tx.statement sid selectSessionChainStmt
    }

turnsBySessionReadModel :: ReadModel TurnsBySessionQuery [TurnRow]
turnsBySessionReadModel =
  ReadModel
    { name = "kioku-turns-by-session",
      tableName = "kioku_turns",
      subscriptionName = "kioku-session-inline",
      version = 1,
      shapeHash = "kioku-turn-v1",
      defaultConsistency = Eventual,
      query = \(TurnsBySessionQuery sid) -> Tx.statement sid selectTurnsBySessionStmt
    }

sessionRowDecoder :: D.Row SessionRow
sessionRowDecoder =
  SessionRow
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nullable D.timestamptz)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)

turnRowDecoder :: D.Row TurnRow
turnRowDecoder =
  TurnRow
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> (fromIntegral @Int32 @Int <$> D.column (D.nonNullable D.int4))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> (fmap (fromIntegral @Int32 @Int) <$> D.column (D.nullable D.int4))
    <*> (fmap (fromIntegral @Int32 @Int) <$> D.column (D.nullable D.int4))
    <*> D.column (D.nonNullable D.timestamptz)

selectSessionByIdStmt :: Statement Text (Maybe SessionRow)
selectSessionByIdStmt =
  preparable
    """
    SELECT session_id, agent_id, focus, namespace, scope_kind, scope_ref, subject_ref,
           previous_session_id, status, started_at, completed_at, model_used, summary, error_message
    FROM kioku_sessions
    WHERE session_id = $1
    """
    (E.param (E.nonNullable E.text))
    (D.rowMaybe sessionRowDecoder)

selectSessionsByNamespaceStmt :: Statement SessionsByNamespaceQuery [SessionRow]
selectSessionsByNamespaceStmt =
  preparable
    """
    SELECT session_id, agent_id, focus, namespace, scope_kind, scope_ref, subject_ref,
           previous_session_id, status, started_at, completed_at, model_used, summary, error_message
    FROM kioku_sessions
    WHERE namespace = $1
    ORDER BY started_at DESC
    LIMIT $2
    """
    ( ((\(SessionsByNamespaceQuery ns _) -> ns) >$< E.param (E.nonNullable E.text))
        <> ((\(SessionsByNamespaceQuery _ limit) -> fromIntegral @Int @Int32 limit) >$< E.param (E.nonNullable E.int4))
    )
    (D.rowList sessionRowDecoder)

selectSessionsByScopeStmt :: Statement SessionsByScopeQuery [SessionRow]
selectSessionsByScopeStmt =
  preparable
    """
    SELECT session_id, agent_id, focus, namespace, scope_kind, scope_ref, subject_ref,
           previous_session_id, status, started_at, completed_at, model_used, summary, error_message
    FROM kioku_sessions
    WHERE namespace = $1
      AND scope_kind IS NOT DISTINCT FROM $2
      AND scope_ref IS NOT DISTINCT FROM $3
    ORDER BY started_at DESC
    """
    ( ((\(SessionsByScopeQuery ns _ _) -> ns) >$< E.param (E.nonNullable E.text))
        <> ((\(SessionsByScopeQuery _ sk _) -> sk) >$< E.param (E.nullable E.text))
        <> ((\(SessionsByScopeQuery _ _ sr) -> sr) >$< E.param (E.nullable E.text))
    )
    (D.rowList sessionRowDecoder)

selectSessionsByFocusStmt :: Statement SessionsByFocusQuery [SessionRow]
selectSessionsByFocusStmt =
  preparable
    """
    SELECT session_id, agent_id, focus, namespace, scope_kind, scope_ref, subject_ref,
           previous_session_id, status, started_at, completed_at, model_used, summary, error_message
    FROM kioku_sessions
    WHERE namespace = $1
      AND focus = $2
    ORDER BY started_at DESC
    """
    ( ((\(SessionsByFocusQuery ns _) -> ns) >$< E.param (E.nonNullable E.text))
        <> ((\(SessionsByFocusQuery _ focus) -> focus) >$< E.param (E.nonNullable E.text))
    )
    (D.rowList sessionRowDecoder)

selectSessionsByStartedRangeStmt :: Statement SessionsByStartedRangeQuery [SessionRow]
selectSessionsByStartedRangeStmt =
  preparable
    """
    SELECT session_id, agent_id, focus, namespace, scope_kind, scope_ref, subject_ref,
           previous_session_id, status, started_at, completed_at, model_used, summary, error_message
    FROM kioku_sessions
    WHERE namespace = $1
      AND started_at >= $2
      AND started_at < $3
    ORDER BY started_at DESC
    """
    ( ((\(SessionsByStartedRangeQuery ns _ _) -> ns) >$< E.param (E.nonNullable E.text))
        <> ((\(SessionsByStartedRangeQuery _ start _) -> start) >$< E.param (E.nonNullable E.timestamptz))
        <> ((\(SessionsByStartedRangeQuery _ _ end) -> end) >$< E.param (E.nonNullable E.timestamptz))
    )
    (D.rowList sessionRowDecoder)

selectSessionChainStmt :: Statement Text [SessionRow]
selectSessionChainStmt =
  preparable
    """
    WITH RECURSIVE chain AS (
      SELECT session_id, agent_id, focus, namespace, scope_kind, scope_ref, subject_ref,
             previous_session_id, status, started_at, completed_at, model_used, summary, error_message
      FROM kioku_sessions
      WHERE session_id = $1
      UNION ALL
      SELECT s.session_id, s.agent_id, s.focus, s.namespace, s.scope_kind, s.scope_ref, s.subject_ref,
             s.previous_session_id, s.status, s.started_at, s.completed_at, s.model_used, s.summary, s.error_message
      FROM kioku_sessions s
      INNER JOIN chain c ON s.session_id = c.previous_session_id
    )
    SELECT session_id, agent_id, focus, namespace, scope_kind, scope_ref, subject_ref,
           previous_session_id, status, started_at, completed_at, model_used, summary, error_message
    FROM chain
    ORDER BY started_at ASC
    """
    (E.param (E.nonNullable E.text))
    (D.rowList sessionRowDecoder)

selectTurnsBySessionStmt :: Statement Text [TurnRow]
selectTurnsBySessionStmt =
  preparable
    """
    SELECT turn_id, session_id, turn_index, role, content, tool_summary, prompt_tokens,
           output_tokens, recorded_at
    FROM kioku_turns
    WHERE session_id = $1
    ORDER BY turn_index ASC
    """
    (E.param (E.nonNullable E.text))
    (D.rowList turnRowDecoder)

upsertSessionStmt :: Statement SessionRow ()
upsertSessionStmt =
  preparable
    """
    INSERT INTO kioku_sessions
      (session_id, agent_id, focus, namespace, scope_kind, scope_ref, subject_ref,
       previous_session_id, status, started_at, completed_at, model_used, summary, error_message, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, NOW())
    ON CONFLICT (session_id) DO UPDATE SET
      agent_id = EXCLUDED.agent_id,
      focus = EXCLUDED.focus,
      namespace = EXCLUDED.namespace,
      scope_kind = EXCLUDED.scope_kind,
      scope_ref = EXCLUDED.scope_ref,
      subject_ref = EXCLUDED.subject_ref,
      previous_session_id = EXCLUDED.previous_session_id,
      status = EXCLUDED.status,
      started_at = EXCLUDED.started_at,
      completed_at = EXCLUDED.completed_at,
      model_used = EXCLUDED.model_used,
      summary = EXCLUDED.summary,
      error_message = EXCLUDED.error_message,
      updated_at = EXCLUDED.updated_at
    """
    sessionRowEncoder
    D.noResult

sessionRowEncoder :: E.Params SessionRow
sessionRowEncoder =
  ((\row -> row.sessionId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.agentId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.focus) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\row -> row.scopeRef) >$< E.param (E.nullable E.text))
    <> ((\row -> row.subjectRef) >$< E.param (E.nullable E.text))
    <> ((\row -> row.previousSessionId) >$< E.param (E.nullable E.text))
    <> ((\row -> row.status) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.startedAt) >$< E.param (E.nonNullable E.timestamptz))
    <> ((\row -> row.completedAt) >$< E.param (E.nullable E.timestamptz))
    <> ((\row -> row.modelUsed) >$< E.param (E.nullable E.text))
    <> ((\row -> row.summary) >$< E.param (E.nullable E.text))
    <> ((\row -> row.errorMessage) >$< E.param (E.nullable E.text))

updateSessionCompletedStmt :: Statement (Text, UTCTime, Maybe Text, Maybe Text) ()
updateSessionCompletedStmt =
  preparable
    "UPDATE kioku_sessions SET status = 'completed', completed_at = $2, model_used = $3, summary = $4, updated_at = NOW() WHERE session_id = $1"
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.text))
    )
    D.noResult

updateSessionFailedStmt :: Statement (Text, UTCTime, Text) ()
updateSessionFailedStmt =
  preparable
    "UPDATE kioku_sessions SET status = 'failed', completed_at = $2, error_message = $3, updated_at = NOW() WHERE session_id = $1"
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nonNullable E.timestamptz))
        (E.param (E.nonNullable E.text))
    )
    D.noResult

insertTurnStmt :: Statement TurnRow ()
insertTurnStmt =
  preparable
    """
    INSERT INTO kioku_turns
      (turn_id, session_id, turn_index, role, content, tool_summary, prompt_tokens, output_tokens, recorded_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    ON CONFLICT (session_id, turn_index) DO UPDATE SET
      role = EXCLUDED.role,
      content = EXCLUDED.content,
      tool_summary = EXCLUDED.tool_summary,
      prompt_tokens = EXCLUDED.prompt_tokens,
      output_tokens = EXCLUDED.output_tokens,
      recorded_at = EXCLUDED.recorded_at
    """
    turnRowEncoder
    D.noResult

turnRowEncoder :: E.Params TurnRow
turnRowEncoder =
  ((\row -> row.turnId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.sessionId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> fromIntegral @Int @Int32 row.turnIndex) >$< E.param (E.nonNullable E.int4))
    <> ((\row -> row.role) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.content) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.toolSummary) >$< E.param (E.nullable E.text))
    <> ((\row -> fmap (fromIntegral @Int @Int32) row.promptTokens) >$< E.param (E.nullable E.int4))
    <> ((\row -> fmap (fromIntegral @Int @Int32) row.outputTokens) >$< E.param (E.nullable E.int4))
    <> ((\row -> row.recordedAt) >$< E.param (E.nonNullable E.timestamptz))
