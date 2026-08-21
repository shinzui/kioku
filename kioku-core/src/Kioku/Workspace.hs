-- | Where a memory space's plaintext artifacts live on disk, and how to move the pre-partition
-- ones there.
--
-- Kioku mirrors each scene and persona to a Markdown file so a host agent can read it without a
-- database. Until memory spaces existed those files were keyed by scope alone:
--
-- > .kioku/scenes/<scope-slug>.md
-- > .kioku/persona/<scope-slug>.md
--
-- Two spaces are allowed to hold the same namespace and the same scope — that is the whole point
-- of the partition — so those two paths are the same path, and one space's scene would overwrite
-- the other's the moment both regenerated. The database stopped colliding when
-- @docs\/plans\/26-…@ gave the rows a composite key; the filesystem did not.
--
-- The layout is now rooted per space:
--
-- > .kioku/spaces/<space-dir>/scenes/<scope-slug>.md
-- > .kioku/spaces/<space-dir>/persona/<scope-slug>.md
--
-- == Why the directory name is not the space id
--
-- A 'MemorySpaceId' rejects @:@, @#@, @%@, @\/@, whitespace and control characters
-- ('Kioku.Api.Access.mkMemorySpaceId'), which is enough for a database column and nowhere near
-- enough for a path component. @..@ is a perfectly legal space id and would walk out of
-- @.kioku\/spaces@ entirely. @.@ names the directory itself. And on the case-insensitive
-- filesystems this project is developed on, @space_A@ and @space_a@ are two spaces and one
-- directory.
--
-- So 'spaceDirectoryName' does what 'Kioku.Distill.ScopeIdentity.scopeSlugFromColumns' already
-- does for scopes: a sanitised readable prefix, which is only there so a human can tell the
-- directories apart, plus a digest of the exact id, which is what actually separates them. Every
-- character outside @[A-Za-z0-9_-]@ becomes @-@, so no encoding of any space id can contain a
-- path separator or a dot segment, and the digest is over the true bytes, so no two distinct ids
-- share a directory whatever the filesystem thinks of their case.
--
-- == The historical tree
--
-- Nothing writes to @.kioku\/scenes@ or @.kioku\/persona@ any more. Those files are history: an
-- upgraded deployment still has them, still readable, and 'planArtifactMigration' reports
-- exactly what would move where. 'applyArtifactMigration' copies rather than moves, so a failed
-- verification leaves the originals to fall back on; removing the old tree afterwards is the
-- operator's call and is deliberately not something this module will do.
--
-- The one exception is deletion, in 'Kioku.Distill.L2' and 'Kioku.Distill.L3': when every memory
-- in a scope is forgotten, the legacy space's historical mirror is unlinked along with the
-- partitioned one. A merely out-of-date file is visible to the operator through the migration
-- plan; forgotten content surviving on disk is not out of date, it is a retention failure.
module Kioku.Workspace
  ( -- * Layout
    spaceArtifactRoot,
    spaceDirectoryName,
    sceneArtifactDir,
    personaArtifactDir,
    legacySceneArtifactDir,
    legacyPersonaArtifactDir,

    -- * Migrating the pre-partition tree
    ArtifactMove (..),
    MoveVerdict (..),
    planArtifactMigration,
    applyArtifactMigration,
  )
where

import Control.Exception (IOException, bracket, finally, throwIO, try)
import Data.ByteString qualified as BS
import Data.List (sort)
import Data.Text qualified as Text
import Kioku.Api.Access (MemorySpaceId, memorySpaceIdText)
import Kioku.Distill.ScopeIdentity (slugWithDigest)
import Kioku.Prelude
import System.Directory
  ( createDirectoryIfMissing,
    doesDirectoryExist,
    doesFileExist,
    listDirectory,
    removeFile,
  )
import System.FilePath (takeDirectory, takeExtension, (</>))
import System.IO (Handle, hClose, openBinaryTempFile)
import System.IO.Error (isAlreadyExistsError)
import System.Posix.Files (createLink, fileMode, getFileStatus, setFileMode)

-- | The directory holding every artifact of one memory space.
--
-- @\<workspace\>\/.kioku\/spaces\/\<space-dir\>@. See the module header for why the last
-- component is not the space id itself.
spaceArtifactRoot :: FilePath -> MemorySpaceId -> FilePath
spaceArtifactRoot workspace space =
  spacesRoot workspace </> Text.unpack (spaceDirectoryName space)

-- | Where a space's scene mirrors go.
sceneArtifactDir :: FilePath -> MemorySpaceId -> FilePath
sceneArtifactDir workspace space = spaceArtifactRoot workspace space </> "scenes"

-- | Where a space's persona mirrors go.
personaArtifactDir :: FilePath -> MemorySpaceId -> FilePath
personaArtifactDir workspace space = spaceArtifactRoot workspace space </> "persona"

-- | The pre-partition scene directory. Read for migration, never written.
legacySceneArtifactDir :: FilePath -> FilePath
legacySceneArtifactDir workspace = kiokuRoot workspace </> "scenes"

-- | The pre-partition persona directory. Read for migration, never written.
legacyPersonaArtifactDir :: FilePath -> FilePath
legacyPersonaArtifactDir workspace = kiokuRoot workspace </> "persona"

