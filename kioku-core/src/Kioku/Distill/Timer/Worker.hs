{-# LANGUAGE DataKinds #-}

module Kioku.Distill.Timer.Worker
  ( fireL1Timer,
    fireKiokuTimer,
    runKiokuTimerWorkerLoop,
    runKiokuTimerWorkerOnce,
    runL1TimerWorkerLoop,
    runL1TimerWorkerOnce,
  )
where

import Control.Concurrent (threadDelay)
import Control.Monad (forever)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Telemetry (KeiroMetrics)
import Keiro.Timer (TimerId (..), TimerRow (..), runTimerWorker)
import Kioku.Distill.L1 (FindMergeCandidates, L1Error (..), L1RunMode (..), distillSessionL1)
import Kioku.Distill.L2 (fireL2SceneTimer)
import Kioku.Distill.L3 (fireL3PersonaTimer)
import Kioku.Distill.Runtime (DistillRuntime)
import Kioku.Distill.Timer (l1ExtractProcessManagerName)
import Kioku.Id (parseIdAnyPrefix)
import Kioku.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Types (EventId (..))

fireL1Timer ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  DistillRuntime ->
  FindMergeCandidates es ->
  TimerRow ->
  Eff es (Maybe EventId)
fireL1Timer rt finder row
  | row.processManagerName /= l1ExtractProcessManagerName =
      pure Nothing
  | otherwise =
      case parseIdAnyPrefix row.correlationId of
        Left _err ->
          pure (Just (timerMarkerEventId row.timerId))
        Right sid -> do
          result <- distillSessionL1 RespectWatermark rt finder sid
          pure $
            case result of
              -- Both a real pass and a watermark skip mean this timer is done.
              Right _outcome -> Just (timerMarkerEventId row.timerId)
              Left (L1SessionNotFound _) -> Just (timerMarkerEventId row.timerId)
              Left _err -> Nothing

fireKiokuTimer ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  DistillRuntime ->
  FindMergeCandidates es ->
  TimerRow ->
  Eff es (Maybe EventId)
fireKiokuTimer rt finder row = do
  l1Result <- fireL1Timer rt finder row
  case l1Result of
    Just eventId -> pure (Just eventId)
    Nothing -> do
      l2Result <- fireL2SceneTimer rt row
      case l2Result of
        Just eventId -> pure (Just eventId)
        Nothing -> fireL3PersonaTimer rt row

runKiokuTimerWorkerOnce ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  Maybe KeiroMetrics ->
  DistillRuntime ->
  FindMergeCandidates es ->
  UTCTime ->
  Eff es (Maybe TimerRow)
runKiokuTimerWorkerOnce metrics rt finder now =
  runTimerWorker metrics now (fireKiokuTimer rt finder)

runL1TimerWorkerOnce ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  Maybe KeiroMetrics ->
  DistillRuntime ->
  FindMergeCandidates es ->
  UTCTime ->
  Eff es (Maybe TimerRow)
runL1TimerWorkerOnce metrics rt finder now =
  runTimerWorker metrics now (fireL1Timer rt finder)

runKiokuTimerWorkerLoop ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  Maybe KeiroMetrics ->
  DistillRuntime ->
  FindMergeCandidates es ->
  Int ->
  Eff es ()
runKiokuTimerWorkerLoop metrics rt finder pollMicros =
  forever do
    now <- liftIO getCurrentTime
    void (runKiokuTimerWorkerOnce metrics rt finder now)
    liftIO (threadDelay (max 100000 pollMicros))

runL1TimerWorkerLoop ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  Maybe KeiroMetrics ->
  DistillRuntime ->
  FindMergeCandidates es ->
  Int ->
  Eff es ()
runL1TimerWorkerLoop metrics rt finder pollMicros =
  forever do
    now <- liftIO getCurrentTime
    void (runL1TimerWorkerOnce metrics rt finder now)
    liftIO (threadDelay (max 100000 pollMicros))

timerMarkerEventId :: TimerId -> EventId
timerMarkerEventId (TimerId uuid) = EventId uuid
