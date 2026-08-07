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
import Kioku.App (runAppIO, withNoopAppEnv)
import Kioku.Cli.Context (cliMemoryContext)
import Kioku.Cli.Options (boundedIntReader)
import Kioku.Cli.Scope (parseScope)
import Kioku.Memory.Embedding (EmbeddingConfig (..), resolveEmbeddingConfig, toEmbeddingModel)
import Kioku.Recall (RecallHit (..), RecallStrategy (..), legacyRecallTarget, mkRecallQuery, recall)
import Kioku.Recall.Capability (detectVectorCapability)
import Kiroku.Store.Connection (defaultConnectionSettings)
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
  context <- cliMemoryContext
  -- 'legacyRecallTarget' keeps @--scope@ meaning exactly what it has always meant: a namespace
  -- alone searches the whole namespace, an entity scope matches exactly. Giving operators a way
  -- to say "the global bucket only" is a grammar change and belongs to
  -- docs/plans/30-migrate-recall-consumers-to-explicit-targets.md.
  request <-
    case mkRecallQuery (legacyRecallTarget opts.scope) opts.query opts.strategy opts.limit of
      Left err -> ioError (userError ("kioku recall: " <> Text.unpack err))
      Right request -> pure request
  withNoopAppEnv (defaultConnectionSettings (Text.pack connStr)) \env -> do
    let model = toEmbeddingModel config
    result <- runAppIO env do
      capability <- detectVectorCapability config.dimensions
      recall model capability context request
    case result of
      Left storeErr -> ioError (userError ("kioku recall store error: " <> show storeErr))
      Right (Left recallErr) -> ioError (userError ("kioku recall error: " <> show recallErr))
      Right (Right []) -> putStrLn "(no matches)"
      Right (Right hits) -> mapM_ (printHit opts.showScores) (zip [(1 :: Int) ..] hits)

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
