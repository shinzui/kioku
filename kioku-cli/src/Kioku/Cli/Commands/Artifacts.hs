-- | @kioku migrate-artifacts@: move the pre-partition workspace mirrors into a memory space.
--
-- Before memory spaces existed, scene and persona mirrors were written to @.kioku\/scenes@ and
-- @.kioku\/persona@, keyed by scope alone. Two spaces holding the same scope would have written
-- to the same file, so the layout is now @.kioku\/spaces\/\<space-dir\>\/{scenes,persona}@ and
-- nothing writes to the old tree any more. This command relocates what is already there.
--
-- It is a dry run unless @--apply@ is passed. That default is the point: the command exists so
-- an operator can read exactly which file would land where, and see any collision, before
-- anything is written.
module Kioku.Cli.Commands.Artifacts
  ( ArtifactsOptions (..),
    artifactsOptionsParser,
    runArtifacts,
  )
where

import Control.Monad (when)
import Data.Text qualified as Text
import Kioku.Api.Access (memorySpaceIdText)
import Kioku.Cli.Context (cliMemorySpace)
import Kioku.Workspace
  ( ArtifactMove (..),
    MoveVerdict (..),
    applyArtifactMigration,
    planArtifactMigration,
  )
import Options.Applicative
import System.Directory (getCurrentDirectory)
import System.Exit (ExitCode (..), exitWith)

data ArtifactsOptions = ArtifactsOptions
  { workspace :: !(Maybe FilePath),
    apply :: !Bool
  }
  deriving stock (Eq, Show)

artifactsOptionsParser :: Parser ArtifactsOptions
artifactsOptionsParser =
  ArtifactsOptions
    <$> optional
      ( strOption
          ( long "workspace"
              <> metavar "DIR"
              <> help "Workspace holding .kioku (default: the current directory)"
          )
      )
    <*> switch
      ( long "apply"
          <> help "Copy the files (default: report what would happen and write nothing)"
      )

-- | The destination space comes from @KIOKU_MEMORY_SPACE@, which defaults to @kioku_legacy@.
--
-- That default is the same rule the database backfill follows: every artifact in the historical
-- tree was written before the partition existed, so it belongs to the one explicit legacy space
-- unless the operator says otherwise. See @docs\/adr\/legacy-data-lands-in-one-explicit-space.md@.
runArtifacts :: ArtifactsOptions -> IO ()
runArtifacts opts = do
  space <- cliMemorySpace
  workspace <- maybe getCurrentDirectory pure opts.workspace
  moves <- planArtifactMigration workspace space
  putStrLn
    ( "kioku artifact migration ("
        <> (if opts.apply then "apply" else "dry run")
        <> ") for memory space "
        <> Text.unpack (memorySpaceIdText space)
    )
  if null moves
    then putStrLn "  (no pre-partition scene or persona mirrors found)"
    else mapM_ (putStrLn . renderMove) moves
  when opts.apply (applyArtifactMigration moves)
  putStrLn (summarize moves)
  -- A collision is a refusal, and a refusal a script cannot see is not a refusal. It is
  -- reported in dry-run mode too, because the whole purpose of the dry run is to find out
  -- before applying.
  when (any ((== MoveCollision) . (.verdict)) moves) (exitWith (ExitFailure 1))

renderMove :: ArtifactMove -> String
renderMove move =
  "  " <> verdictLabel move.verdict <> "  " <> move.source <> " -> " <> move.destination

verdictLabel :: MoveVerdict -> String
verdictLabel = \case
  MoveReady -> "copy     "
  MoveAlreadyMigrated -> "migrated "
  MoveCollision -> "COLLISION"

summarize :: [ArtifactMove] -> String
summarize moves =
  show (count MoveReady)
    <> " to copy, "
    <> show (count MoveAlreadyMigrated)
    <> " already migrated, "
    <> show (count MoveCollision)
    <> " refused as collisions."
  where
    count verdict = length (filter ((== verdict) . (.verdict)) moves)
