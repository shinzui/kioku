module Kioku.Session
  ( SessionRow (..),
    SessionWriteError (..),
    start,
    awaitInput,
    resume,
    forceResume,
    complete,
    failSession,
    recordInteractive,
    recordTurn,
    getById,
    getRecentInNamespace,
    getByScope,
    getByFocus,
    getByStartedRange,
    getChain,
    getDelegationChildren,
    getAwaitingByCorrelationKey,
    getTurns,
  )
where

import Data.List (find)
import Data.Text qualified as Text
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Command (CommandError (..), defaultRunCommandOptions)
import Keiro.Projection (runCommandWithProjections)
import Keiro.ReadModel (ConsistencyMode (..), ReadModelError, runQueryWith)
import Kioku.Api.Scope (MemoryScope, Namespace (..), scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Distill.Timer (l1TimerScheduleProjection)
import Kioku.Id (SessionId, idText)
import Kioku.Prelude
import Kioku.Session.Domain
import Kioku.Session.EventStream (sessionEventStream, sessionStream)
import Kioku.Session.ReadModel
  ( AwaitingSessionsByCorrelationKeyQuery (..),
    SessionByIdQuery (..),
    SessionChainQuery (..),
    SessionDelegationChildrenQuery (..),
    SessionRow (..),
    SessionsByFocusQuery (..),
    SessionsByNamespaceQuery (..),
    SessionsByScopeQuery (..),
    SessionsByStartedRangeQuery (..),
    TurnRow,
    TurnsBySessionQuery (..),
    awaitingSessionsByCorrelationKeyReadModel,
    sessionByIdReadModel,
    sessionChainReadModel,
    sessionDelegationChildrenReadModel,
    sessionInlineProjection,
    sessionsByFocusReadModel,
    sessionsByNamespaceReadModel,
    sessionsByScopeReadModel,
    sessionsByStartedRangeReadModel,
    turnsBySessionReadModel,
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)

data SessionWriteError
  = SessionCommandRejected !CommandError
  | SessionReadFailed !ReadModelError
  | SessionNotFound
  | SessionNotRunning
  | SessionNotAwaiting
  | SessionCorrelationMismatch
  | SessionInvalidLineage !Text
  | SessionConflict !Text
  deriving stock (Generic, Show)

-- | The deepest delegation chain a session may declare. Far above any legitimate agent
-- hierarchy; it exists to bound absurd input, not to express a product limit.
maxDelegationDepth :: Int
maxDelegationDepth = 64

start ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  StartSessionData ->
  Eff es (Either SessionWriteError SessionId)
start cmdData =
  case validateLineage cmdData of
    Just reason -> pure (Left (SessionInvalidLineage reason))
    Nothing -> do
      existing <- getById cmdData.sessionId
      case existing of
        Left err -> pure (Left (SessionReadFailed err))
        Right (Just row) -> pure (idempotentOr "start" startMismatch row cmdData.sessionId)
        Right Nothing ->
          runSessionCommand cmdData.sessionId (StartSession cmdData)
            >>= acceptRejectedIfMatches cmdData.sessionId (isNothing . startMismatch)
  where
    startMismatch = mismatchOf sessionStartFields cmdData

-- | Pure, command-time lineage checks: 'Just' a reason means reject.
--
-- Deliberately does /not/ check that the referenced sessions exist. Existence checks would
-- be read-model reads with their own races, and they would forbid legitimate out-of-order
-- ingestion; a dangling pointer is harmless to the chain query, which simply stops walking.
-- Because existence is unchecked a cycle can still be constructed (write A→B before B
-- exists, then B→A), which is why 'selectSessionChainStmt' carries its own cycle guard.
--
-- These run only here, never during replay, so no historical event can be made
-- unreplayable by tightening them.
validateLineage :: StartSessionData -> Maybe Text
validateLineage d
  | d.previousSessionId == Just d.sessionId =
      Just "previousSessionId must not be the session's own id"
  | d.parentSessionId == Just d.sessionId =
      Just "parentSessionId must not be the session's own id"
  | d.delegationDepth < 0 =
      Just "delegationDepth must not be negative"
  | d.delegationDepth > maxDelegationDepth =
      Just ("delegationDepth must not exceed " <> Text.pack (show maxDelegationDepth))
  | isJust d.parentSessionId && d.delegationDepth < 1 =
      Just "a delegated session (parentSessionId present) must have delegationDepth >= 1"
  | isNothing d.parentSessionId && d.delegationDepth /= 0 =
      Just "a root session (no parentSessionId) must have delegationDepth 0"
  | otherwise = Nothing

-- * Idempotent accepts

-- | The five statuses the projection writes. Parsing at the point of decision keeps
-- 'SessionRow.status' a 'Text' (it is part of the read-model shape hosts consume) while
-- removing stringly-typed comparisons from the decision logic.
data SessionStatus
  = StatusRunning
  | StatusAwaiting
  | StatusCompleted
  | StatusFailed
  | StatusInteractive
  deriving stock (Eq, Show)

parseSessionStatus :: Text -> Maybe SessionStatus
parseSessionStatus = \case
  "running" -> Just StatusRunning
  "awaiting" -> Just StatusAwaiting
  "completed" -> Just StatusCompleted
  "failed" -> Just StatusFailed
  "interactive" -> Just StatusInteractive
  _ -> Nothing

-- | Look up the session and hand its row plus parsed status to the caller.
withExistingSession ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  (SessionRow -> SessionStatus -> Eff es (Either SessionWriteError SessionId)) ->
  Eff es (Either SessionWriteError SessionId)
withExistingSession sid k = do
  existing <- getById sid
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right Nothing -> pure (Left SessionNotFound)
    Right (Just row) ->
      case parseSessionStatus row.status of
        Nothing -> pure (Left (SessionConflict ("unrecognized session status: " <> row.status)))
        Just status -> k row status

-- | A named comparison between one request field and the row that already exists.
type FieldCheck cmd = (Text, cmd -> SessionRow -> Bool)

-- | The first request field that disagrees with the recorded row, if any.
--
-- Call-time timestamps (@startedAt@, @completedAt@, @failedAt@, @resumedAt@) are
-- deliberately /not/ compared. The session id is the identity, so a second write against it
-- carrying the same semantic payload is a retry — and a retry that re-reads the clock is
-- the normal shape of one. Comparing the timestamp would turn every such retry into a hard
-- conflict; kioku's own distillation pass does exactly this on the memory side (see
-- 'Kioku.Memory.mismatchOf'), which is what proved the point.
--
-- Semantic payload is compared, including 'awaitingDeadline' — a deadline is something the
-- caller /asked for/, not a record of when it called.
mismatchOf :: [FieldCheck cmd] -> cmd -> SessionRow -> Maybe Text
mismatchOf checks cmd row =
  fst <$> find (\(_, matches) -> not (matches cmd row)) checks

