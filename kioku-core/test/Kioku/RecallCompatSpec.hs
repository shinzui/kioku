-- Every test here is /about/ the deprecated entry point, so the deprecation is suppressed for
-- this module and nowhere else. A caller that has not migrated must still get the warning, and a
-- future deprecated use anywhere outside this file must still be visible.
{-# OPTIONS_GHC -Wno-deprecations #-}

-- | The compatibility promise, executed against a real database.
--
-- 'Kioku.Recall.legacyRecall' exists so that a caller holding a pre-'RecallTarget'
-- 'RecallRequest' keeps the rows it has today while the compiler tells it to migrate. That
-- promise is only worth anything if it is measured, because the mistake it guards against —
-- mapping a global scope to the exact global bucket instead of to the whole namespace — compiles,
-- runs, and returns a plausible subset of the right answer with no error at all.
--
-- So each case here runs the legacy request and the explicit request side by side over the same
-- seeded rows and asserts they return the same memory ids. Everything runs keyword-only under
-- 'VectorExtensionUnavailable', so no embedding endpoint is involved and the embedding model is
-- never forced.
module Kioku.RecallCompatSpec (tests) where

import Data.List (sort)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Text.Encoding (encodeUtf8)
import Effectful (Eff, IOE, (:>))
import Hasql.Transaction qualified as Tx
import Kioku.Api.Access (memorySpaceIdText)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.App (AppEffects, runAppIO, withNoopAppEnv)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Recall
  ( RecallError (..),
    RecallHit (..),
    RecallLimit,
    RecallQuery (..),
    RecallRequest (..),
    RecallStrategy (..),
    RecallTarget (..),
    legacyRecall,
    mkRecallLimit,
    recall,
  )
import Kioku.Recall.Capability (VectorCapability (..))
import Kioku.SpaceFixtures (otherSpace, testContext, testSpace)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Transaction (runTransaction)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertEqual, assertFailure, testCase)

-- Each 'withRecallFixture' spins an ephemeral PostgreSQL cluster and applies every migration, so
-- the scenarios are grouped into two of them rather than one per assertion.
tests :: TestTree
tests =
  testGroup
    "Recall.Compat"
    [ testCase "a legacy scope returns exactly what its explicit target returns" testLegacyMatchesExplicit,
      testCase "the legacy request's edges are preserved" testLegacyEdges
    ]

-- | The case the whole compatibility layer exists for.
--
-- A legacy @ScopeGlobal ns@ returns every active row in @ns@, entity-scoped rows included, and an
-- entity scope returns only itself. If 'Kioku.Api.Recall.legacyRecallTarget' were ever
-- "corrected" to send a global scope to the exact global bucket, the first assertion returns
-- @["m_global"]@ instead of both ids — a silent narrowing, which is exactly the kind of failure
-- that reaches a downstream months later as "recall got worse".
testLegacyMatchesExplicit :: IO ()
testLegacyMatchesExplicit =
  withRecallFixture \runEff -> do
    result <- runEff do
      seedCorpus
      legacyWide <- runLegacy (legacyRequest ns1Global)
      explicitWide <- runExplicit (explicitRequest (NamespaceWide ns1))
      legacyExact <- runLegacy (legacyRequest ns1Entity)
      explicitExact <- runExplicit (explicitRequest (ExactScope ns1Entity))
      pure (legacyWide, explicitWide, legacyExact, explicitExact)
    case result of
      Left err -> assertFailure ("store error: " <> show err)
      Right (legacyWide, explicitWide, legacyExact, explicitExact) -> do
        assertEqual
          "a legacy global scope returns the global bucket and the entity scope alike"
          (Right ["m_entity", "m_global"])
          (hitIds legacyWide)
        assertEqual
          "and returns exactly what the explicit namespace-wide target returns"
          (hitIds explicitWide)
          (hitIds legacyWide)
        assertEqual
          "a legacy entity scope returns only that scope"
          (Right ["m_entity"])
          (hitIds legacyExact)
        assertEqual
          "and returns exactly what the explicit exact target returns"
          (hitIds explicitExact)
          (hitIds legacyExact)