-- | A path-safe, collision-free directory name for one memory space.
--
-- The readable half cannot be trusted for identity and the digest cannot be read by a human, so
-- the name is both. This is the same shape as a scope slug, for the same reasons.
spaceDirectoryName :: MemorySpaceId -> Text
spaceDirectoryName space =
  slugWithDigest raw raw
  where
    raw = memorySpaceIdText space

kiokuRoot :: FilePath -> FilePath
kiokuRoot workspace = workspace </> ".kioku"

spacesRoot :: FilePath -> FilePath
spacesRoot workspace = kiokuRoot workspace </> "spaces"

-- | What would happen to one historical artifact file.
data ArtifactMove = ArtifactMove
  { source :: !FilePath,
    destination :: !FilePath,
    verdict :: !MoveVerdict
  }
  deriving stock (Generic, Eq, Show)

-- | Why a move will or will not happen.
data MoveVerdict
  = -- | Nothing is at the destination; the file will be copied.
    MoveReady
  | -- | The destination already holds byte-identical content. This is what makes a second run a
    -- no-op rather than an error.
    MoveAlreadyMigrated
  | -- | The destination exists with different content. Refused: the partitioned file is the one
    -- the running system writes, and overwriting it with a pre-partition snapshot would replace
    -- current content with older content.
    MoveCollision
  deriving stock (Generic, Eq, Show)

-- | Work out what migrating the historical tree into one memory space would do, without touching
-- anything.
--
-- Only @.md@ files are considered, because those are the only files Kioku ever wrote there; a
-- @README@ or an editor swap file an operator left behind is not Kioku's to relocate. The result
-- is sorted by source path so that a dry run and the run that follows it read the same.
planArtifactMigration :: FilePath -> MemorySpaceId -> IO [ArtifactMove]
planArtifactMigration workspace space = do
  scenes <- planDirectory (legacySceneArtifactDir workspace) (sceneArtifactDir workspace space)
  personas <- planDirectory (legacyPersonaArtifactDir workspace) (personaArtifactDir workspace space)
  pure (scenes <> personas)

planDirectory :: FilePath -> FilePath -> IO [ArtifactMove]
planDirectory sourceDir destinationDir = do
  present <- doesDirectoryExist sourceDir
  if not present
    then pure []
    else do
      entries <- sort . filter isMarkdown <$> listDirectory sourceDir
      traverse (planOne sourceDir destinationDir) entries
  where
    isMarkdown = (== ".md") . takeExtension

planOne :: FilePath -> FilePath -> FilePath -> IO ArtifactMove
planOne sourceDir destinationDir name = do
  let source = sourceDir </> name
      destination = destinationDir </> name
  occupied <- doesFileExist destination
  verdict <-
    if not occupied
      then pure MoveReady
      else do
        same <- sameContent source destination
        pure (if same then MoveAlreadyMigrated else MoveCollision)
  pure ArtifactMove {source, destination, verdict}

-- | Compared by exact bytes rather than by size or mtime: a copy made by an earlier run has a
-- different mtime and must still count as already migrated.
sameContent :: FilePath -> FilePath -> IO Bool
sameContent left right = do
  leftBytes <- BS.readFile left
  rightBytes <- BS.readFile right
  pure (leftBytes == rightBytes)

-- | Carry out a plan, publishing every 'MoveReady' file without replacing anything else.
--
-- Copy, not move: the historical file stays where it is until an operator has verified the new
-- layout and removed the old tree themselves. A 'MoveCollision' is skipped here rather than
-- overwritten — the caller is expected to report it and exit non-zero, which is what makes a
-- refusal visible instead of silent. Publication itself also refuses replacement, so a worker
-- that creates the destination after this plan was made cannot be clobbered. Re-running is safe:
-- every file copied by the previous run plans as 'MoveAlreadyMigrated'.
applyArtifactMigration :: [ArtifactMove] -> IO ()
applyArtifactMigration moves =
  forM_ moves \move ->
    when (move.verdict == MoveReady) do
      createDirectoryIfMissing True (takeDirectory move.destination)
      copyFileNoReplace move.source move.destination

-- | Copy through a fully written temporary sibling and atomically publish it with POSIX
-- @link(2)@. Hard-link creation fails if @destination@ already exists, closing the race between
-- 'planArtifactMigration' and this apply step without ever exposing partial bytes.
copyFileNoReplace :: FilePath -> FilePath -> IO ()
copyFileNoReplace source destination = do
  sourceBytes <- BS.readFile source
  sourceMode <- fileMode <$> getFileStatus source
  bracket
    (openBinaryTempFile destinationDir temporaryTemplate)
    cleanupTemporary
    \(temporary, handle) -> do
      BS.hPut handle sourceBytes
      hClose handle
      setFileMode temporary sourceMode
      published <- try @IOException (createLink temporary destination)
      case published of
        Right () -> pure ()
        Left err
          | isAlreadyExistsError err -> do
              destinationBytes <- BS.readFile destination
              unless (destinationBytes == sourceBytes) $
                throwIO (userError ("kioku artifact migration refused existing destination: " <> destination))
          | otherwise -> throwIO err
  where
    destinationDir = takeDirectory destination

-- The name is intentionally recognizable: a process killed before bracket cleanup may leave a
-- hidden sibling that an operator can safely identify after confirming no migration is running.
temporaryTemplate :: FilePath
temporaryTemplate = ".kioku-migrate-artifacts.tmp"

cleanupTemporary :: (FilePath, Handle) -> IO ()
cleanupTemporary (temporary, handle) =
  hClose handle `finally` removeFile temporary
