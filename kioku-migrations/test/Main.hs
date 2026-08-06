{-# LANGUAGE MultilineStrings #-}

-- | Tests for the migration machinery itself, as opposed to the schema it produces
-- (that lives in @kioku-core@'s @Kioku.SchemaSpec@).
--
-- The interesting property here is that kioku's registry-bump migration must keep
-- working across keiro's pending schema relocation, which moves @keiro_read_models@
-- out of the @kiroku@ schema into a dedicated @keiro@ one. Kioku cannot compile against
-- that keiro yet, so the layout test builds each physical layout by hand in a bare
-- database and runs the shipped migration bytes against it.
module Main where

import Control.Exception (bracket)
import Data.Foldable (toList)
import Data.Int (Int64)
import Data.Maybe (mapMaybe)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as Text.Encoding
import Data.Text.IO qualified as Text.IO
import Database.PostgreSQL.Migrate
  ( Confirmation (Confirmed),
    EquivalentHistoryPolicy (AllowEquivalentHistory),
    HistoryImportOutcome (AlreadyImported, Imported),
    HistoryImportReport (..),
    HistoryImportResult (..),
    MigrationId,
    MigrationOutcome (AlreadyApplied, AppliedNow),
    MigrationReport (..),
    MigrationResult (..),
    VerificationReport (..),
    connectionProviderFromSettings,
    defaultImportOptions,
    defaultRunOptions,
    migrationId,
    runMigrationPlan,
    validateHistoryMappingTargets,
    verifyMigrationPlan,
    withEquivalentHistory,
  )
import Database.PostgreSQL.Migrate.Embed (checkMigrationManifest)
import Database.PostgreSQL.Migrate.History.Codd (importCoddHistoryWithValidators)
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kioku.Migrations (kiokuMigrationPlan)
import Kioku.Migrations.History.Codd
  ( cohortCoddHistoryMappings,
    cohortCoddSourceConfig,
    cohortCoddStateValidators,
    kiokuCoddHistoryMappings,
  )
import Kioku.Migrations.TestSupport (withBareDatabase, withKiokuMigratedDatabase)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "kioku-migrations"
    [ testGroup
        "the registry bump finds keiro_read_models wherever the keiro cohort put it"
        [ testCase "kiroku schema (the pinned keiro bootstrap)" (assertRegistryBump "kiroku"),
          testCase "keiro schema (after keiro's relocation)" (assertRegistryBump "keiro"),
          testCase "public schema (long-lived dev databases)" (assertRegistryBump "public")
        ],
      testCase "the full migration chain applies to a fresh database" testFreshDatabase,
      testCase "the migration manifest is complete and valid" testManifestIntegrity,
      testCase "the pinned Codd history maps 30 known plan targets" testHistoryMappings,
      testCase "the pre-cutover Codd cohort imports 30 rows and applies only nine forward migrations" testCoddCohortImport,
      testGroup
        "the memory-space partition migration"
        [ testCase "backfills every pre-partition row into the legacy space" testMemorySpaceBackfill,
          testCase "refuses to finish when a derived row disagrees with its session" testMemorySpaceDriftAborts,
          testCase "re-applying its body changes nothing" testMemorySpaceBackfillIdempotent
        ]
    ]

-- * The manifest guard

testManifestIntegrity :: Assertion
testManifestIntegrity = do
  result <- checkMigrationManifest "migrations/manifest"
  case result of
    Left err -> assertFailure ("invalid migration manifest: " <> show err)
    Right _ -> pure ()

testHistoryMappings :: Assertion
testHistoryMappings = do
  plan <- either (fail . show) pure kiokuMigrationPlan
  length (toList kiokuCoddHistoryMappings) @?= 10
  length (toList cohortCoddHistoryMappings) @?= 30
  case validateHistoryMappingTargets plan cohortCoddHistoryMappings of
    Left err -> assertFailure ("invalid Codd history mapping target: " <> show err)
    Right () -> pure ()

-- * The layout test

-- | Build @keiro_read_models@ in @schema@ exactly as a keiro bootstrap would, seed it with
-- a stale session row and an unrelated memory row, run the shipped registry-bump migration,
-- and assert it reconciled the session row to v3 without touching anything else.
--
-- Before the migration's body was rewritten this failed on the @keiro@ layout with
-- @42P01 undefined_table@: the old body pinned @search_path@ to @kiroku, public@ and named
-- the table unqualified.
assertRegistryBump :: Text -> Assertion
assertRegistryBump schema =
  withBareConnection \conn -> do
    registryBumpMigration <- loadRegistryBumpMigration
    run conn (Session.script (bootstrapLayout schema))
    run conn (Session.script seedRegistryRows)
    run conn (Session.script registryBumpMigration)
    session <- run conn (Session.statement "kioku-session-by-id" (selectRegistryRow schema))
    session @?= Just (3, "kioku-session-v3", "live")
    -- A too-broad UPDATE would sweep the memory models to the session identity along with
    -- the session ones. They are different read models at a different version.
    memory <- run conn (Session.statement "kioku-memory-by-id" (selectRegistryRow schema))
    memory @?= Just (1, "kioku-memory-v1", "live")

-- | keiro's bootstrap DDL for the registry table, verbatim apart from the schema. It is
-- identical at the pinned commit (unqualified, under @SET search_path TO kiroku@) and at
-- keiro HEAD (qualified as @keiro.keiro_read_models@).
bootstrapLayout :: Text -> Text
bootstrapLayout schema =
  "CREATE SCHEMA IF NOT EXISTS "
    <> schema
    <> ";\n\
       \CREATE TABLE IF NOT EXISTS "
    <> schema
    <> ".keiro_read_models (\n\
       \  name TEXT PRIMARY KEY,\n\
       \  version BIGINT NOT NULL,\n\
       \  shape_hash TEXT NOT NULL,\n\
       \  last_built_at TIMESTAMPTZ,\n\
       \  status TEXT NOT NULL,\n\
       \  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()\n\
       \);\n\
       \SET search_path TO "
    <> schema
    <> ", pg_catalog;\n"

-- | A session model left behind at v2 — the state that makes every session query fail
-- closed with @ReadModelStaleSchema@ — plus a memory model that is already current.
seedRegistryRows :: Text
seedRegistryRows =
  "INSERT INTO keiro_read_models (name, version, shape_hash, last_built_at, status)\n\
  \VALUES ('kioku-session-by-id', 2, 'kioku-session-v2', now(), 'live'),\n\
  \       ('kioku-memory-by-id', 1, 'kioku-memory-v1', now(), 'live');\n"

selectRegistryRow :: Text -> Statement Text (Maybe (Int64, Text, Text))
selectRegistryRow schema =
  preparable
    ( "SELECT version, shape_hash, status FROM "
        <> schema
        <> ".keiro_read_models WHERE name = $1"
    )
    (E.param (E.nonNullable E.text))
    ( D.rowMaybe
        ( (,,)
            <$> D.column (D.nonNullable D.int8)
            <*> D.column (D.nonNullable D.text)
            <*> D.column (D.nonNullable D.text)
        )
    )

loadRegistryBumpMigration :: IO Text
loadRegistryBumpMigration =
  loadMigration "0006-kioku-session-readmodel-registry-bump.sql"

-- | A migration's bytes as they were compiled into this binary, so a test exercises exactly
-- what ships. @-- codd:@ directives are ordinary SQL comments, so a whole file runs as one
-- script.
loadMigration :: FilePath -> IO Text
loadMigration name = do
  result <- checkMigrationManifest "migrations/manifest"
  entries <- either (fail . show) pure result
  case lookup name (toList entries) of
    Nothing -> fail ("no manifest migration named " <> name)
    Just bytes -> pure (Text.Encoding.decodeUtf8 bytes)

-- * The fresh-database test

-- | The rewritten body still applies inside the real pg-migrate chain.
testFreshDatabase :: Assertion
testFreshDatabase =
  withKiokuMigratedDatabase \connStr ->
    withConnection connStr \conn -> do
      found <- run conn (Session.statement () registryTableExists)
      found @?= True

registryTableExists :: Statement () Bool
registryTableExists =
  preparable
    "SELECT to_regclass('keiro.keiro_read_models') IS NOT NULL"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

-- * The memory-space partition migration

-- | Prove the backfill on data that genuinely predates the partition.
--
-- The migrated database already has the column, so the test first puts it back the way it
-- was: 'undoMemorySpacePartition' drops every @memory_space_id@ (taking its indexes and
-- constraints with it) and restores the single-column scene and persona primary keys. Rows
-- inserted after that are indistinguishable from rows written by an older kioku, which is
-- what makes running the shipped migration bytes over them a test of the real upgrade
-- rather than of a mock of one.
testMemorySpaceBackfill :: Assertion
testMemorySpaceBackfill =
  withPrePartitionDatabase \conn -> do
    partition <- loadMigration memorySpacePartitionMigration
    run conn (Session.script partition)

    run conn (Session.statement () countMemorySpaces)
      >>= (@?= [("kioku_legacy", 8)])

    -- The turn whose session row is missing is the one case the derivation cannot answer
    -- from a parent, and it must still land somewhere explicit.
    run conn (Session.statement "t-orphan" selectTurnSpace)
      >>= (@?= Just "kioku_legacy")

    -- The partition-leading indexes and the composite scene/persona keys are what make the
    -- boundary enforceable rather than merely recorded.
    indexes <- run conn (Session.statement () selectKiokuIndexes)
    mapM_
      (\name -> assertBool (Text.unpack name <> " is missing") (name `elem` indexes))
      [ "kioku_memories_space_scope_idx",
        "kioku_memories_space_type_idx",
        "kioku_memories_space_namespace_idx",
        "kioku_sessions_space_scope_idx",
        "kioku_sessions_space_namespace_started_idx",
        "kioku_sessions_space_namespace_focus_idx",
        "kioku_sessions_space_awaiting_corr_idx",
        "kioku_consolidation_space_scope_idx"
      ]
    assertBool
      "kioku_scenes_scope_idx still exists; it duplicates the prefix of kioku_scenes_scope_scene_key_unique"
      ("kioku_scenes_scope_idx" `notElem` indexes)

    run conn (Session.statement "kioku_scenes" selectPrimaryKeyColumns)
      >>= (@?= ["memory_space_id", "scene_id"])
    run conn (Session.statement "kioku_personas" selectPrimaryKeyColumns)
      >>= (@?= ["memory_space_id", "persona_id"])

    -- Two spaces may now hold the same namespace, scope, and scene key. Before the composite
    -- key this pair collided on the scope-derived primary key and one silently overwrote the
    -- other through the upsert's ON CONFLICT clause.
    run conn (Session.script twoSpacesOneScopeKey)

-- | The derivation rule is a guard, not a comment: a turn that disagrees with its session
-- aborts the whole migration instead of quietly persisting a row in the wrong space.
--
-- Tampering after a first successful pass is how the state is reached, because the backfill
-- itself cannot produce it. On the second pass the @IS NULL@ updates match nothing and the
-- validation block is what runs.
testMemorySpaceDriftAborts :: Assertion
testMemorySpaceDriftAborts =
  withPrePartitionDatabase \conn -> do
    partition <- loadMigration memorySpacePartitionMigration
    run conn (Session.script partition)
    run conn (Session.script "UPDATE kiroku.kioku_turns SET memory_space_id = 'space_elsewhere' WHERE turn_id = 't-1'")

    result <- Connection.use conn (Session.script partition)
    case result of
      Right () -> assertFailure "the migration accepted a turn in a different space from its session"
      Left err ->
        assertBool
          ("expected a drift failure, got: " <> show err)
          ("different space from their session" `Text.isInfixOf` Text.pack (show err))

-- | Re-applying the body must be a no-op, which is what makes it safe to re-run after a
-- partially failed deployment.
testMemorySpaceBackfillIdempotent :: Assertion
testMemorySpaceBackfillIdempotent =
  withPrePartitionDatabase \conn -> do
    partition <- loadMigration memorySpacePartitionMigration
    run conn (Session.script partition)
    before <- run conn (Session.statement () kiokuSchemaSnapshot)
    spacesBefore <- run conn (Session.statement () countMemorySpaces)

    run conn (Session.script partition)
    run conn (Session.statement () kiokuSchemaSnapshot) >>= (@?= before)
    run conn (Session.statement () countMemorySpaces) >>= (@?= spacesBefore)

memorySpacePartitionMigration :: FilePath
memorySpacePartitionMigration = "0011-kioku-memory-space-partition.sql"

-- | A fully migrated database rolled back to the shape it had before memory spaces, then
-- seeded with one row in every partitioned table.
withPrePartitionDatabase :: (Connection.Connection -> IO a) -> IO a
withPrePartitionDatabase use =
  withKiokuMigratedDatabase \connStr ->
    withConnection connStr \conn -> do
      run conn (Session.script undoMemorySpacePartition)
      run conn (Session.script prePartitionRows)
      use conn

-- | @DROP COLUMN … CASCADE@ takes the column's indexes and constraints with it, including the
-- composite primary keys, which is why the single-column ones have to be put back by hand.
-- The rest of the DDL below is the pre-partition index set verbatim.
undoMemorySpacePartition :: Text
undoMemorySpacePartition =
  """
  ALTER TABLE kiroku.kioku_memories DROP COLUMN memory_space_id CASCADE;
  ALTER TABLE kiroku.kioku_sessions DROP COLUMN memory_space_id CASCADE;
  ALTER TABLE kiroku.kioku_turns DROP COLUMN memory_space_id CASCADE;
  ALTER TABLE kiroku.kioku_l1_watermarks DROP COLUMN memory_space_id CASCADE;
  ALTER TABLE kiroku.kioku_consolidation_decisions DROP COLUMN memory_space_id CASCADE;
  ALTER TABLE kiroku.kioku_scenes DROP COLUMN memory_space_id CASCADE;
  ALTER TABLE kiroku.kioku_personas DROP COLUMN memory_space_id CASCADE;

  ALTER TABLE kiroku.kioku_scenes ADD CONSTRAINT kioku_scenes_pkey PRIMARY KEY (scene_id);
  ALTER TABLE kiroku.kioku_personas ADD CONSTRAINT kioku_personas_pkey PRIMARY KEY (persona_id);
  ALTER TABLE kiroku.kioku_scenes ADD CONSTRAINT kioku_scenes_scope_scene_key_unique
    UNIQUE NULLS NOT DISTINCT (namespace, scope_kind, scope_ref, scene_key);
  ALTER TABLE kiroku.kioku_personas ADD CONSTRAINT kioku_personas_scope_unique
    UNIQUE NULLS NOT DISTINCT (namespace, scope_kind, scope_ref);

  CREATE INDEX kioku_memories_scope_idx
    ON kiroku.kioku_memories (namespace, scope_kind, scope_ref) WHERE status = 'active';
  CREATE INDEX kioku_memories_type_idx
    ON kiroku.kioku_memories (memory_type) WHERE status = 'active';
  CREATE INDEX kioku_sessions_scope_idx
    ON kiroku.kioku_sessions (namespace, scope_kind, scope_ref);
  CREATE INDEX kioku_sessions_namespace_started_idx
    ON kiroku.kioku_sessions (namespace, started_at DESC);
  CREATE INDEX kioku_sessions_namespace_focus_idx
    ON kiroku.kioku_sessions (namespace, focus, started_at DESC);
  CREATE INDEX kioku_sessions_awaiting_corr_idx
    ON kiroku.kioku_sessions (namespace, awaiting_correlation_key) WHERE status = 'awaiting';
  CREATE INDEX kioku_consolidation_scope_idx
    ON kiroku.kioku_consolidation_decisions (namespace, scope_kind, scope_ref);
  CREATE INDEX kioku_scenes_scope_idx
    ON kiroku.kioku_scenes (namespace, scope_kind, scope_ref);
  """

-- | Eight rows: one per partitioned table, plus a turn whose session does not exist.
prePartitionRows :: Text
prePartitionRows =
  """
  INSERT INTO kiroku.kioku_sessions (session_id, agent_id, focus, namespace, started_at)
  VALUES ('s-1', 'agent', 'focus', 'ns', now());

  INSERT INTO kiroku.kioku_turns (turn_id, session_id, turn_index, role, content, recorded_at)
  VALUES ('t-1', 's-1', 1, 'user', 'hello', now()),
         ('t-orphan', 's-vanished', 1, 'user', 'hello', now());

  INSERT INTO kiroku.kioku_l1_watermarks (session_id, last_turn_index) VALUES ('s-1', 1);

  INSERT INTO kiroku.kioku_memories
    (memory_id, agent_id, session_id, namespace, memory_type, content, created_at, updated_at)
  VALUES ('m-1', 'agent', 's-1', 'ns', 'fact', 'content', now(), now());

  INSERT INTO kiroku.kioku_consolidation_decisions
    (decision_id, session_id, namespace, candidate_content, decision)
  VALUES ('d-1', 's-1', 'ns', 'content', 'store');

  INSERT INTO kiroku.kioku_scenes (scene_id, namespace, scene_key, title, body_md, source_hash)
  VALUES ('kioku_scene:ns:default', 'ns', 'default', 'title', 'body', 'hash');

  INSERT INTO kiroku.kioku_personas (persona_id, namespace, body_md, source_hash)
  VALUES ('kioku_persona:ns', 'ns', 'body', 'hash');
  """

-- | The same scope-derived scene and persona ids, in a second space. Both inserts must
-- succeed; if either the primary key or the scope-uniqueness constraint had kept its old
-- shape, the second space would collide with the first.
twoSpacesOneScopeKey :: Text
twoSpacesOneScopeKey =
  """
  INSERT INTO kiroku.kioku_scenes
    (memory_space_id, scene_id, namespace, scene_key, title, body_md, source_hash)
  VALUES ('space_other', 'kioku_scene:ns:default', 'ns', 'default', 'title', 'body', 'hash');

  INSERT INTO kiroku.kioku_personas (memory_space_id, persona_id, namespace, body_md, source_hash)
  VALUES ('space_other', 'kioku_persona:ns', 'ns', 'body', 'hash');
  """

-- | Every partitioned row, grouped by the space it landed in.
countMemorySpaces :: Statement () [(Text, Int64)]
countMemorySpaces =
  preparable
    """
    SELECT memory_space_id, count(*)
    FROM (
      SELECT memory_space_id FROM kiroku.kioku_memories
      UNION ALL SELECT memory_space_id FROM kiroku.kioku_sessions
      UNION ALL SELECT memory_space_id FROM kiroku.kioku_turns
      UNION ALL SELECT memory_space_id FROM kiroku.kioku_l1_watermarks
      UNION ALL SELECT memory_space_id FROM kiroku.kioku_consolidation_decisions
      UNION ALL SELECT memory_space_id FROM kiroku.kioku_scenes
      UNION ALL SELECT memory_space_id FROM kiroku.kioku_personas
    ) AS partitioned
    GROUP BY memory_space_id
    ORDER BY memory_space_id
    """
    E.noParams
    (D.rowList ((,) <$> D.column (D.nonNullable D.text) <*> D.column (D.nonNullable D.int8)))

selectTurnSpace :: Statement Text (Maybe Text)
selectTurnSpace =
  preparable
    "SELECT memory_space_id FROM kiroku.kioku_turns WHERE turn_id = $1"
    (E.param (E.nonNullable E.text))
    (D.rowMaybe (D.column (D.nonNullable D.text)))

-- | @pg_indexes.indexname@ is a @name@, not a @text@; the cast is what lets hasql decode it.
selectKiokuIndexes :: Statement () [Text]
selectKiokuIndexes =
  preparable
    "SELECT indexname::text FROM pg_indexes WHERE schemaname = 'kiroku'"
    E.noParams
    (D.rowList (D.column (D.nonNullable D.text)))

selectPrimaryKeyColumns :: Statement Text [Text]
selectPrimaryKeyColumns =
  preparable
    """
    SELECT a.attname::text
    FROM pg_constraint c
    JOIN pg_class t ON t.oid = c.conrelid
    JOIN pg_namespace n ON n.oid = t.relnamespace
    CROSS JOIN LATERAL unnest(c.conkey) WITH ORDINALITY AS k(attnum, ordinality)
    JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
    WHERE c.contype = 'p' AND n.nspname = 'kiroku' AND t.relname = $1
    ORDER BY k.ordinality
    """
    (E.param (E.nonNullable E.text))
    (D.rowList (D.column (D.nonNullable D.text)))

kiokuSchemaSnapshot :: Statement () Text
kiokuSchemaSnapshot =
  preparable
    """
    SELECT md5(
      coalesce((SELECT string_agg(table_name || '.' || column_name || ':' || data_type || ':' || is_nullable,
                                  E'\n' ORDER BY table_name, ordinal_position)
                  FROM information_schema.columns
                 WHERE table_schema = 'kiroku' AND table_name LIKE 'kioku\\_%'), '')
      || coalesce((SELECT string_agg(indexname || ':' || indexdef, E'\n' ORDER BY indexname)
                     FROM pg_indexes
                    WHERE schemaname = 'kiroku' AND tablename LIKE 'kioku\\_%'), ''))
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.text)))

-- * The downstream Codd cutover rehearsal

-- | Exercise the operator runbook against the exact 30 historical migration
-- payloads from the pinned cohort. The fixture deliberately starts with Keiro's
-- tables in @kiroku@ and sentinel Codd filenames, then runs the two filename
-- fixups and schema relocation before importing history.
testCoddCohortImport :: Assertion
testCoddCohortImport =
  withBareDatabase \connStr -> do
    plan <- either (fail . show) pure kiokuMigrationPlan
    fixture <- Text.IO.readFile "test/fixtures/pre-cutover-schema.sql"
    let legacyNames = fixtureMigrationNames fixture
        settings = Settings.connectionString connStr
        provider = connectionProviderFromSettings settings
    length legacyNames @?= 30

    kirokuFixup <- Text.IO.readFile "codd-upgrade/realign-kiroku-migration-timestamps.sql"
    keiroFixup <- Text.IO.readFile "codd-upgrade/realign-keiro-migration-timestamps.sql"
    relocation <- Text.IO.readFile "codd-upgrade/relocate-keiro-tables-to-keiro-schema.sql"
    withConnection connStr \conn -> do
      run conn (Session.script fixture)
      run conn (Session.script (coddV5Ledger legacyNames))
      run conn (Session.script kirokuFixup)
      run conn (Session.script keiroFixup)
      run conn (Session.script relocation)
      run conn (Session.script seedSessionRegistry)

    beforeSource <- query connStr coddSnapshotStatement
    beforeSchema <- query connStr cohortSchemaSnapshotStatement
    query connStr forwardMigrationEffectCountStatement >>= (@?= 0)

    sourceConfig <-
      either
        (assertFailure . show)
        pure
        (cohortCoddSourceConfig provider False "Codd cohort rehearsal" Confirmed)
    first <-
      importCoddHistoryWithValidators
        (withEquivalentHistory AllowEquivalentHistory defaultImportOptions)
        cohortCoddStateValidators
        sourceConfig
        provider
        plan
        cohortCoddHistoryMappings
        >>= either (assertFailure . show) pure
    importOutcomes first @?= replicate 30 Imported
    query connStr importedLedgerCountsStatement >>= (@?= (30, 30))
    query connStr coddSnapshotStatement >>= (@?= beforeSource)
    query connStr cohortSchemaSnapshotStatement >>= (@?= beforeSchema)
    query connStr forwardMigrationEffectCountStatement >>= (@?= 0)

    second <-
      importCoddHistoryWithValidators
        (withEquivalentHistory AllowEquivalentHistory defaultImportOptions)
        cohortCoddStateValidators
        sourceConfig
        provider
        plan
        cohortCoddHistoryMappings
        >>= either (assertFailure . show) pure
    importOutcomes second @?= replicate 30 AlreadyImported

    migrated <- runMigrationPlan defaultRunOptions settings plan >>= either (assertFailure . show) pure
    let MigrationReport {results = migratedResults} = migrated
    appliedNow migrated @?= expectedForwardMigrationIds
    length [() | MigrationResult {outcome = AlreadyApplied} <- toList migratedResults] @?= 30
    query connStr forwardMigrationEffectCountStatement >>= (@?= 5)

    verification <- verifyMigrationPlan defaultRunOptions settings plan >>= either (assertFailure . show) pure
    let VerificationReport {issues = verificationIssues, appliedMigrations, pendingMigrations, unknownMigrations} = verification
    verificationIssues @?= []
    length appliedMigrations @?= 39
    pendingMigrations @?= []
    unknownMigrations @?= []

    repeated <- runMigrationPlan defaultRunOptions settings plan >>= either (assertFailure . show) pure
    let MigrationReport {results = repeatedResults} = repeated
    length [() | MigrationResult {outcome = AlreadyApplied} <- toList repeatedResults] @?= 39
    length [() | MigrationResult {outcome = AppliedNow} <- toList repeatedResults] @?= 0

fixtureMigrationNames :: Text -> [FilePath]
fixtureMigrationNames =
  fmap (Text.unpack . Text.takeWhile (/= ' '))
    . mapMaybe (Text.stripPrefix "-- BEGIN ")
    . Text.lines

coddV5Ledger :: [FilePath] -> Text
coddV5Ledger filenames =
  Text.unlines
    [ "CREATE SCHEMA codd;",
      "CREATE TABLE codd.sql_migrations (",
      "  id serial PRIMARY KEY,",
      "  migration_timestamp timestamptz NOT NULL UNIQUE,",
      "  applied_at timestamptz,",
      "  name text NOT NULL UNIQUE,",
      "  application_duration interval,",
      "  num_applied_statements int,",
      "  no_txn_failed_at timestamptz,",
      "  txnid bigint,",
      "  connid int",
      ");",
      "INSERT INTO codd.sql_migrations (migration_timestamp, applied_at, name, num_applied_statements)",
      "SELECT timestamptz '2024-01-01 00:00:00+00' + ordinal * interval '1 second',",
      "       timestamptz '2024-01-02 00:00:00+00' + ordinal * interval '1 second',",
      "       name, 1",
      "FROM unnest(ARRAY[" <> Text.intercalate "," (sqlString . Text.pack <$> filenames) <> "]::text[])",
      "  WITH ORDINALITY AS historical(name, ordinal);"
    ]

sqlString :: Text -> Text
sqlString value = "'" <> Text.replace "'" "''" value <> "'"

seedSessionRegistry :: Text
seedSessionRegistry =
  """
  INSERT INTO keiro.keiro_read_models (name, version, shape_hash, last_built_at, status)
  SELECT name, 3, 'kioku-session-v3', now(), 'live'
  FROM unnest(ARRAY[
    'kioku-session-by-id',
    'kioku-sessions-by-namespace',
    'kioku-sessions-by-scope',
    'kioku-sessions-by-focus',
    'kioku-sessions-by-started-range',
    'kioku-session-chain',
    'kioku-session-delegation-children',
    'kioku-sessions-awaiting-by-correlation-key'
  ]) AS session_models(name)
  ON CONFLICT (name) DO UPDATE
    SET version = EXCLUDED.version,
        shape_hash = EXCLUDED.shape_hash,
        status = EXCLUDED.status;
  """

importOutcomes :: HistoryImportReport -> [HistoryImportOutcome]
importOutcomes HistoryImportReport {importResults} = importOutcome <$> toList importResults

appliedNow :: MigrationReport -> [MigrationId]
appliedNow MigrationReport {results} =
  [migration | MigrationResult {migration, outcome = AppliedNow} <- toList results]

expectedForwardMigrationIds :: [MigrationId]
expectedForwardMigrationIds =
  expectRight
    <$> [ migrationId "kiroku" "0007-stream-truncate-before",
          migrationId "kiroku" "0008-schema-management-comment",
          migrationId "keiro" "0015-keiro-outbox-claim-order-index",
          migrationId "keiro" "0016-keiro-inbox-drop-received-idx",
          migrationId "keiro" "0017-schema-management-comment",
          migrationId "keiro" "0018",
          migrationId "keiro" "0019-keiro-snapshots-state-shape-hash",
          migrationId "keiro" "0020-keiro-workflow-children-failure-reason",
          migrationId "kioku" "0011-kioku-memory-space-partition"
        ]

expectRight :: (Show error) => Either error value -> value
expectRight = either (error . show) id

importedLedgerCountsStatement :: Statement () (Int64, Int64)
importedLedgerCountsStatement =
  preparable
    "SELECT (SELECT count(*) FROM pgmigrate.migrations WHERE status = 'applied'), (SELECT count(*) FROM pgmigrate.history_imports)"
    E.noParams
    (D.singleRow ((,) <$> required D.int8 <*> required D.int8))
  where
    required = D.column . D.nonNullable

coddSnapshotStatement :: Statement () (Int64, Text)
coddSnapshotStatement =
  preparable
    "SELECT count(*), string_agg(name, ',' ORDER BY name) FROM codd.sql_migrations"
    E.noParams
    (D.singleRow ((,) <$> required D.int8 <*> required D.text))
  where
    required = D.column . D.nonNullable

cohortSchemaSnapshotStatement :: Statement () Text
cohortSchemaSnapshotStatement =
  preparable
    """
    SELECT md5(string_agg(
      table_schema || '.' || table_name || '.' || column_name || ':' || data_type || ':' || is_nullable || ':' || coalesce(column_default, ''),
      E'\n' ORDER BY table_schema, table_name, ordinal_position))
    FROM information_schema.columns
    WHERE table_schema IN ('kiroku', 'keiro')
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.text)))

