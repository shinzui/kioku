module Main where

import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy.Char8 qualified as LazyByteString
import Data.Foldable (for_)
import Data.Int (Int64)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate
  ( Confirmation (..),
    EquivalentHistoryPolicy (AllowEquivalentHistory),
    HistoryImportOutcome (..),
    HistoryImportReport (..),
    HistoryImportResult (..),
    MigrationPlan,
    connectionProviderFromSettings,
    defaultImportOptions,
    defaultRunOptions,
    withEquivalentHistory,
  )
import Database.PostgreSQL.Migrate.CLI
import Database.PostgreSQL.Migrate.History.Codd
  ( defaultCoddLockKey,
    importCoddHistoryWithValidators,
    withCoddLockKey,
  )
import Hasql.Connection.Settings qualified as Settings
import Kioku.App (runAppIO, withNoopAppEnv)
import Kioku.Migrations (kiokuMigrationPlan)
import Kioku.Migrations.History.Codd
  ( cohortCoddHistoryMappings,
    cohortCoddSourceConfig,
    cohortCoddStateValidators,
  )
import Kioku.ReadModel (ReadModelSchema (..), ReconcileOutcome (..), reconcileReadModelRegistry)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Options.Applicative
import Options.Applicative qualified as Opt
import System.Environment (lookupEnv)
import System.Exit qualified as Exit
import Text.Read qualified as Read

-- | Apply the migration chain, then reconcile keiro's read-model registry to the
-- identity this binary's read models declare.
--
-- The second half is what keeps a read-model version bump from taking production
-- down: keiro's @registerReadModel@ only ever inserts, so an existing registry row
-- stays pinned at its old version and every query for that model fails closed with
-- @ReadModelStaleSchema@. Reconciling here means the repair ships with the schema
-- change instead of needing a hand-written registry migration per bump. Migration
-- time is also the only moment where exactly one process is doing this; doing it at
-- app startup would have every host racing to write the registry on boot.
main :: IO ()
main = do
  plan <- either (fail . show) pure kiokuMigrationPlan
  command <-
    execParser
      ( info
          (kiokuCommandParser plan <**> helper)
          (fullDesc <> progDesc "Manage the Kiroku, Keiro, and Kioku migration components")
      )
  defaultDatabaseUrl <- lookupEnv "DATABASE_URL"
  case command of
    Standard migrationCommand -> runStandardCommand plan defaultDatabaseUrl migrationCommand
    ImportCodd importOptions -> runImportCommand plan defaultDatabaseUrl importOptions

data KiokuCommand
  = Standard !MigrationCommand
  | ImportCodd !CoddImportOptions

data CoddImportOptions = CoddImportOptions
  { targetSettings :: !(Maybe Settings.Settings),
    sourceSettings :: !(Maybe Settings.Settings),
    sourceLockKey :: !Int64,
    strictSource :: !Bool,
    reason :: !Text.Text,
    confirmation :: !Confirmation,
    outputFormat :: !OutputFormat
  }

kiokuCommandParser :: MigrationPlan -> Parser KiokuCommand
kiokuCommandParser plan =
  (Standard <$> migrationCommandParser plan)
    <|> hsubparser
      ( Opt.command
          "import"
          ( info
              (ImportCodd <$> coddImportOptionsParser <**> helper)
              (progDesc "Import the 30-migration pinned Kiroku/Keiro/Kioku Codd cohort without replaying DDL")
          )
      )

coddImportOptionsParser :: Parser CoddImportOptions
coddImportOptionsParser =
  CoddImportOptions
    <$> optional (databaseUrlOption "database-url" "Target PostgreSQL connection string; defaults to DATABASE_URL")
    <*> optional (databaseUrlOption "source-database-url" "Codd source connection string; defaults to the target")
    <*> option
      auto
      ( long "source-lock-key"
          <> metavar "INT64"
          <> value defaultCoddLockKey
          <> showDefault
          <> help "Cooperating Codd advisory-lock key"
      )
    <*> switch (long "strict-source" <> help "Reject unselected rows in the shared Codd ledger")
    <*> strOption (long "reason" <> metavar "TEXT" <> help "Audit reason recorded with every imported migration")
    <*> flag NotConfirmed Confirmed (long "confirm" <> help "Confirm the checked-in Codd payload evidence")
    <*> flag TextOutput JsonOutput (long "json" <> help "Emit JSON schema version 1")
  where
    databaseUrlOption optionName description =
      option
        (Settings.connectionString . Text.pack <$> str)
        (long optionName <> metavar "URL" <> help description)

