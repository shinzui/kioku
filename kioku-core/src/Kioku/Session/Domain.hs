{-# LANGUAGE TemplateHaskell #-}

module Kioku.Session.Domain
  ( SessionVertex (..),
    SessionRegs,
    StartSessionData (..),
    CompleteSessionData (..),
    FailSessionData (..),
    RecordInteractiveSessionData (..),
    RecordTurnData (..),
    SessionCommand (..),
    commandSessionId,
    SessionStartedData (..),
    SessionCompletedData (..),
    SessionFailedData (..),
    InteractiveSessionRecordedData (..),
    TurnRecordedData (..),
    SessionEvent (..),
    eventSessionId,
    sessionTransducer,
  )
where

import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer)
import Keiki.Generics (emptyRegFile)
import Keiki.Generics.TH (deriveAggregate)
import Kioku.Api.Scope (MemoryScope)
import Kioku.Id (SessionId)
import Kioku.Prelude

data SessionVertex = NotCreated | Running | Completed | Failed | Interactive
  deriving stock (Eq, Show, Enum, Bounded)

type SessionRegs = '[]

data StartSessionData = StartSessionData
  { sessionId :: !SessionId,
    agentId :: !Text,
    focus :: !Text,
    scope :: !MemoryScope,
    subjectRef :: !(Maybe Text),
    previousSessionId :: !(Maybe SessionId),
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
  | RecordInteractiveSession !RecordInteractiveSessionData
  | RecordTurn !RecordTurnData
  deriving stock (Generic, Eq, Show)

commandSessionId :: SessionCommand -> SessionId
commandSessionId = \case
  StartSession d -> d.sessionId
  CompleteSession d -> d.sessionId
  FailSession d -> d.sessionId
  RecordInteractiveSession d -> d.sessionId
  RecordTurn d -> d.sessionId

data SessionStartedData = SessionStartedData
  { sessionId :: !SessionId,
    agentId :: !Text,
    focus :: !Text,
    scope :: !MemoryScope,
    subjectRef :: !(Maybe Text),
    previousSessionId :: !(Maybe SessionId),
    startedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

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
        B.emit
          wireSessionStarted
          SessionStartedTermFields
            { sessionId = d.sessionId,
              agentId = d.agentId,
              focus = d.focus,
              scope = d.scope,
              subjectRef = d.subjectRef,
              previousSessionId = d.previousSessionId,
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
  where
    isTerminal = \case
      Completed -> True
      Failed -> True
      Interactive -> True
      _ -> False
