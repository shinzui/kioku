module Kioku.Migrations.TestSupport
  ( withKiokuMigratedDatabase,
    withBareDatabase,
  )
where

import Data.Text (Text)
import EphemeralPg qualified
import Keiro.Test.Postgres qualified as Keiro
import Kioku.Migrations (kiokuMigrations)

withKiokuMigratedDatabase :: (Text -> IO a) -> IO a
withKiokuMigratedDatabase use = do
  component <- either (fail . show) pure kiokuMigrations
  Keiro.withMigratedSuiteWith [component] \fixture ->
    Keiro.withFreshDatabase fixture use

-- | An ephemeral database with no migrations applied at all — not even keiro's
-- bootstrap. Tests that need to build a schema layout by hand (for instance, to
-- exercise a migration against a keiro cohort this package is not compiled
-- against) start from here.
withBareDatabase :: (Text -> IO a) -> IO a
withBareDatabase use = do
  result <- EphemeralPg.with (use . EphemeralPg.connectionString)
  either (fail . show) pure result
