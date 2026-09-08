{-# LANGUAGE DataKinds #-}

module Kioku.Distill.Runtime
  ( DistillRuntime,
    TestRunners (..),
    testDistillRuntime,
    withTestRunners,
    withDistillWorkspace,
    distillAvailability,
    RuntimeSmokeInput (..),
    RuntimeSmokeOutput (..),
    distillWorkspaceRoot,
    newDistillRuntime,
    runConsolidation,
    runDistillProgram,
    runExtraction,
    runPersonaDistillation,
    runSceneDistillation,
    runtimeSmokeProgram,
  )
where

import Kioku.AI.Config
import Kioku.AI.Interactive
import Kioku.AI.Runtime
import Kioku.Distill.Consolidate (ConsolidateInput, ConsolidationDecision, consolidateProgram, consolidateSignature)
import Kioku.Distill.Extract (ExtractInput, ExtractOutput, extractProgram, extractSignature)
import Kioku.Distill.Persona (PersonaInput, PersonaOutput, personaProgram, personaSignature)
import Kioku.Distill.Scene (SceneInput, SceneOutput, sceneProgram, sceneSignature)
import Kioku.Prelude
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError)
import Shikumi.Module (predict)
import Shikumi.Program (Program)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema.Types (Field)
import Shikumi.Signature (Signature, mkSignature)
import System.Directory (getCurrentDirectory)

data DistillRuntime = DistillRuntime AIRuntime (Maybe FilePath) (Maybe TestRunners)

-- | Explicit controlled-runner seam for tests. Production construction accepts
-- only a validated AIRuntime; its captured settings cannot be record-updated.
data TestRunners = TestRunners
  { runExtract :: ExtractInput -> IO (Either ShikumiError ExtractOutput),
    runConsolidate :: ConsolidateInput -> IO (Either ShikumiError ConsolidationDecision),
    runScene :: SceneInput -> IO (Either ShikumiError SceneOutput),
    runPersona :: PersonaInput -> IO (Either ShikumiError PersonaOutput)
  }

testDistillRuntime :: IO DistillRuntime
testDistillRuntime = pure (DistillRuntime disabledAIRuntime Nothing (Just emptyTestRunners))

emptyTestRunners :: TestRunners
emptyTestRunners = TestRunners (const missing) (const missing) (const missing) (const missing)
  where
    missing = fail "test distillation runner was not supplied"

withTestRunners :: DistillRuntime -> (TestRunners -> TestRunners) -> DistillRuntime
withTestRunners (DistillRuntime ai root runners) f =
  DistillRuntime ai root (Just (f (fromMaybe emptyTestRunners runners)))

withDistillWorkspace :: FilePath -> DistillRuntime -> DistillRuntime
withDistillWorkspace root (DistillRuntime ai _ runners) = DistillRuntime ai (Just root) runners

distillWorkspaceRoot :: DistillRuntime -> IO FilePath
distillWorkspaceRoot (DistillRuntime _ root _) = maybe getCurrentDirectory pure root

newtype RuntimeSmokeInput = RuntimeSmokeInput
  { prompt :: Field "short input text to echo" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newtype RuntimeSmokeOutput = RuntimeSmokeOutput
  { answer :: Field "the input text repeated back" Text
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToSchema, FromModel, ToPrompt, Validatable)

newDistillRuntime :: AIRuntime -> Maybe FilePath -> DistillRuntime
newDistillRuntime ai root = DistillRuntime ai root Nothing

distillAvailability :: DistillRuntime -> AIFeature -> Either AIExecutionError ()
distillAvailability (DistillRuntime ai _ runners) feature =
  maybe (executionAvailability ai feature) (const (Right ())) runners

runDistillProgram :: DistillRuntime -> AIFeature -> Program i o -> i -> IO (Either AIExecutionError o)
runDistillProgram (DistillRuntime ai _ _) = runAIProgram ai

runTyped ::
  (ToPrompt i, ToPrompt o, ToSchema o, FromModel o, Validatable o) =>
  AIRuntime -> AIFeature -> Signature i o -> Program i o -> i -> IO (Either AIExecutionError o)
runTyped ai feature signature program = case featureConfiguration ai feature of
  InteractiveConfig {} -> runInteractiveSignature ai feature signature
  _ -> runAIProgram ai feature program

runExtraction :: DistillRuntime -> ExtractInput -> IO (Either AIExecutionError ExtractOutput)
runExtraction (DistillRuntime ai _ runners) =
  maybe
    (runTyped ai Extraction extractSignature extractProgram)
    (\r i -> either (Left . AIProgramFailed) Right <$> r.runExtract i)
    runners

runConsolidation :: DistillRuntime -> ConsolidateInput -> IO (Either AIExecutionError ConsolidationDecision)
runConsolidation (DistillRuntime ai _ runners) =
  maybe
    (runTyped ai Consolidation consolidateSignature consolidateProgram)
    (\r i -> either (Left . AIProgramFailed) Right <$> r.runConsolidate i)
    runners

runSceneDistillation :: DistillRuntime -> SceneInput -> IO (Either AIExecutionError SceneOutput)
runSceneDistillation (DistillRuntime ai _ runners) =
  maybe
    (runTyped ai Scene sceneSignature sceneProgram)
    (\r i -> either (Left . AIProgramFailed) Right <$> r.runScene i)
    runners

runPersonaDistillation :: DistillRuntime -> PersonaInput -> IO (Either AIExecutionError PersonaOutput)
runPersonaDistillation (DistillRuntime ai _ runners) =
  maybe
    (runTyped ai Persona personaSignature personaProgram)
    (\r i -> either (Left . AIProgramFailed) Right <$> r.runPersona i)
    runners

runtimeSmokeProgram :: Program RuntimeSmokeInput RuntimeSmokeOutput
runtimeSmokeProgram =
  predict $
    mkSignature
      "Return the provided input text exactly once in the answer field."
