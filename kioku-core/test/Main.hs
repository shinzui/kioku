module Main where

import Kioku.DistillSpec qualified as DistillSpec
import Kioku.EmbeddingWorkerSpec qualified as EmbeddingWorkerSpec
import Kioku.RecallSpec qualified as RecallSpec
import Kioku.ReiCompatSpec qualified as ReiCompatSpec
import Kioku.SessionLineageSpec qualified as SessionLineageSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "kioku"
      [ ReiCompatSpec.tests,
        RecallSpec.tests,
        SessionLineageSpec.tests,
        EmbeddingWorkerSpec.tests,
        DistillSpec.tests
      ]
