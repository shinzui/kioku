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
    SessionStartedData (..),
    SessionCompletedData (..),
    SessionFailedData (..),
    SessionAwaitingData (..),
    SessionResumedData (..),
    InteractiveSessionRecordedData (..),
    TurnRecordedData (..),
    SessionEvent (..),
    eventSessionId,
    sessionTransducer,
  )
where

import Data.Aeson.Types (withObject, (.!=), (.:), (.:?))
import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer, lit, (.==), (.||))
import Keiki.Generics (emptyRegFile)
import Keiki.Generics.TH (deriveAggregate)
import Kioku.Api.Scope (MemoryScope)
import Kioku.Id (SessionId)
import Kioku.Prelude

data SessionVertex = NotCreated | Running | Completed | Failed | Interactive | Awaiting
  deriving stock (Eq, Show, Enum, Bounded)

-- | Replayed aggregate state carried alongside the vertex.
--
-- @awaitedCorrelationKey@ is the key the session is currently parked on (set by
-- @SessionAwaiting@, cleared by @SessionResumed@). It is what makes resume-correlation
-- matching an aggregate invariant rather than a racy read-model precheck.
--
-- @lastTurnIndex@ is the highest turn index committed so far (-1 before any turn), which
-- makes @RecordTurn@'s strictly-increasing index contract enforceable in the state machine
-- rather than only at the command layer.
type SessionRegs =
  '[ '("awaitedCorrelationKey", Maybe Text),
     '("lastTurnIndex", Int)
   ]

data StartSessionData = StartSessionData
  { sessionId :: !SessionId,
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
    completedAt :: !UTCTime,
    modelUsed :: !(Maybe Text),
    summary :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data FailSessionData = FailSessionData
  { sessionId :: !SessionId,
    failedAt :: !UTCTime,
    errorMessage :: !Text
  }
  deriving stock (Generic, Eq, Show)

-- | What a parked session is waiting for.
data Continuation = Continuation
  { reason :: !Text,
    correlationKey :: !(Maybe Text),
    deadline :: !(Maybe UTCTime)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data AwaitInputData = AwaitInputData
  { sessionId :: !SessionId,
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
    correlationKey :: !(Maybe Text),
    force :: !Bool,
    input :: !Text,
    resumedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data RecordInteractiveSessionData = RecordInteractiveSessionData
  { sessionId :: !SessionId,
    agentId :: !Text,
    focus :: !Text,
    scope :: !MemoryScope,
    subjectRef :: !(Maybe Text),
    startedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data RecordTurnData = RecordTurnData
  { sessionId :: !SessionId,
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

data SessionStartedData = SessionStartedData
  { sessionId :: !SessionId,
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
    completedAt :: !UTCTime,
    modelUsed :: !(Maybe Text),
    summary :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data SessionFailedData = SessionFailedData
  { sessionId :: !SessionId,
    failedAt :: !UTCTime,
    errorMessage :: !Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data SessionAwaitingData = SessionAwaitingData
  { sessionId :: !SessionId,
    reason :: !Text,
    correlationKey :: !(Maybe Text),
    deadline :: !(Maybe UTCTime),
    awaitedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data SessionResumedData = SessionResumedData
  { sessionId :: !SessionId,
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
      correlationKey <- o .:? "correlationKey"
      force <- o .:? "force" .!= isNothing correlationKey
      input <- o .: "input"
      resumedAt <- o .: "resumedAt"
      pure SessionResumedData {sessionId, correlationKey, force, input, resumedAt}

data InteractiveSessionRecordedData = InteractiveSessionRecordedData
  { sessionId :: !SessionId,
    agentId :: !Text,
    focus :: !Text,
    scope :: !MemoryScope,
    subjectRef :: !(Maybe Text),
    startedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data TurnRecordedData = TurnRecordedData
  { sessionId :: !SessionId,
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
  deriving anyclass (FromJSON, ToJSON)

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
        -- into Running, and thus into Awaiting and RecordTurn — must initialize both.
        B.slot @"awaitedCorrelationKey" =: lit Nothing
        B.slot @"lastTurnIndex" =: lit (-1)
        B.emit
          wireSessionStarted
          SessionStartedTermFields
            { sessionId = d.sessionId,
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
        B.emit
          wireInteractiveSessionRecorded
          InteractiveSessionRecordedTermFields
            { sessionId = d.sessionId,
              agentId = d.agentId,
              focus = d.focus,
              scope = d.scope,
              subjectRef = d.subjectRef,
              startedAt = d.startedAt
            }
        B.goto Interactive

    B.from Running do
      B.onCmd inCtorCompleteSession $ \d -> B.do
        B.emit
          wireSessionCompleted
          SessionCompletedTermFields
            { sessionId = d.sessionId,
              completedAt = d.completedAt,
              modelUsed = d.modelUsed,
              summary = d.summary
            }
        B.goto Completed

      B.onCmd inCtorFailSession $ \d -> B.do
        B.emit
          wireSessionFailed
          SessionFailedTermFields
            { sessionId = d.sessionId,
              failedAt = d.failedAt,
              errorMessage = d.errorMessage
            }
        B.goto Failed

      B.onCmd inCtorRecordTurn $ \d -> B.do
        -- Turn identity: (sessionId, turnIndex). Indexes must strictly increase, so a
        -- re-delivered or out-of-order turn cannot silently overwrite a committed one.
        -- 'turnIndex' is already in the event payload, so replay recovers it and existing
        -- strictly-increasing streams rehydrate unchanged (verified by Audit B).
        B.requireGt d.turnIndex (B.reg @"lastTurnIndex")
        B.slot @"lastTurnIndex" =: d.turnIndex
        B.emit
          wireTurnRecorded
          TurnRecordedTermFields
            { sessionId = d.sessionId,
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
        B.slot @"awaitedCorrelationKey" =: d.correlationKey
        B.emit
          wireSessionAwaiting
          SessionAwaitingTermFields
            { sessionId = d.sessionId,
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
        B.requireGuard
          ((d.force .== lit True) .|| (d.correlationKey .== B.reg @"awaitedCorrelationKey"))
        B.slot @"awaitedCorrelationKey" =: lit Nothing
        B.emit
          wireSessionResumed
          SessionResumedTermFields
            { sessionId = d.sessionId,
              correlationKey = d.correlationKey,
              -- Mandatory for replay: the guard reads 'force', and hydration can only
              -- recover command fields that the event payload carries.
              force = d.force,
              input = d.input,
              resumedAt = d.resumedAt
            }
        B.goto Running

      B.onCmd inCtorCompleteSession $ \d -> B.do
        B.emit
          wireSessionCompleted
          SessionCompletedTermFields
            { sessionId = d.sessionId,
              completedAt = d.completedAt,
              modelUsed = d.modelUsed,
              summary = d.summary
            }
        B.goto Completed

      B.onCmd inCtorFailSession $ \d -> B.do
        B.emit
          wireSessionFailed
          SessionFailedTermFields
            { sessionId = d.sessionId,
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
