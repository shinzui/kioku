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
import Data.Char (isAsciiLower, isDigit)
import Data.Int (Int64)
import Data.List (sort, (\\))
import Data.Text (Text)
import Data.Text.Encoding qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Session (Session)
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kioku.Migrations (embeddedKiokuMigrationFiles)
import Kioku.Migrations.TestSupport (withBareDatabase, withKiokuMigratedDatabase)
import System.Directory (listDirectory)
import System.FilePath (stripExtension, takeExtension)
import Test.Tasty (TestTree, defaultMain, testGroup)
import Test.Tasty.HUnit (Assertion, assertFailure, testCase, (@?=))

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
      testGroup
        "the embedded migration list matches the directory on disk"
        [ testCase "no migration is missing from the binary" testEmbedIsCurrent,
          testCase "every migration is named the way codd orders by" testMigrationNames
        ]
    ]

-- * The embed guard

-- | Template Haskell embeds @sql-migrations/@ at compile time, and @file-embed@ registers
-- as compilation dependencies only the files it /found/. A file newly ADDED to the
-- directory is therefore invisible to GHC's recompilation check: the module looks up to
-- date, the splice never re-runs, and the binary silently ships without the migration. No
-- TH-side trick can see the file it is precisely the gap that hides, so the guard has to
-- be a runtime comparison.
testEmbedIsCurrent :: Assertion
testEmbedIsCurrent = do
  -- Cabal runs a test suite with the package root as its working directory — the same
  -- relative path the splice used.
  onDisk <- sort . filter isSqlFile <$> listDirectory "sql-migrations"
  let embedded = sort (map fst embeddedKiokuMigrationFiles)
  if onDisk == embedded
    then pure ()
    else
      assertFailure
        ( unlines
            ( [ "The compiled-in migration list is stale.",
                "",
                "  missing from the binary: " <> show (onDisk \\ embedded),
                "  embedded but not on disk: " <> show (embedded \\ onDisk),
                "",
                "Fix: EDIT kioku-migrations/src/Kioku/Migrations.hs (bump the",
                "\"Last added\" comment) and rebuild. `touch` does not work —",
                "GHC's recompilation check is content-based, so the file's bytes",
                "must actually change. `just new-migration` does this for you."
              ]
            )
        )

-- | codd orders migrations by the UTC timestamp in the filename, so a mis-scaffolded name
-- does not fail — it silently runs in the wrong place.
testMigrationNames :: Assertion
testMigrationNames =
  case filter (not . wellFormed) (map fst embeddedKiokuMigrationFiles) of
    [] -> pure ()
    bad ->
      assertFailure
        ( "migration filenames must be YYYY-MM-DD-HH-MM-SS-slug.sql, but found: "
            <> show bad
        )
  where
    wellFormed name =
      case stripExtension ".sql" name of
        Nothing -> False
        Just stem ->
          case splitAt 19 stem of
            (stamp, '-' : slug) ->
              map digitOrDash stamp == "dddd-dd-dd-dd-dd-dd"
                && not (null slug)
                && all (\c -> isAsciiLower c || isDigit c || c == '-') slug
            _ -> False
    digitOrDash c
      | isDigit c = 'd'
      | otherwise = c

isSqlFile :: FilePath -> Bool
isSqlFile = (== ".sql") . takeExtension

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

-- | The migration's bytes as they were compiled into this binary, so the test exercises
-- exactly what ships. @-- codd:@ directives are ordinary SQL comments, so the whole file
-- runs as one script.
registryBumpMigration :: Text
registryBumpMigration =
  case lookup name embeddedKiokuMigrationFiles of
    Nothing -> error ("no embedded migration named " <> name)
    Just bytes -> Text.decodeUtf8 bytes
  where
    name = "2026-07-03-14-37-18-kioku-session-readmodel-registry-bump.sql"

-- * The fresh-database test

-- | The rewritten body still applies inside the real codd chain, on the cohort this package
-- actually compiles against.
testFreshDatabase :: Assertion
testFreshDatabase =
  withKiokuMigratedDatabase \connStr ->
    withConnection connStr \conn -> do
      found <- run conn (Session.statement () registryTableExists)
      found @?= True

registryTableExists :: Statement () Bool
registryTableExists =
  preparable
    "SELECT to_regclass('kiroku.keiro_read_models') IS NOT NULL"
    E.noParams
    (D.singleRow (D.column (D.nonNullable D.bool)))

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
