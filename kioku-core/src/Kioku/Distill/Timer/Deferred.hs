{-# LANGUAGE DataKinds #-}

-- | Authorized discovery and foreground execution of parked distillation work.
module Kioku.Distill.Timer.Deferred
  ( DeferredTimer (..),
    DeferredPage (..),
    DeferredResumeResult (..),
    listDeferredTimers,
    resumeDeferredTimer,
  )
where

import Control.Concurrent (threadDelay)
import Data.Aeson qualified as Aeson
import Data.Text qualified as Text
import Effectful (Eff, IOE, raise, (:>))
import Effectful.Concurrent (runConcurrent)
import Effectful.Concurrent.Async (race)
import Effectful.Error.Static (Error)
import Effectful.Exception (finally, mask)
import Keiro.Timer qualified as Timer
import Kioku.AI.Config (AIExecutionError, AIFeature (..))
import Kioku.Api.Access
import Kioku.Distill.L1 (FindMergeCandidates)
import Kioku.Distill.L2 (SceneTimerPayload (..), l2SceneProcessManagerName)
import Kioku.Distill.L3 (PersonaTimerPayload (..), l3PersonaProcessManagerName)
import Kioku.Distill.Runtime (DistillRuntime, distillAvailability)
import Kioku.Distill.Timer (L1TimerPayload (..), l1ExtractProcessManagerName)
import Kioku.Distill.Timer.Outcome (FireOutcome (..))
import Kioku.Distill.Timer.Worker (fireKiokuTimer)
import Kioku.Id (SessionId, parseIdLenient)
import Kioku.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)

data DeferredTimer = DeferredTimer
  { timer :: !Timer.TimerRow,
    memorySpace :: !MemorySpaceId,
    features :: ![AIFeature],
    reason :: !Text
  }
  deriving stock (Eq, Show)

-- | Continue even when authorization removes every entry from a storage page.
-- The cursor is opaque storage position, not permission to inspect its timer.
data DeferredPage = DeferredPage
  { entries :: ![DeferredTimer],
    nextAfterTimerId :: !(Maybe Timer.TimerId)
  }
  deriving stock (Eq, Show)

data DeferredResumeResult
  = DeferredNotEligible
  | DeferredAccessDenied !MemoryAccessDenial
  | DeferredExecutionUnavailable !AIExecutionError
  | DeferredClaimRefused
  | DeferredOwnershipLost
  | DeferredFinished !FireOutcome
  deriving stock (Eq, Show)

deferredPrefix :: Text
deferredPrefix = "kioku:deferred:interactive-unavailable "

-- Decode exactly the handler's payload before authorizing or claiming anything.
inspectDeferred :: Timer.TimerInspection -> Maybe DeferredTimer
inspectDeferred inspection = do
  let row = inspection.timer
  guard (row.status == Timer.Dead)
  reason <- inspection.lastError
  guard (deferredPrefix `Text.isPrefixOf` reason)
  (space, features) <-
    if row.processManagerName == l1ExtractProcessManagerName
      then do
        _ <- either (const Nothing) Just (parseIdLenient row.correlationId :: Either Text SessionId)
        payload <- decode @L1TimerPayload row.payload
        pure (payload.memorySpaceId, [Extraction, Consolidation])
      else
        if row.processManagerName == l2SceneProcessManagerName
          then do
            payload <- decode @SceneTimerPayload row.payload
            pure (payload.memorySpaceId, [Scene])
          else
            if row.processManagerName == l3PersonaProcessManagerName
              then do
                payload <- decode @PersonaTimerPayload row.payload
                pure (payload.memorySpaceId, [Persona])
              else Nothing
  pure (DeferredTimer row space features reason)
  where
    decode :: (FromJSON a) => Aeson.Value -> Maybe a
    decode value = case Aeson.fromJSON value of
      Aeson.Success result -> Just result
      Aeson.Error _ -> Nothing

