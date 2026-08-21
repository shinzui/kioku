-- | The filesystem half of the memory-space partition.
--
-- The database stopped letting two spaces collide when their rows got a composite key. These
-- cases are about the other artifact: a Markdown mirror whose filename is derived from a scope
-- that two spaces are allowed to share.
--
-- The traversal cases are the ones worth reading twice. A 'MemorySpaceId' is validated for a
-- database column, not for a path — @..@ passes 'mkMemorySpaceId' — so nothing but the encoding
-- in "Kioku.Workspace" stands between a hostile space id and the rest of the disk.
module Kioku.WorkspaceSpec (tests) where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Kioku.Api.Access (MemorySpaceId, mkMemorySpaceId)
import Kioku.Distill.ScopeIdentity (slugWithDigest)
import Kioku.Workspace
  ( ArtifactMove (..),
    MoveVerdict (..),
    applyArtifactMigration,
    legacyPersonaArtifactDir,
    legacySceneArtifactDir,
    personaArtifactDir,
    planArtifactMigration,
    sceneArtifactDir,
    spaceArtifactRoot,
    spaceDirectoryName,
  )
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath (isRelative, joinPath, splitDirectories, (</>))
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Workspace artifact layout"
    [ testCase "two spaces never share an artifact root" testDistinctRoots,
      testCase "the same space always gets the same root" testStableRoot,
      testCase "space directories use the shared persisted slug recipe" testSharedSlugRecipe,
      testCase "a case-only difference is still two roots" testCaseOnlyDifference,
      testCase "no space id can escape .kioku/spaces" testNoTraversal,
      testCase "a fresh workspace has nothing to migrate" testEmptyMigration,
      testCase "the historical tree is planned, copied, and left in place" testMigrationCopies,
      testCase "a second run is a no-op" testMigrationIdempotent,
      testCase "a destination with different content is refused" testMigrationCollision,
      testCase "a non-markdown file is not Kioku's to relocate" testMigrationIgnoresOtherFiles
    ]

-- * Layout

-- | Same namespace, same scope, same filename — different directory. Without this the two
-- spaces' mirrors are one file, and whichever regenerated last wins.
testDistinctRoots :: Assertion
testDistinctRoots =
  assertBool
    "two memory spaces resolved to the same artifact root"
    (spaceArtifactRoot "/w" (spaceNamed "space_a") /= spaceArtifactRoot "/w" (spaceNamed "space_b"))

testStableRoot :: Assertion
testStableRoot =
  assertEqual
    "the artifact root must be a function of the space id alone"
    (spaceArtifactRoot "/w" (spaceNamed "space_a"))
    (spaceArtifactRoot "/w" (spaceNamed "space_a"))

testSharedSlugRecipe :: Assertion
testSharedSlugRecipe = do
  spaceDirectoryName (spaceNamed "space_A") @?= "space_A-c1c5662504"
  spaceDirectoryName (spaceNamed "space_A") @?= slugWithDigest "space_A" "space_A"
  spaceDirectoryName (spaceNamed "..") @?= "---5ec1f7e700"

-- | macOS and Windows fold case in path components, so a sanitised name alone would merge these
-- two spaces into one directory on the machines this is developed on. The digest is what keeps
-- them apart, and it is over the exact bytes.
testCaseOnlyDifference :: Assertion
testCaseOnlyDifference =
  assertBool
    "space_A and space_a resolved to the same artifact root"
    (spaceDirectoryName (spaceNamed "space_A") /= spaceDirectoryName (spaceNamed "space_a"))

-- | Every one of these is a legal 'MemorySpaceId': 'mkMemorySpaceId' rejects @:@, @#@, @%@, @\/@,
-- whitespace and control characters, and nothing else. @..@ in particular would walk out of
-- @.kioku\/spaces@ if the id were used as a path component directly.
testNoTraversal :: Assertion
testNoTraversal =
  mapM_ check ["..", ".", "...", "..-..", "a.b", "____"]
  where
    check raw = do
      let space = spaceNamed (Text.pack raw)
          name = Text.unpack (spaceDirectoryName space)
          root = spaceArtifactRoot "workspace" space
      assertBool
        (raw <> " encoded to a directory name with a path separator: " <> name)
        (length (splitDirectories name) == 1)
      assertBool
        (raw <> " encoded to a dot segment: " <> name)
        (name /= "." && name /= "..")
      assertBool
        (raw <> " escaped .kioku/spaces: " <> root)
        (joinPath ["workspace", ".kioku", "spaces"] `isInfixOf` root && isRelative root)