-- | A duplicate request that matches what already happened succeeds; one that conflicts
-- with it gets a conflict error naming the field that differs.
idempotentOr ::
  Text ->
  (SessionRow -> Maybe Text) ->
  SessionRow ->
  SessionId ->
  Either SessionWriteError SessionId
idempotentOr operation mismatch row sid =
  case mismatch row of
    Nothing -> Right sid
    Just field ->
      Left (SessionConflict (operation <> ": " <> field <> " differs from the recorded session"))

-- | Translate a losing race into the success the winner got.
--
-- Two identical requests can be in flight at once; keiro's optimistic-concurrency retry
-- lets one win and rejects the other. Re-reading the row after a rejection tells us which
-- kind of loser this is: if the observed state now matches what we asked for, the write we
-- wanted happened (someone else did it) and the caller gets the idempotent success. A
-- genuinely conflicting loser still gets its rejection.
acceptRejectedIfMatches ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  (SessionRow -> Bool) ->
  Either SessionWriteError SessionId ->
  Eff es (Either SessionWriteError SessionId)
acceptRejectedIfMatches sid matches = \case
  Left err@(SessionCommandRejected CommandRejected) -> do
    reread <- getById sid
    pure case reread of
      Right (Just row) | matches row -> Right sid
      _ -> Left err
  other -> pure other

sessionStartFields :: [FieldCheck StartSessionData]
sessionStartFields =
  [ ("agentId", \d row -> row.agentId == d.agentId),
    ("focus", \d row -> row.focus == d.focus),
    ("namespace", \d row -> row.namespace == scopeNamespaceText d.scope),
    ("scopeKind", \d row -> row.scopeKind == scopeKindText d.scope),
    ("scopeRef", \d row -> row.scopeRef == scopeRefText d.scope),
    ("subjectRef", \d row -> row.subjectRef == d.subjectRef),
    ("previousSessionId", \d row -> row.previousSessionId == (idText <$> d.previousSessionId)),
    ("parentSessionId", \d row -> row.parentSessionId == (idText <$> d.parentSessionId)),
    ("delegationDepth", \d row -> row.delegationDepth == d.delegationDepth)
  ]

