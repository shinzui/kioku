{-# LANGUAGE MultilineStrings #-}

module Kioku.Migrations.TestSupport
  ( withKiokuMigratedDatabase,
    withBareDatabase,
  )
where

import Data.Text (Text)
import Database.PostgreSQL.Migrate.Test qualified as PgMigrate
import EphemeralPg qualified
import Hasql.Connection qualified as Connection
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kioku.Migrations (kiokuMigrationPlan)

withKiokuMigratedDatabase :: (Text -> IO a) -> IO a
withKiokuMigratedDatabase use = do
  plan <- either (fail . show) pure kiokuMigrationPlan
  result <-
    PgMigrate.withMigratedDatabase plan \connection -> do
      connectionStringResult <- Connection.use connection connectionStringSession
      connectionString <- either (fail . show) pure connectionStringResult
      use connectionString
  either (fail . show) pure result

-- | An ephemeral database with no migrations applied at all — not even keiro's
-- bootstrap. Tests that need to build a schema layout by hand (for instance, to
-- exercise a migration against a keiro cohort this package is not compiled
-- against) start from here.
withBareDatabase :: (Text -> IO a) -> IO a
withBareDatabase use = do
  result <- EphemeralPg.with (use . EphemeralPg.connectionString)
  either (fail . show) pure result

-- pg-migrate-test-support deliberately supplies a live Hasql connection so
-- assertions cannot inherit runner session state. Kioku's established shim
-- supplies a connection string instead, so recover the ephemeral server's
-- connection coordinates from that fresh callback session.
connectionStringSession :: Session.Session Text
connectionStringSession = Session.statement () connectionStringStatement

connectionStringStatement :: Statement () Text
connectionStringStatement =
  preparable
    """
    SELECT 'host=' || split_part(current_setting('unix_socket_directories'), ',', 1)
        || ' port=' || current_setting('port')
        || ' dbname=' || current_database()
        || ' user=' || current_user
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.text)))
