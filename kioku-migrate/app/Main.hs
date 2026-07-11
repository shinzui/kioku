module Main where

import Codd.Environment (getCoddSettings)
import Data.Foldable (for_)
import Data.Text qualified as Text
import Data.Time (secondsToDiffTime)
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Migrations (runKiokuMigrationsNoCheck)
import Kioku.ReadModel (ReadModelSchema (..), ReconcileOutcome (..), reconcileReadModelRegistry)
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import System.Environment (getEnv)
import System.Exit (die)

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
  settings <- getCoddSettings
  _ <- runKiokuMigrationsNoCheck settings (secondsToDiffTime 5)
  -- The same libpq keyword string codd just used.
  connStr <- getEnv "CODD_CONNECTION"
  tracer <- noopTracer
  withStore (defaultConnectionSettings (Text.pack connStr)) \store -> do
    result <-
      runAppIO
        AppEnv {store = store, tracer = tracer, metrics = Nothing}
        reconcileReadModelRegistry
    case result of
      Left err -> die ("read-model registry reconciliation failed: " <> show err)
      Right outcomes -> for_ outcomes report

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