sessionInteractiveFields :: [FieldCheck RecordInteractiveSessionData]
sessionInteractiveFields =
  [ ("status", \_ row -> parseSessionStatus row.status == Just StatusInteractive),
    ("agentId", \d row -> row.agentId == d.agentId),
    ("focus", \d row -> row.focus == d.focus),
    ("namespace", \d row -> row.namespace == scopeNamespaceText d.scope),
    ("scopeKind", \d row -> row.scopeKind == scopeKindText d.scope),
    ("scopeRef", \d row -> row.scopeRef == scopeRefText d.scope),
    ("subjectRef", \d row -> row.subjectRef == d.subjectRef)
  ]

sessionAwaitFields :: [FieldCheck AwaitInputData]
sessionAwaitFields =
  [ ("awaitingReason", \d row -> row.awaitingReason == Just d.reason),
    ("awaitingCorrelationKey", \d row -> row.awaitingCorrelationKey == d.correlationKey),
    ("awaitingDeadline", \d row -> row.awaitingDeadline == d.deadline)
  ]

sessionResumeFields :: [FieldCheck ResumeSessionData]
sessionResumeFields =
  [("resumeInput", \d row -> row.resumeInput == Just d.input)]

sessionCompleteFields :: [FieldCheck CompleteSessionData]
sessionCompleteFields =
  [ ("modelUsed", \d row -> row.modelUsed == d.modelUsed),
    ("summary", \d row -> row.summary == d.summary)
  ]

sessionFailFields :: [FieldCheck FailSessionData]
sessionFailFields =
  [("errorMessage", \d row -> row.errorMessage == Just d.errorMessage)]

complete ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  CompleteSessionData ->
  Eff es (Either SessionWriteError SessionId)
complete cmdData =
  withExistingSession cmdData.sessionId \row status ->
    case status of
      StatusRunning -> runComplete
      StatusAwaiting -> runComplete
      StatusCompleted -> pure (idempotentOr "complete" completeMismatch row cmdData.sessionId)
      StatusFailed -> pure (Left (SessionConflict "complete: the session already failed"))
      StatusInteractive ->
        pure (Left (SessionConflict "complete: an interactive session has no lifecycle to complete"))
  where
    completeMismatch = mismatchOf sessionCompleteFields cmdData
    runComplete =
      runSessionCommand cmdData.sessionId (CompleteSession cmdData)
        >>= acceptRejectedIfMatches cmdData.sessionId (isNothing . completeMismatch)

failSession ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  FailSessionData ->
  Eff es (Either SessionWriteError SessionId)
failSession cmdData =
  withExistingSession cmdData.sessionId \row status ->
    case status of
      StatusRunning -> runFail
      StatusAwaiting -> runFail
      StatusFailed -> pure (idempotentOr "failSession" failMismatch row cmdData.sessionId)
      StatusCompleted ->
        pure (Left (SessionConflict "failSession: the session already completed successfully"))
      StatusInteractive ->
        pure (Left (SessionConflict "failSession: an interactive session has no lifecycle to fail"))
  where
    failMismatch = mismatchOf sessionFailFields cmdData
    runFail =
      runSessionCommand cmdData.sessionId (FailSession cmdData)
        >>= acceptRejectedIfMatches cmdData.sessionId (isNothing . failMismatch)

awaitInput ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  AwaitInputData ->
  Eff es (Either SessionWriteError SessionId)
awaitInput cmdData =
  withExistingSession cmdData.sessionId \row status ->
    case status of
      StatusAwaiting -> pure (idempotentOr "awaitInput" awaitMismatch row cmdData.sessionId)
      StatusRunning ->
        runSessionCommand cmdData.sessionId (AwaitInput cmdData)
          >>= acceptRejectedIfMatches cmdData.sessionId (isNothing . awaitMismatch)
      _ -> pure (Left SessionNotRunning)
  where
    awaitMismatch = mismatchOf sessionAwaitFields cmdData

-- | Resume a parked session with the key it parked on.
--
-- The correlation key must match exactly — a keyed resume of a keyless wait, or of a wait
-- on a different key, is rejected. An omitted key no longer bypasses matching; use
-- 'forceResume' for that, explicitly.
--
-- The precheck below only shapes a friendly early error. The real enforcement is the
-- aggregate's own guard, which keiro re-evaluates after any optimistic-concurrency retry —
-- so a stale caller cannot resume a wait that was already resumed and re-parked.
resume ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  ResumeSessionData ->
  Eff es (Either SessionWriteError SessionId)
resume cmdData =
  withExistingSession cmdData.sessionId \row status ->
    case status of
      -- Already running: a re-delivery of *this* resume is a success; a different input
      -- means someone else answered the wait, which is a conflict, not an idempotent hit.
      StatusRunning -> pure (idempotentOr "resume" resumeMismatch row cmdData.sessionId)
      StatusAwaiting
        | not cmdData.force && row.awaitingCorrelationKey /= cmdData.correlationKey ->
            pure (Left SessionCorrelationMismatch)
        | otherwise ->
            runSessionCommand cmdData.sessionId (ResumeSession cmdData)
              >>= acceptRejectedIfMatches cmdData.sessionId (isNothing . resumeMismatch)
      _ -> pure (Left SessionNotAwaiting)
  where
    resumeMismatch = mismatchOf sessionResumeFields cmdData

