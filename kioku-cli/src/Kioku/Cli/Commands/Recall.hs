module Kioku.Cli.Commands.Recall
  ( RecallOptions (..),
    recallOptionsParser,
    runRecall,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.Api.Scope (MemoryScope)
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Cli.Options (boundedIntReader)
import Kioku.Cli.Scope (parseScope)
import Kioku.Memory.Embedding (EmbeddingConfig (..), resolveEmbeddingConfig, toEmbeddingModel)
import Kioku.Recall (RecallHit (..), RecallRequest (..), RecallStrategy (..), recall)
import Kioku.Recall.Capability (detectVectorCapability)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Options.Applicative
import System.Environment (lookupEnv)
import Text.Printf (printf)

data RecallOptions = RecallOptions
  { query :: !Text,
    scope :: !MemoryScope,
    strategy :: !RecallStrategy,
    limit :: !Int,
    showScores :: !Bool
  }
  deriving stock (Eq, Show)

recallOptionsParser :: Parser RecallOptions
recallOptionsParser =
  RecallOptions
    <$> (Text.pack <$> argument str (metavar "QUERY"))
    <*> option
      (eitherReader parseScope)
      ( long "scope"
          <> metavar "NAMESPACE[:KIND:REF]"
          <> help "Memory scope to search; REF may contain ':'"
      )
    <*> option
      (eitherReader parseStrategy)
      ( long "strategy"
          <> metavar "keyword|embedding|hybrid"
          <> value Hybrid
          <> help "Recall strategy"
      )
    <*> option
      (boundedIntReader "LIMIT" 1 100)
      ( long "limit"
          <> metavar "N"
          <> value 8
          <> help "Maximum hits to return (1-100)"
      )
    <*> switch
      ( long "show-scores"
          <> help "Print fused scores and component ranks"
      )

runRecall :: RecallOptions -> IO ()
runRecall opts = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  config <- resolveEmbeddingConfig
  withStore (defaultConnectionSettings (Text.pack connStr)) $ \st -> do
    tr <- noopTracer
    let env = AppEnv {store = st, tracer = tr, metrics = Nothing}
        model = toEmbeddingModel config
        request =
          RecallRequest
            { scope = opts.scope,
              query = opts.query,
              strategy = opts.strategy,
              maxResults = opts.limit
            }
    result <- runAppIO env do
      capability <- detectVectorCapability config.dimensions
      recall model capability request
    case result of
      Left storeErr -> ioError (userError ("kioku recall store error: " <> show storeErr))
      Right [] -> putStrLn "(no matches)"
      Right hits -> mapM_ (printHit opts.showScores) (zip [(1 :: Int) ..] hits)

parseStrategy :: String -> Either String RecallStrategy
parseStrategy = \case
  "keyword" -> Right Keyword
  "embedding" -> Right Embedding
  "hybrid" -> Right Hybrid
  other -> Left ("unknown strategy: " <> other)

printHit :: Bool -> (Int, RecallHit) -> IO ()
printHit showScores (index, hit)
  | showScores =
      putStrLn $
        show index
          <> ". score="
          <> printf "%.4f" hit.score
          <> " fts="
          <> rankText hit.ftsRank
          <> " vec="
          <> rankText hit.vecRank
          <> " "
          <> Text.unpack hit.memory.memoryType
          <> " "
          <> show (Text.unpack hit.memory.content)
  | otherwise =
      putStrLn $
        show index
          <> ". "
          <> Text.unpack hit.memory.memoryType
          <> " "
          <> show (Text.unpack hit.memory.content)

rankText :: Maybe Int -> String
rankText Nothing = "-"
rankText (Just rank) = show rank

requireEnv :: String -> IO String
requireEnv name = do
  found <- lookupEnv name
  case found of
    Just envValue -> pure envValue
    Nothing -> ioError (userError (name <> " is not set"))