forwardMigrationEffectCountStatement :: Statement () Int64
forwardMigrationEffectCountStatement =
  preparable
    """
    SELECT (
      (EXISTS (SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'kiroku' AND table_name = 'streams' AND column_name = 'truncate_before'))::int
      + (coalesce(obj_description(to_regnamespace('kiroku'), 'pg_namespace'), '') =
          'Managed by pg-migrate component kiroku through 0008-schema-management-comment')::int
      + (to_regclass('keiro.keiro_outbox_claim_order_idx') IS NOT NULL)::int
      + (to_regclass('keiro.keiro_inbox_received_idx') IS NULL)::int
      + (coalesce(obj_description(to_regnamespace('keiro'), 'pg_namespace'), '') =
          'Managed by pg-migrate component keiro through 0017-schema-management-comment')::int
    )::bigint
    """
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.int8)))

-- * Harness

withBareConnection :: (Connection.Connection -> IO a) -> IO a
withBareConnection use = withBareDatabase \connStr -> withConnection connStr use

withConnection :: Text -> (Connection.Connection -> IO a) -> IO a
withConnection connStr =
  bracket
    ( Connection.acquire (Settings.connectionString connStr)
        >>= either (\err -> assertFailure ("could not connect: " <> show err)) pure
    )
    Connection.release

run :: Connection.Connection -> Session a -> IO a
run conn session =
  Connection.use conn session
    >>= either (\err -> assertFailure (show err)) pure

query :: Text -> Statement () a -> IO a
query connStr statement = withConnection connStr \conn -> run conn (Session.statement () statement)
