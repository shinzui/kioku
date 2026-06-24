module Kioku.Memory.EventStream
  ( MemoryEventStream,
    memoryEventStream,
    memoryCodec,
    memoryStream,
    parseMemoryEvent,
  )
where

import Data.Aeson (Value)
import Data.Aeson.Types (parseEither)
import Data.Text qualified as Text
import Keiki.Core (HsPred)
import Keiki.Generics (emptyRegFile)
import Keiro.Codec (Codec (..), EventType (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kioku.Id (MemoryId, idText)
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
    Left err -> Left (Text.pack err)
