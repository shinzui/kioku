module Kioku.Cli.Commands.Worker
  ( WorkerOptions (..),
    workerOptionsParser,
    runWorker,
  )
where

import Control.Concurrent (forkIO)
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Effectful (IOE, (:>))
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Distill.L1 (FindMergeCandidates, recallCandidates)
import Kioku.Distill.Runtime (newDistillRuntime)
import Kioku.Distill.Timer.Worker (runKiokuTimerWorkerLoop, runKiokuTimerWorkerOnce)
import Kioku.Memory.Embedding (EmbeddingConfig (..), resolveEmbeddingConfig, toEmbeddingModel)
import Kioku.Memory.Embedding.Worker (backfillMissingEmbeddings, runEmbeddingWorkerHost)
import Kioku.Recall.Capability (VectorCapability (..), detectVectorCapability)
import Kiroku.Store.Connection (KirokuStore, defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (Store)
import Options.Applicative
import System.Environment (lookupEnv)

data WorkerOptions = WorkerOptions
  { backfill :: !Bool,
    timersOnce :: !Bool
  }
  deriving stock (Eq, Show)

workerOptionsParser :: Parser WorkerOptions
workerOptionsParser =
  WorkerOptions
    <$> switch
      ( long "backfill"
          <> help "Run one embedding backfill pass and exit"
      )
    <*> switch
      ( long "timers-once"
          <> help "Claim and fire at most one due kioku distillation timer, then exit"
      )

runWorker :: WorkerOptions -> IO ()
runWorker opts = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  config <- resolveEmbeddingConfig
  withStore (defaultConnectionSettings (Text.pack connStr)) $ \st -> do
    tr <- noopTracer
    let env = AppEnv {store = st, tracer = tr, metrics = Nothing}
    if opts.timersOnce
      then runTimerOnce env config
      else do
        result <- runAppIO env detectVectorCapability
        capability <- case result of
          Left storeErr -> ioError (userError ("kioku worker store error: " <> show storeErr))
          Right cap -> pure cap
        if opts.backfill
          then runBackfill env capability config
          else runContinuousWorker env st capability config

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
  let model = toEmbeddingModel config
  result <- runAppIO env (backfillMissingEmbeddings capability model config.dimensions)
  case result of
    Left storeErr -> ioError (userError ("kioku worker backfill store error: " <> show storeErr))
    Right count -> putStrLn ("Backfilled " <> show count <> " memory embeddings.")

runContinuousWorker :: AppEnv -> KirokuStore -> VectorCapability -> EmbeddingConfig -> IO ()
runContinuousWorker env store capability config = do
  let model = toEmbeddingModel config
  case capability of
    VectorAvailable -> do
      _ <- forkIO (runTimerLoop env capability config)
      result <- runAppIO env (runEmbeddingWorkerHost store capability model config.dimensions)
      case result of
        Left storeErr -> ioError (userError ("kioku worker store error: " <> show storeErr))
        Right () -> pure ()
    VectorExtensionUnavailable -> do
      putStrLn "pgvector is not available; recall will run FTS-only; running kioku timer worker only."
      runTimerLoop env capability config
    VectorColumnsUnavailable missing -> do
      putStrLn ("pgvector columns are missing (" <> Text.unpack (Text.intercalate ", " missing) <> "); running kioku timer worker only.")
      runTimerLoop env capability config

runTimerOnce :: AppEnv -> EmbeddingConfig -> IO ()
runTimerOnce env config = do
  rt <- newDistillRuntime
  now <- getCurrentTime
  result <- runAppIO env do
    capability <- detectVectorCapability
    runKiokuTimerWorkerOnce Nothing rt (mergeCandidateFinder config capability) now
  case result of
    Left storeErr -> ioError (userError ("kioku timer worker store error: " <> show storeErr))
    Right Nothing -> putStrLn "No due kioku distillation timers."
    Right (Just _) -> putStrLn "Processed one due kioku distillation timer."

runTimerLoop :: AppEnv -> VectorCapability -> EmbeddingConfig -> IO ()
runTimerLoop env capability config = do
  rt <- newDistillRuntime
  putStrLn "kioku timer worker started."
  result <-
    runAppIO
      env
      (runKiokuTimerWorkerLoop Nothing rt (mergeCandidateFinder config capability) defaultTimerPollMicros)
  case result of
    Left storeErr -> ioError (userError ("kioku timer worker store error: " <> show storeErr))
    Right () -> pure ()

defaultTimerPollMicros :: Int
defaultTimerPollMicros = 5 * 1000 * 1000

requireEnv :: String -> IO String
requireEnv name = do
  found <- lookupEnv name
  case found of
    Just envValue -> pure envValue
    Nothing -> ioError (userError (name <> " is not set"))
