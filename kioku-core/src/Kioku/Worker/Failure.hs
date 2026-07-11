-- | Failure classification shared by kioku's background workers.
--
-- Both workers must answer the same question about every failure: is this
-- worth retrying, is it permanently broken, or does it not belong to me? This
-- module owns the half of that taxonomy that concerns kiroku store errors and
-- the embedding worker's retry schedule. The distillation timers' half lives in
-- "Kioku.Distill.Timer.Outcome".
module Kioku.Worker.Failure
  ( isTransientStoreError,
    embeddingRetryDelay,
  )
where

import Kiroku.Store.Error (StoreError (..))
import Shibuya.Core.Ack (RetryDelay (..))
import Shibuya.Core.Types (Attempt (..))

-- | Is this store error worth retrying?
--
-- Transient errors are the ones kiroku's own constructor documentation calls
-- retryable: a pool timeout, a connection torn down mid-operation, and the
-- catch-all connection error. Everything else describes a stable disagreement
-- between the caller and the database — a version conflict, a missing stream, a
-- server error whose SQLSTATE kiroku does not recognise — and would fail
-- identically on every redelivery.
--
-- The match lists every constructor explicitly rather than falling through a
-- wildcard so that @-Wincomplete-patterns@ forces a classification decision if
-- a future kiroku version adds one.
isTransientStoreError :: StoreError -> Bool
isTransientStoreError = \case
  PoolAcquisitionTimeout -> True
  ConnectionLost _ -> True
  ConnectionError _ -> True
  WrongExpectedVersion {} -> False
  EmptyAppendBatch _ -> False
  StreamNotFound _ -> False
  ReservedStreamName _ -> False
  StreamNameTooLong _ _ -> False
  StreamAlreadyExists _ -> False
  DuplicateEvent _ -> False
  EventAlreadyLinked _ _ -> False
  LinkSourceEventMissing _ -> False
  UnexpectedServerError _ _ -> False

-- | Backoff for a redelivered @MemoryRecorded@ event, by zero-based delivery
-- attempt: 5s, 20s, 60s, then 180s.
--
-- The bound lives upstream, not here: the shibuya-kiroku adapter maps 'AckRetry'
-- onto kiroku's per-subscription retry policy, which dead-letters after five
-- total deliveries. At most four of these delays are ever consumed, and an
-- outage outlasting that window is recovered by the worker's startup backfill
-- rather than by retrying forever. 'Nothing' (an adapter that does not track
-- redeliveries) gets the longest delay.
embeddingRetryDelay :: Maybe Attempt -> RetryDelay
embeddingRetryDelay = \case
  Just (Attempt 0) -> RetryDelay 5
  Just (Attempt 1) -> RetryDelay 20
  Just (Attempt 2) -> RetryDelay 60
  _ -> RetryDelay 180
