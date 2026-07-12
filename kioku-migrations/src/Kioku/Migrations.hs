module Kioku.Migrations
  ( DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    kiokuMigrations,
    kiokuMigrationPlan,
  )
where

import Data.List.NonEmpty (NonEmpty (..))
import Database.PostgreSQL.Migrate
  ( DefinitionError,
    MigrationComponent,
    MigrationPlan,
    PlanError,
    migrationPlan,
  )
import Keiro.Migrations qualified as Keiro
import Kioku.Migrations.Internal.Definition (kiokuMigrations)
import Kiroku.Store.Migrations qualified as Kiroku

-- | The complete Kiroku, Keiro, and Kioku plan in dependency order.
kiokuMigrationPlan :: Either PlanError MigrationPlan
kiokuMigrationPlan = do
  kiroku <- componentOrDie "Kiroku" Kiroku.kirokuMigrations
  keiro <- componentOrDie "Keiro" Keiro.keiroMigrations
  kioku <- componentOrDie "Kioku" kiokuMigrations
  migrationPlan (kiroku :| [keiro, kioku])
  where
    componentOrDie label =
      either (error . (("invalid embedded " <> label <> " migration component: ") <>) . show) pure
