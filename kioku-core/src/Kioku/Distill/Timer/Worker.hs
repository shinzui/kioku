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
import Data.Aeson.Types qualified as Aeson
import Data.HashMap.Strict (HashMap)
import Data.HashMap.Strict qualified as HashMap
import Data.Int (Int64)
import Data.Text qualified as Text
import Data.Time (NominalDiffTime, addUTCTime)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Telemetry (KeiroMetrics)
import Keiro.Timer
  ( TimerId (..),
    TimerRequest (..),
    TimerRow (..),
    TimerWorkerOptions (..),
    deadLetterTimer,
    requeueStuckTimer,
    runTimerWorkerWith,
    scheduleTimerTx,
  )
import Kioku.Api.Access (MemoryContextProvider (..), MemorySpaceId, memorySpaceIdText)
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
import Kioku.Partition (parsePartitionSpace)
import Kioku.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..))
import OpenTelemetry.Attributes qualified as Attr
import Shibuya.Telemetry.Effect (Tracing, addAttributes, defaultSpanArguments, withSpan')
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
      l2Result <- fireL2SceneTimer contexts rt row
      case l2Result of
        FireNotMine -> fireL3PersonaTimer contexts rt row
        outcome -> pure outcome
    outcome -> pure outcome

-- | Turn a fire verdict into keiro timer state.
--
-- Returning 'Nothing' to keiro means "do not mark this row fired"; every such
-- branch has already moved the row itself, so the timer never sits in @firing@
-- waiting on the 300-second stale requeue.
--
-- Every diagnostic this writes names the memory space, including the @last_error@ that lands in
-- the dead-letter row. That column is what an operator actually reads at three in the morning,
-- and a dead-lettered distillation that does not say which tenant it belongs to is a page
-- somebody has to answer with a query.
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
    let annotated = spaceQualified row reason
    logTimer row ("dead-lettering: " <> annotated)
    void (deadLetterTimer row.timerId annotated)
    pure Nothing
  FireNotMine -> do
    logTimer row "no handler owns this process manager; requeueing"
    rescheduleClaimedTimer row unknownTimerRetryDelay
    pure Nothing

-- | Prefix a diagnostic with the memory space the timer's payload names.
--
-- @unknown@ covers the payloads that have no space to name: a malformed payload, or one from a
-- process manager that is not Kioku's. Those are exactly the cases where the timer is about to
-- be dead-lettered, so saying "unknown" is more useful than silently claiming the legacy space.
spaceQualified :: TimerRow -> Text -> Text
spaceQualified row reason =
  "[memory space "
    <> maybe "unknown" memorySpaceIdText (timerPayloadSpace row.payload)
    <> "] "
    <> reason

-- | The memory space a timer payload names, for diagnostics only.
--
-- Every one of the three payload types carries the space, and each decodes it through
-- 'parsePartitionSpace' — the same function this uses — so this cannot disagree with the handler
-- that actually acts on the payload. It is read here rather than returned by the handlers so
-- that a span and a dead-letter row can name the space even when no handler claimed the timer.
timerPayloadSpace :: Aeson.Value -> Maybe MemorySpaceId
timerPayloadSpace = \case
  Aeson.Object o -> Aeson.parseMaybe parsePartitionSpace o
  _ -> Nothing

-- | Span attributes for one fire attempt.
--
-- The space is here, on the trace, and deliberately not on a metric: a memory space is
-- caller-supplied text with no bound on how many distinct values exist, and a counter labelled
-- by it is an unbounded time series per tenant. Traces are sampled and per-incident; that is the
-- right place for an identifier a caller chose.
timerSpanAttributes :: TimerRow -> HashMap Text Attr.Attribute
timerSpanAttributes row =
  HashMap.fromList
    ( [ ("kioku.timer.process_manager", Attr.toAttribute row.processManagerName),
        ("kioku.timer.id", Attr.toAttribute (timerIdText row.timerId)),
        ("kioku.timer.attempts", Attr.toAttribute (fromIntegral @Int @Int64 row.attempts))
      ]
        <> foldMap
          (\space -> [("kioku.memory_space_id", Attr.toAttribute (memorySpaceIdText space))])
          (timerPayloadSpace row.payload)
    )

-- | What the fire decided, as a bounded outcome plus an unbounded reason.
--
-- The outcome is one of four constants, so it is safe anywhere including a metric label. The
-- reason is free text — an LLM provider message, a codec error — and stays on the span.
fireOutcomeAttributes :: FireOutcome -> HashMap Text Attr.Attribute
fireOutcomeAttributes = \case
  FireCompleted _ -> HashMap.fromList [outcomeAttr "completed"]
  FireRetryLater _ note -> HashMap.fromList [outcomeAttr "retry", reasonAttr note]
  FireFailedPermanently reason -> HashMap.fromList [outcomeAttr "dead_letter", reasonAttr reason]
  FireNotMine -> HashMap.fromList [outcomeAttr "not_mine"]
  where
    outcomeAttr value = ("kioku.timer.outcome", Attr.toAttribute (value :: Text))
    reasonAttr value = ("kioku.timer.reason", Attr.toAttribute value)

timerIdText :: TimerId -> Text
timerIdText (TimerId uuid) = UUID.toText uuid

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

-- | Claim and fire at most one due timer, inside a span that names the memory space.
--
-- keiro's own timer metrics stay exactly as they are: they carry no space and no principal, and
-- this deliberately adds neither. See 'timerSpanAttributes'.
runKiokuTimerWorkerOnce ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es, Tracing :> es) =>
  Maybe KeiroMetrics ->
  MemoryContextProvider (Eff es) ->
  DistillRuntime ->
  FindMergeCandidates es ->
  UTCTime ->
  Eff es (Maybe TimerRow)
runKiokuTimerWorkerOnce metrics contexts rt finder now =
  runTimerWorkerWith metrics kiokuTimerWorkerOptions now \row ->
    withSpan' "kioku.timer.fire" defaultSpanArguments \fireSpan -> do
      addAttributes fireSpan (timerSpanAttributes row)
      outcome <- fireKiokuTimer contexts rt finder row
      addAttributes fireSpan (fireOutcomeAttributes outcome)
      applyFireOutcome row outcome

-- | Claim and fire due timers until none remain, returning how many were
-- processed.
--
-- The old loop slept between every timer, capping throughput at one timer per
-- poll interval. This cannot spin: every outcome other than 'FireCompleted'
-- either moves the row's @fire_at@ at least 30 seconds out or puts it in a
-- terminal state, so a timer processed in this pass is not claimable again
-- within it.
drainKiokuTimers ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es, Tracing :> es) =>
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
