module Kioku.AIRuntimeSpec (tests) where

import Baikai.Api (Api (..))
import Baikai.Content (AssistantContent (..), emptyTextContent)
import Baikai.Interactive qualified as I
import Baikai.Model qualified as M
import Baikai.Options qualified as O
import Baikai.Provider.Registry qualified as R
import Baikai.Response (emptyResponse)
import Control.Concurrent (forkIO, newEmptyMVar, putMVar, takeMVar)
import Control.Lens ((&), (.~))
import Data.Aeson qualified as A
import Data.Aeson.KeyMap qualified as KM
import Data.Aeson.Types (parseEither)
import Data.ByteString.Lazy qualified as LBS
import Data.Generics.Labels ()
import Data.IORef
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Text.Encoding (encodeUtf8)
import Data.Vector qualified as V
import Kioku.AI.Config
import Kioku.AI.File (parseAIConfig)
import Kioku.AI.Runtime
import Kioku.Distill.Consolidate
import Kioku.Distill.Extract
import Kioku.Distill.Persona
import Kioku.Distill.Runtime
import Kioku.Distill.Scene
import Shikumi.Schema.Types (field)
import System.Exit (ExitCode (..))
import System.Posix.Files (createSymbolicLink)
import Test.Tasty
import Test.Tasty.HUnit

tests :: TestTree
tests =
  testGroup
    "AI runtime"
    [ testCase "versioned configuration rejects unknown modes and features" $ do
        mapM_
          ( \raw -> case A.eitherDecodeStrict raw >>= parseEither parseAIConfig of
              Left _ -> pure ()
              Right _ -> assertFailure "accepted invalid configuration"
          )
          [ "{\"version\":2}",
            "{\"version\":1,\"permissions\":[\"automatic\"]}",
            "{\"version\":1,\"features\":{\"unknown\":{\"mode\":\"disabled\"}}}",
            "{\"version\":1,\"distillation\":{\"mode\":\"api\"}}"
          ],
      testCase "disabled construction and all features make no calls" $ do
        rt <- expect =<< newAIRuntime noHostCapabilities disabledAIConfig
        mapM_ (\f -> executionAvailability rt f @?= Left (AIDisabled f)) [minBound .. maxBound]
        result <- runExtraction (newDistillRuntime rt Nothing) input
        result @?= Left (AIDisabled Extraction),
      testCase "overrides cannot grant API authority" $ do
        result <- newAIRuntime noHostCapabilities {allowInteractive = True} completionConfig
        case result of Left _ -> pure (); Right _ -> assertFailure "API was permitted",
      testCase "transport aliases cannot disguise batch as API" $ do
        registry <- R.newProviderRegistry
        let cfg = disabledAIConfig {distillationDefault = CompletionConfig API ((M.mkModel (Custom "anthropic-messages-cli") "m" "")) O.emptyOptions}
        result <- newAIRuntime noHostCapabilities {apiRegistry = Just registry} cfg
        case result of Left _ -> pure (); Right _ -> assertFailure "batch was permitted",
      testCase "concurrent host registries and model/options remain isolated" $ do
        left <- host "left"
        right <- host "right"
        l <- newEmptyMVar
        r <- newEmptyMVar
        _ <- forkIO (smoke left >>= putMVar l)
        _ <- forkIO (smoke right >>= putMVar r)
        takeMVar l >>= (@?= Right (RuntimeSmokeOutput (field "left")))
        takeMVar r >>= (@?= Right (RuntimeSmokeOutput (field "right"))),
      testCase "per-feature batch override uses only its authorized registry and options" testBatchOverride,
      testCase "interactive background ownership is deferred without a call" $ do
        rt <- expect =<< newAIRuntime noHostCapabilities {allowInteractive = True} interactiveConfig
        result <- runExtraction (newDistillRuntime rt Nothing) input
        result @?= Left (InteractiveUnavailable Extraction),
      testCase "real result file is decoded through extraction validation" $ do
        rt <- interactive (fixture Valid)
        result <- runExtraction (newDistillRuntime rt Nothing) input
        result @?= Right (ExtractOutput []),
      testCase "interactive handoff checks all remaining feature signatures" $ do
        ai <- interactive (fixture Valid)
        let rt = newDistillRuntime ai Nothing
        runSceneDistillation rt (SceneInput (field "fixture") (field "facts")) >>= (@?= Right (SceneOutput (field "Fixture") (field "Facts")))
        runPersonaDistillation rt (PersonaInput (field "fixture") (field "facts")) >>= (@?= Right (PersonaOutput (field "Facts")))
        let atom = ExtractedAtom (field "fact") (field "fixture") (field 100) (field "high")
        result <- runConsolidation rt (ConsolidateInput (field "fixture") atom [])
        result @?= Right (ConsolidationDecision StoreAtom [] Nothing (field "Fixture")),
      testCase "invalid result files never succeed" $
        mapM_
          ( \variant -> do
              rt <- interactive (fixture variant)
              result <- runExtraction (newDistillRuntime rt Nothing) input
              case result of Left _ -> pure (); Right _ -> assertFailure ("accepted " <> show variant)
          )
          [WrongId, Missing, BadDomain, Nonzero, Symlink, Oversized, Cancelled]
    ]

