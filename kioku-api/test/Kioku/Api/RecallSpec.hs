-- 'rejects' names the type it is decoding at each call site rather than inferring it from an
-- expected value, because the whole point is that there /is/ no value.
{-# LANGUAGE AllowAmbiguousTypes #-}

-- | Pure tests for "Kioku.Api.Recall": the three things a recall call can target, the bytes
-- they put on the wire, and the conversion that keeps a pre-'RecallTarget' caller's results
-- unchanged.
--
-- Nothing here touches a database. What is being pinned is a vocabulary — specifically that the
-- exact global bucket, the exact entity scope, and the whole namespace are three distinguishable
-- values in Haskell and three distinguishable objects in JSON, which is the property whose
-- absence made @ScopeGlobal@ mean two different things depending on which function received it.
module Kioku.Api.RecallSpec (tests) where

import Data.Aeson (FromJSON, ToJSON, Value (..), decode, encode)
import Data.Aeson.KeyMap qualified as KeyMap
import Data.ByteString.Lazy (ByteString)
import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.Api.Recall
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Kioku.Api.Recall"
    [ targetDistinctionTests,
      legacyConversionTests,
      targetWireTests,
      targetDecodingTests,
      strategyTests,
      limitTests,
      queryTests
    ]

-- | The whole reason this type exists: three meanings, three values.
targetDistinctionTests :: TestTree
targetDistinctionTests =
  testGroup
    "the three targets are three values"
    [ testCase "the exact global bucket is not the whole namespace" do
        assertBool
          "distinct"
          (ExactScope (ScopeGlobal mori) /= NamespaceWide mori),
      testCase "the exact global bucket is not an exact entity" do
        assertBool
          "distinct"
          (ExactScope (ScopeGlobal mori) /= ExactScope moriRepo),
      testCase "every target names exactly one namespace" do
        fmap
          recallTargetNamespace
          [ExactScope (ScopeGlobal mori), ExactScope moriRepo, NamespaceWide mori]
          @?= [mori, mori, mori],
      testCase "only an exact target has a scope" do
        recallTargetExactScope (ExactScope moriRepo) @?= Just moriRepo
        recallTargetExactScope (NamespaceWide mori) @?= Nothing,
      testCase "widening is a question a caller can ask" do
        -- An audit line, a CLI confirmation, or a policy check wants this predicate, and none of
        -- them should have to pattern-match a scope to compute it.
        fmap
          recallTargetIsNamespaceWide
          [ExactScope (ScopeGlobal mori), ExactScope moriRepo, NamespaceWide mori]
          @?= [False, False, True]
    ]

-- | The compatibility mapping. It preserves what a caller gets today, which means it must send
-- the global scope to the /wide/ target — the mapping that returns more rows, not fewer.
legacyConversionTests :: TestTree
legacyConversionTests =
  testGroup
    "legacyRecallTarget"
    [ testCase "a global scope stays namespace-wide" do
        legacyRecallTarget (ScopeGlobal mori) @?= NamespaceWide mori,
      testCase "an entity scope becomes an exact target" do
        legacyRecallTarget moriRepo @?= ExactScope moriRepo,
      testCase "it never silently narrows a caller to the global bucket" do
        -- The load-bearing case. The other mapping compiles, runs, and returns a small fraction
        -- of the rows the caller had yesterday, with no error and no warning.
        assertBool
          "not narrowed"
          (legacyRecallTarget (ScopeGlobal mori) /= ExactScope (ScopeGlobal mori)),
      testCase "the exact global bucket is reachable only by asking for it" do
        assertBool
          "no scope converts to an exact global target"
          ( ExactScope (ScopeGlobal mori)
              `notElem` fmap legacyRecallTarget [ScopeGlobal mori, moriRepo]
          )
    ]

-- | The wire contract. These three shapes end up in HTTP request bodies and SDK unions, so
-- changing one is a breaking change and should have to be done on purpose, with this test in the
-- diff.
targetWireTests :: TestTree
targetWireTests =
  testGroup
    "targets on the wire"
    [ encodesAs
        "exact global"
        (ExactScope (ScopeGlobal mori))
        "{\"kind\":\"exact_global\",\"namespace\":\"mori\"}",
      encodesAs
        "exact entity"
        (ExactScope moriRepo)
        "{\"kind\":\"exact_entity\",\"namespace\":\"mori\",\"scope_kind\":\"repo\",\"scope_ref\":\"shinzui/kikan\"}",
      encodesAs
        "namespace wide"
        (NamespaceWide mori)
        "{\"kind\":\"namespace_wide\",\"namespace\":\"mori\"}",
      testCase "the discriminator is what separates exact-global from namespace-wide" do
        -- Both carry a namespace and nothing else, so if the tag were dropped or defaulted the
        -- two would be the same object — which is the SQL-level defect this vocabulary replaces,
        -- moved onto the wire.
        assertBool
          "distinct encodings"
          (encode (ExactScope (ScopeGlobal mori)) /= encode (NamespaceWide mori)),
      testGroup
        "round-trips"
        [ roundTrip "exact global" (ExactScope (ScopeGlobal mori)),
          roundTrip "exact entity" (ExactScope moriRepo),
          roundTrip "namespace wide" (NamespaceWide mori),
          roundTrip "a ref containing a slash" (ExactScope moriRepo),
          roundTrip
            "a ref containing a colon"
            (ExactScope (ScopeEntity mori (ScopeKind "agent") "rei:coach"))
        ]
    ]

-- | Decoding is a contract, not a guess.
targetDecodingTests :: TestTree
targetDecodingTests =
  testGroup
    "decoding refuses what it cannot mean"
    [ testCase "an unknown kind is an error, not a default" do
        rejects @RecallTarget "{\"kind\":\"everything\",\"namespace\":\"mori\"}",
      testCase "a missing kind is an error, not namespace-wide" do
        rejects @RecallTarget "{\"namespace\":\"mori\"}",
      testCase "an exact global target may not carry a scope kind" do
        -- Accepting and ignoring it would let a caller believe they had asked for an entity.
        rejects @RecallTarget
          "{\"kind\":\"exact_global\",\"namespace\":\"mori\",\"scope_kind\":\"repo\"}",
      testCase "a namespace-wide target may not carry scope fields" do
        rejects @RecallTarget
          "{\"kind\":\"namespace_wide\",\"namespace\":\"mori\",\"scope_kind\":\"repo\",\"scope_ref\":\"x\"}",
      testCase "an exact entity target needs both halves of the scope" do
        rejects @RecallTarget "{\"kind\":\"exact_entity\",\"namespace\":\"mori\",\"scope_kind\":\"repo\"}"
        rejects @RecallTarget "{\"kind\":\"exact_entity\",\"namespace\":\"mori\",\"scope_ref\":\"x\"}"
        rejects @RecallTarget "{\"kind\":\"exact_entity\",\"namespace\":\"mori\"}",
      testCase "a namespace is held to the same rule as a constructed one" do
        -- 'mkNamespace' rejects the characters the scope-identity encoding gives meaning to. A
        -- decoder that skipped that check would validate only the path nobody attacks.
        rejects @RecallTarget "{\"kind\":\"namespace_wide\",\"namespace\":\"mori/other\"}"
        rejects @RecallTarget "{\"kind\":\"namespace_wide\",\"namespace\":\"\"}",
      testCase "a scope kind is held to the same rule as a constructed one" do
        rejects @RecallTarget
          "{\"kind\":\"exact_entity\",\"namespace\":\"mori\",\"scope_kind\":\"re:po\",\"scope_ref\":\"x\"}",
      testCase "a scope ref is deliberately free text" do
        -- Refs are host-controlled and legitimately contain '/' and ':' — repo-style refs and
        -- arbitrary agent names. Validating them here would reject data that already exists.
        decode @RecallTarget
          "{\"kind\":\"exact_entity\",\"namespace\":\"mori\",\"scope_kind\":\"repo\",\"scope_ref\":\"shinzui/kikan\"}"
          @?= Just (ExactScope moriRepo)
    ]

strategyTests :: TestTree
strategyTests =
  testGroup
    "RecallStrategy"
    [ testCase "has the expected stable spellings" do
        fmap recallStrategyText allRecallStrategies @?= ["keyword", "embedding", "hybrid"],
      testCase "parses back from every spelling" do
        traverse (parseRecallStrategy . recallStrategyText) allRecallStrategies
          @?= Right allRecallStrategies,
      testCase "rejects an unknown spelling, naming the alternatives" do
        case parseRecallStrategy "semantic" of
          Right unexpected -> fail ("expected rejection, got " <> show unexpected)
          Left message -> do
            assertBool "names keyword" ("keyword" `Text.isInfixOf` message)
            assertBool "names hybrid" ("hybrid" `Text.isInfixOf` message),
      testCase "crosses the wire as a bare string" do
        encode Hybrid @?= "\"hybrid\"",
      testCase "decoding rejects an unknown spelling" do
        rejects @RecallStrategy "\"semantic\"",
      testGroup
        "round-trips"
        [roundTrip (show strategy) strategy | strategy <- allRecallStrategies]
    ]

limitTests :: TestTree
limitTests =
  testGroup
    "RecallLimit"
    [ testCase "rejects zero, which silently returns nothing" do
        rejected (mkRecallLimit 0),
      testCase "rejects a negative limit" do
        rejected (mkRecallLimit (-1)),
      testCase "accepts both ends of the range" do
        fmap recallLimitInt (mkRecallLimit 1) @?= Right 1
        fmap recallLimitInt (mkRecallLimit maxRecallLimit) @?= Right maxRecallLimit,
      testCase "rejects one past the maximum" do
        rejected (mkRecallLimit (maxRecallLimit + 1)),
      testCase "the maximum is the most a fused result set can hold" do
        -- Each channel contributes at most 50 candidates, so 100 distinct memories is the
        -- ceiling. A larger limit has never returned more rows; it only widened what the
        -- database was asked to plan for.
        maxRecallLimit @?= 100,
      testCase "the default is what the command line has always used" do
        recallLimitInt defaultRecallLimit @?= 8,
      testCase "crosses the wire as a bare number" do
        encode defaultRecallLimit @?= "8",
      testCase "decoding enforces the same bounds as constructing" do
        rejects @RecallLimit "0"
        rejects @RecallLimit "101"
    ]

queryTests :: TestTree
queryTests =
  testGroup
    "RecallQuery"
    [ testCase "the smart constructor validates the limit and nothing else" do
        fmap (\q -> q.target) (mkRecallQuery (NamespaceWide mori) "commit style" Hybrid 8)
          @?= Right (NamespaceWide mori)
        rejected (mkRecallQuery (NamespaceWide mori) "commit style" Hybrid 0),
      testCase "empty query text is accepted, because websearch_to_tsquery accepts it" do
        -- Today an empty or punctuation-only query returns no matches rather than an error.
        -- Rejecting it here would be a behaviour change for every caller that relies on that.
        fmap (\q -> q.query) (mkRecallQuery (NamespaceWide mori) "" Keyword 8) @?= Right "",
      encodesAs
        "a whole request"
        (expectRight (mkRecallQuery (ExactScope moriRepo) "commit style" Hybrid 8))
        "{\"target\":{\"kind\":\"exact_entity\",\"namespace\":\"mori\",\"scope_kind\":\"repo\",\
        \\"scope_ref\":\"shinzui/kikan\"},\"query\":\"commit style\",\"strategy\":\"hybrid\",\
        \\"max_results\":8}",
      roundTrip
        "a whole request round-trips"
        (expectRight (mkRecallQuery (NamespaceWide mori) "commit style" Keyword 3)),
      testCase "a request has exactly four fields, and none of them is a memory space" do
        -- The space comes from the MemoryAccessContext at execution. If it were a field here, a
        -- caller composing a request could widen a target and a tenancy in one edit.
        case decode @Value (encode (expectRight (mkRecallQuery (NamespaceWide mori) "q" Hybrid 3))) of
          Just (Object fields) ->
            sort (KeyMap.keys fields) @?= ["max_results", "query", "strategy", "target"]
          other -> fail ("expected a JSON object, got " <> show other)
    ]

mori :: Namespace
mori = Namespace "mori"

moriRepo :: MemoryScope
moriRepo = ScopeEntity mori (ScopeKind "repo") "shinzui/kikan"

-- | Compare the encoding as a decoded 'Value' rather than as bytes: aeson's object key order is
-- unspecified, and pinning it would make this test fail for a reason that is not a contract
-- change.
encodesAs :: (ToJSON a) => String -> a -> ByteString -> TestTree
encodesAs name value expected =
  testCase name (decode @Value (encode value) @?= decode @Value expected)

roundTrip :: (ToJSON a, FromJSON a, Eq a, Show a) => String -> a -> TestTree
roundTrip name value =
  testCase name (decode (encode value) @?= Just value)

rejects :: forall a. (FromJSON a, Show a) => ByteString -> IO ()
rejects raw =
  case decode @a raw of
    Nothing -> pure ()
    Just unexpected -> fail ("expected rejection of " <> show raw <> ", got " <> show unexpected)

rejected :: (Show a) => Either Text a -> IO ()
rejected = \case
  Left _ -> pure ()
  Right unexpected -> fail ("expected rejection, got " <> show unexpected)

expectRight :: Either Text a -> a
expectRight = either (error . Text.unpack) id