-- * Migration

testEmptyMigration :: Assertion
testEmptyMigration =
  withSystemTempDirectory "kioku-workspace-empty" \workspace -> do
    moves <- planArtifactMigration workspace legacyish
    moves @?= []

-- | The plan names both trees, the apply copies them, and — the part that matters — the original
-- is still there afterwards. An operator who applies and then finds the new layout wrong must
-- still have something to fall back on.
testMigrationCopies :: Assertion
testMigrationCopies =
  withSystemTempDirectory "kioku-workspace-copy" \workspace -> do
    writeHistorical workspace "scenes" "web-abc.md" "scene body"
    writeHistorical workspace "persona" "web-abc.md" "persona body"

    planned <- planArtifactMigration workspace legacyish
    map (.verdict) planned @?= [MoveReady, MoveReady]
    assertEqual
      "the plan must name both partitioned destinations, scenes first"
      [ sceneArtifactDir workspace legacyish </> "web-abc.md",
        personaArtifactDir workspace legacyish </> "web-abc.md"
      ]
      (map (.destination) planned)

    applyArtifactMigration planned

    assertFileIs (sceneArtifactDir workspace legacyish </> "web-abc.md") "scene body"
    assertFileIs (personaArtifactDir workspace legacyish </> "web-abc.md") "persona body"
    assertFileIs (legacySceneArtifactDir workspace </> "web-abc.md") "scene body"
    assertFileIs (legacyPersonaArtifactDir workspace </> "web-abc.md") "persona body"

testMigrationIdempotent :: Assertion
testMigrationIdempotent =
  withSystemTempDirectory "kioku-workspace-idempotent" \workspace -> do
    writeHistorical workspace "scenes" "web-abc.md" "scene body"
    planArtifactMigration workspace legacyish >>= applyArtifactMigration

    replanned <- planArtifactMigration workspace legacyish
    map (.verdict) replanned @?= [MoveAlreadyMigrated]
    -- Applying the second plan must still be safe, and must still leave the file alone.
    applyArtifactMigration replanned
    assertFileIs (sceneArtifactDir workspace legacyish </> "web-abc.md") "scene body"

-- | The partitioned file is the one the running system writes. A pre-partition snapshot with the
-- same name is older, so copying over it would replace current content with stale content.
testMigrationCollision :: Assertion
testMigrationCollision =
  withSystemTempDirectory "kioku-workspace-collision" \workspace -> do
    writeHistorical workspace "scenes" "web-abc.md" "the pre-partition snapshot"
    createDirectoryIfMissing True (sceneArtifactDir workspace legacyish)
    writeFile (sceneArtifactDir workspace legacyish </> "web-abc.md") "what the worker wrote today"

    planned <- planArtifactMigration workspace legacyish
    map (.verdict) planned @?= [MoveCollision]

    applyArtifactMigration planned
    assertFileIs (sceneArtifactDir workspace legacyish </> "web-abc.md") "what the worker wrote today"

-- | Only @.md@ files were ever Kioku's. An editor swap file or a README an operator dropped in
-- the directory is theirs, and relocating it would be a surprise.
testMigrationIgnoresOtherFiles :: Assertion
testMigrationIgnoresOtherFiles =
  withSystemTempDirectory "kioku-workspace-other" \workspace -> do
    writeHistorical workspace "scenes" "notes.txt" "not a mirror"
    writeHistorical workspace "scenes" ".web-abc.md.swp" "not a mirror either"
    moves <- planArtifactMigration workspace legacyish
    moves @?= []

-- * Helpers

-- | Not 'legacyMemorySpaceId' itself, because these cases are about the layout rather than about
-- which space the CLI defaults to, and a fixture that happened to be the default would hide a
-- path built from a hard-coded constant.
legacyish :: MemorySpaceId
legacyish = spaceNamed "space_migrated"

writeHistorical :: FilePath -> FilePath -> FilePath -> String -> IO ()
writeHistorical workspace kind name body = do
  let dir = workspace </> ".kioku" </> kind
  createDirectoryIfMissing True dir
  writeFile (dir </> name) body

assertFileIs :: FilePath -> String -> Assertion
assertFileIs path expected = do
  exists <- doesFileExist path
  assertBool ("expected a file at " <> path) exists
  actual <- readFile path
  assertEqual ("contents of " <> path) expected actual

spaceNamed :: Text.Text -> MemorySpaceId
spaceNamed = either (error . Text.unpack) id . mkMemorySpaceId