testBatchOverride :: IO ()
testBatchOverride = do
  let model name = M.mkModel (Custom "fixture") name ""
      handler name tokens = R.apiProviderWith (Custom "fixture") (\_ _ _ -> error "unexpected stream") $ \chosen _ opts -> do
        M.modelId chosen @?= name
        opts.maxTokens @?= Just tokens
        pure (emptyResponse & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ ("[[ ## answer ## ]]\n" <> name <> "\n[[ ## completed ## ]]"))))
  api <- R.newProviderRegistryFrom [handler "api" 17]
  batch <- R.newProviderRegistryFrom [handler "batch" 23]
  let cfg =
        disabledAIConfig
          { distillationDefault = CompletionConfig API (model "api") (O.emptyOptions {O.maxTokens = Just 17}),
            featureOverrides = Map.singleton Persona (CompletionConfig Batch (model "batch") (O.emptyOptions {O.maxTokens = Just 23}))
          }
  ai <- expect =<< newAIRuntime noHostCapabilities {apiRegistry = Just api, batchRegistry = Just batch} cfg
  let rt = newDistillRuntime ai Nothing
  runDistillProgram rt Extraction runtimeSmokeProgram (RuntimeSmokeInput (field "fixture")) >>= (@?= Right (RuntimeSmokeOutput (field "api")))
  runDistillProgram rt Persona runtimeSmokeProgram (RuntimeSmokeInput (field "fixture")) >>= (@?= Right (RuntimeSmokeOutput (field "batch")))

expect :: (Show e) => Either e a -> IO a
expect = either (assertFailure . show) pure

input :: ExtractInput
input = ExtractInput (field "fixture") (field "test") (field "No durable facts.")

completionConfig :: AIConfig
completionConfig = disabledAIConfig {distillationDefault = CompletionConfig API model (O.emptyOptions {O.maxTokens = Just 17})}
  where
    model = (M.mkModel (Custom "fixture") "chosen" "") {M.provider = "fixture"}

host :: T.Text -> IO AIRuntime
host answer = do
  calls <- newIORef (0 :: Int)
  let handler = R.apiProviderWith (Custom "fixture") (\_ _ _ -> error "unexpected stream") $ \model _ opts -> do
        M.modelId model @?= "chosen"
        opts.maxTokens @?= Just 17
        modifyIORef' calls (+ 1)
        pure (emptyResponse & #message . #content .~ V.singleton (AssistantText (emptyTextContent & #text .~ ("[[ ## answer ## ]]\n" <> answer <> "\n[[ ## completed ## ]]"))))
  reg <- R.newProviderRegistryFrom [handler]
  rt <- expect =<< newAIRuntime noHostCapabilities {apiRegistry = Just reg} completionConfig
  readIORef calls >>= (@?= 0)
  R.registerApiProviderWith reg (handler {R.complete = \_ _ _ -> assertFailure "mutated host registry reached runtime"})
  pure rt

smoke :: AIRuntime -> IO (Either AIExecutionError RuntimeSmokeOutput)
smoke rt = runDistillProgram (newDistillRuntime rt Nothing) Extraction runtimeSmokeProgram (RuntimeSmokeInput (field "hello"))

interactiveConfig :: AIConfig
interactiveConfig = disabledAIConfig {distillationDefault = InteractiveConfig I.InteractiveClaude ((I.interactiveLaunchRequest "") {I.modelId = Just "fixture"})}

interactive launch = expect =<< newAIRuntime noHostCapabilities {allowInteractive = True, launchInteractive = Just launch} interactiveConfig

data Variant = Valid | WrongId | Missing | BadDomain | Nonzero | Symlink | Oversized | Cancelled deriving (Show)

fixture Cancelled feature _ = pure (Left (AIInteractiveFailed feature "cancelled"))
fixture variant feature req = do
  let raw = T.drop 1 (snd (T.breakOn "\n" req.userPrompt))
  value <- expect (A.eitherDecodeStrict (encodeUtf8 raw))
  case value of
    A.Object manifest -> do
      let lookupField key = maybe (error "missing manifest field") id (KM.lookup key manifest)
          output = case lookupField "outputFile" of A.String p -> T.unpack p; _ -> error "invalid outputFile"
          result = case variant of
            BadDomain -> A.object ["atoms" A..= [A.object ["atomType" A..= ("invalid" :: T.Text), "content" A..= ("x" :: T.Text), "priority" A..= (100 :: Int), "confidence" A..= ("high" :: T.Text)]]]
            _ -> case feature of
              Scene -> A.object ["title" A..= ("Fixture" :: T.Text), "bodyMd" A..= ("Facts" :: T.Text)]
              Persona -> A.object ["bodyMd" A..= ("Facts" :: T.Text)]
              Consolidation -> A.object ["action" A..= ("StoreAtom" :: T.Text), "targetMemoryIds" A..= ([] :: [T.Text]), "resultContent" A..= A.Null, "rationale" A..= ("Fixture" :: T.Text)]
              _ -> A.object ["atoms" A..= ([] :: [A.Value])]
          envelope = A.object ["requestId" A..= (case variant of WrongId -> A.String "stale"; _ -> lookupField "requestId"), "feature" A..= lookupField "feature", "result" A..= result]
      case variant of
        Missing -> pure ()
        Oversized -> LBS.writeFile output (LBS.replicate (1024 * 1024 + 1) 32)
        Symlink -> createSymbolicLink "request.json" output
        _ -> LBS.writeFile output (A.encode envelope)
      pure (Right (I.interactiveLaunchResult I.InteractiveClaude (case variant of Nonzero -> ExitFailure 1; _ -> ExitSuccess)))
    _ -> assertFailure "invalid manifest"
