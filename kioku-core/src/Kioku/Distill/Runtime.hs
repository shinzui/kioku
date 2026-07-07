{-# LANGUAGE DataKinds #-}

module Kioku.Distill.Runtime
  ( DistillRuntime (..),
    RuntimeSmokeInput (..),
    RuntimeSmokeOutput (..),
    newDistillRuntime,
    runConsolidation,
    runDistillProgram,
    runExtraction,
    runPersonaDistillation,
    runSceneDistillation,
    runtimeSmokeProgram,
  )
where

import Baikai.Model (Model)
import Baikai.Models.Generated qualified as Models
import Baikai.Provider.Claude.Api qualified as ClaudeApi
import Baikai.Provider.Registry (globalProviderRegistry)
import Effectful (runEff)
import Effectful.Concurrent (runConcurrent)
import Effectful.Error.Static (runErrorNoCallStack)
import Kioku.Distill.Consolidate (ConsolidateInput, ConsolidationDecision, consolidateProgram)
import Kioku.Distill.Extract (ExtractInput, ExtractOutput, extractProgram)
import Kioku.Distill.Persona (PersonaInput, PersonaOutput, personaProgram)
import Kioku.Distill.Scene (SceneInput, SceneOutput, sceneProgram)
import Kioku.Prelude
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLMConfig, defaultLLMConfig, runLLMResilient)
import Shikumi.Module (predict)
import Shikumi.Program (Program, runProgram)
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Schema (FromModel, ToSchema, Validatable)
import Shikumi.Schema.Types (Field)
import Shikumi.Signature (mkSignature)

data DistillRuntime = DistillRuntime
  { config :: !LLMConfig,
    defaultModel :: !Model,
    runExtract :: !(ExtractInput -> IO (Either ShikumiError ExtractOutput)),
    runConsolidate :: !(ConsolidateInput -> IO (Either ShikumiError ConsolidationDecision)),
    runScene :: !(SceneInput -> IO (Either ShikumiError SceneOutput)),
    runPersona :: !(PersonaInput -> IO (Either ShikumiError PersonaOutput))
  }

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

newDistillRuntime :: IO DistillRuntime
newDistillRuntime = do
  ClaudeApi.register
  let config = defaultLLMConfig globalProviderRegistry
      defaultModel = Models.anthropic_claude_haiku_4_5
      liveRun = runLiveDistillProgram config defaultModel
  pure
    DistillRuntime
      { config,
        defaultModel,
        runExtract = liveRun extractProgram,
        runConsolidate = liveRun consolidateProgram,
        runScene = liveRun sceneProgram,
        runPersona = liveRun personaProgram
      }

runDistillProgram :: DistillRuntime -> Program i o -> i -> IO (Either ShikumiError o)
runDistillProgram rt prog input =
  runLiveDistillProgram rt.config rt.defaultModel prog input

runExtraction :: DistillRuntime -> ExtractInput -> IO (Either ShikumiError ExtractOutput)
runExtraction rt =
  rt.runExtract

runConsolidation :: DistillRuntime -> ConsolidateInput -> IO (Either ShikumiError ConsolidationDecision)
runConsolidation rt =
  rt.runConsolidate

runSceneDistillation :: DistillRuntime -> SceneInput -> IO (Either ShikumiError SceneOutput)
runSceneDistillation rt =
  rt.runScene

runPersonaDistillation :: DistillRuntime -> PersonaInput -> IO (Either ShikumiError PersonaOutput)
runPersonaDistillation rt =
  rt.runPersona

runLiveDistillProgram :: LLMConfig -> Model -> Program i o -> i -> IO (Either ShikumiError o)
runLiveDistillProgram config model prog input =
  runEff
    . runErrorNoCallStack @ShikumiError
    . runConcurrent
    . runRouting model
    . runLLMResilient config
    . routeLLM
    $ runProgram prog input

runtimeSmokeProgram :: Program RuntimeSmokeInput RuntimeSmokeOutput
runtimeSmokeProgram =
  predict $
    mkSignature
      "Return the provided input text exactly once in the answer field."