runStandardCommand :: MigrationPlan -> Maybe String -> MigrationCommand -> IO ()
runStandardCommand plan defaultDatabaseUrl command = do
  let defaultSettings =
        Settings.connectionString (Text.pack (maybe "" id defaultDatabaseUrl))
      environment = cliEnvironment defaultSettings plan defaultRunOptions
  outcome <- runMigrationCommand environment command
  case commandOutputFormat command of
    TextOutput -> Text.IO.putStrLn (renderMigrationCommandText outcome)
    JsonOutput -> LazyByteString.putStrLn (Aeson.encode (renderMigrationCommandJson outcome))
  reconcileAfterUp defaultDatabaseUrl command outcome
  Exit.exitWith
    (case exitClass outcome of ExitSucceeded -> Exit.ExitSuccess; _ -> Exit.ExitFailure 1)

runImportCommand :: MigrationPlan -> Maybe String -> CoddImportOptions -> IO ()
runImportCommand plan defaultDatabaseUrl options = do
  let fallbackSettings = Settings.connectionString (Text.pack (maybe "" id defaultDatabaseUrl))
      targetSettings = maybe fallbackSettings id options.targetSettings
      sourceSettings = maybe targetSettings id options.sourceSettings
      targetProvider = connectionProviderFromSettings targetSettings
      sourceProvider = connectionProviderFromSettings sourceSettings
  config <-
    either
      (Exit.die . ("invalid Codd import configuration: " <>) . show)
      pure
      ( cohortCoddSourceConfig
          sourceProvider
          options.strictSource
          options.reason
          options.confirmation
      )
  imported <-
    importCoddHistoryWithValidators
      (withEquivalentHistory AllowEquivalentHistory defaultImportOptions)
      cohortCoddStateValidators
      (withCoddLockKey options.sourceLockKey config)
      targetProvider
      plan
      cohortCoddHistoryMappings
  report <- either (Exit.die . ("Codd history import failed: " <>) . show) pure imported
  case options.outputFormat of
    JsonOutput -> LazyByteString.putStrLn (Aeson.encode (renderHistoryImportJson "codd" report))
    TextOutput -> renderImportReport report

renderImportReport :: HistoryImportReport -> IO ()
renderImportReport HistoryImportReport {importResults, cleanupIssues} = do
  for_ (NonEmpty.toList importResults) \HistoryImportResult {importedMigration, importOutcome} ->
    putStrLn
      ( show importedMigration
          <> ": "
          <> case importOutcome of
            Imported -> "imported"
            AlreadyImported -> "already imported"
      )
  for_ cleanupIssues \cleanupIssue ->
    putStrLn ("cleanup_issue=" <> show cleanupIssue)

reconcileAfterUp :: Maybe String -> MigrationCommand -> CliOutcome -> IO ()
reconcileAfterUp defaultDatabaseUrl command outcome =
  case (command, exitClass outcome) of
    (Up UpOptions {connection = ConnectionOptions override}, ExitSucceeded) ->
      reconcile (maybe defaultConnectionString settingsConnectionString override)
    _ -> pure ()
  where
    defaultConnectionString = Text.pack (maybe "" id defaultDatabaseUrl)

settingsConnectionString :: Settings.Settings -> Text.Text
settingsConnectionString settings =
  case Read.readMaybe (show settings) of
    Just connectionString -> Text.pack connectionString
    Nothing -> error "Hasql rendered an unreadable connection string"

reconcile :: Text.Text -> IO ()
reconcile connectionString =
  withNoopAppEnv (defaultConnectionSettings connectionString) \env -> do
    result <-
      runAppIO env reconcileReadModelRegistry
    case result of
      Left err -> Exit.die ("read-model registry reconciliation failed: " <> show err)
      Right outcomes -> for_ outcomes report

commandOutputFormat :: MigrationCommand -> OutputFormat
commandOutputFormat command =
  case command of
    Plan PlanOptions {output = OutputOptions format} -> format
    List ListOptions {output = OutputOptions format} -> format
    Check CheckOptions {output = OutputOptions format} -> format
    Status StatusOptions {output = OutputOptions format} -> format
    Verify VerifyOptions {output = OutputOptions format} -> format
    Up UpOptions {output = OutputOptions format} -> format
    Repair RepairOptions {output = OutputOptions format} -> format
    New NewOptions {output = OutputOptions format} -> format

-- | Report only what changed, so a no-op run stays quiet.
report :: (ReadModelSchema, ReconcileOutcome) -> IO ()
report (schema, outcome) =
  case outcome of
    AlreadyCurrent -> pure ()
    Registered -> say "registered read model"
    Reconciled -> say "reconciled read model"
  where
    say verb =
      putStrLn
        ( verb
            <> " "
            <> Text.unpack schema.readModelName
            <> " at v"
            <> show schema.readModelVersion
            <> " ("
            <> Text.unpack schema.readModelShapeHash
            <> ")"
        )
