{-# LANGUAGE TemplateHaskell #-}

module Kioku.Session.Domain
  ( SessionVertex (..),
    SessionRegs,
    StartSessionData (..),
    CompleteSessionData (..),
    FailSessionData (..),
    Continuation (..),
    AwaitInputData (..),
    ResumeSessionData (..),
    RecordInteractiveSessionData (..),
    RecordTurnData (..),
    SessionCommand (..),
    commandSessionId,
    commandMemorySpaceId,
    SessionStartedData (..),
    SessionCompletedData (..),
    SessionFailedData (..),
    SessionAwaitingData (..),
    SessionResumedData (..),
    InteractiveSessionRecordedData (..),
    TurnRecordedData (..),
    SessionEvent (..),
    eventSessionId,
    eventMemorySpaceId,
    sessionTransducer,
  )
where

import Data.Aeson.Types (withObject, (.!=), (.:), (.:?))
import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer, lit, (.==), (.||))
import Keiki.Generics (emptyRegFile)
import Keiki.Generics.TH (deriveAggregate)
import Kioku.Api.Access (MemorySpaceId, PrincipalRef, RecordedPrincipal)
import Kioku.Api.Scope (MemoryScope)
import Kioku.Id (SessionId)
import Kioku.Partition (parsePartitionSpace, parseRecordedActor, parseRecordedActorFromAgent, parseRecordedOwner)
import Kioku.Prelude

data SessionVertex = NotCreated | Running | Completed | Failed | Interactive | Awaiting
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | Replayed aggregate state carried alongside the vertex.
--
-- @awaitedCorrelationKey@ is the key the session is currently parked on (set by
-- @SessionAwaiting@, cleared by @SessionResumed@). It is what makes resume-correlation
-- matching an aggregate invariant rather than a racy read-model precheck.
--
-- @lastTurnIndex@ is the highest turn index committed so far (-1 before any turn), which
-- makes @RecordTurn@'s strictly-increasing index contract enforceable in the state machine
-- rather than only at the command layer.
--
-- @memorySpaceId@ is the space the session was started in. Every later command must name it,
-- so a caller authorized for one space cannot append a turn to, park, resume, complete, or fail
-- a session belonging to another. Keeping it in the register file rather than re-reading a row
-- is what makes that check survive an optimistic-concurrency retry.
type SessionRegs =
  '[ '("awaitedCorrelationKey", Maybe Text),
     '("lastTurnIndex", Int),
     '("memorySpaceId", MemorySpaceId)
   ]

data StartSessionData = StartSessionData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    ownerPrincipal :: !(Maybe PrincipalRef),
    agentId :: !Text,
    focus :: !Text,
    scope :: !MemoryScope,
    subjectRef :: !(Maybe Text),
    previousSessionId :: !(Maybe SessionId),
    parentSessionId :: !(Maybe SessionId),
    delegationDepth :: !Int,
    startedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data CompleteSessionData = CompleteSessionData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    completedAt :: !UTCTime,
    modelUsed :: !(Maybe Text),
    summary :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data FailSessionData = FailSessionData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    failedAt :: !UTCTime,
    errorMessage :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | What a parked session is waiting for.
