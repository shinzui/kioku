{-# LANGUAGE DataKinds #-}
{-# LANGUAGE OverloadedStrings #-}

-- Run against synthetic evidence only; no database connection is opened.
import Kioku.AI.File (loadAIRuntime)
import Kioku.Distill.Extract (ExtractInput (..))
import Kioku.Distill.Runtime (newDistillRuntime, runExtraction)
import Shikumi.Schema.Types (field)
import System.Environment (getArgs)

main :: IO ()
main = do
  args <- getArgs
  path <- case args of
    [path] -> pure path
    _ -> ioError (userError "usage: ai-interactive-smoke.hs AI_CONFIG_FILE")
  ai <- loadAIRuntime True (Just path)
  result <-
    runExtraction
      (newDistillRuntime ai Nothing)
      ( ExtractInput
          (field "Synthetic acceptance fixture")
          (field "kioku:test")
          (field "The user explicitly prefers concise answers. Remember this preference.")
      )
  either (ioError . userError . show) print result
