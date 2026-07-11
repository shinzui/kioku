module Main where

import Kioku.AwaitingSpec qualified as AwaitingSpec
import Kioku.DistillSpec qualified as DistillSpec
import Kioku.EmbeddingWorkerSpec qualified as EmbeddingWorkerSpec
import Kioku.IdempotencySpec qualified as IdempotencySpec
import Kioku.ReadModelReconcileSpec qualified as ReadModelReconcileSpec
import Kioku.RecallSpec qualified as RecallSpec
import Kioku.RecallSqlSpec qualified as RecallSqlSpec
import Kioku.ReiCompatSpec qualified as ReiCompatSpec
import Kioku.SchemaSpec qualified as SchemaSpec
import Kioku.ScopeIdentitySpec qualified as ScopeIdentitySpec
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
        ReadModelReconcileSpec.tests,
        RecallSpec.tests,
        RecallSqlSpec.tests,
        SchemaSpec.tests,
        ScopeIdentitySpec.tests,
        SessionInvariantsSpec.tests,
        SessionLineageSpec.tests,
        EmbeddingWorkerSpec.tests,
        TimerWorkerSpec.tests,
        DistillSpec.tests
      ]
