{-# LANGUAGE DataKinds #-}

module Kioku.Distill.Runtime
  ( DistillRuntime (..),
    RuntimeSmokeInput (..),
    RuntimeSmokeOutput (..),
    newDistillRuntime,
    runDistillProgram,
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
import Kioku.Prelude
import Shikumi.Adapter (ToPrompt)
import Shikumi.Error (ShikumiError)
import Shikumi.LLM (LLMConfig, defaultLLMConfig, runLLMResilient)
import Shikumi.Module (predict)
import Shikumi.Program (Program, runProgram)
import Shikumi.Routing (routeLLM, runRouting)
import Shikumi.Schema (FromModel, ToSchema)
import Shikumi.Schema.Types (Field)
import Shikumi.Signature (mkSignature)

data DistillRuntime = DistillRuntime
  { config :: !LLMConfig,
    defaultModel :: !Model
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
  deriving anyclass (ToSchema, FromModel, ToPrompt)

newDistillRuntime :: IO DistillRuntime
newDistillRuntime = do
  ClaudeApi.register
  pure
    DistillRuntime
      { config = defaultLLMConfig globalProviderRegistry,
        defaultModel = Models.anthropic_claude_haiku_4_5
      }

runDistillProgram :: DistillRuntime -> Program i o -> i -> IO (Either ShikumiError o)
runDistillProgram rt prog input =
  runEff
    . runErrorNoCallStack @ShikumiError
    . runConcurrent
    . runRouting rt.defaultModel
    . runLLMResilient rt.config
    . routeLLM
    $ runProgram prog input

runtimeSmokeProgram :: Program RuntimeSmokeInput RuntimeSmokeOutput
runtimeSmokeProgram =
  predict $
    mkSignature
      "Return the provided input text exactly once in the answer field."
