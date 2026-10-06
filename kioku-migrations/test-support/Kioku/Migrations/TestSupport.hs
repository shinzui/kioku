module Kioku.Migrations.TestSupport
  ( withKiokuMigratedDatabase,
    withBareDatabase,
  )
where

import Data.Monoid (Last (..))
import Data.Text (Text)
import EphemeralPg qualified
import Keiro.Test.Postgres qualified as Keiro
import Kioku.Migrations (kiokuMigrations)
import System.Directory (createDirectoryIfMissing)
import System.Posix.User (getEffectiveUserID)

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
  -- Migrated fixtures delegate to mori://shinzui/keiro/packages/keiro-test-support.
  -- Share its stable per-user root so either fixture sweeps abandoned clusters
  -- from earlier runs, including runs under a different shell's TMPDIR.
  uid <- getEffectiveUserID
  let root = "/tmp/ephpg-keiro-" <> show uid
  createDirectoryIfMissing True root
  let config = EphemeralPg.defaultConfig {EphemeralPg.temporaryRoot = Last (Just root)}
  result <- EphemeralPg.withConfig config (use . EphemeralPg.connectionString)
  either (fail . show) pure result
