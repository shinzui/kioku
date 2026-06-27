{-# LANGUAGE DataKinds #-}

module Kioku.Distill.Timer
  ( idleFlushSeconds,
    l1ExtractProcessManagerName,
    l1TimerId,
    l1TimerScheduleProjection,
  )
where

import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.Foldable (traverse_)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Time (NominalDiffTime, addUTCTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUIDv5
import Keiro.Projection (InlineProjection (..))
import Keiro.Timer (TimerId (..), TimerRequest (..), scheduleTimerTx)
import Kioku.Id (SessionId, idText)
import Kioku.Prelude
import Kioku.Session.Domain
  ( InteractiveSessionRecordedData (..),
    SessionCompletedData (..),
    SessionEvent (..),
    SessionFailedData (..),
    SessionStartedData (..),
    TurnRecordedData (..),
  )

idleFlushSeconds :: NominalDiffTime
idleFlushSeconds = 30 * 60

l1ExtractProcessManagerName :: Text
l1ExtractProcessManagerName = "kioku-l1-extract"

l1TimerScheduleProjection :: InlineProjection SessionEvent
l1TimerScheduleProjection =
  InlineProjection
    { name = "kioku-l1-timer-schedule",
      apply = \event _recorded -> traverse_ scheduleTimerTx (timerRequestsForEvent event)
    }

l1TimerId :: SessionId -> Text -> UTCTime -> TimerId
l1TimerId sid kind fireAt =
  TimerId $
    UUIDv5.generateNamed
      l1TimerNamespace
      (BS.unpack (TE.encodeUtf8 raw))
  where
    raw =
      l1ExtractProcessManagerName
        <> ":"
        <> idText sid
        <> ":"
        <> kind
        <> ":"
        <> Text.pack (show fireAt)

timerRequestsForEvent :: SessionEvent -> [TimerRequest]
timerRequestsForEvent = \case
  SessionStarted d ->
    [l1TimerRequest d.sessionId "idle" (addUTCTime idleFlushSeconds d.startedAt) (Just 0)]
  InteractiveSessionRecorded d ->
    [l1TimerRequest d.sessionId "idle" (addUTCTime idleFlushSeconds d.startedAt) (Just 0)]
  SessionCompleted d ->
    [l1TimerRequest d.sessionId "final" d.completedAt Nothing]
  SessionFailed d ->
    [l1TimerRequest d.sessionId "final" (failedAt d) Nothing]
  SessionAwaiting _ -> []
  SessionResumed _ -> []
  TurnRecorded d ->
    let idle = l1TimerRequest d.sessionId "idle" (addUTCTime idleFlushSeconds d.recordedAt) (Just d.turnIndex)
        ramp = l1TimerRequest d.sessionId "ramp" d.recordedAt (Just d.turnIndex)
     in if isRampTurn d.turnIndex then [ramp, idle] else [idle]

l1TimerRequest :: SessionId -> Text -> UTCTime -> Maybe Int -> TimerRequest
l1TimerRequest sid kind fireAt turnCount =
  TimerRequest
    { timerId = l1TimerId sid kind fireAt,
      processManagerName = l1ExtractProcessManagerName,
      correlationId = idText sid,
      fireAt,
      payload =
        Aeson.object
          [ "kind" Aeson..= kind,
            "turnCount" Aeson..= turnCount
          ]
    }

isRampTurn :: Int -> Bool
isRampTurn n =
  n == 1 || n == 2 || n == 4 || n == 8 || n == 16 || (n > 16 && n `mod` 16 == 0)

l1TimerNamespace :: UUID
l1TimerNamespace =
  fromMaybe UUID.nil $
    UUID.fromString "6b696f6b-752d-7131-8000-6c3174696d72"
