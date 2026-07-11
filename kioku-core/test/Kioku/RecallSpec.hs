module Kioku.RecallSpec
  ( tests,
  )
where

import Data.Set qualified as Set
import Data.Text (Text)
import Data.Time (UTCTime, addUTCTime)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..))
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.Recall
import Kioku.Recall.Capability (CapabilityProbe (..), VectorCapability (..), classifyProbe)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Recall scoring"
    [ testCase "RRF fusion favors a memory present in both lists" testRrfFusion,
      testCase "signal blending maps recency priority and confidence" testSignalBlending,
      testCase "character budgets truncate and stop before total cap" testBudgets,
      testCase "execution plan fails open to keyword when vectors are unavailable" testFailOpenPlan,
      testCase "capability classification names the reason vectors are unusable" testCapabilityClassification
    ]

testRrfFusion :: Assertion
testRrfFusion = do
  let now = read "2026-06-24 00:00:00 UTC"
      a = row "a" now "alpha"
      b = row "b" now "bravo"
      c = row "c" now "charlie"
      hits = fuseRecallCandidates now [a, b] [b, c]
  (hitId <$> hits) @?= ["b", "a", "c"]
  assertApprox "rank 1 RRF term" (1 / 61) (rrfTerm 1)

testSignalBlending :: Assertion
testSignalBlending = do
  let now = read "2026-06-24 00:00:00 UTC"
      thirtyDaysAgo = addUTCTime (negate (30 * 86400)) now
      memoryRow = (row "m" thirtyDaysAgo "content") {priority = 0, confidence = "high"}
      expected = rrfTerm 1 + rrfTerm 2 + (0.10 * 0.5) + (0.15 * 1.0) + (0.05 * 1.0)
  assertApprox "recency halves at 30 days" 0.5 (recencyDecay now thirtyDaysAgo)
  priorityWeight 0 @?= 1.0
  confidenceWeight "medium" @?= 0.6
  assertApprox "blended score" expected (blendScore now memoryRow (Just 1) (Just 2))

testBudgets :: Assertion
testBudgets = do
  let now = read "2026-06-24 00:00:00 UTC"
      hit1 = RecallHit {memory = row "a" now "abcdefghij", score = 2, ftsRank = Just 1, vecRank = Nothing}
      hit2 = RecallHit {memory = row "b" now "klmnopqrst", score = 1, ftsRank = Just 2, vecRank = Nothing}
      budgeted = applyCharacterBudgets 5 8 [hit1, hit2]
  case budgeted of
    [onlyHit] -> do
      hitId onlyHit @?= "a"
      onlyHit.memory.content @?= "ab..."
    other -> fail ("Expected one budgeted hit, got " <> show (hitId <$> other))

testFailOpenPlan :: Assertion
testFailOpenPlan = do
  planRecallExecution VectorAvailable Keyword
    @?= RecallExecutionPlan {runFts = True, runVector = False, needsQueryEmbedding = False}
  planRecallExecution VectorAvailable Embedding
    @?= RecallExecutionPlan {runFts = False, runVector = True, needsQueryEmbedding = True}
  planRecallExecution VectorAvailable Hybrid
    @?= RecallExecutionPlan {runFts = True, runVector = True, needsQueryEmbedding = True}
  planRecallExecution VectorExtensionUnavailable Hybrid
    @?= RecallExecutionPlan {runFts = True, runVector = False, needsQueryEmbedding = False}
  planRecallExecution (VectorColumnsUnavailable ["embedding"]) Embedding
    @?= RecallExecutionPlan {runFts = True, runVector = False, needsQueryEmbedding = False}
  -- A mismatch is a configuration error, not a missing feature, but recall's response is the
  -- same: the vector channel cannot work, so degrade rather than fail on every query.
  planRecallExecution (VectorDimensionMismatch 512 1536) Hybrid
    @?= RecallExecutionPlan {runFts = True, runVector = False, needsQueryEmbedding = False}

testCapabilityClassification :: Assertion
testCapabilityClassification = do
  classifyProbe 1536 healthyProbe @?= VectorAvailable
  -- The type must be nameable on *this* connection's search_path, not merely installed
  -- somewhere in the database: recall casts with a bare `$1::vector`.
  classifyProbe 1536 healthyProbe {hasVectorType = False} @?= VectorExtensionUnavailable
  classifyProbe 1536 healthyProbe {hasEmbedding = False, embeddingTypmod = Nothing}
    @?= VectorColumnsUnavailable ["embedding"]
  classifyProbe 512 healthyProbe @?= VectorDimensionMismatch 512 1536
  -- A column declared without a width constrains nothing, so there is nothing to disagree
  -- with; -1 is what pgvector reports for `vector` with no dimension.
  classifyProbe 512 healthyProbe {embeddingTypmod = Just (-1)} @?= VectorAvailable
  where
    healthyProbe =
      CapabilityProbe
        { hasVectorType = True,
          hasEmbedding = True,
          hasEmbeddingModel = True,
          hasDimensions = True,
          hasContentHash = True,
          embeddingTypmod = Just 1536
        }

row :: Text -> UTCTime -> Text -> MemoryRecord
row memoryId createdAt content =
  MemoryRecord
    { memoryId,
      agentId = "agent",
      sessionId = Nothing,
      scope = ScopeGlobal (Namespace "rei"),
      memoryType = "pattern",
      content,
      priority = 100,
      confidence = "medium",
      tags = Set.empty,
      status = "active",
      createdAt
    }

hitId :: RecallHit -> Text
hitId hit = hit.memory.memoryId

assertApprox :: String -> Double -> Double -> Assertion
assertApprox label expected actual =
  assertBool
    (label <> ": expected " <> show expected <> ", got " <> show actual)
    (abs (expected - actual) < 0.0001)