authorizeDeferred :: MemoryContextProvider (Eff es) -> DeferredTimer -> Eff es (Either MemoryAccessDenial ())
authorizeDeferred contexts entry = do
  let space = entry.memorySpace
      permissions = if Extraction `elem` entry.features then [MemoryDistill, MemoryRecord, MemoryForget] else [MemoryDistill]
  decision <- contexts.contextForSpace space
  pure $ do
    context <- decision
    if memoryContextSpace context /= space
      then Left (MemoryPermissionDenied space MemoryDistill)
      else case filter (not . (`memoryContextAllows` context)) permissions of
        missing : _ -> Left (MemoryPermissionDenied space missing)
        [] -> Right ()

-- | Recover expired leases, read one bounded storage page, and omit every row
-- whose payload or current authorization cannot be validated. No AI is invoked.
listDeferredTimers ::
  (Store :> es) =>
  MemoryContextProvider (Eff es) ->
  Timer.DeadTimerPageRequest ->
  Eff es (Either Timer.DeadTimerReadError DeferredPage)
listDeferredTimers contexts request = do
  void Timer.recoverExpiredTimerResumes
  page <- Timer.findDeadTimers (Timer.DeadTimerFilter Nothing (Timer.ReasonPrefix deferredPrefix)) request
  case page of
    Left err -> pure (Left err)
    Right found -> do
      authorized <- forM (mapMaybe inspectDeferred found.timers) $ \entry -> do
        decision <- authorizeDeferred contexts entry
        pure (either (const Nothing) (const (Just entry)) decision)
      pure (Right (DeferredPage (mapMaybe id authorized) found.nextAfterTimerId))

-- | Claims count toward the same eight-attempt ceiling as background work.
-- Unavailable preflights do not claim. All unsuccessful foreground outcomes
-- re-park with the original reason; retries require another explicit resume.
-- A renewing lease fences finalization and stops local work on ownership loss.
-- External effects still rely on distillation's existing idempotent writes.
resumeDeferredTimer ::
  (IOE :> es, Store :> es, KirokuStoreResource :> es, Error StoreError :> es) =>
  MemoryContextProvider (Eff es) ->
  DistillRuntime ->
  FindMergeCandidates es ->
  Timer.TimerId ->
  Eff es DeferredResumeResult
resumeDeferredTimer contexts rt finder tid = do
  void Timer.recoverExpiredTimerResumes
  inspection <- Timer.lookupTimerInspection tid
  case inspection >>= inspectDeferred of
    Nothing -> pure DeferredNotEligible
    Just entry -> do
      decision <- authorizeDeferred contexts entry
      case decision of
        Left denial -> pure (DeferredAccessDenied denial)
        Right () -> case traverse (distillAvailability rt) entry.features of
          Left err -> pure (DeferredExecutionUnavailable err)
          Right _ -> mask $ \restore -> do
            claimed <-
              Timer.claimDeadTimer
                Timer.DeadTimerClaimRequest
                  { timerId = tid,
                    processManagerName = entry.timer.processManagerName,
                    expectedReason = entry.reason,
                    maxAttempts = 8,
                    leaseSeconds = 120
                  }
            case claimed of
              Left _ -> pure DeferredClaimRefused
              Right Nothing -> pure DeferredClaimRefused
              Right (Just claim) ->
                restore (runClaim claim) `finally` void (Timer.parkTimerResume claim)
  where
    runClaim claim = do
      -- Keep renewal alive through execution and token-checked finalization.
      result <- runConcurrent $ race (raise (execute claim)) (raise (heartbeat claim))
      pure (either id (const DeferredOwnershipLost) result)
    execute claim = do
      outcome <- fireKiokuTimer contexts rt finder (Timer.resumeClaimTimer claim)
      finalized <- case outcome of
        FireCompleted event -> Timer.completeTimerResume claim event
        _ -> Timer.parkTimerResume claim
      pure (if finalized then DeferredFinished outcome else DeferredOwnershipLost)
    heartbeat claim = do
      liftIO (threadDelay (30 * 1000 * 1000))
      renewed <- Timer.renewTimerResume claim 120
      case renewed of
        Right True -> heartbeat claim
        _ -> pure ()
