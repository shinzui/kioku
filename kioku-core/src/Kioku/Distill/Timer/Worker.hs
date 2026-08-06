{-# LANGUAGE DataKinds #-}

module Kioku.Distill.Timer.Worker
  ( applyFireOutcome,
    drainKiokuTimers,
    fireKiokuTimer,
    fireL1Timer,
    kiokuTimerWorkerOptions,
    runKiokuTimerWorkerOnce,
  )
where

import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, addUTCTime)
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Telemetry (KeiroMetrics)
import Keiro.Timer
  ( TimerRequest (..),
    TimerRow (..),
    TimerWorkerOptions (..),
    deadLetterTimer,
    requeueStuckTimer,
    runTimerWorkerWith,
    scheduleTimerTx,
  )
import Kioku.Api.Access (MemoryContextProvider (..))
import Kioku.Distill.L1 (FindMergeCandidates, L1Error (..), L1RunMode (..), distillSessionL1)
import Kioku.Distill.L2 (fireL2SceneTimer)
import Kioku.Distill.L3 (fireL3PersonaTimer)
import Kioku.Distill.Runtime (DistillRuntime)
import Kioku.Distill.Timer (L1TimerPayload (..), l1ExtractProcessManagerName)
import Kioku.Distill.Timer.Outcome
  ( FireOutcome (..),
    fireRetryDelay,
    timerMarkerEventId,
    unknownTimerRetryDelay,
  )
import Kioku.Id (parseIdLenient)
import Kioku.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..))
import System.IO qualified as IO

