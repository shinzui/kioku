module Kioku.Cli.Commands.Worker
  ( WorkerOptions (..),
    workerOptionsParser,
    runWorker,
  )
where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race)
import Control.Exception (SomeException, displayException, try)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Effectful (IOE, (:>))
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Distill.L1 (FindMergeCandidates, recallCandidates)
import Kioku.Distill.Runtime (newDistillRuntime)
import Kioku.Distill.Timer.Worker (drainKiokuTimers, runKiokuTimerWorkerOnce)
import Kioku.Memory.Embedding (EmbeddingConfig (..), resolveEmbeddingConfig, toEmbeddingModel)
import Kioku.Memory.Embedding.Worker (backfillMissingEmbeddings, runEmbeddingWorkerHost)
import Kioku.Recall.Capability (VectorCapability (..), detectVectorCapability)
import Kiroku.Store.Connection (KirokuStore, defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (Store)
import Options.Applicative
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

-- | The two one-shot modes are unrelated — an embedding backfill and firing one distillation
-- timer — so there is no combined meaning to define. As two 'switch'es they were silently
-- ordered: @--backfill --timers-once@ checked @timersOnce@ first and ignored @--backfill@
-- without a word. As a sum parsed from mutually exclusive alternatives, passing both is a
-- parse error.
data WorkerOptions
  = WorkerContinuous
  | WorkerBackfill
  | WorkerTimersOnce
  deriving stock (Eq, Show)

workerOptionsParser :: Parser WorkerOptions
workerOptionsParser =
  flag'
    WorkerBackfill
    ( long "backfill"
        <> help "Run one embedding backfill pass and exit (conflicts with --timers-once)"
    )
    <|> flag'
      WorkerTimersOnce
      ( long "timers-once"
          <> help "Claim and fire at most one due kioku distillation timer, then exit (conflicts with --backfill)"
      )
    <|> pure WorkerContinuous

runWorker :: WorkerOptions -> IO ()
runWorker opts = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  config <- resolveEmbeddingConfig
  withStore (defaultConnectionSettings (Text.pack connStr)) $ \st -> do
    tr <- noopTracer
    let env = AppEnv {store = st, tracer = tr, metrics = Nothing}
    case opts of
      WorkerTimersOnce -> runTimerOnce env config
      WorkerBackfill -> withCapability env config \capability ->
        runBackfill env capability config
      WorkerContinuous -> withCapability env config \capability ->
        runContinuousWorker env st capability config

withCapability :: AppEnv -> EmbeddingConfig -> (VectorCapability -> IO a) -> IO a
withCapability env config k = do
  result <- runAppIO env (detectVectorCapability config.dimensions)
  case result of
    Left storeErr -> ioError (userError ("kioku worker store error: " <> show storeErr))
    Right capability -> k capability

-- | Merge candidates come from hybrid recall over the atom's own text, not from
-- a priority-ordered scan prefix: a duplicate ranked below the scan window was
-- invisible to the consolidator and got re-stored forever. Recall degrades to
-- FTS-only without pgvector and to keyword-only when the embedding call fails,
-- so no capability gating is needed here.
mergeCandidateFinder ::
  (IOE :> es, Store :> es) =>
  EmbeddingConfig ->
  VectorCapability ->
  FindMergeCandidates es
mergeCandidateFinder config capability =
  recallCandidates (toEmbeddingModel config) capability mergeCandidateLimit

mergeCandidateLimit :: Int
mergeCandidateLimit = 8

runBackfill :: AppEnv -> VectorCapability -> EmbeddingConfig -> IO ()
runBackfill env capability config = do
  -- Refuse before any event is touched: a backfill under a mismatched dimension count would
  -- embed every memory in the store and fail the ::vector cast on every single one.
  case capability of
    VectorDimensionMismatch configured actual ->
      dieWorker (dimensionMismatchMessage configured actual)
    _ -> pure ()
  let model = toEmbeddingModel config
  result <- runAppIO env (backfillMissingEmbeddings capability model config.dimensions)
  case result of
    Left storeErr -> ioError (userError ("kioku worker backfill store error: " <> show storeErr))
    Right count -> putStrLn ("Backfilled " <> show count <> " memory embeddings.")

-- | Run both pipelines under supervision.
--
-- The timer loop used to run on a bare 'forkIO', which produced two silent
-- deaths. A store error aborted the loop's single error scope and killed only
-- the forked thread, leaving a process that looked alive while all distillation
-- had stopped. In the other direction, an embedding halt made shibuya exit its
-- processor gracefully, 'waitApp' return, and the whole process exit 0 — taking
-- the timer loop with it.
--
-- 'race' makes both directions loud: whichever pipeline stops first ends the
-- race, and the process exits non-zero with a reason so a supervisor restarts
-- it. Neither side is expected to return at all.
runContinuousWorker :: AppEnv -> KirokuStore -> VectorCapability -> EmbeddingConfig -> IO ()
runContinuousWorker env store capability config = do
  let model = toEmbeddingModel config
  case capability of
    VectorAvailable -> do
      startupBackfill env capability config
      outcome <-
        try @SomeException $
          race
            (runTimerLoop env capability config)
            (runAppIO env (runEmbeddingWorkerHost store capability model config.dimensions))
      case outcome of
        -- A halted processor can tear its own machinery down hard enough to
        -- surface as an exception rather than a clean return (shibuya's halt path
        -- can leave a thread blocked in STM). Either way the pipeline is gone;
        -- what matters is that the operator gets a reason and a non-zero exit
        -- instead of a process that looks alive.
        Left err ->
          dieWorker ("worker pipeline crashed: " <> displayException err)
        Right (Left ()) ->
          dieWorker "timer loop stopped unexpectedly"
        Right (Right (Left storeErr)) ->
          dieWorker ("embedding worker stopped with store error: " <> show storeErr)
        Right (Right (Right ())) ->
          -- The handler already printed the halt reason at decision time.
          dieWorker "embedding worker stopped (processor halted or subscription ended)"
    VectorExtensionUnavailable -> do
      putStrLn "pgvector is not available; recall will run FTS-only; running kioku timer worker only."
      runTimerLoop env capability config
    VectorColumnsUnavailable missing -> do
      putStrLn ("pgvector columns are missing (" <> Text.unpack (Text.intercalate ", " missing) <> "); running kioku timer worker only.")
      runTimerLoop env capability config
    -- Loud, but not fatal. Every embedding write would fail on the ::vector cast, so there
    -- is no point starting the embedding host — but distillation timers have nothing to do
    -- with embeddings, and killing the whole worker would stop them too.
    VectorDimensionMismatch configured actual -> do
      hPutStrLn stderr ("kioku worker: " <> dimensionMismatchMessage configured actual <> "; running kioku timer worker only.")
      runTimerLoop env capability config

-- | A dimension mismatch would otherwise be discovered one failed event at a time, forever.
dimensionMismatchMessage :: Int -> Int -> String
dimensionMismatchMessage configured actual =
  "embedding dimension mismatch: KIOKU_EMBEDDING_DIMENSIONS="
    <> show configured
    <> " but kiroku.kioku_memories.embedding is vector("
    <> show actual
    <> "); fix the env var or migrate the column"

-- | Recover embeddings lost to an outage that outlasted the retry window.
-- Idempotent, so it is safe on every start. A failure here is only a warning:
-- if the database is down, the loops' own retry and exit behavior is the honest
-- place for that to surface, not a special case at startup.
startupBackfill :: AppEnv -> VectorCapability -> EmbeddingConfig -> IO ()
startupBackfill env capability config = do
  result <- runAppIO env (backfillMissingEmbeddings capability (toEmbeddingModel config) config.dimensions)
  case result of
    Left storeErr ->
      hPutStrLn stderr ("kioku worker: startup backfill failed: " <> show storeErr)
    Right count ->
      putStrLn ("Startup backfill: embedded " <> show count <> " missing memory embeddings.")

dieWorker :: String -> IO ()
dieWorker msg = do
  hPutStrLn stderr ("kioku worker: " <> msg <> "; exiting")
  exitWith (ExitFailure 1)

runTimerOnce :: AppEnv -> EmbeddingConfig -> IO ()
runTimerOnce env config = do
  rt <- newDistillRuntime
  now <- getCurrentTime
  result <- runAppIO env do
    capability <- detectVectorCapability config.dimensions
    runKiokuTimerWorkerOnce Nothing rt (mergeCandidateFinder config capability) now
  case result of
    Left storeErr -> ioError (userError ("kioku timer worker store error: " <> show storeErr))
    Right Nothing -> putStrLn "No due kioku distillation timers."
    Right (Just _) -> putStrLn "Processed one due kioku distillation timer."

-- | Drain due timers, sleep, repeat — forever.
--
-- Each pass gets its own 'runAppIO', and therefore its own store-error scope.
-- That is the whole point: the old loop lived inside a single 'runAppIO', so the
-- first transient store error aborted the @forever@ and killed the loop. Here a
-- store error is logged and retried with capped exponential backoff (5s doubling
-- to 60s, reset on success), because a database outage should not require an
-- operator to restart anything — and restarting would not have helped.
--
-- This never returns normally, so 'race' seeing it finish genuinely means
-- something impossible happened. Non-store exceptions propagate to 'race', which
-- is equally loud.
runTimerLoop :: AppEnv -> VectorCapability -> EmbeddingConfig -> IO ()
runTimerLoop env capability config = do
  rt <- newDistillRuntime
  putStrLn "kioku timer worker started."
  let go failures = do
        result <- runAppIO env (drainKiokuTimers Nothing rt (mergeCandidateFinder config capability))
        case result of
          Left storeErr -> do
            hPutStrLn stderr ("kioku timer worker: store error (will retry): " <> show storeErr)
            threadDelay (storeErrorBackoffMicros failures)
            go (failures + 1)
          Right _processed -> do
            threadDelay defaultTimerPollMicros
            go 0
  go 0

-- | 5s doubling per consecutive failure, capped at 60s.
storeErrorBackoffMicros :: Int -> Int
storeErrorBackoffMicros failures =
  min (60 * 1000 * 1000) (5 * 1000 * 1000 * (2 ^ min 8 (max 0 failures)))

-- | With draining, the poll interval no longer caps throughput: a burst of due
-- timers is processed in one pass rather than one per interval.
defaultTimerPollMicros :: Int
defaultTimerPollMicros = 5 * 1000 * 1000

requireEnv :: String -> IO String
requireEnv name = do
  found <- lookupEnv name
  case found of
    Just envValue -> pure envValue
    Nothing -> ioError (userError (name <> " is not set"))
