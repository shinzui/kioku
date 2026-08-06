-- | Starting, driving, and reading agent sessions.
--
-- Every write takes a 'MemoryAccessContext' first, for the reasons set out in "Kioku.Memory":
-- Kioku's core never decides who may write where, it only refuses to write without a decision.
-- All session writes ask for the 'MemoryRecord' permission — a session, its turns, and its
-- lifecycle are memory being recorded.
--
-- A session belongs to the space it was started in, and the aggregate refuses every later
-- command that names a different one. That includes 'forceResumeWithContext': waiving the
-- correlation-key check is an operator override for a lost key, not for the isolation boundary.
--
-- The unsuffixed functions ('start', 'complete', …) remain for one release as deprecated
-- compatibility wrappers confined to 'legacyMemorySpaceId'. Reads are not partitioned yet; see
-- "Kioku.Memory" and @docs\/user\/upgrading-to-memory-spaces.md@.
module Kioku.Session
  ( SessionRow (..),
    SessionWriteError (..),

    -- * Writing sessions
    startWithContext,
    awaitInputWithContext,
    resumeWithContext,
    forceResumeWithContext,
    completeWithContext,
    failSessionWithContext,
    recordInteractiveWithContext,
    recordTurnWithContext,

    -- * Deprecated compatibility wrappers, confined to the legacy memory space
    start,
    awaitInput,
    resume,
    forceResume,
    complete,
    failSession,
    recordInteractive,
    recordTurn,

    -- * Reading sessions
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
import Kioku.Api.Access
  ( MemoryAccessContext,
    MemoryPermission (..),
    MemorySpaceId,
    RecordedPrincipal (..),
    legacyMemorySpaceId,
    memoryContextAllows,
    memoryContextRecordedActor,
    memoryContextSpace,
  )
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
    TurnRow (..),
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
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
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
  | -- | the context authorized other actions, but not this one
    SessionNotPermitted !MemoryPermission
  | -- | the command names a memory space the context was not minted for:
    -- @SessionSpaceMismatch requested authorized@
    SessionSpaceMismatch !MemorySpaceId !MemorySpaceId
  | -- | the command attributes the write to somebody other than the context's own principal
    SessionActorMismatch !RecordedPrincipal !RecordedPrincipal
  deriving stock (Generic, Show)

-- | Gate a write on the decision that authorized it. See 'Kioku.Memory.underContext' — same
-- three checks, same reasons: a context minted for one action cannot be spent on another, on
-- another space, or in somebody else's name.
underContext ::
  (Applicative f) =>
  MemoryAccessContext ->
  MemoryPermission ->
  MemorySpaceId ->
  RecordedPrincipal ->
  f (Either SessionWriteError a) ->
  f (Either SessionWriteError a)
underContext context permission space actor run
  | not (memoryContextAllows permission context) =
      pure (Left (SessionNotPermitted permission))
  | space /= authorizedSpace =
      pure (Left (SessionSpaceMismatch space authorizedSpace))
  | actor /= authorizedActor =
      pure (Left (SessionActorMismatch actor authorizedActor))
  | otherwise = run
  where
    authorizedSpace = memoryContextSpace context
    authorizedActor = memoryContextRecordedActor context

-- | Gate a deprecated wrapper on the one space it is allowed to touch.
inLegacySpaceOnly ::
  (Applicative f) =>
  MemorySpaceId ->
  f (Either SessionWriteError a) ->
  f (Either SessionWriteError a)
inLegacySpaceOnly space run
  | space /= legacyMemorySpaceId = pure (Left (SessionSpaceMismatch space legacyMemorySpaceId))
  | otherwise = run

-- | The deepest delegation chain a session may declare. Far above any legitimate agent
-- hierarchy; it exists to bound absurd input, not to express a product limit.
maxDelegationDepth :: Int
maxDelegationDepth = 64

-- | Start a session in the space the context authorizes.
startWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  StartSessionData ->
  Eff es (Either SessionWriteError SessionId)
startWithContext context cmdData =
  underContext context MemoryRecord cmdData.memorySpaceId cmdData.actorPrincipal (startIn cmdData)

{-# DEPRECATED start "Use startWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: start a session in the legacy memory space, with no authorization context.
start ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  StartSessionData ->
  Eff es (Either SessionWriteError SessionId)
start cmdData = inLegacySpaceOnly cmdData.memorySpaceId (startIn cmdData)

startIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  StartSessionData ->
  Eff es (Either SessionWriteError SessionId)
startIn cmdData =
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

-- | Complete a session in the space the context authorizes.
completeWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  CompleteSessionData ->
  Eff es (Either SessionWriteError SessionId)
completeWithContext context cmdData =
  underContext context MemoryRecord cmdData.memorySpaceId cmdData.actorPrincipal (completeIn cmdData)

{-# DEPRECATED complete "Use completeWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: complete within the legacy memory space, with no authorization context.
complete ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  CompleteSessionData ->
  Eff es (Either SessionWriteError SessionId)
complete cmdData = inLegacySpaceOnly cmdData.memorySpaceId (completeIn cmdData)

completeIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  CompleteSessionData ->
  Eff es (Either SessionWriteError SessionId)
completeIn cmdData =
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

-- | Fail a session in the space the context authorizes.
failSessionWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  FailSessionData ->
  Eff es (Either SessionWriteError SessionId)
failSessionWithContext context cmdData =
  underContext context MemoryRecord cmdData.memorySpaceId cmdData.actorPrincipal (failSessionIn cmdData)

{-# DEPRECATED failSession "Use failSessionWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: fail within the legacy memory space, with no authorization context.
failSession ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  FailSessionData ->
  Eff es (Either SessionWriteError SessionId)
failSession cmdData = inLegacySpaceOnly cmdData.memorySpaceId (failSessionIn cmdData)

failSessionIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  FailSessionData ->
  Eff es (Either SessionWriteError SessionId)
failSessionIn cmdData =
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

-- | Park a session in the space the context authorizes.
awaitInputWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  AwaitInputData ->
  Eff es (Either SessionWriteError SessionId)
awaitInputWithContext context cmdData =
  underContext context MemoryRecord cmdData.memorySpaceId cmdData.actorPrincipal (awaitInputIn cmdData)

{-# DEPRECATED awaitInput "Use awaitInputWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: park within the legacy memory space, with no authorization context.
awaitInput ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  AwaitInputData ->
  Eff es (Either SessionWriteError SessionId)
awaitInput cmdData = inLegacySpaceOnly cmdData.memorySpaceId (awaitInputIn cmdData)

awaitInputIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  AwaitInputData ->
  Eff es (Either SessionWriteError SessionId)
awaitInputIn cmdData =
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
resumeWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  ResumeSessionData ->
  Eff es (Either SessionWriteError SessionId)
resumeWithContext context cmdData =
  underContext context MemoryRecord cmdData.memorySpaceId cmdData.actorPrincipal (resumeIn cmdData)

{-# DEPRECATED resume "Use resumeWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: resume within the legacy memory space, with no authorization context.
resume ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  ResumeSessionData ->
  Eff es (Either SessionWriteError SessionId)
resume cmdData = inLegacySpaceOnly cmdData.memorySpaceId (resumeIn cmdData)

resumeIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  ResumeSessionData ->
  Eff es (Either SessionWriteError SessionId)
resumeIn cmdData =
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
-- wait, a force resume may answer the wrong one. Prefer 'resumeWithContext'.
--
-- @force@ waives the correlation-key check and nothing else. The session must still belong to
-- the space this context authorizes, and the aggregate enforces that independently.
forceResumeWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  SessionId ->
  Text ->
  UTCTime ->
  Eff es (Either SessionWriteError SessionId)
forceResumeWithContext context sid input resumedAt =
  resumeWithContext
    context
    (forcedResumeData (memoryContextSpace context) (memoryContextRecordedActor context) sid input resumedAt)

{-# DEPRECATED forceResume "Use forceResumeWithContext. This wrapper acts only in legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: force-resume within the legacy memory space, with no authorization context.
forceResume ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  Text ->
  UTCTime ->
  Eff es (Either SessionWriteError SessionId)
forceResume sid input resumedAt =
  resumeIn (forcedResumeData legacyMemorySpaceId UnattributedPrincipal sid input resumedAt)

forcedResumeData :: MemorySpaceId -> RecordedPrincipal -> SessionId -> Text -> UTCTime -> ResumeSessionData
forcedResumeData memorySpaceId actorPrincipal sid input resumedAt =
  ResumeSessionData
    { sessionId = sid,
      memorySpaceId,
      actorPrincipal,
      correlationKey = Nothing,
      force = True,
      input,
      resumedAt
    }

-- | Record an interactive session in the space the context authorizes.
recordInteractiveWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  RecordInteractiveSessionData ->
  Eff es (Either SessionWriteError SessionId)
recordInteractiveWithContext context cmdData =
  underContext context MemoryRecord cmdData.memorySpaceId cmdData.actorPrincipal (recordInteractiveIn cmdData)

{-# DEPRECATED recordInteractive "Use recordInteractiveWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: record an interactive session in the legacy memory space, with no context.
recordInteractive ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  RecordInteractiveSessionData ->
  Eff es (Either SessionWriteError SessionId)
recordInteractive cmdData = inLegacySpaceOnly cmdData.memorySpaceId (recordInteractiveIn cmdData)

recordInteractiveIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  RecordInteractiveSessionData ->
  Eff es (Either SessionWriteError SessionId)
recordInteractiveIn cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right (Just row) -> pure (idempotentOr "recordInteractive" interactiveMismatch row cmdData.sessionId)
    Right Nothing ->
      runSessionCommand cmdData.sessionId (RecordInteractiveSession cmdData)
        >>= acceptRejectedIfMatches cmdData.sessionId (isNothing . interactiveMismatch)
  where
    interactiveMismatch = mismatchOf sessionInteractiveFields cmdData

-- | Record one turn of a running session.
--
-- Turn identity is @(sessionId, turnIndex)@; @turnId@ is an idempotency token that travels
-- with it. A re-delivery of an identical turn succeeds without appending an event; the same
-- index carrying different content, or the same @turnId@ reappearing at a different index,
-- is a conflict. The aggregate independently enforces that indexes strictly increase.
--
-- Reusing a @turnId@ across two /different sessions/ remains a raw primary-key violation
-- surfaced as @StoreFailed@: turn ids are host-generated, so a cross-session collision is a
-- caller bug, and mapping that specific SQL error from inside keiro's projection
-- transaction is not worth the machinery.
recordTurnWithContext ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryAccessContext ->
  RecordTurnData ->
  Eff es (Either SessionWriteError SessionId)
recordTurnWithContext context cmdData =
  underContext context MemoryRecord cmdData.memorySpaceId cmdData.actorPrincipal (recordTurnIn cmdData)

{-# DEPRECATED recordTurn "Use recordTurnWithContext. This wrapper accepts only legacyMemorySpaceId and will be removed." #-}

-- | Deprecated: record a turn within the legacy memory space, with no authorization context.
recordTurn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  RecordTurnData ->
  Eff es (Either SessionWriteError SessionId)
recordTurn cmdData = inLegacySpaceOnly cmdData.memorySpaceId (recordTurnIn cmdData)

recordTurnIn ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  RecordTurnData ->
  Eff es (Either SessionWriteError SessionId)
recordTurnIn cmdData =
  withExistingSession cmdData.sessionId \_row status ->
    case status of
      StatusRunning -> do
        turns <- getTurns cmdData.sessionId
        case turns of
          Left err -> pure (Left (SessionReadFailed err))
          Right existingTurns ->
            case turnVerdict cmdData existingTurns of
              Just verdict -> pure verdict
              Nothing ->
                runSessionCommand cmdData.sessionId (RecordTurn cmdData)
                  >>= acceptRejectedTurnIfMatches cmdData
      _ -> pure (Left SessionNotRunning)

-- | The turns-table counterpart of 'acceptRejectedIfMatches': a concurrent duplicate that
-- lost the optimistic-concurrency race converges to the winner's success.
acceptRejectedTurnIfMatches ::
  (IOE :> es, Store :> es) =>
  RecordTurnData ->
  Either SessionWriteError SessionId ->
  Eff es (Either SessionWriteError SessionId)
acceptRejectedTurnIfMatches d = \case
  Left err@(SessionCommandRejected CommandRejected) -> do
    turns <- getTurns d.sessionId
    pure case turns of
      Right rows
        | Just row <- find (\row -> row.turnIndex == d.turnIndex) rows,
          turnRowMatches d row ->
            Right d.sessionId
      _ -> Left err
  other -> pure other

-- | 'Just' a final answer if an existing turn row already decides this request;
-- 'Nothing' if the command should run.
turnVerdict :: RecordTurnData -> [TurnRow] -> Maybe (Either SessionWriteError SessionId)
turnVerdict d existingTurns
  | Just row <- sameIndex =
      Just
        if turnRowMatches d row
          then Right d.sessionId
          else Left (SessionConflict ("recordTurn: turn " <> Text.pack (show d.turnIndex) <> " already recorded with different content"))
  | any (\row -> row.turnId == d.turnId) existingTurns =
      Just (Left (SessionConflict ("recordTurn: turnId " <> d.turnId <> " is already used at a different turn index")))
  | otherwise = Nothing
  where
    sameIndex = find (\row -> row.turnIndex == d.turnIndex) existingTurns

turnRowMatches :: RecordTurnData -> TurnRow -> Bool
turnRowMatches d row =
  row.turnId == d.turnId
    && row.role == d.role
    && row.content == d.content
    && row.toolSummary == d.toolSummary
    && row.promptTokens == d.promptTokens
    && row.outputTokens == d.outputTokens

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
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
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
