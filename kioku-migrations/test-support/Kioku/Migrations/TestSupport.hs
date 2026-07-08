module Kioku.Migrations.TestSupport
  ( withKiokuMigratedDatabase,
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
