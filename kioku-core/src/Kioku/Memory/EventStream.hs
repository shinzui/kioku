module Kioku.Memory.EventStream
  ( MemoryEventStream,
    memoryEventStream,
    memoryCodec,
    memoryStream,
    parseMemoryEvent,
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
import Kioku.Id (MemoryId, SessionId, idText, parseIdLenient)
import Kioku.Memory.Domain
import Kioku.Prelude

type MemoryEventStream =
  EventStream (HsPred MemoryRegs MemoryCommand) MemoryRegs MemoryVertex MemoryCommand MemoryEvent

memoryStream :: MemoryId -> Stream MemoryEventStream
memoryStream mid = Stream.entityStream (Stream.categoryUnsafe "kioku_memory") (idText mid)

memoryEventStream :: MemoryEventStream
memoryEventStream =
  EventStream
    { transducer = memoryTransducer,
      initialState = NotCreated,
      initialRegisters = emptyRegFile,
      eventCodec = memoryCodec,
      resolveStreamName = Stream.streamName,
      snapshotPolicy = Never,
      stateCodec = Nothing
    }

memoryCodec :: Codec MemoryEvent
memoryCodec =
  Codec
    { eventTypes =
        EventType
          <$> "MemoryRecorded"
            :| [ "MemorySuperseded",
                 "MemoryArchived",
                 "MemoryTagsUpdated",
                 "MemoryConfidenceUpdated",
                 "MemoryMerged"
               ],
      eventType =
        EventType . \case
          MemoryRecorded {} -> "MemoryRecorded"
          MemorySuperseded {} -> "MemorySuperseded"
          MemoryArchived {} -> "MemoryArchived"
          MemoryTagsUpdated {} -> "MemoryTagsUpdated"
          MemoryConfidenceUpdated {} -> "MemoryConfidenceUpdated"
          MemoryMerged {} -> "MemoryMerged",
      schemaVersion = 1,
      encode = toJSON,
      decode = const parseMemoryEvent,
      upcasters = []
    }

parseMemoryEvent :: Value -> Either Text MemoryEvent
parseMemoryEvent value =
  case parseEither parseJSON value of
    Right event -> Right event
    Left nativeErr ->
      case parseEither parseLegacyMemoryEvent value of
        Right event -> Right event
        Left legacyErr -> Left (Text.pack nativeErr <> "; legacy decode failed: " <> Text.pack legacyErr)

parseLegacyMemoryEvent :: Value -> Parser MemoryEvent
parseLegacyMemoryEvent =
  withObject "Rei AgentMemoryEvent" $ \o -> do
    tag <- o .: "type"
    payload <- o .: "data"
    case tag of
      "agent_memory_recorded" -> MemoryRecorded <$> parseLegacyMemoryRecorded payload
      "agent_memory_superseded" -> MemorySuperseded <$> parseLegacyMemorySuperseded payload
      "agent_memory_archived" -> MemoryArchived <$> parseLegacyMemoryArchived payload
      "agent_memory_tags_updated" -> MemoryTagsUpdated <$> parseLegacyMemoryTagsUpdated payload
      "agent_memory_confidence_updated" -> MemoryConfidenceUpdated <$> parseLegacyMemoryConfidenceUpdated payload
      other -> fail ("Unknown Rei AgentMemoryEvent tag: " <> Text.unpack other)

parseLegacyMemoryRecorded :: Value -> Parser MemoryRecordedData
parseLegacyMemoryRecorded =
  withObject "Rei AgentMemoryRecordedData" $ \o -> do
    memoryId <- parseLegacyMemoryId =<< o .: "memoryId"
    sessionId <- traverse parseLegacySessionId =<< o .:? "sessionId"
    scope <- parseLegacyAnchor =<< o .: "anchor"
    supersedes <- traverse parseLegacyMemoryId =<< o .:? "supersedes"
    MemoryRecordedData memoryId
      <$> o .: "agentId"
      <*> pure sessionId
      <*> pure scope
      <*> o .: "memoryType"
      <*> o .: "content"
      <*> pure 100
      <*> o .: "confidence"
      <*> o .: "tags"
      <*> pure supersedes
      <*> o .: "recordedAt"

parseLegacyMemorySuperseded :: Value -> Parser MemorySupersededData
parseLegacyMemorySuperseded =
  withObject "Rei AgentMemorySupersededData" $ \o ->
    MemorySupersededData
      <$> (parseLegacyMemoryId =<< o .: "memoryId")
      <*> (parseLegacyMemoryId =<< o .: "supersededBy")
      <*> o .: "supersededAt"

parseLegacyMemoryArchived :: Value -> Parser MemoryArchivedData
parseLegacyMemoryArchived =
  withObject "Rei AgentMemoryArchivedData" $ \o ->
    MemoryArchivedData
      <$> (parseLegacyMemoryId =<< o .: "memoryId")
      <*> o .: "archivedAt"

parseLegacyMemoryTagsUpdated :: Value -> Parser MemoryTagsUpdatedData
parseLegacyMemoryTagsUpdated =
  withObject "Rei AgentMemoryTagsUpdatedData" $ \o ->
    MemoryTagsUpdatedData
      <$> (parseLegacyMemoryId =<< o .: "memoryId")
      <*> o .: "tags"
      <*> o .: "updatedAt"

parseLegacyMemoryConfidenceUpdated :: Value -> Parser MemoryConfidenceUpdatedData
parseLegacyMemoryConfidenceUpdated =
  withObject "Rei AgentMemoryConfidenceUpdatedData" $ \o ->
    MemoryConfidenceUpdatedData
      <$> (parseLegacyMemoryId =<< o .: "memoryId")
      <*> o .: "confidence"
      <*> o .: "updatedAt"

parseLegacyAnchor :: Value -> Parser MemoryScope
parseLegacyAnchor =
  withObject "Rei MemoryAnchor" $ \o -> do
    anchorType <- o .: "type"
    case anchorType of
      "intention" -> ScopeEntity reiNamespace (ScopeKind "intention") <$> o .: "id"
      "habit" -> ScopeEntity reiNamespace (ScopeKind "habit") <$> o .: "id"
      "workspace" -> pure (ScopeGlobal reiNamespace)
      other -> fail ("Unknown Rei MemoryAnchor type: " <> Text.unpack other)

parseLegacyMemoryId :: Text -> Parser MemoryId
parseLegacyMemoryId = either (fail . Text.unpack) pure . parseIdLenient

parseLegacySessionId :: Text -> Parser SessionId
parseLegacySessionId = either (fail . Text.unpack) pure . parseIdLenient

reiNamespace :: Namespace
reiNamespace = Namespace "rei"
