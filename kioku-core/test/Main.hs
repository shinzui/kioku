module Main where

import Kioku.EmbeddingWorkerSpec qualified as EmbeddingWorkerSpec
import Kioku.RecallSpec qualified as RecallSpec
import Kioku.ReiCompatSpec qualified as ReiCompatSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "kioku"
      [ ReiCompatSpec.tests,
        RecallSpec.tests,
        EmbeddingWorkerSpec.tests
      ]