-- | kioku's timer policy.
--
-- Eight claims with 'fireRetryDelay''s backoff spans roughly an hour before a
-- timer is dead-lettered, which is the point of the ceiling: a structurally
-- failing distillation (a conversation past the model's context window, say)
-- must stop costing LLM tokens and start being visible instead. The 300-second
-- stale requeue is keiro's default and unchanged.
kiokuTimerWorkerOptions :: TimerWorkerOptions
kiokuTimerWorkerOptions =
  TimerWorkerOptions {maxAttempts = Just 8, requeueStuckAfter = Just 300}

-- | Fire one L1 distillation timer.
--
-- A background pass discovers its own work, so it cannot arrive holding an authorization
-- context the way an interactive caller does. It reads the memory space out of the timer
-- payload — put there by the projection from the session event, and defaulted to the legacy
-- space for timers scheduled before that field existed — and asks the provider for a decision
-- about /that/ space. An embedded host wires the provider to
-- 'Kioku.Api.Access.assumeAuthorizedContextProvider'.
fireL1Timer ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryContextProvider (Eff es) ->
  DistillRuntime ->
  FindMergeCandidates es ->
  TimerRow ->
  Eff es FireOutcome
fireL1Timer contexts rt finder row
  | row.processManagerName /= l1ExtractProcessManagerName =
      pure FireNotMine
  | otherwise =
      case parseIdLenient row.correlationId of
        -- A correlation id that is not a session id will never become one.
        -- This used to be marked fired, which looked like success.
        Left _err ->
          pure
            ( FireFailedPermanently
                ("L1 timer correlation id is not a session id: " <> row.correlationId)
            )
        Right sid ->
          -- A payload this handler cannot parse will not parse on the next attempt either.
          case Aeson.fromJSON @L1TimerPayload row.payload of
            Aeson.Error err ->
              pure (FireFailedPermanently ("L1 timer payload is malformed: " <> Text.pack err))
            Aeson.Success payload -> do
              decision <- contexts.contextForSpace payload.memorySpaceId
              case decision of
                -- Dead-letter rather than retry: a refusal to distill this space is a
                -- configuration fact, and quietly retrying it every 30 seconds forever would
                -- hide it. The dead-letter row is where an operator can see and requeue it.
                Left denial ->
                  pure
                    ( FireFailedPermanently
                        ("L1 timer is not authorized for its memory space: " <> Text.pack (show denial))
                    )
                Right context -> do
                  result <- distillSessionL1 context RespectWatermark rt finder sid
                  pure $
                    case result of
                      -- Both a real pass and a watermark skip mean this timer is done.
                      Right _outcome -> FireCompleted (timerMarkerEventId row.timerId)
                      -- A session may legitimately be gone (deleted data); nothing to do.
                      Left (L1SessionNotFound _) -> FireCompleted (timerMarkerEventId row.timerId)
                      -- Everything else — a failed LLM extraction or consolidation, a
                      -- read-model error, a failed write — is worth another attempt, and
                      -- the attempt ceiling bounds how many.
                      Left err -> FireRetryLater (fireRetryDelay row.attempts) (Text.pack (show err))

-- | Offer the timer to each handler in turn. The handlers identify their own
-- work by process-manager name, so a 'FireNotMine' simply falls through to the
-- next one; a 'FireNotMine' from all three means no handler owns this timer, and
-- the runner decides what to do about that.
fireKiokuTimer ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemoryContextProvider (Eff es) ->
  DistillRuntime ->
  FindMergeCandidates es ->
  TimerRow ->
  Eff es FireOutcome
fireKiokuTimer contexts rt finder row = do
  l1Result <- fireL1Timer contexts rt finder row
  case l1Result of
    FireNotMine -> do
      l2Result <- fireL2SceneTimer rt row
      case l2Result of
        FireNotMine -> fireL3PersonaTimer rt row
        outcome -> pure outcome
    outcome -> pure outcome

-- | Turn a fire verdict into keiro timer state.
--
-- Returning 'Nothing' to keiro means "do not mark this row fired"; every such
-- branch has already moved the row itself, so the timer never sits in @firing@
-- waiting on the 300-second stale requeue.
applyFireOutcome ::
  (IOE :> es, Store :> es) =>
  TimerRow ->
  FireOutcome ->
  Eff es (Maybe EventId)
applyFireOutcome row = \case
  FireCompleted eventId -> pure (Just eventId)
  FireRetryLater delay note -> do
    logTimer row ("retrying in " <> Text.pack (show delay) <> ": " <> note)
    rescheduleClaimedTimer row delay
    pure Nothing
  FireFailedPermanently reason -> do
    logTimer row ("dead-lettering: " <> reason)
    void (deadLetterTimer row.timerId reason)
    pure Nothing
  FireNotMine -> do
    logTimer row "no handler owns this process manager; requeueing"
    rescheduleClaimedTimer row unknownTimerRetryDelay
    pure Nothing

-- | Push a claimed timer back out into the future.
--
-- keiro has no single-call "reschedule a firing timer" at this pin, so this is
-- two public calls: 'requeueStuckTimer' moves the claimed @firing@ row back to
-- @scheduled@ (leaving @fire_at@ alone), and 'scheduleTimerTx' then re-arms it —
-- its upsert only updates rows that are @scheduled@, which is exactly what the
-- first call just guaranteed. @attempts@ is deliberately not reset, so the
-- ceiling counts total claims.
rescheduleClaimedTimer ::
  (IOE :> es, Store :> es) =>
  TimerRow ->
  NominalDiffTime ->
  Eff es ()
rescheduleClaimedTimer row delay = do
  requeued <- requeueStuckTimer row.timerId
  when requeued do
    now <- liftIO getCurrentTime
    runTransaction $
      scheduleTimerTx
        TimerRequest
          { timerId = row.timerId,
            processManagerName = row.processManagerName,
            correlationId = row.correlationId,
            fireAt = addUTCTime delay now,
            payload = row.payload
          }

runKiokuTimerWorkerOnce ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  Maybe KeiroMetrics ->
  MemoryContextProvider (Eff es) ->
  DistillRuntime ->
  FindMergeCandidates es ->
  UTCTime ->
  Eff es (Maybe TimerRow)
runKiokuTimerWorkerOnce metrics contexts rt finder now =
  runTimerWorkerWith metrics kiokuTimerWorkerOptions now \row ->
    fireKiokuTimer contexts rt finder row >>= applyFireOutcome row

-- | Claim and fire due timers until none remain, returning how many were
-- processed.
--
-- The old loop slept between every timer, capping throughput at one timer per
-- poll interval. This cannot spin: every outcome other than 'FireCompleted'
-- either moves the row's @fire_at@ at least 30 seconds out or puts it in a
-- terminal state, so a timer processed in this pass is not claimable again
-- within it.
drainKiokuTimers ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  Maybe KeiroMetrics ->
  MemoryContextProvider (Eff es) ->
  DistillRuntime ->
  FindMergeCandidates es ->
  Eff es Int
drainKiokuTimers metrics contexts rt finder = go 0
  where
    go processed = do
      now <- liftIO getCurrentTime
      claimed <- runKiokuTimerWorkerOnce metrics contexts rt finder now
      case claimed of
        Nothing -> pure processed
        Just _ -> go (processed + 1)

logTimer :: (IOE :> es) => TimerRow -> Text -> Eff es ()
logTimer row msg =
  liftIO
    ( IO.hPutStrLn
        IO.stderr
        ( Text.unpack
            ( "kioku-distill-timer["
                <> row.processManagerName
                <> " attempt "
                <> Text.pack (show row.attempts)
                <> "]: "
                <> msg
            )
        )
    )
