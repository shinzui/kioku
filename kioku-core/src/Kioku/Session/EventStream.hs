module Kioku.Session.EventStream
  ( SessionEventStream,
    sessionEventStream,
    sessionCodec,
    sessionStream,
    parseSessionEvent,
  )
where

import Data.Aeson (Value)
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import Data.Text qualified as Text
import Keiki.Core (HsPred)
import Keiki.Generics (emptyRegFile)
import Keiro.Codec (Codec (..), EventType (..))
import Keiro.EventStream (EventStream (..), SnapshotPolicy (..))
import Keiro.EventStream.Validate (ValidatedEventStream, mkEventStreamOrThrow)
import Keiro.Stream (Stream)
import Keiro.Stream qualified as Stream
import Kioku.Id (SessionId, idText)
import Kioku.Prelude
import Kioku.Session.Domain

type SessionEventStream =
  EventStream (HsPred SessionRegs SessionCommand) SessionRegs SessionVertex SessionCommand SessionEvent

sessionStream :: SessionId -> Stream SessionEventStream
sessionStream sid = Stream.entityStream (Stream.categoryUnsafe "kioku_session") (idText sid)

sessionEventStream :: ValidatedEventStream (HsPred SessionRegs SessionCommand) SessionRegs SessionVertex SessionCommand SessionEvent
sessionEventStream =
  mkEventStreamOrThrow "kioku-session" sessionEventStreamDefinition

sessionEventStreamDefinition :: SessionEventStream
sessionEventStreamDefinition =
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
                 "SessionAwaiting",
                 "SessionResumed",
                 "InteractiveSessionRecorded",
                 "TurnRecorded"
               ],
      eventType =
        EventType . \case
          SessionStarted {} -> "SessionStarted"
          SessionCompleted {} -> "SessionCompleted"
          SessionFailed {} -> "SessionFailed"
          SessionAwaiting {} -> "SessionAwaiting"
          SessionResumed {} -> "SessionResumed"
          InteractiveSessionRecorded {} -> "InteractiveSessionRecorded"
          TurnRecorded {} -> "TurnRecorded",
      schemaVersion = 1,
      encode = toJSON,
      decode = const parseSessionEvent,
      upcasters = []
    }

parseSessionEvent :: Value -> Either Text SessionEvent
parseSessionEvent = first Text.pack . parseEither parseJSON
