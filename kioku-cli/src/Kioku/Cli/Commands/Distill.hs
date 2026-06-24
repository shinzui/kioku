module Kioku.Cli.Commands.Distill
  ( CandidateSource (..),
    DistillOptions (..),
    distillOptionsParser,
    runDistill,
  )
where

import Data.Text qualified as Text
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Distill.L1 (L1Summary (..), distillSessionL1, recallCandidates, scopedScanCandidates)
import Kioku.Distill.Runtime (newDistillRuntime)
import Kioku.Id (SessionId, idText, parseIdAnyPrefix)
import Kioku.Memory.Embedding (resolveEmbeddingConfig, toEmbeddingModel)
import Kioku.Recall.Capability (detectVectorCapability)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Options.Applicative
import System.Environment (lookupEnv)

data CandidateSource = CandidateScan | CandidateRecall
  deriving stock (Eq, Show)

data DistillOptions = DistillOptions
  { sessionId :: !SessionId,
    candidateSource :: !CandidateSource,
    candidateLimit :: !Int
  }
  deriving stock (Eq, Show)

distillOptionsParser :: Parser DistillOptions
distillOptionsParser =
  hsubparser $
    command
      "session"
      ( info
          sessionOptionsParser
          (progDesc "Run one L1 distillation pass for a session")
      )

sessionOptionsParser :: Parser DistillOptions
sessionOptionsParser =
  DistillOptions
    <$> argument
      (eitherReader parseSessionId)
      (metavar "SESSION_ID")
    <*> option
      (eitherReader parseCandidateSource)
      ( long "candidates"
          <> metavar "scan|recall"
          <> value CandidateScan
          <> help "Candidate lookup source"
      )
    <*> option
      auto
      ( long "limit"
          <> metavar "N"
          <> value 5
          <> help "Maximum merge candidates per extracted atom"
      )

runDistill :: DistillOptions -> IO ()
runDistill opts = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  rt <- newDistillRuntime
  recallConfig <-
    case opts.candidateSource of
      CandidateScan -> pure Nothing
      CandidateRecall -> Just <$> resolveEmbeddingConfig
  withStore (defaultConnectionSettings (Text.pack connStr)) $ \st -> do
    tr <- noopTracer
    let env = AppEnv {store = st, tracer = tr, metrics = Nothing}
    result <- runAppIO env do
      finder <-
        case (opts.candidateSource, recallConfig) of
          (CandidateRecall, Just config) -> do
            capability <- detectVectorCapability
            pure (recallCandidates (toEmbeddingModel config) capability opts.candidateLimit)
          _ ->
            pure (scopedScanCandidates opts.candidateLimit)
      distillSessionL1 rt finder opts.sessionId
    case result of
      Left storeErr -> ioError (userError ("kioku distill store error: " <> show storeErr))
      Right (Left l1Err) -> ioError (userError ("kioku distill error: " <> show l1Err))
      Right (Right summary) -> printSummary opts.sessionId summary

parseSessionId :: String -> Either String SessionId
parseSessionId raw =
  case parseIdAnyPrefix (Text.pack raw) of
    Left err -> Left (Text.unpack err)
    Right sid -> Right sid

parseCandidateSource :: String -> Either String CandidateSource
parseCandidateSource = \case
  "scan" -> Right CandidateScan
  "recall" -> Right CandidateRecall
  other -> Left ("unknown candidate source: " <> other)

printSummary :: SessionId -> L1Summary -> IO ()
printSummary sid summary =
  putStrLn $
    "Distilled session "
      <> Text.unpack (idText sid)
      <> ": extracted="
      <> show summary.extracted
      <> " stored="
      <> show summary.stored
      <> " merged="
      <> show summary.merged
      <> " skipped="
      <> show summary.skipped

requireEnv :: String -> IO String
requireEnv name = do
  found <- lookupEnv name
  case found of
    Just envValue -> pure envValue
    Nothing -> ioError (userError (name <> " is not set"))
