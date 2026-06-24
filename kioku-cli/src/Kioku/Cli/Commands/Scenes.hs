module Kioku.Cli.Commands.Scenes
  ( ScenesOptions (..),
    runScenes,
    scenesOptionsParser,
  )
where

import Data.Text qualified as Text
import Kioku.Api.Scope (MemoryScope)
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Cli.Scope (parseScope)
import Kioku.Distill.L2 (SceneRow (..), getScenesByScope)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Options.Applicative
import System.Environment (lookupEnv)

newtype ScenesOptions = ScenesOptions
  { scope :: MemoryScope
  }
  deriving stock (Eq, Show)

scenesOptionsParser :: Parser ScenesOptions
scenesOptionsParser =
  ScenesOptions
    <$> option
      (eitherReader parseScope)
      ( long "scope"
          <> metavar "NAMESPACE[:KIND:REF]"
          <> help "Memory scope whose scenes should be printed"
      )

runScenes :: ScenesOptions -> IO ()
runScenes opts = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  withStore (defaultConnectionSettings (Text.pack connStr)) $ \st -> do
    tr <- noopTracer
    let env = AppEnv {store = st, tracer = tr, metrics = Nothing}
    result <- runAppIO env (getScenesByScope opts.scope)
    case result of
      Left storeErr -> ioError (userError ("kioku scenes store error: " <> show storeErr))
      Right [] -> putStrLn "(no scenes)"
      Right scenes -> mapM_ printScene scenes

printScene :: SceneRow -> IO ()
printScene row = do
  putStrLn ("# " <> Text.unpack row.title)
  putStrLn ""
  putStrLn (Text.unpack row.bodyMd)

requireEnv :: String -> IO String
requireEnv name = do
  found <- lookupEnv name
  case found of
    Just envValue -> pure envValue
    Nothing -> ioError (userError (name <> " is not set"))