-- | Resume a parked session regardless of which key it parked on.
--
-- An operator/host override for unsticking a session whose awaited key is lost or wrong.
-- It is inherently last-writer-wins: if the session is concurrently re-parked on a new
-- wait, a force resume may answer the wrong one. Prefer 'resume'.
forceResume ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  Text ->
  UTCTime ->
  Eff es (Either SessionWriteError SessionId)
forceResume sid input resumedAt =
  resume
    ResumeSessionData
      { sessionId = sid,
        correlationKey = Nothing,
        force = True,
        input,
        resumedAt
      }

recordInteractive ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  RecordInteractiveSessionData ->
  Eff es (Either SessionWriteError SessionId)
recordInteractive cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right (Just row) -> pure (idempotentOr "recordInteractive" interactiveMismatch row cmdData.sessionId)
    Right Nothing ->
      runSessionCommand cmdData.sessionId (RecordInteractiveSession cmdData)
        >>= acceptRejectedIfMatches cmdData.sessionId (isNothing . interactiveMismatch)
  where
    interactiveMismatch = mismatchOf sessionInteractiveFields cmdData

recordTurn ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  RecordTurnData ->
  Eff es (Either SessionWriteError SessionId)
recordTurn cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right Nothing -> pure (Left SessionNotFound)
    Right (Just row)
      | row.status /= "running" -> pure (Left SessionNotRunning)
      | otherwise -> runSessionCommand cmdData.sessionId (RecordTurn cmdData)

getById ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es (Either ReadModelError (Maybe SessionRow))
getById sid =
  runQueryWith Nothing Eventual sessionByIdReadModel (SessionByIdQuery (idText sid))

getRecentInNamespace ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  Int ->
  Eff es (Either ReadModelError [SessionRow])
getRecentInNamespace ns limit =
  runQueryWith Nothing Eventual sessionsByNamespaceReadModel (SessionsByNamespaceQuery (namespaceText ns) limit)

getByScope ::
  (IOE :> es, Store :> es) =>
  MemoryScope ->
  Eff es (Either ReadModelError [SessionRow])
getByScope scope =
  runQueryWith
    Nothing
    Eventual
    sessionsByScopeReadModel
    (SessionsByScopeQuery (scopeNamespaceText scope) (scopeKindText scope) (scopeRefText scope))

getByFocus ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  Text ->
  Eff es (Either ReadModelError [SessionRow])
getByFocus ns focus =
  runQueryWith Nothing Eventual sessionsByFocusReadModel (SessionsByFocusQuery (namespaceText ns) focus)

getByStartedRange ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  UTCTime ->
  UTCTime ->
  Eff es (Either ReadModelError [SessionRow])
getByStartedRange ns startedAfter startedBefore =
  runQueryWith Nothing Eventual sessionsByStartedRangeReadModel (SessionsByStartedRangeQuery (namespaceText ns) startedAfter startedBefore)

getChain ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es (Either ReadModelError [SessionRow])
getChain sid =
  runQueryWith Nothing Eventual sessionChainReadModel (SessionChainQuery (idText sid))

getDelegationChildren ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es (Either ReadModelError [SessionRow])
getDelegationChildren sid =
  runQueryWith Nothing Eventual sessionDelegationChildrenReadModel (SessionDelegationChildrenQuery (idText sid))

getAwaitingByCorrelationKey ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  Text ->
  Eff es (Either ReadModelError [SessionRow])
getAwaitingByCorrelationKey ns correlationKey =
  runQueryWith Nothing Eventual awaitingSessionsByCorrelationKeyReadModel (AwaitingSessionsByCorrelationKeyQuery (namespaceText ns) correlationKey)

namespaceText :: Namespace -> Text
namespaceText (Namespace ns) = ns

getTurns ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es (Either ReadModelError [TurnRow])
getTurns sid =
  runQueryWith Nothing Eventual turnsBySessionReadModel (TurnsBySessionQuery (idText sid))

runSessionCommand ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  SessionCommand ->
  Eff es (Either SessionWriteError SessionId)
runSessionCommand sid cmd = do
  result <-
    runCommandWithProjections
      defaultRunCommandOptions
      sessionEventStream
      (sessionStream sid)
      cmd
      [sessionInlineProjection, l1TimerScheduleProjection]
  pure $
    case result of
      Left err -> Left (SessionCommandRejected err)
      Right _ -> Right sid