-- | The three edges of the legacy request that 'RecallQuery' does not have.
--
-- __The space.__ The legacy request is the only recall input carrying a memory space of its own,
-- so it is the only one that can disagree with the context that authorized it. It is refused
-- rather than retargeted, for the same reason the deprecated write wrappers in "Kioku.Memory"
-- refuse: quietly rewriting the space would make the compatibility layer a way to reach another
-- space's data.
--
-- __A zero limit.__ @take (max 0 n)@ returned nothing, so this returns nothing, rather than
-- becoming a validation error an unmigrated caller meets as a crash.
--
-- __An oversized limit.__ 'Kioku.Api.Recall.mkRecallLimit' refuses anything above
-- 'Kioku.Api.Recall.maxRecallLimit', but a legacy caller passing 5000 was never getting 5000 rows
-- — each channel contributes at most 50 candidates — so clamping is invisible where refusing
-- would be a new failure.
testLegacyEdges :: IO ()
testLegacyEdges =
  withRecallFixture \runEff -> do
    result <- runEff do
      seedCorpus
      mismatched <- runLegacy (legacyRequest ns1Global) {memorySpaceId = otherSpace}
      zeroLimit <- runLegacy (legacyRequestLimited ns1Global 0)
      oversize <- runLegacy (legacyRequestLimited ns1Global 5000)
      pure (mismatched, zeroLimit, oversize)
    case result of
      Left err -> assertFailure ("store error: " <> show err)
      Right (mismatched, zeroLimit, oversize) -> do
        case mismatched of
          Left (RecallSpaceMismatch requested authorized) -> do
            assertEqual "names the space that was asked for" otherSpace requested
            assertEqual "names the space the context authorizes" testSpace authorized
          other -> assertFailure ("expected a space mismatch, got " <> show (hitIds other))
        assertEqual "a zero limit returns no hits" (Right []) (hitIds zeroLimit)
        assertEqual
          "an oversized limit still returns every match"
          (Right ["m_entity", "m_global"])
          (hitIds oversize)

runLegacy :: (Store :> es, IOE :> es) => RecallRequest -> Eff es (Either RecallError [RecallHit])
runLegacy = legacyRecall undefinedModel VectorExtensionUnavailable testContext

runExplicit :: (Store :> es, IOE :> es) => RecallQuery -> Eff es (Either RecallError [RecallHit])
runExplicit = recall undefinedModel VectorExtensionUnavailable testContext

-- * Fixture

ns1 :: Namespace
ns1 = Namespace "ns1"

ns1Global, ns1Entity, ns2Global :: MemoryScope
ns1Global = ScopeGlobal ns1
ns1Entity = ScopeEntity ns1 (ScopeKind "repo") "web"
ns2Global = ScopeGlobal (Namespace "ns2")

-- | The keyword channel never embeds, and 'VectorExtensionUnavailable' makes that a guarantee
-- rather than a hope: the execution plan is keyword-only, so this is never forced.
undefinedModel :: a
undefinedModel = error "the keyword channel must not embed"

legacyRequest :: MemoryScope -> RecallRequest
legacyRequest scope = legacyRequestLimited scope 10

-- | Built rather than record-updated: 'RecallRequest' and 'RecallQuery' both have a @maxResults@
-- field, and a record update over an ambiguous field is a warning GHC intends to stop supporting.
legacyRequestLimited :: MemoryScope -> Int -> RecallRequest
legacyRequestLimited scope maxResults =
  RecallRequest
    { memorySpaceId = testSpace,
      scope,
      query = searchText,
      strategy = Keyword,
      maxResults
    }

explicitRequest :: RecallTarget -> RecallQuery
explicitRequest target =
  RecallQuery {target, query = searchText, strategy = Keyword, maxResults = limitOf 10}

searchText :: Text
searchText = "deployment pipeline"

limitOf :: Int -> RecallLimit
limitOf = either (error . Text.unpack) id . mkRecallLimit

hitIds :: Either RecallError [RecallHit] -> Either RecallError [Text]
hitIds = fmap (sort . fmap (\hit -> hit.memory.memoryId))

-- | One row in the global bucket, one under an entity scope in the same namespace, and one in a
-- different namespace that no target may ever return.
seedCorpus :: (Store :> es) => Eff es ()
seedCorpus =
  seedMemories
    [ ("m_global", ns1Global),
      ("m_entity", ns1Entity),
      ("m_other_ns", ns2Global)
    ]

seedMemories :: (Store :> es) => [(Text, MemoryScope)] -> Eff es ()
seedMemories rows =
  runTransaction . Tx.sql . encodeUtf8 $
    "INSERT INTO kioku.memories (memory_space_id, memory_id, agent_id, namespace, scope_kind, scope_ref, memory_type, content, status, created_at, updated_at) VALUES "
      <> Text.intercalate ", " (row <$> rows)
  where
    row (memoryId, scope) =
      "('"
        <> memorySpaceIdText testSpace
        <> "', '"
        <> memoryId
        <> "', 'agent', '"
        <> namespaceOf scope
        <> "', "
        <> sqlText (kindOf scope)
        <> ", "
        <> sqlText (refOf scope)
        <> ", 'fact', 'the deployment pipeline runs on nix flakes', 'active', now(), now())"

    namespaceOf = \case
      ScopeGlobal (Namespace ns) -> ns
      ScopeEntity (Namespace ns) _ _ -> ns

    kindOf = \case
      ScopeGlobal _ -> Nothing
      ScopeEntity _ (ScopeKind kind) _ -> Just kind

    refOf = \case
      ScopeGlobal _ -> Nothing
      ScopeEntity _ _ ref -> Just ref

    sqlText Nothing = "NULL"
    sqlText (Just value) = "'" <> value <> "'"

withRecallFixture :: ((forall a. Eff AppEffects a -> IO (Either StoreError a)) -> IO ()) -> IO ()
withRecallFixture use =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env ->
      use (runAppIO env)
