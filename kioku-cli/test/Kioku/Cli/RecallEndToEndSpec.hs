-- | @kioku recall@ against a real database, driven the way an operator drives it.
--
-- "Kioku.Cli.ParserSpec" proves each flag produces the intended 'RecallTarget', and
-- @Kioku.RecallTargetSpec@ in @kioku-core@ proves what each target returns. What neither can see
-- is the seam between them: that the parsed target is the one handed to the query, that
-- @KIOKU_MEMORY_SPACE@ bounds the search, and that the run announces itself on stderr without
-- putting a word on stdout.
--
-- The command runs as a subprocess rather than through 'Kioku.Cli.Commands.Recall.runRecall' in
-- process. @stdout@, @stderr@ and the environment are process-wide, and tasty runs cases
-- concurrently, so redirecting them here would race every other case in the suite. A subprocess
-- gets its own three.
--
-- Every case is @--strategy keyword@, which plans no vector channel and therefore never embeds:
-- the suite needs a database, not an embedding endpoint.
module Kioku.Cli.RecallEndToEndSpec (tests) where

import Control.Monad.IO.Class (liftIO)
import Data.Aeson (toJSON)
import Data.List (isInfixOf)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Timer qualified as Timer
import Kioku.Api.Access
  ( MemoryAccessContext,
    MemoryActor (..),
    MemorySpaceId,
    assumeAuthorizedMemoryContext,
    memoryContextRecordedActor,
    memorySpaceIdText,
    mkMemorySpaceId,
    mkPrincipalRef,
  )
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (Confidence (..), MemoryType (..))
import Kioku.App (runAppIO, withNoopAppEnv)
import Kioku.Distill.L2 (SceneTimerPayload (..), l2SceneProcessManagerName)
import Kioku.Id (genMemoryId)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Effect.Resource (KirokuStoreResource)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import System.Environment (getEnvironment)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (CreateProcess (..), proc, readCreateProcessWithExitCode)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "kioku recall end to end"
    [ testCase "deferred commands list, refuse disabled execution, and complete original work" deferredCommands,
      testCase "explicit AI file overrides environment and credentials do not enable AI" aiFilePrecedence,
      testCase "each flag reaches the database as its own target, inside one space" targetsReachPostgres
    ]

