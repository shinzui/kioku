module Kioku.Migrations.TestSupport
  ( withKiokuMigratedDatabase,
    withBareDatabase,
  )
where

import Codd.Extras.Settings (noCheckCoddSettings)
import Codd.Extras.TestSupport (withMigratedDatabase)
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import Kioku.Migrations (runKiokuMigrationsNoCheck)

withKiokuMigratedDatabase :: (Text -> IO a) -> IO a
withKiokuMigratedDatabase =
  withMigratedDatabase \connStr -> do
    _ <-
      runKiokuMigrationsNoCheck
        (noCheckCoddSettings ["kiroku", "keiro", "kioku", "public"] connStr)
        (secondsToDiffTime 5)
    pure ()

-- | An ephemeral database with no migrations applied at all — not even keiro's
-- bootstrap. Tests that need to build a schema layout by hand (for instance, to
-- exercise a migration against a keiro cohort this package is not compiled
-- against) start from here.
withBareDatabase :: (Text -> IO a) -> IO a
withBareDatabase = withMigratedDatabase (\_ -> pure ())
