module Kioku.Session.EventStream
  ( SessionEventStream,
    sessionEventStream,
    sessionCodec,
    sessionStream,
    parseSessionEvent,
  )
where

import Data.Aeson (Value)
import Data.Aeson.Types (Parser, parseEither, withObject, (.:), (.:?))
import Data.Text qualified as Text
import Keiki.Core (HsPred)
import Keiki.Generics (emptyRegFile)
import Keiro.Codec (Codec (..), EventType (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Id (SessionId, idText, parseIdAnyPrefix)
import Kioku.Prelude
import Kioku.Session.Domain

type SessionEventStream =
  EventStream (HsPred SessionRegs SessionCommand) SessionRegs SessionVertex SessionCommand SessionEvent

sessionStream :: SessionId -> Stream SessionEventStream
sessionStream sid = Stream.entityStream (Stream.categoryUnsafe "kioku_session") (idText sid)

sessionEventStream :: SessionEventStream
sessionEventStream =
  EventStream
    { transducer = sessionTransducer,
      initialState = NotCreated,
      initialRegisters = emptyRegFile,
      eventCodec = sessionCodec,
      resolveStreamName = Stream.streamName,
      snapshotPolicy = Never,
      stateCodec = Nothing
    }

sessionCodec :: Codec SessionEvent
sessionCodec =
  Codec
    { eventTypes =
        EventType
          <$> "SessionStarted"
            :| [ "SessionCompleted",
                 "SessionFailed",
                 "InteractiveSessionRecorded",
                 "TurnRecorded"
               ],
      eventType =
        EventType . \case
          SessionStarted {} -> "SessionStarted"
          SessionCompleted {} -> "SessionCompleted"
          SessionFailed {} -> "SessionFailed"
          InteractiveSessionRecorded {} -> "InteractiveSessionRecorded"
          TurnRecorded {} -> "TurnRecorded",
      schemaVersion = 1,
      encode = toJSON,
      decode = const parseSessionEvent,
      upcasters = []
    }

parseSessionEvent :: Value -> Either Text SessionEvent
parseSessionEvent value =
  case parseEither parseJSON value of
    Right event -> Right event
    Left nativeErr ->
      case parseEither parseLegacySessionEvent value of
        Right event -> Right event
        Left legacyErr -> Left (Text.pack nativeErr <> "; legacy decode failed: " <> Text.pack legacyErr)

parseLegacySessionEvent :: Value -> Parser SessionEvent
parseLegacySessionEvent =
  withObject "Rei AgentSessionEvent" $ \o -> do
    tag <- o .: "type"
    payload <- o .: "data"
    case tag of
      "agent_session_started" -> SessionStarted <$> parseLegacySessionStarted payload
      "agent_session_completed" -> SessionCompleted <$> parseLegacySessionCompleted payload
      "agent_session_failed" -> SessionFailed <$> parseLegacySessionFailed payload
      "interactive_session_recorded" -> InteractiveSessionRecorded <$> parseLegacyInteractiveSessionRecorded payload
      other -> fail ("Unknown Rei AgentSessionEvent tag: " <> Text.unpack other)

parseLegacySessionStarted :: Value -> Parser SessionStartedData
parseLegacySessionStarted =
  withObject "Rei AgentSessionStartedData" $ \o -> do
    sessionId <- parseLegacySessionId =<< o .: "sessionId"
    intentionId <- o .:? "intentionId"
    previousSessionId <- traverse parseLegacySessionId =<< o .:? "previousSessionId"
    SessionStartedData sessionId
      <$> o .: "agentId"
      <*> o .: "focusType"
      <*> pure (sessionScope intentionId)
      <*> o .:? "focusTarget"
      <*> pure previousSessionId
      <*> o .: "startedAt"

parseLegacySessionCompleted :: Value -> Parser SessionCompletedData
parseLegacySessionCompleted =
  withObject "Rei AgentSessionCompletedData" $ \o ->
    SessionCompletedData
      <$> (parseLegacySessionId =<< o .: "sessionId")
      <*> o .: "completedAt"
      <*> o .:? "modelUsed"
      <*> o .:? "summary"

parseLegacySessionFailed :: Value -> Parser SessionFailedData
parseLegacySessionFailed =
  withObject "Rei AgentSessionFailedData" $ \o ->
    SessionFailedData
      <$> (parseLegacySessionId =<< o .: "sessionId")
      <*> o .: "failedAt"
      <*> o .: "errorMessage"

parseLegacyInteractiveSessionRecorded :: Value -> Parser InteractiveSessionRecordedData
parseLegacyInteractiveSessionRecorded =
  withObject "Rei InteractiveSessionRecordedData" $ \o -> do
    sessionId <- parseLegacySessionId =<< o .: "sessionId"
    intentionId <- o .:? "intentionId"
    InteractiveSessionRecordedData sessionId
      <$> o .: "agentId"
      <*> o .: "focusType"
      <*> pure (sessionScope intentionId)
      <*> pure Nothing
      <*> o .: "startedAt"

parseLegacySessionId :: Text -> Parser SessionId
parseLegacySessionId = either (fail . Text.unpack) pure . parseIdAnyPrefix

sessionScope :: Maybe Text -> MemoryScope
sessionScope = \case
  Just intentionId -> ScopeEntity reiNamespace (ScopeKind "intention") intentionId
  Nothing -> ScopeGlobal reiNamespace

reiNamespace :: Namespace
reiNamespace = Namespace "rei"
