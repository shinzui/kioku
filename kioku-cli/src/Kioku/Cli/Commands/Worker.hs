module Kioku.Cli.Commands.Worker
  ( WorkerOptions (..),
    workerOptionsParser,
    runWorker,
  )
where

import Data.Text qualified as Text
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Memory.Embedding (EmbeddingConfig (..), resolveEmbeddingConfig, toEmbeddingModel)
import Kioku.Memory.Embedding.Worker (backfillMissingEmbeddings, runEmbeddingWorkerHost)
import Kioku.Recall.Capability (VectorCapability (..), detectVectorCapability)
import Kiroku.Store.Connection (KirokuStore, defaultConnectionSettings, withStore)
import Options.Applicative
import System.Environment (lookupEnv)

newtype WorkerOptions = WorkerOptions
  { backfill :: Bool
  }
  deriving stock (Eq, Show)

workerOptionsParser :: Parser WorkerOptions
workerOptionsParser =
  WorkerOptions
    <$> switch
      ( long "backfill"
          <> help "Run one embedding backfill pass and exit"
      )

runWorker :: WorkerOptions -> IO ()
runWorker opts = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  config <- resolveEmbeddingConfig
  withStore (defaultConnectionSettings (Text.pack connStr)) $ \st -> do
    tr <- noopTracer
    let env = AppEnv {store = st, tracer = tr, metrics = Nothing}
    result <- runAppIO env detectVectorCapability
    capability <- case result of
      Left storeErr -> ioError (userError ("kioku worker store error: " <> show storeErr))
      Right cap -> pure cap
    case capability of
      VectorAvailable
        | opts.backfill -> runBackfill env capability config
        | otherwise -> runContinuousWorker env st capability config
      VectorExtensionUnavailable ->
        putStrLn "pgvector is not available; recall will run FTS-only; nothing to embed."
      VectorColumnsUnavailable missing ->
        putStrLn ("pgvector columns are missing (" <> Text.unpack (Text.intercalate ", " missing) <> "); nothing to embed.")

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
  result <- runAppIO env (runEmbeddingWorkerHost store capability model config.dimensions)
  case result of
    Left storeErr -> ioError (userError ("kioku worker store error: " <> show storeErr))
    Right () -> pure ()

requireEnv :: String -> IO String
requireEnv name = do
  found <- lookupEnv name
  case found of
    Just envValue -> pure envValue
    Nothing -> ioError (userError (name <> " is not set"))
