{-# LANGUAGE TemplateHaskell #-}

module Kioku.Migrations
  ( kiokuOwnMigrations,
    kiokuMigrations,
    runKiokuMigrations,
    runKiokuMigrationsNoCheck,
    embeddedKiokuMigrationFiles,
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
kiokuOwnMigrations = Embedded.parseEmbeddedMigrations "Kioku" embeddedKiokuMigrationFiles

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

-- | Kioku's own migration files, exactly as they were compiled into this binary.
--
-- The Template Haskell splice below re-reads @sql-migrations/@ only when THIS
-- MODULE recompiles. @file-embed@ registers every file it /found/ as a
-- compilation dependency, so editing or deleting a migration does trigger a
-- rebuild — but a file newly ADDED to the directory is, by construction, not
-- among them. GHC therefore considers this module up to date and the binary
-- silently ships without the new migration.
--
-- GHC's recompilation check is content-based, so @touch@ing this file does not
-- help: its bytes must actually change. Adding a migration by hand means adding
-- it here too (bump the "last added" note below); @just new-migration@ does it
-- for you. The @kioku-migrations-test@ suite compares this list against the
-- directory on disk and fails if they diverge, so a stale embed is a test
-- failure rather than a production surprise.
--
-- Last added: 2026-07-11 kioku-scope-identity-recompute.
embeddedKiokuMigrationFiles :: [(FilePath, ByteString)]
embeddedKiokuMigrationFiles = sortOn fst $(embedDir "sql-migrations")
