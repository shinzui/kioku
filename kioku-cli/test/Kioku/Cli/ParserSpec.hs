-- | Pure tests for the CLI's parsing boundary: no database, no network, no environment.
--
-- optparse-applicative parsers are ordinary values, so 'execParserPure' exercises exactly what
-- an operator's argv hits — including the failure text they will read.
module Kioku.Cli.ParserSpec (tests) where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Cli.Commands.Distill (DistillOptions (..), distillOptionsParser)
import Kioku.Cli.Scope (parseScope)
import Kioku.Id (genMemoryId, genSessionId, idText)
import Options.Applicative
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Kioku.Cli parsers"
    [ sessionIdTests,
      scopeTests
    ]

-- | Run a parser against an argument list, rendering a failure the way the real CLI would.
parseWith :: Parser a -> [String] -> Either String a
parseWith p args =
  case execParserPure defaultPrefs (info (p <**> helper) mempty) args of
    Success a -> Right a
    Failure failure -> Left (fst (renderFailure failure "kioku"))
    CompletionInvoked _ -> Left "unexpected completion"

sessionIdTests :: TestTree
sessionIdTests =
  testGroup
    "distill session id parsing is strict"
    [ testCase "a kioku_session id is accepted" do
        sid <- genSessionId
        case parseWith distillOptionsParser ["session", Text.unpack (idText sid)] of
          Left err -> assertBool ("expected success, got: " <> err) False
          Right opts -> opts.sessionId @?= sid,
      testCase "a kioku_memory id is rejected, naming both prefixes" do
        mid <- genMemoryId
        case parseWith distillOptionsParser ["session", Text.unpack (idText mid)] of
          Right _ ->
            assertBool "expected a memory id to be rejected where a session id is expected" False
          Left err -> do
            assertBool ("error should name the expected prefix: " <> err) ("kioku_session" `isInfixOf` err)
            assertBool ("error should name the received prefix: " <> err) ("kioku_memory" `isInfixOf` err),
      testCase "a bare uuid with no prefix is rejected" do
        case parseWith distillOptionsParser ["session", "01h455vb4pex5vsknk084sn02q"] of
          Right _ -> assertBool "expected a prefixless id to be rejected" False
          Left err -> assertBool ("error should name the expected prefix: " <> err) ("kioku_session" `isInfixOf` err)
    ]

-- | The ref is everything after the second colon, colons included; the namespace and kind are
-- not. Splitting on every colon used to make a URL or @host:port@ ref unreachable.
scopeTests :: TestTree
scopeTests =
  testGroup
    "scope grammar splits on the first two colons only"
    [ testCase "a bare namespace is the global scope" do
        parseScope "mori" @?= Right (ScopeGlobal (Namespace "mori")),
      testCase "a plain entity scope" do
        parseScope "rei:intention:intention_demo"
          @?= Right (ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_demo"),
      testCase "a ref may contain slashes" do
        parseScope "mori:repo:github.com/shinzui/kioku"
          @?= Right (ScopeEntity (Namespace "mori") (ScopeKind "repo") "github.com/shinzui/kioku"),
      testCase "a host:port ref keeps its colon" do
        parseScope "ops:host:db.internal:5432"
          @?= Right (ScopeEntity (Namespace "ops") (ScopeKind "host") "db.internal:5432"),
      testCase "a URL ref keeps every colon" do
        parseScope "rei:url:https://example.com:8080/x"
          @?= Right (ScopeEntity (Namespace "rei") (ScopeKind "url") "https://example.com:8080/x"),
      testCase "one colon is not an entity scope" do
        assertLeft "a:b" (parseScope "a:b"),
      testCase "an empty ref is rejected" do
        assertLeft "a:b:" (parseScope "a:b:"),
      testCase "an empty namespace is rejected" do
        assertLeft ":b:c" (parseScope ":b:c"),
      testCase "an empty kind is rejected" do
        assertLeft "a::c" (parseScope "a::c"),
      testCase "the empty string is rejected" do
        assertLeft "" (parseScope ""),
      -- The identity encoding gives these characters meaning; EP-5 (docs/plans/13) rejects
      -- them at the constructor, and the CLI must not route around that.
      testCase "a slash in the namespace is still rejected" do
        assertLeft "a/b:kind:ref" (parseScope "a/b:kind:ref")
    ]
  where
    assertLeft label = \case
      Left _ -> pure ()
      Right scope -> assertBool (label <> " should not parse, got: " <> show scope) False
