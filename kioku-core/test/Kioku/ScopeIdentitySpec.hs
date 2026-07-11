module Kioku.ScopeIdentitySpec (tests) where

import Data.List (nub)
import Data.Text (Text)
import Data.Text qualified as Text
import Data.Time (UTCTime)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..), mkNamespace, mkScopeKind)
import Kioku.Distill.L2 (l2SceneTimerId, sceneRowId)
import Kioku.Distill.L3 (l3PersonaTimerId, personaRowId)
import Kioku.Distill.ScopeIdentity (escapeScopeComponent, scopeIdentity, scopeSlugFromColumns)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Scope identity"
    [ testCase "two scopes that used to collide now derive different everything" testCollision,
      testCase "well-formed scopes keep their exact legacy ids" testLegacyStability,
      testCase "escaping is injective on adversarial components" testEscapeInjective,
      testCase "mirror slugs separate scopes the sanitiser cannot" testSlugCollision,
      testCase "namespace and kind reject the reserved characters" testValidators
    ]

-- | The canonical collision. Both of these used to render @a/b/c@, so they shared one scene
-- row, one persona row, one timer id and one mirror file — and the upserts do not update the
-- scope columns on conflict, so the second scope's content landed on the first scope's row.
collidingGlobal, collidingEntity :: MemoryScope
collidingGlobal = ScopeGlobal (Namespace "a/b/c")
collidingEntity = ScopeEntity (Namespace "a") (ScopeKind "b") "c"

testCollision :: Assertion
testCollision = do
  scopeIdentity collidingGlobal @?= "a%2Fb%2Fc"
  scopeIdentity collidingEntity @?= "a/b/c"

  assertAllDistinct "scene row id" [sceneRowId collidingGlobal, sceneRowId collidingEntity]
  assertAllDistinct "persona row id" [personaRowId collidingGlobal, personaRowId collidingEntity]
  assertAllDistinct
    "scene timer id"
    [show (l2SceneTimerId collidingGlobal "src"), show (l2SceneTimerId collidingEntity "src")]
  assertAllDistinct
    "persona timer id"
    [show (l3PersonaTimerId collidingGlobal fireAt), show (l3PersonaTimerId collidingEntity fireAt)]
  assertAllDistinct
    "mirror slug"
    [ scopeSlugFromColumns "a/b/c" Nothing Nothing,
      scopeSlugFromColumns "a" (Just "b") (Just "c")
    ]
  where
    fireAt :: UTCTime
    fireAt = read "2026-07-11 00:00:00 UTC"

-- | Every scope observed in the hosts and the docs contains none of @%@, @/@, @:@, and so
-- must encode to itself. This is what lets the id-recompute migration touch almost nothing:
-- if these bytes changed, every existing scene and persona row would be orphaned.
testLegacyStability :: Assertion
testLegacyStability = do
  sceneRowId (ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_abc")
    @?= "kioku_scene:rei/intention/intention_abc:default"
  personaRowId (ScopeEntity (Namespace "mori") (ScopeKind "repo") "web")
    @?= "kioku_persona:mori/repo/web"
  personaRowId (ScopeGlobal (Namespace "shikigami"))
    @?= "kioku_persona:shikigami"

-- | Refs are host free text and legitimately contain @/@ (repo-style refs such as
-- @shinzui/kikan@), so the encoding has to stay injective rather than reject them.
testEscapeInjective :: Assertion
testEscapeInjective = do
  escapeScopeComponent "a/b" @?= "a%2Fb"
  escapeScopeComponent "a%2Fb" @?= "a%252Fb"
  escapeScopeComponent "a:b" @?= "a%3Ab"
  escapeScopeComponent "plain-ref_123" @?= "plain-ref_123"
  assertAllDistinct
    "escaped adversarial components"
    (escapeScopeComponent <$> ["a/b", "a%2Fb", "a:b", "a%3Ab", "a%25b"])

-- | The readable half of a slug cannot be collision-free: the sanitiser maps every unsafe
-- character to @-@, so these two scopes both render @a-b@. The hash suffix is what separates
-- them.
testSlugCollision :: Assertion
testSlugCollision = do
  let dashedNamespace = scopeSlugFromColumns "a-b" Nothing Nothing
      splitScope = scopeSlugFromColumns "a" (Just "b") Nothing
      global = scopeSlugFromColumns "a/b/c" Nothing Nothing
      entity = scopeSlugFromColumns "a" (Just "b") (Just "c")
  assertAllDistinct "slugs whose readable prefixes both sanitise to a-b" [dashedNamespace, splitScope]
  assertAllDistinct "slugs for the scopes that used to collide" [global, entity]
  assertBool
    ("the slug keeps a human-readable prefix, got " <> show entity)
    ("a-b-c-" `Text.isPrefixOf` entity)

testValidators :: Assertion
testValidators = do
  mkNamespace "rei" @?= Right (Namespace "rei")
  mkScopeKind "intention" @?= Right (ScopeKind "intention")
  assertLeft "an empty namespace" (mkNamespace "")
  assertLeft "a namespace with a slash" (mkNamespace "a/b")
  assertLeft "a namespace with a percent" (mkNamespace "a%b")
  assertLeft "a kind with a colon" (mkScopeKind "a:b")

assertLeft :: (Show a) => String -> Either Text a -> Assertion
assertLeft label = \case
  Left _ -> pure ()
  Right value -> assertBool (label <> " should have been rejected, got " <> show value) False

assertAllDistinct :: (Eq a, Show a) => String -> [a] -> Assertion
assertAllDistinct label values =
  assertBool
    (label <> ": expected all distinct, got " <> show values)
    (length (nub values) == length values)
