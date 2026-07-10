{-# LANGUAGE TemplateHaskell #-}

module Kioku.Migrations
  ( kiokuOwnMigrations,
    kiokuMigrations,
    runKiokuMigrations,
    runKiokuMigrationsNoCheck,
  )
where

import Codd (ApplyResult, CoddSettings, VerifySchemas)
import Codd.Extras.Apply (applyParsedMigrations, applyParsedMigrationsNoCheck)
import Codd.Extras.Embedded qualified as Embedded
import Codd.Parsing (AddedSqlMigration, EnvVars)
import Data.ByteString (ByteString)
import Data.FileEmbed (embedDir)
import Data.List (sortOn)
import Data.Time (DiffTime)
import Keiro.Migrations (keiroFrameworkMigrations)
import Kiroku.Store.Migrations (kirokuMigrations)

kiokuOwnMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
kiokuOwnMigrations = Embedded.parseEmbeddedMigrations "Kioku" embeddedKiokuFiles

kiokuMigrations :: (MonadFail m, EnvVars m) => m [AddedSqlMigration m]
kiokuMigrations = do
  kiroku <- kirokuMigrations
  keiro <- keiroFrameworkMigrations
  own <- kiokuOwnMigrations
  pure (kiroku <> keiro <> own)

runKiokuMigrations :: CoddSettings -> DiffTime -> VerifySchemas -> IO ApplyResult
runKiokuMigrations settings connectTimeout verifySchemas =
  applyParsedMigrations settings connectTimeout verifySchemas kiokuMigrations

runKiokuMigrationsNoCheck :: CoddSettings -> DiffTime -> IO ApplyResult
runKiokuMigrationsNoCheck settings connectTimeout =
  applyParsedMigrationsNoCheck settings connectTimeout kiokuMigrations

embeddedKiokuFiles :: [(FilePath, ByteString)]
-- Keep this binding source-touched when adding SQL files; Template Haskell embeds
-- the directory contents at compile time. Last touched: 2026-07-10 l1 watermarks migration.
embeddedKiokuFiles = sortOn fst $(embedDir "sql-migrations")
