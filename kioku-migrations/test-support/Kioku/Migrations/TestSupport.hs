module Kioku.Migrations.TestSupport
  ( withKiokuMigratedDatabase,
  )
where

import Codd (CoddSettings (..))
import Codd.Parsing (connStringParser)
import Codd.Representations.Types (DbRep (..))
import Codd.Types (ConnectionString, SchemaAlgo (..), SchemaSelection (..), SqlSchema (..), TxnIsolationLvl (..), singleTryPolicy)
import Data.Aeson (Value (Null))
import Data.Attoparsec.Text (endOfInput, parseOnly)
import Data.Map qualified as Map
import Data.Text (Text)
import Data.Time (secondsToDiffTime)
import EphemeralPg qualified as Pg
import Kioku.Migrations (runKiokuMigrationsNoCheck)

withKiokuMigratedDatabase :: (Text -> IO a) -> IO a
withKiokuMigratedDatabase action = do
  result <- Pg.withCached $ \db -> do
    let connStr = Pg.connectionString db
    _ <- runKiokuMigrationsNoCheck (testCoddSettings connStr) (secondsToDiffTime 5)
    action connStr
  case result of
    Left err -> error ("Failed to start ephemeral PostgreSQL: " <> show err)
    Right value -> pure value

testCoddSettings :: Text -> CoddSettings
testCoddSettings connStr =
  CoddSettings
    { migsConnString = parseConnString connStr,
      sqlMigrations = [],
      onDiskReps = Right (DbRep Null Map.empty Map.empty),
      namespacesToCheck = IncludeSchemas [SqlSchema "kiroku", SqlSchema "public"],
      extraRolesToCheck = [],
      retryPolicy = singleTryPolicy,
      txnIsolationLvl = DbDefault,
      schemaAlgoOpts = SchemaAlgo False False False
    }

parseConnString :: Text -> ConnectionString
parseConnString connStr =
  case parseOnly (connStringParser <* endOfInput) connStr of
    Left err -> error ("Could not parse ephemeral PostgreSQL connection string for codd: " <> err)
    Right parsed -> parsed