aiFilePrecedence :: IO ()
aiFilePrecedence = withSystemTempDirectory "kioku-ai-config-test" $ \dir -> do
  let path = dir </> "disabled.json"
  writeFile path "{\"version\":1}"
  inherited <- getEnvironment
  let variables =
        filter (\(name, _) -> name `notElem` ["KIOKU_AI_CONFIG", "PG_CONNECTION_STRING", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"]) inherited
          <> [("KIOKU_AI_CONFIG", dir </> "missing.json"), ("PG_CONNECTION_STRING", "host=/nonexistent connect_timeout=1"), ("ANTHROPIC_API_KEY", "sentinel-not-a-credential")]
  (code, _, err) <- readCreateProcessWithExitCode (proc "kioku" ["worker", "--backfill", "--ai-config", path]) {env = Just variables} ""
  assertBool "disabled backfill fails" (code /= ExitSuccess)
  assertContains "explicit file wins" "AIDisabled MemoryEmbedding" err
  assertMissing "credential redaction" "sentinel-not-a-credential" err
  (environmentCode, _, environmentError) <- readCreateProcessWithExitCode (proc "kioku" ["worker", "--backfill"]) {env = Just variables} ""
  assertBool "environment file is used without flag" (environmentCode /= ExitSuccess)
  assertContains "environment fallback" "missing.json" environmentError

-- | Two spaces holding the same namespace and the same two scopes, with content that names which
-- space and which scope it came from — so a row appearing in the wrong answer is unmistakable.
alphaSpace :: MemorySpaceId
alphaSpace = spaceNamed "space_cli_alpha"

betaSpace :: MemorySpaceId
betaSpace = spaceNamed "space_cli_beta"

namespaceText :: Text
namespaceText = "mori"

entityScope :: MemoryScope
entityScope = ScopeEntity (Namespace namespaceText) (ScopeKind "repo") "web"

globalScope :: MemoryScope
globalScope = ScopeGlobal (Namespace namespaceText)

targetsReachPostgres :: IO ()
targetsReachPostgres = withKiokuMigratedDatabase \connStr -> do
  now <- getCurrentTime
  seeded <-
    withNoopAppEnv (defaultConnectionSettings connStr) \env ->
      runAppIO env do
        seed alphaSpace globalScope "alpha global checklist" now
        seed alphaSpace entityScope "alpha web checklist" now
        seed betaSpace globalScope "beta global checklist" now
        seed betaSpace entityScope "beta web checklist" now
  case seeded of
    Left storeErr -> assertFailure ("seeding failed: " <> show storeErr)
    Right () -> pure ()

  let recallIn space args = runKioku connStr space (["recall", "checklist", "--strategy", "keyword"] <> args)

  -- The global bucket is the target that had no representation at all before this initiative.
  (globalCode, globalOut, _) <- recallIn alphaSpace ["--global-bucket", Text.unpack namespaceText]
  globalCode @?= ExitSuccess
  assertContains "the global bucket" "alpha global" globalOut
  assertMissing "the global bucket" "alpha web" globalOut

  (entityCode, entityOut, _) <- recallIn alphaSpace ["--scope", Text.unpack namespaceText <> ":repo:web"]
  entityCode @?= ExitSuccess
  assertContains "the entity scope" "alpha web" entityOut
  assertMissing "the entity scope" "alpha global" entityOut

  (wideCode, wideOut, wideErr) <- recallIn alphaSpace ["--namespace-wide", Text.unpack namespaceText]
  wideCode @?= ExitSuccess
  assertContains "namespace-wide" "alpha global" wideOut
  assertContains "namespace-wide" "alpha web" wideOut

  -- No target may cross the partition, however wide it is. The other space's rows differ only in
  -- one word, and the widest target is the one that would reach them if anything could.
  mapM_ (\out -> assertMissing "any target in the alpha space" "beta" out) [globalOut, entityOut, wideOut]

  -- The same widest target under the other space's context answers with that space's rows.
  (betaCode, betaOut, betaErr) <- recallIn betaSpace ["--namespace-wide", Text.unpack namespaceText]
  betaCode @?= ExitSuccess
  assertContains "namespace-wide in the beta space" "beta global" betaOut
  assertContains "namespace-wide in the beta space" "beta web" betaOut
  assertMissing "namespace-wide in the beta space" "alpha" betaOut

  -- The banner says what was searched, and says it where a pipe will not pick it up.
  assertContains "the stderr banner" "every scope in mori" wideErr
  assertContains "the stderr banner" (Text.unpack (memorySpaceIdText alphaSpace)) wideErr
  assertContains "the stderr banner" (Text.unpack (memorySpaceIdText betaSpace)) betaErr
  assertMissing "stdout" "kioku recall: searching" wideOut

  -- The one spelling whose meaning would have changed fails before it reaches the database.
  (bareCode, bareOut, bareErr) <- recallIn alphaSpace ["--scope", Text.unpack namespaceText]
  assertBool ("a bare --scope namespace must fail, got: " <> show bareCode) (bareCode /= ExitSuccess)
  assertContains "the ambiguity error" "--global-bucket mori" bareErr
  assertContains "the ambiguity error" "--namespace-wide mori" bareErr
  assertMissing "the ambiguity error's stdout" "checklist" bareOut

seed ::
  (IOE :> es, KirokuStoreResource :> es, Store :> es, Error StoreError :> es) =>
  MemorySpaceId ->
  MemoryScope ->
  Text ->
  UTCTime ->
  Eff es ()
seed space scope content now = do
  memoryId <- liftIO genMemoryId
  let context = contextFor space
  recorded <-
    Memory.recordWithContext
      context
      RecordMemoryData
        { memorySpaceId = space,
          actorPrincipal = memoryContextRecordedActor context,
          ownerPrincipal = Nothing,
          memoryId,
          agentId = "cli-test",
          sessionId = Nothing,
          scope,
          memoryType = MemoryPreference,
          content,
          priority = 50,
          confidence = HighConfidence,
          tags = mempty,
          supersedes = Nothing,
          recordedAt = now
        }
  case recorded of
    Left writeErr -> liftIO (assertFailure ("recordWithContext: " <> show writeErr))
    Right _ -> pure ()

-- | Run the built @kioku@ binary. Cabal puts it on @PATH@ through @build-tool-depends@.
--
-- The connection string and memory space are replaced rather than added, so a developer's
-- exported @PG_CONNECTION_STRING@ cannot redirect the test at their own database.
runKioku :: Text -> MemorySpaceId -> [String] -> IO (ExitCode, String, String)
runKioku = runKiokuAt Nothing

runKiokuAt :: Maybe FilePath -> Text -> MemorySpaceId -> [String] -> IO (ExitCode, String, String)
runKiokuAt directory connStr space args = do
  inherited <- getEnvironment
  let overridden =
        [ (name, value)
        | (name, value) <- inherited,
          name `notElem` ["PG_CONNECTION_STRING", "KIOKU_MEMORY_SPACE", "KIOKU_AI_CONFIG", "ANTHROPIC_API_KEY", "OPENAI_API_KEY"]
        ]
          <> [ ("PG_CONNECTION_STRING", Text.unpack connStr),
               ("KIOKU_MEMORY_SPACE", Text.unpack (memorySpaceIdText space))
             ]
  readCreateProcessWithExitCode (proc "kioku" args) {env = Just overridden, cwd = directory} ""

assertContains :: String -> String -> String -> IO ()
assertContains label needle haystack =
  assertBool
    (label <> " should mention " <> show needle <> ", got:\n" <> haystack)
    (needle `isInfixOf` haystack)

assertMissing :: String -> String -> String -> IO ()
assertMissing label needle haystack =
  assertBool
    (label <> " must not mention " <> show needle <> ", got:\n" <> haystack)
    (not (needle `isInfixOf` haystack))

contextFor :: MemorySpaceId -> MemoryAccessContext
contextFor space = assumeAuthorizedMemoryContext space testActor

testActor :: MemoryActor
testActor =
  MemoryActor (either (error . Text.unpack) id (mkPrincipalRef "agent_01h9xk3v7hf8b9c0d1e2f3g4h5"))

spaceNamed :: Text -> MemorySpaceId
spaceNamed raw = either (error . Text.unpack) id (mkMemorySpaceId raw)

-- No memories exist in this scope, so valid foreground scene work completes
-- without invoking a model. The core timer suite separately exercises the real
-- interactive manifest/result handoff during a contested foreground claim.
deferredCommands :: IO ()
deferredCommands = withKiokuMigratedDatabase $ \connStr ->
  withSystemTempDirectory "kioku-deferred-cli" $ \dir -> do
    let tid = Timer.TimerId UUID.nil
        disabled = dir </> "disabled.json"
        interactive = dir </> "interactive.json"
    writeFile disabled "{\"version\":1}"
    writeFile interactive "{\"version\":1,\"permissions\":[\"interactive\"],\"distillation\":{\"mode\":\"interactive\",\"provider\":\"claude\",\"model\":\"fixture\",\"workingDir\":\".\"}}"
    now <- getCurrentTime
    withNoopAppEnv (defaultConnectionSettings connStr) $ \app -> do
      seeded <- runAppIO app $ do
        runTransaction
          ( Timer.scheduleTimerTx
              ( Timer.TimerRequest
                  tid
                  l2SceneProcessManagerName
                  "scene-fixture"
                  now
                  (toJSON (SceneTimerPayload alphaSpace globalScope))
              )
          )
        Timer.deadLetterTimer tid "kioku:deferred:interactive-unavailable feature=scene"
      seeded @?= Right True
      (listed, output, _) <- runKiokuAt (Just dir) connStr alphaSpace ["worker", "deferred", "list", "--ai-config", disabled]
      listed @?= ExitSuccess
      assertContains "list timer" (UUID.toString UUID.nil) output
      assertContains "list space" (Text.unpack (memorySpaceIdText alphaSpace)) output
      (refused, _, diagnostic) <- runKiokuAt (Just dir) connStr alphaSpace ["worker", "deferred", "resume", UUID.toString UUID.nil, "--ai-config", disabled]
      assertBool "disabled resume refuses" (refused /= ExitSuccess)
      assertContains "disabled reason" "AIDisabled Scene" diagnostic
      afterRefusal <- runAppIO app (Timer.lookupTimer tid)
      fmap (fmap (.attempts)) afterRefusal @?= Right (Just 0)
      (completed, done, err) <- runKiokuAt (Just dir) connStr alphaSpace ["worker", "deferred", "resume", UUID.toString UUID.nil, "--ai-config", interactive]
      assertBool ("foreground failed: " <> err) (completed == ExitSuccess)
      assertContains "completion" "Completed the original deferred timer" done
      final <- runAppIO app (Timer.lookupTimer tid)
      fmap (fmap (.status)) final @?= Right (Just Timer.Fired)
      fmap (fmap (.attempts)) final @?= Right (Just 1)
