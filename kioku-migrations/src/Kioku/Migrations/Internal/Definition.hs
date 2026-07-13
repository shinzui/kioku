{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -fplugin=Database.PostgreSQL.Migrate.Embed.RecompilePlugin #-}

module Kioku.Migrations.Internal.Definition
  ( embeddedMigrationEntries,
    kiokuMigrations,
  )
where

import Data.ByteString (ByteString)
import Data.List.NonEmpty (NonEmpty)
import Data.Set qualified as Set
import Database.PostgreSQL.Migrate
  ( DefinitionError,
    MigrationComponent,
    migrationComponentFromEmbeddedSql,
  )
import Database.PostgreSQL.Migrate.Embed (embedMigrationManifest)

embeddedMigrationEntries :: NonEmpty (FilePath, ByteString)
embeddedMigrationEntries =
  $(embedMigrationManifest "migrations/manifest")

-- The preserved @-- codd: in-txn@ comments are part of the historical payload
-- evidence used by the one-time Codd import. pg-migrate treats them as ordinary
-- SQL comments; do not remove them from the embedded bytes.
kiokuMigrations :: Either DefinitionError MigrationComponent
kiokuMigrations =
  migrationComponentFromEmbeddedSql
    "kioku"
    (Set.singleton "keiro")
    embeddedMigrationEntries
