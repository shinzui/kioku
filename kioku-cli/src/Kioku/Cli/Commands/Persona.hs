module Kioku.Cli.Commands.Persona
  ( PersonaOptions (..),
    personaOptionsParser,
    runPersona,
  )
where

import Data.Text qualified as Text
import Kioku.Api.Scope (MemoryScope)
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Cli.Scope (parseScope)
import Kioku.Distill.L3 (PersonaRow (..), getPersonaByScope)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Options.Applicative
import System.Environment (lookupEnv)

newtype PersonaOptions = PersonaOptions
  { scope :: MemoryScope
  }
  deriving stock (Eq, Show)

personaOptionsParser :: Parser PersonaOptions
personaOptionsParser =
  PersonaOptions
    <$> option
      (eitherReader parseScope)
      ( long "scope"
          <> metavar "NAMESPACE[:KIND:REF]"
          <> help "Memory scope whose persona should be printed"
      )

runPersona :: PersonaOptions -> IO ()
runPersona opts = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  withStore (defaultConnectionSettings (Text.pack connStr)) $ \st -> do
    tr <- noopTracer
    let env = AppEnv {store = st, tracer = tr, metrics = Nothing}
    result <- runAppIO env (getPersonaByScope opts.scope)
    case result of
      Left storeErr -> ioError (userError ("kioku persona store error: " <> show storeErr))
      Right Nothing -> putStrLn "(no persona yet)"
      Right (Just persona) -> printPersona persona

printPersona :: PersonaRow -> IO ()
printPersona row =
  putStrLn (Text.unpack row.bodyMd)

requireEnv :: String -> IO String
requireEnv name = do
  found <- lookupEnv name
  case found of
    Just envValue -> pure envValue
    Nothing -> ioError (userError (name <> " is not set"))
