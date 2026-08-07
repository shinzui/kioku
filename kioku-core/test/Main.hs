module Main where

import Kioku.AwaitingSpec qualified as AwaitingSpec
import Kioku.CodecCompatSpec qualified as CodecCompatSpec
import Kioku.DistillSpec qualified as DistillSpec
import Kioku.EmbeddingWorkerSpec qualified as EmbeddingWorkerSpec
import Kioku.IdempotencySpec qualified as IdempotencySpec
import Kioku.MemorySpaceSpec qualified as MemorySpaceSpec
import Kioku.PortfolioAccessSpec qualified as PortfolioAccessSpec
import Kioku.ReadModelReconcileSpec qualified as ReadModelReconcileSpec
import Kioku.RecallCompatSpec qualified as RecallCompatSpec
import Kioku.RecallSpec qualified as RecallSpec
import Kioku.RecallSqlSpec qualified as RecallSqlSpec
import Kioku.ReiCompatSpec qualified as ReiCompatSpec
import Kioku.SchemaSpec qualified as SchemaSpec
import Kioku.ScopeIdentitySpec qualified as ScopeIdentitySpec
import Kioku.SessionInvariantsSpec qualified as SessionInvariantsSpec
import Kioku.SessionLineageSpec qualified as SessionLineageSpec
import Kioku.SpaceIsolationSpec qualified as SpaceIsolationSpec
import Kioku.TimerWorkerSpec qualified as TimerWorkerSpec
import Kioku.WorkspaceSpec qualified as WorkspaceSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "kioku"
      [ AwaitingSpec.tests,
        CodecCompatSpec.tests,
        ReiCompatSpec.tests,
        IdempotencySpec.tests,
        MemorySpaceSpec.tests,
        PortfolioAccessSpec.tests,
        ReadModelReconcileSpec.tests,
        RecallSpec.tests,
        RecallCompatSpec.tests,
        RecallSqlSpec.tests,
        SchemaSpec.tests,
        ScopeIdentitySpec.tests,
        SessionInvariantsSpec.tests,
        SessionLineageSpec.tests,
        SpaceIsolationSpec.tests,
        WorkspaceSpec.tests,
        EmbeddingWorkerSpec.tests,
        TimerWorkerSpec.tests,
        DistillSpec.tests
      ]
