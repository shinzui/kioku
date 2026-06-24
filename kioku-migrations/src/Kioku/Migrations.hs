{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Kioku.Migrations
  ( kiokuOwnMigrations,
    kiokuMigrations,
    runKiokuMigrations,
    runKiokuMigrationsNoCheck,
  )
where

import Codd (ApplyResult (SchemasNotVerified), CoddSettings, VerifySchemas, applyMigrations, applyMigrationsNoCheck)
import Codd.Logging (runCoddLogger)
import Codd.Parsing (AddedSqlMigration, EnvVars, PureStream (..), parseAddedSqlMigration)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.List (sortOn)
import Data.Text.Encoding qualified as TE
import Data.Time (DiffTime)
import Keiro.Migrations (keiroFrameworkMigrations)
import Kiroku.Store.Migrations (kirokuMigrations)
import Streaming.Prelude qualified as Streaming

kiokuOwnMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
kiokuOwnMigrations =
  traverse parseEmbeddedMigration embeddedKiokuFiles
  where
    parseEmbeddedMigration :: forall m. (MonadFail m, EnvVars m) => (FilePath, ByteString) -> m (AddedSqlMigration m)
    parseEmbeddedMigration (name, bytes) = do
      let stream :: PureStream m
          stream = PureStream $ Streaming.yield (TE.decodeUtf8 bytes)
      result <- parseAddedSqlMigration name stream
      case result of
        Left err -> fail ("Invalid Kioku migration " <> name <> ": " <> err)
        Right migration -> pure migration

kiokuMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
kiokuMigrations = do
  kiroku <- kirokuMigrations
  keiro <- keiroFrameworkMigrations
  own <- kiokuOwnMigrations
  pure (kiroku <> keiro <> own)

runKiokuMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runKiokuMigrations settings connectTimeout verifySchemas =
  runCoddLogger do
    migrations <- kiokuMigrations
    applyMigrations settings (Just migrations) connectTimeout verifySchemas

runKiokuMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runKiokuMigrationsNoCheck settings connectTimeout =
  runCoddLogger do
    migrations <- kiokuMigrations
    applyMigrationsNoCheck settings (Just migrations) connectTimeout (const (pure SchemasNotVerified))

embeddedKiokuFiles :: [(FilePath, ByteString)]
-- Keep this binding source-touched when adding SQL files; Template Haskell embeds
-- the directory contents at compile time.
embeddedKiokuFiles = sortOn fst $(embedDir "sql-migrations")