--
-- @deadline@ is advisory only: it is stored for hosts and kioku does not enforce it. No timer
-- fires and nothing expires when it passes (MasterPlan 2 decision, 2026-07-07).
data Continuation = Continuation
  { reason :: !Text,
    correlationKey :: !(Maybe Text),
    deadline :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

-- | Park a session until a host supplies input.
--
-- @deadline@ is advisory only: it is stored for hosts and kioku does not enforce it. No timer
-- fires and nothing expires when it passes (MasterPlan 2 decision, 2026-07-07).
data AwaitInputData = AwaitInputData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    reason :: !Text,
    correlationKey :: !(Maybe Text),
    deadline :: !(Maybe UTCTime),
    awaitedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

-- | Resume a parked session.
--
-- @correlationKey@ must equal the key the session parked on, or the aggregate rejects the
-- command. @force@ waives that check; it is set only by 'Kioku.Session.forceResume' and is
-- inherently last-writer-wins.
data ResumeSessionData = ResumeSessionData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    correlationKey :: !(Maybe Text),
    force :: !Bool,
    input :: !Text,
    resumedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data RecordInteractiveSessionData = RecordInteractiveSessionData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    ownerPrincipal :: !(Maybe PrincipalRef),
    agentId :: !Text,
    focus :: !Text,
    scope :: !MemoryScope,
    subjectRef :: !(Maybe Text),
    startedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data RecordTurnData = RecordTurnData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    turnId :: !Text,
    turnIndex :: !Int,
    role :: !Text,
    content :: !Text,
    toolSummary :: !(Maybe Text),
    promptTokens :: !(Maybe Int),
    outputTokens :: !(Maybe Int),
    recordedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data SessionCommand
  = StartSession !StartSessionData
  | CompleteSession !CompleteSessionData
  | FailSession !FailSessionData
  | AwaitInput !AwaitInputData
  | ResumeSession !ResumeSessionData
  | RecordInteractiveSession !RecordInteractiveSessionData
  | RecordTurn !RecordTurnData
  deriving stock (Generic, Eq, Show)

commandSessionId :: SessionCommand -> SessionId
commandSessionId = \case
  StartSession d -> d.sessionId
  CompleteSession d -> d.sessionId
  FailSession d -> d.sessionId
  AwaitInput d -> d.sessionId
  ResumeSession d -> d.sessionId
  RecordInteractiveSession d -> d.sessionId
  RecordTurn d -> d.sessionId

-- | The memory space a command claims to act in. Every command names one; the aggregate refuses
-- any that disagrees with the space the session was started in.
commandMemorySpaceId :: SessionCommand -> MemorySpaceId
commandMemorySpaceId = \case
  StartSession d -> d.memorySpaceId
  CompleteSession d -> d.memorySpaceId
  FailSession d -> d.memorySpaceId
  AwaitInput d -> d.memorySpaceId
  ResumeSession d -> d.memorySpaceId
  RecordInteractiveSession d -> d.memorySpaceId
  RecordTurn d -> d.memorySpaceId

-- | As on the memory side, every @FromJSON@ instance below is hand-written so that payloads
-- written before memory spaces existed keep decoding. 'Kioku.Partition' owns the defaults;
-- @ToJSON@ stays derived so encoding only ever emits the new form.
data SessionStartedData = SessionStartedData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    ownerPrincipal :: !(Maybe PrincipalRef),
    agentId :: !Text,
    focus :: !Text,
    scope :: !MemoryScope,
    subjectRef :: !(Maybe Text),
    previousSessionId :: !(Maybe SessionId),
    parentSessionId :: !(Maybe SessionId),
    delegationDepth :: !Int,
    startedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON SessionStartedData where
  parseJSON =
    withObject "SessionStartedData" \o ->
      SessionStartedData
        <$> o .: "sessionId"
        <*> parsePartitionSpace o
        <*> parseRecordedActorFromAgent o
        <*> parseRecordedOwner o
        <*> o .: "agentId"
        <*> o .: "focus"
        <*> o .: "scope"
        <*> o .:? "subjectRef"
        <*> o .:? "previousSessionId"
        <*> o .:? "parentSessionId"
        <*> o .:? "delegationDepth" .!= 0
        <*> o .: "startedAt"

data SessionCompletedData = SessionCompletedData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    completedAt :: !UTCTime,
    modelUsed :: !(Maybe Text),
    summary :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON SessionCompletedData where
  parseJSON =
    withObject "SessionCompletedData" \o ->
      SessionCompletedData
        <$> o .: "sessionId"
        <*> parsePartitionSpace o
        <*> parseRecordedActor o
        <*> o .: "completedAt"
        <*> o .:? "modelUsed"
        <*> o .:? "summary"

data SessionFailedData = SessionFailedData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    failedAt :: !UTCTime,
    errorMessage :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON SessionFailedData where
  parseJSON =
    withObject "SessionFailedData" \o ->
      SessionFailedData
        <$> o .: "sessionId"
        <*> parsePartitionSpace o
        <*> parseRecordedActor o
        <*> o .: "failedAt"
        <*> o .: "errorMessage"

data SessionAwaitingData = SessionAwaitingData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    reason :: !Text,
    correlationKey :: !(Maybe Text),
    deadline :: !(Maybe UTCTime),
    awaitedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON SessionAwaitingData where
  parseJSON =
    withObject "SessionAwaitingData" \o ->
      SessionAwaitingData
        <$> o .: "sessionId"
        <*> parsePartitionSpace o
        <*> parseRecordedActor o
        <*> o .: "reason"
        <*> o .:? "correlationKey"
        <*> o .:? "deadline"
        <*> o .: "awaitedAt"

data SessionResumedData = SessionResumedData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    correlationKey :: !(Maybe Text),
    force :: !Bool,
    input :: !Text,
    resumedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

-- | Events written before the resume-correlation guard landed carry no @force@ key. Under
-- the old code an omitted correlation key bypassed matching entirely, so a keyless legacy
-- resume decodes as a force-resume and a keyed one as a plain resume. That is what keeps
-- every historical stream replayable through the guard the transducer now applies.
instance FromJSON SessionResumedData where
  parseJSON =
    withObject "SessionResumedData" \o -> do
      sessionId <- o .: "sessionId"
      memorySpaceId <- parsePartitionSpace o
      actorPrincipal <- parseRecordedActor o
      correlationKey <- o .:? "correlationKey"
      force <- o .:? "force" .!= isNothing correlationKey
      input <- o .: "input"
      resumedAt <- o .: "resumedAt"
      pure SessionResumedData {sessionId, memorySpaceId, actorPrincipal, correlationKey, force, input, resumedAt}

data InteractiveSessionRecordedData = InteractiveSessionRecordedData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    ownerPrincipal :: !(Maybe PrincipalRef),
    agentId :: !Text,
    focus :: !Text,
    scope :: !MemoryScope,
    subjectRef :: !(Maybe Text),
    startedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON InteractiveSessionRecordedData where
  parseJSON =
    withObject "InteractiveSessionRecordedData" \o ->
      InteractiveSessionRecordedData
        <$> o .: "sessionId"
        <*> parsePartitionSpace o
        <*> parseRecordedActorFromAgent o
        <*> parseRecordedOwner o
        <*> o .: "agentId"
        <*> o .: "focus"
        <*> o .: "scope"
        <*> o .:? "subjectRef"
        <*> o .: "startedAt"

data TurnRecordedData = TurnRecordedData
  { sessionId :: !SessionId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    turnId :: !Text,
    turnIndex :: !Int,
    role :: !Text,
    content :: !Text,
    toolSummary :: !(Maybe Text),
    promptTokens :: !(Maybe Int),
    outputTokens :: !(Maybe Int),
    recordedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON TurnRecordedData where
  parseJSON =
    withObject "TurnRecordedData" \o ->
      TurnRecordedData
        <$> o .: "sessionId"
        <*> parsePartitionSpace o
        <*> parseRecordedActor o
        <*> o .: "turnId"
        <*> o .: "turnIndex"
        <*> o .: "role"
        <*> o .: "content"
        <*> o .:? "toolSummary"
        <*> o .:? "promptTokens"
        <*> o .:? "outputTokens"
        <*> o .: "recordedAt"

data SessionEvent
  = SessionStarted !SessionStartedData
  | SessionCompleted !SessionCompletedData
  | SessionFailed !SessionFailedData
  | SessionAwaiting !SessionAwaitingData
  | SessionResumed !SessionResumedData
  | InteractiveSessionRecorded !InteractiveSessionRecordedData
  | TurnRecorded !TurnRecordedData
  deriving stock (Generic, Eq, Show)

instance FromJSON SessionEvent where
  parseJSON = genericParseJSON eventAesonOptions

instance ToJSON SessionEvent where
  toJSON = genericToJSON eventAesonOptions

eventSessionId :: SessionEvent -> SessionId
eventSessionId = \case
  SessionStarted d -> d.sessionId
  SessionCompleted d -> d.sessionId
  SessionFailed d -> d.sessionId
  SessionAwaiting d -> d.sessionId
  SessionResumed d -> d.sessionId
  InteractiveSessionRecorded d -> d.sessionId
  TurnRecorded d -> d.sessionId

-- | The memory space a stored event belongs to. Every event carries one, including every event
-- written before memory spaces existed: those decode into 'legacyMemorySpaceId'.
eventMemorySpaceId :: SessionEvent -> MemorySpaceId
eventMemorySpaceId = \case
  SessionStarted d -> d.memorySpaceId
  SessionCompleted d -> d.memorySpaceId
  SessionFailed d -> d.memorySpaceId
  SessionAwaiting d -> d.memorySpaceId
  SessionResumed d -> d.memorySpaceId
  InteractiveSessionRecorded d -> d.memorySpaceId
  TurnRecorded d -> d.memorySpaceId

$(deriveAggregate ''SessionCommand ''SessionRegs ''SessionEvent)

sessionTransducer ::
  SymTransducer
    (HsPred SessionRegs SessionCommand)
    SessionRegs
    SessionVertex
    SessionCommand
    SessionEvent
sessionTransducer =
  B.buildTransducer NotCreated emptyRegFile isTerminal do
    B.from NotCreated do
      B.onCmd inCtorStartSession $ \d -> B.do
        -- 'emptyRegFile' binds every slot to a deferred error, so this edge — the only way
        -- into Running, and thus into Awaiting and RecordTurn — must initialize all three.
        B.slot @"awaitedCorrelationKey" =: lit Nothing
        B.slot @"lastTurnIndex" =: lit (-1)
        B.slot @"memorySpaceId" =: d.memorySpaceId
        B.emit
          wireSessionStarted
          SessionStartedTermFields
            { sessionId = d.sessionId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              ownerPrincipal = d.ownerPrincipal,
              agentId = d.agentId,
              focus = d.focus,
              scope = d.scope,
              subjectRef = d.subjectRef,
              previousSessionId = d.previousSessionId,
              parentSessionId = d.parentSessionId,
              delegationDepth = d.delegationDepth,
              startedAt = d.startedAt
            }
        B.goto Running

      B.onCmd inCtorRecordInteractiveSession $ \d -> B.do
        -- Interactive is terminal, so nothing later reads this slot. It is still set, because a
        -- register left bound to 'emptyRegFile''s deferred error is a trap for the next edge
        -- somebody adds here.
        B.slot @"memorySpaceId" =: d.memorySpaceId
        B.emit
          wireInteractiveSessionRecorded
          InteractiveSessionRecordedTermFields
            { sessionId = d.sessionId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              ownerPrincipal = d.ownerPrincipal,
              agentId = d.agentId,
              focus = d.focus,
              scope = d.scope,
              subjectRef = d.subjectRef,
              startedAt = d.startedAt
            }
        B.goto Interactive

    B.from Running do
      -- Every edge out of a live session repeats the space guard: the command must name the
      -- space the session was started in.
      B.onCmd inCtorCompleteSession $ \d -> B.do
        B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
        B.emit
          wireSessionCompleted
          SessionCompletedTermFields
            { sessionId = d.sessionId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              completedAt = d.completedAt,
              modelUsed = d.modelUsed,
              summary = d.summary
            }
        B.goto Completed

      B.onCmd inCtorFailSession $ \d -> B.do
        B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
        B.emit
          wireSessionFailed
          SessionFailedTermFields
            { sessionId = d.sessionId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              failedAt = d.failedAt,
              errorMessage = d.errorMessage
            }
        B.goto Failed

      B.onCmd inCtorRecordTurn $ \d -> B.do
        -- Turn identity: (sessionId, turnIndex). Indexes must strictly increase, so a
        -- re-delivered or out-of-order turn cannot silently overwrite a committed one.
        -- 'turnIndex' is already in the event payload, so replay recovers it and existing
        -- strictly-increasing streams rehydrate unchanged (verified by Audit B).
        B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
        B.requireGt d.turnIndex (B.reg @"lastTurnIndex")
        B.slot @"lastTurnIndex" =: d.turnIndex
        B.emit
          wireTurnRecorded
          TurnRecordedTermFields
            { sessionId = d.sessionId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              turnId = d.turnId,
              turnIndex = d.turnIndex,
              role = d.role,
              content = d.content,
              toolSummary = d.toolSummary,
              promptTokens = d.promptTokens,
              outputTokens = d.outputTokens,
              recordedAt = d.recordedAt
            }
        B.goto Running

      B.onCmd inCtorAwaitInput $ \d -> B.do
        B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
        B.slot @"awaitedCorrelationKey" =: d.correlationKey
        B.emit
          wireSessionAwaiting
          SessionAwaitingTermFields
            { sessionId = d.sessionId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              reason = d.reason,
              correlationKey = d.correlationKey,
              deadline = d.deadline,
              awaitedAt = d.awaitedAt
            }
        B.goto Awaiting

    B.from Awaiting do
      B.onCmd inCtorResumeSession $ \d -> B.do
        -- The resume must name the key this session actually parked on, unless it is an
        -- explicit force. Enforcing it here rather than in a read-model precheck is what
        -- closes the race: keiro re-runs this edge against the post-conflict state.
        --
        -- Note that 'force' waives the correlation-key check and nothing else. A forced resume
        -- still has to name the session's own memory space; an operator override for a lost key
        -- is not an override for the isolation boundary.
        B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
        B.requireGuard
          ((d.force .== lit True) .|| (d.correlationKey .== B.reg @"awaitedCorrelationKey"))
        B.slot @"awaitedCorrelationKey" =: lit Nothing
        B.emit
          wireSessionResumed
          SessionResumedTermFields
            { sessionId = d.sessionId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              correlationKey = d.correlationKey,
              -- Mandatory for replay: the guard reads 'force', and hydration can only
              -- recover command fields that the event payload carries.
              force = d.force,
              input = d.input,
              resumedAt = d.resumedAt
            }
        B.goto Running

      B.onCmd inCtorCompleteSession $ \d -> B.do
        B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
        B.emit
          wireSessionCompleted
          SessionCompletedTermFields
            { sessionId = d.sessionId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              completedAt = d.completedAt,
              modelUsed = d.modelUsed,
              summary = d.summary
            }
        B.goto Completed

      B.onCmd inCtorFailSession $ \d -> B.do
        B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
        B.emit
          wireSessionFailed
          SessionFailedTermFields
            { sessionId = d.sessionId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              failedAt = d.failedAt,
              errorMessage = d.errorMessage
            }
        B.goto Failed
  where
    isTerminal = \case
      Completed -> True
      Failed -> True
      Interactive -> True
      _ -> False
