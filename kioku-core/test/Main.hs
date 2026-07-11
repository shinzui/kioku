module Main where

import Kioku.AwaitingSpec qualified as AwaitingSpec
import Kioku.DistillSpec qualified as DistillSpec
import Kioku.EmbeddingWorkerSpec qualified as EmbeddingWorkerSpec
import Kioku.IdempotencySpec qualified as IdempotencySpec
import Kioku.RecallSpec qualified as RecallSpec
import Kioku.ReiCompatSpec qualified as ReiCompatSpec
import Kioku.SessionInvariantsSpec qualified as SessionInvariantsSpec
import Kioku.SessionLineageSpec qualified as SessionLineageSpec
import Kioku.TimerWorkerSpec qualified as TimerWorkerSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "kioku"
      [ AwaitingSpec.tests,
        ReiCompatSpec.tests,
        IdempotencySpec.tests,
        RecallSpec.tests,
        SessionInvariantsSpec.tests,
        SessionLineageSpec.tests,
        EmbeddingWorkerSpec.tests,
        TimerWorkerSpec.tests,
        DistillSpec.tests
      ]
