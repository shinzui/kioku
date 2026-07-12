{-# LANGUAGE MultilineStrings #-}
{-# LANGUAGE TemplateHaskell #-}

module Kioku.Migrations.History.Codd
  ( kiokuCoddHistoryMappings,
    cohortCoddHistoryMappings,
    cohortCoddSourceConfig,
    kiokuCoddSourcePayloads,
    kiokuCoddManifestText,
    kiokuLegacyMigrationNames,
    cohortCoddStateValidators,
  )
where

import Data.Aeson qualified as Aeson
import Data.Bifunctor (first)
import Data.ByteString (ByteString)
import Data.Foldable (toList)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Database.PostgreSQL.Migrate
  ( Confirmation,
    ConnectionProvider,
    EvidenceRequirement (AllOf, Evidence),
    HistoryMapping,
    PayloadRelation (EquivalentState, SamePayload),
    StateValidator,
    evidenceKey,
    historyMapping,
    migrationId,
    stateValidationError,
    stateValidator,
  )
import Database.PostgreSQL.Migrate.History.Codd
  ( CoddDefinitionError,
    CoddSourceConfig,
    coddEvidenceKey,
    coddSourceConfig,
    parseCoddManifest,
  )
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Migrations.History.Codd qualified as Keiro
import Kioku.Migrations.Internal.Definition (embeddedMigrationEntries)
import Kioku.Migrations.Internal.EmbedFile (embedTextFile)
import Kiroku.Store.Migrations.History.Codd qualified as Kiroku

kiokuLegacyMigrationNames :: NonEmpty FilePath
kiokuLegacyMigrationNames =
  "2026-06-24-00-00-00-kioku-base.sql"
    :| [ "2026-06-24-01-00-00-kioku-memory-embeddings.sql",
         "2026-06-24-02-00-00-kioku-distillation.sql",
         "2026-06-27-20-35-00-kioku-session-delegation-lineage.sql",
         "2026-06-27-21-10-35-kioku-awaiting-session-state.sql",
         "2026-07-03-14-37-18-kioku-session-readmodel-registry-bump.sql",
         "2026-07-10-14-41-38-kioku-l1-watermarks.sql",
         "2026-07-11-17-35-11-kioku-schema-hardening.sql",
         "2026-07-11-17-45-43-kioku-embedding-schema-heal.sql",
         "2026-07-11-18-18-36-kioku-scope-identity-recompute.sql"
       ]

nativeMigrationNames :: NonEmpty Text
nativeMigrationNames =
  "0001-kioku-base"
    :| [ "0002-kioku-memory-embeddings",
         "0003-kioku-distillation",
         "0004-kioku-session-delegation-lineage",
         "0005-kioku-awaiting-session-state",
         "0006-kioku-session-readmodel-registry-bump",
         "0007-kioku-l1-watermarks",
         "0008-kioku-schema-hardening",
         "0009-kioku-embedding-schema-heal",
         "0010-kioku-scope-identity-recompute"
       ]

kiokuCoddHistoryMappings :: NonEmpty HistoryMapping
kiokuCoddHistoryMappings =
  zipWithNonEmpty mapping kiokuLegacyMigrationNames nativeMigrationNames
  where
    mapping sourceFilename targetName
      | targetName == "0006-kioku-session-readmodel-registry-bump" =
          historyMapping
            target
            (AllOf (Evidence sourceKey :| [Evidence sessionRegistryEvidenceKey]))
            EquivalentState
      | otherwise = historyMapping target (Evidence sourceKey) (SamePayload sourceKey)
      where
        target = definitionInvariant (migrationId "kioku" targetName)
        sourceKey = definitionInvariant (first show (coddEvidenceKey sourceFilename))

cohortCoddHistoryMappings :: NonEmpty HistoryMapping
cohortCoddHistoryMappings =
  kirokuPinnedCoddHistoryMappings
    <> keiroPinnedCoddHistoryMappings
    <> kiokuCoddHistoryMappings

kirokuPinnedCoddHistoryMappings :: NonEmpty HistoryMapping
kirokuPinnedCoddHistoryMappings = takeNonEmpty 6 Kiroku.kirokuCoddHistoryMappings

keiroPinnedCoddHistoryMappings :: NonEmpty HistoryMapping
keiroPinnedCoddHistoryMappings =
  zipWithNonEmpty equivalentMapping keiroPinnedLegacyMigrationNames keiroPinnedNativeMigrationNames
  where
    equivalentMapping sourceFilename targetName =
      historyMapping
        (definitionInvariant (migrationId "keiro" targetName))
        (AllOf (Evidence sourceKey :| [Evidence keiroSchemaEvidenceKey]))
        EquivalentState
      where
        sourceKey = definitionInvariant (first show (coddEvidenceKey sourceFilename))

cohortCoddSourceConfig ::
  ConnectionProvider ->
  Bool ->
  Text ->
  Confirmation ->
  Either CoddDefinitionError CoddSourceConfig
cohortCoddSourceConfig sourceProvider strictSource reason confirmation =
  coddSourceConfig
    sourceProvider
    selectedLegacyMigrationNames
    strictSource
    samePayloadSourcePayloads
    (Just combinedManifest)
    reason
    confirmation
  where
    combinedManifest =
      definitionInvariant
        ( parseCoddManifest
            (filterLockText samePayloadFilenames (Kiroku.kirokuCoddManifestText <> kiokuCoddManifestText))
        )

selectedLegacyMigrationNames :: NonEmpty FilePath
selectedLegacyMigrationNames =
  kirokuPinnedLegacyMigrationNames <> keiroPinnedLegacyMigrationNames <> kiokuLegacyMigrationNames

kirokuPinnedLegacyMigrationNames :: NonEmpty FilePath
kirokuPinnedLegacyMigrationNames = takeNonEmpty 6 Kiroku.kirokuLegacyMigrationNames

keiroPinnedLegacyMigrationNames :: NonEmpty FilePath
keiroPinnedLegacyMigrationNames = takeNonEmpty 14 Keiro.keiroLegacyMigrationNames

keiroPinnedNativeMigrationNames :: NonEmpty Text
keiroPinnedNativeMigrationNames =
  "0001-keiro-bootstrap"
    :| [ "0002-keiro-outbox",
         "0003-keiro-inbox",
         "0004-keiro-timer-recovery",
         "0005-keiro-workflow-steps",
         "0006-keiro-awakeables",
         "0007-keiro-workflow-children",
         "0008-keiro-workflow-generation",
         "0009-keiro-subscription-shards",
         "0010-keiro-messaging-crash-recovery",
         "0011-keiro-workflows-instances",
         "0012-keiro-workflow-gc-index",
         "0013-keiro-workflows-wake-after",
         "0014-keiro-projection-dedup"
       ]

samePayloadFilenames :: Set.Set FilePath
samePayloadFilenames =
  Set.fromList
    ( toList kirokuPinnedLegacyMigrationNames
        <> filter (/= registryBumpLegacyFilename) (toList kiokuLegacyMigrationNames)
    )

samePayloadSourcePayloads :: Map.Map FilePath ByteString
samePayloadSourcePayloads =
  Map.restrictKeys
    (Kiroku.kirokuCoddSourcePayloads <> kiokuCoddSourcePayloads)
    samePayloadFilenames

filterLockText :: Set.Set FilePath -> Text -> Text
filterLockText selected =
  Text.unlines
    . filter
      ( \line ->
          case Text.words line of
            [_checksum, filename] -> Set.member (Text.unpack filename) selected
            _ -> False
      )
    . Text.lines

kiokuCoddSourcePayloads :: Map.Map FilePath ByteString
kiokuCoddSourcePayloads =
  Map.fromList
    (zip (toList kiokuLegacyMigrationNames) (snd <$> toList embeddedMigrationEntries))

kiokuCoddManifestText :: Text
kiokuCoddManifestText = $(embedTextFile "migrations.lock")

cohortCoddStateValidators :: [StateValidator]
cohortCoddStateValidators =
  [ stateValidator keiroSchemaEvidenceKey do
      valid <- Tx.statement () keiroSchemaIsCurrentStatement
      pure
        if valid
          then Right (Aeson.object ["schema" Aeson..= ("keiro" :: Text), "historicalMigrations" Aeson..= (14 :: Int)])
          else Left keiroSchemaValidationError,
    stateValidator sessionRegistryEvidenceKey do
      valid <- Tx.statement () sessionRegistryIsCurrentStatement
      pure
        if valid
          then Right (Aeson.object ["sessionReadModels" Aeson..= (8 :: Int), "version" Aeson..= (3 :: Int)])
          else Left sessionRegistryValidationError
  ]

keiroSchemaEvidenceKey =
  definitionInvariant (evidenceKey "keiro:pre-pg-migrate-schema-relocated")

keiroSchemaValidationError =
  definitionInvariant
    ( stateValidationError
        "expected the relocated Keiro schema, tables, indexes, recovery columns, workflow backfill, and generation-aware workflow-step primary key"
    )

sessionRegistryEvidenceKey =
  definitionInvariant (evidenceKey "kioku:session-readmodels-v3")

sessionRegistryValidationError =
  definitionInvariant
    ( stateValidationError
        "expected all eight Kioku session read-model rows in keiro.keiro_read_models at version 3, shape kioku-session-v3, and live status"
    )

keiroSchemaIsCurrentStatement :: Statement () Bool
keiroSchemaIsCurrentStatement =
  preparable
    """
    SELECT
      (SELECT count(*) = 11 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'keiro' AND c.relkind = 'r'
          AND c.relname = ANY (ARRAY[
            'keiro_snapshots','keiro_read_models','keiro_timers','keiro_outbox',
            'keiro_inbox','keiro_workflow_steps','keiro_awakeables',
            'keiro_workflow_children','keiro_subscription_shards','keiro_workflows',
            'keiro_projection_dedup']))
      AND (SELECT count(*) = 19 FROM pg_catalog.pg_class c
        JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'keiro' AND c.relkind = 'i'
          AND c.relname = ANY (ARRAY[
            'keiro_snapshots_compat_idx','keiro_timers_due_idx',
            'keiro_outbox_pending_idx','keiro_outbox_head_of_line_idx',
            'keiro_inbox_received_idx','keiro_inbox_completed_idx',
            'keiro_workflow_steps_workflow_idx','keiro_awakeables_pending_idx',
            'keiro_awakeables_owner_idx','keiro_workflow_children_parent_idx',
            'keiro_workflow_children_running_idx','keiro_subscription_shards_owner_idx',
            'keiro_subscription_shards_lease_idx','keiro_inbox_backlog_idx',
            'keiro_outbox_sent_gc_idx','keiro_outbox_source_order_idx',
            'keiro_workflows_active_idx','keiro_workflows_gc_idx',
            'keiro_projection_dedup_applied_at_idx']))
      AND (SELECT count(*) = 4 FROM information_schema.columns
        WHERE table_schema = 'keiro'
          AND (table_name, column_name) IN (
            ('keiro_timers','last_error'),
            ('keiro_workflow_steps','generation'),
            ('keiro_inbox','attempt_count'),
            ('keiro_workflows','wake_after')))
      AND EXISTS (
        SELECT 1 FROM pg_catalog.pg_constraint con
        JOIN pg_catalog.pg_class rel ON rel.oid = con.conrelid
        JOIN pg_catalog.pg_namespace n ON n.oid = rel.relnamespace
        WHERE n.nspname = 'keiro' AND rel.relname = 'keiro_workflow_steps'
          AND con.contype = 'p' AND pg_get_constraintdef(con.oid)
            = 'PRIMARY KEY (workflow_id, workflow_name, generation, step_name)')
      AND NOT EXISTS (
        SELECT 1
        FROM (
          SELECT workflow_id, workflow_name FROM keiro.keiro_workflow_steps GROUP BY 1,2
        ) steps
        LEFT JOIN keiro.keiro_workflows workflows USING (workflow_id, workflow_name)
        WHERE workflows.workflow_id IS NULL)
      AND NOT EXISTS (
        SELECT 1 FROM keiro.keiro_workflow_children children
        LEFT JOIN keiro.keiro_workflows workflows
          ON workflows.workflow_id = children.child_id
         AND workflows.workflow_name = children.child_name
        WHERE children.status = 'running' AND workflows.workflow_id IS NULL)
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

sessionRegistryIsCurrentStatement :: Statement () Bool
sessionRegistryIsCurrentStatement =
  preparable
    """
    SELECT count(*) = 8
       AND bool_and(version = 3)
       AND bool_and(shape_hash = 'kioku-session-v3')
       AND bool_and(status = 'live')
    FROM keiro.keiro_read_models
    WHERE name IN (
      'kioku-session-by-id',
      'kioku-sessions-by-namespace',
      'kioku-sessions-by-scope',
      'kioku-sessions-by-focus',
      'kioku-sessions-by-started-range',
      'kioku-session-chain',
      'kioku-session-delegation-children',
      'kioku-sessions-awaiting-by-correlation-key'
    )
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

zipWithNonEmpty :: (a -> b -> c) -> NonEmpty a -> NonEmpty b -> NonEmpty c
zipWithNonEmpty combine (firstA :| restA) (firstB :| restB) =
  combine firstA firstB :| zipWith combine restA restB

takeNonEmpty :: Int -> NonEmpty a -> NonEmpty a
takeNonEmpty count values =
  case take count (toList values) of
    firstValue : remainingValues -> firstValue :| remainingValues
    [] -> error "takeNonEmpty requires a positive count"

registryBumpLegacyFilename :: FilePath
registryBumpLegacyFilename = "2026-07-03-14-37-18-kioku-session-readmodel-registry-bump.sql"

definitionInvariant :: (Show error) => Either error value -> value
definitionInvariant = either (error . ("invalid checked-in Kioku migration definition: " <>) . show) id
