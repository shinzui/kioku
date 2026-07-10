{-# LANGUAGE DataKinds #-}

module Kioku.Distill.Timer
  ( idleFlushSeconds,
    l1ExtractProcessManagerName,
    l1FinalTimerId,
    l1IdleTimerId,
    l1RampTimerId,
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

-- | Every timer id is a UUIDv5 over stable event data only, never over
-- @fireAt@, so re-projecting a session's events can never double-schedule.
--
-- The idle id in particular is one per session: keiro's @scheduleTimerTx@
-- upserts on @timer_id@ and re-arms the row (moving @fire_at@ forward) only
-- while it is still @scheduled@, so every recorded turn pushes the same single
-- row later instead of inserting another. That is the debounce — a 50-turn
-- session holds one idle timer, not fifty.
l1TimerIdFor :: Text -> TimerId
l1TimerIdFor suffix =
  TimerId $
    UUIDv5.generateNamed
      l1TimerNamespace
      (BS.unpack (TE.encodeUtf8 (l1ExtractProcessManagerName <> ":" <> suffix)))

l1IdleTimerId :: SessionId -> TimerId
l1IdleTimerId sid = l1TimerIdFor (idText sid <> ":idle")

l1RampTimerId :: SessionId -> Int -> TimerId
l1RampTimerId sid turnIndex =
  l1TimerIdFor (idText sid <> ":ramp:" <> Text.pack (show turnIndex))

l1FinalTimerId :: SessionId -> TimerId
l1FinalTimerId sid = l1TimerIdFor (idText sid <> ":final")

timerRequestsForEvent :: SessionEvent -> [TimerRequest]
timerRequestsForEvent = \case
  SessionStarted d ->
    [idleRequest d.sessionId (addUTCTime idleFlushSeconds d.startedAt) (Just 0)]
  InteractiveSessionRecorded d ->
    [idleRequest d.sessionId (addUTCTime idleFlushSeconds d.startedAt) (Just 0)]
  SessionCompleted d ->
    [finalRequest d.sessionId d.completedAt]
  SessionFailed d ->
    [finalRequest d.sessionId (failedAt d)]
  SessionAwaiting _ -> []
  SessionResumed _ -> []
  TurnRecorded d ->
    let idle = idleRequest d.sessionId (addUTCTime idleFlushSeconds d.recordedAt) (Just d.turnIndex)
        ramp = rampRequest d.sessionId d.turnIndex d.recordedAt
     in if isRampTurn d.turnIndex then [ramp, idle] else [idle]

idleRequest :: SessionId -> UTCTime -> Maybe Int -> TimerRequest
idleRequest sid = l1TimerRequest (l1IdleTimerId sid) sid "idle"

rampRequest :: SessionId -> Int -> UTCTime -> TimerRequest
rampRequest sid turnIndex fireAt =
  l1TimerRequest (l1RampTimerId sid turnIndex) sid "ramp" fireAt (Just turnIndex)

finalRequest :: SessionId -> UTCTime -> TimerRequest
finalRequest sid fireAt =
  l1TimerRequest (l1FinalTimerId sid) sid "final" fireAt Nothing

-- | @turnCount@ in the payload is diagnostic only; the real freshness check is
-- the @kioku_l1_watermarks@ read inside the pass.
l1TimerRequest :: TimerId -> SessionId -> Text -> UTCTime -> Maybe Int -> TimerRequest
l1TimerRequest timerId sid kind fireAt turnCount =
  TimerRequest
    { timerId,
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
