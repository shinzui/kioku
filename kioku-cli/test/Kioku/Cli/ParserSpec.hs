-- | Pure tests for the CLI's parsing boundary: no database, no network, no environment.
--
-- optparse-applicative parsers are ordinary values, so 'execParserPure' exercises exactly what
-- an operator's argv hits — including the failure text they will read.
module Kioku.Cli.ParserSpec (tests) where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Kioku.Api.Access (mkMemorySpaceId)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Cli.Commands.Demo (DemoOptions (..), demoOptionsParser, demoScope)
import Kioku.Cli.Commands.DemoSession (DemoSessionOptions (..), demoSessionOptionsParser)
import Kioku.Cli.Commands.Distill (DistillOptions (..), distillOptionsParser)
import Kioku.Cli.Commands.Recall (RecallOptions (..), describeTarget, recallOptionsParser)
import Kioku.Cli.Commands.Worker (WorkerOptions (..), workerOptionsParser)
import Kioku.Cli.Options (redactConnectionString)
import Kioku.Cli.Scope (parseScope)
import Kioku.Id (genMemoryId, genSessionId, idText)
import Kioku.Memory.Embedding.Worker (EmbeddingBackfillScope (..))
import Kioku.Recall (RecallTarget (..))
import Options.Applicative
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Kioku.Cli parsers"
    [ sessionIdTests,
      scopeTests,
      recallTargetTests,
      limitTests,
      demoGuardTests,
      redactionTests,
      workerModeTests
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

-- | Recall is the only command that can be asked to widen what it searches, so each of the three
-- things it can search has exactly one spelling and none of them is a bare namespace.
--
-- @--scope mori@ used to mean /the whole mori namespace/, which is the opposite of what
-- @kioku scenes --scope mori@ means by the same text. It is now a parse error rather than a
-- silently narrower search: an operator's script would otherwise keep exiting zero while
-- returning a fraction of its rows.
recallTargetTests :: TestTree
recallTargetTests =
  testGroup
    "recall spells each target exactly once"
    [ testCase "--scope takes an entity scope" do
        target ["--scope", "mori:repo:web"]
          @?= Right (ExactScope (ScopeEntity (Namespace "mori") (ScopeKind "repo") "web")),
      testCase "--global-bucket takes a namespace and means the rows with no entity scope" do
        target ["--global-bucket", "mori"] @?= Right (ExactScope (ScopeGlobal (Namespace "mori"))),
      testCase "--namespace-wide takes a namespace and means every scope under it" do
        target ["--namespace-wide", "mori"] @?= Right (NamespaceWide (Namespace "mori")),
      -- The distinction the whole initiative exists for: two flags naming the same namespace
      -- must not produce the same target.
      testCase "the global bucket and the namespace are different targets" do
        assertBool
          "--global-bucket and --namespace-wide must not agree"
          (target ["--global-bucket", "mori"] /= target ["--namespace-wide", "mori"]),
      testCase "--scope keeps the shared colon rules" do
        target ["--scope", "ops:host:db.internal:5432"]
          @?= Right (ExactScope (ScopeEntity (Namespace "ops") (ScopeKind "host") "db.internal:5432")),
      testCase "a bare namespace is refused, naming both replacements" do
        case target ["--scope", "mori"] of
          Right parsed -> assertBool ("--scope mori should not parse, got: " <> show parsed) False
          Left err -> do
            assertBool ("error should offer --global-bucket: " <> err) ("--global-bucket mori" `isInfixOf` err)
            assertBool ("error should offer --namespace-wide: " <> err) ("--namespace-wide mori" `isInfixOf` err)
            assertBool
              ("error should say which one preserves the old behavior: " <> err)
              ("returned before" `isInfixOf` err),
      testCase "no target at all lists the three forms" do
        case parseWith recallOptionsParser ["query"] of
          Right parsed -> assertBool ("a targetless recall should not parse, got: " <> show parsed) False
          Left err -> do
            assertBool ("failure should say what is missing: " <> err) ("Missing:" `isInfixOf` err)
            mapM_
              (\flag -> assertBool ("failure should list " <> flag <> ": " <> err) (flag `isInfixOf` err))
              ["--scope", "--global-bucket", "--namespace-wide"],
      testCase "two targets is a parse error naming the second" do
        assertConflict "--namespace-wide" (target ["--scope", "a:b:c", "--namespace-wide", "mori"]),
      testCase "two targets in the other order is also a parse error" do
        assertConflict "--global-bucket" (target ["--namespace-wide", "mori", "--global-bucket", "mori"]),
      -- A scope handed to a namespace flag is someone reaching for --scope, and saying so beats
      -- reporting a reserved character.
      testCase "a scope passed to --namespace-wide points at --scope" do
        case target ["--namespace-wide", "mori:repo:web"] of
          Right parsed -> assertBool ("should not parse, got: " <> show parsed) False
          Left err -> assertBool ("error should point at --scope: " <> err) ("--scope" `isInfixOf` err),
      -- The stderr banner is the only place a run says which of the three it did.
      testCase "each target describes itself distinctly" do
        describeTarget (ExactScope (ScopeGlobal (Namespace "mori"))) @?= "the global bucket of mori"
        describeTarget (NamespaceWide (Namespace "mori")) @?= "every scope in mori"
        describeTarget (ExactScope (ScopeEntity (Namespace "mori") (ScopeKind "repo") "web"))
          @?= "scope mori:repo:web"
    ]
  where
    target extra = fmap (.target) (parseWith recallOptionsParser (["query"] <> extra))

    assertConflict rejected = \case
      Right parsed -> assertBool ("expected a conflict error, got: " <> show parsed) False
      Left err ->
        assertBool
          ("failure should name the conflicting flag " <> rejected <> ": " <> err)
          (rejected `isInfixOf` err)

-- | Out-of-range limits are a parse error, not a Postgres error (@--limit -1@ used to reach
-- SQL and come back as @LIMIT must not be negative@).
limitTests :: TestTree
limitTests =
  testGroup
    "--limit is bounded at the parser"
    [ testCase "recall rejects a negative limit, naming the range" do
        assertLimitError "between 1 and 100" (recallWith ["--limit", "-1"]),
      testCase "recall rejects zero" do
        assertLimitError "between 1 and 100" (recallWith ["--limit", "0"]),
      testCase "recall rejects one past the maximum" do
        assertLimitError "between 1 and 100" (recallWith ["--limit", "101"]),
      testCase "recall accepts both ends of the range" do
        fmap (.limit) (recallWith ["--limit", "1"]) @?= Right 1
        fmap (.limit) (recallWith ["--limit", "100"]) @?= Right 100,
      testCase "recall's default limit is unchanged" do
        fmap (.limit) (recallWith []) @?= Right 8,
      testCase "distill rejects one past its lower maximum" do
        sid <- genSessionId
        assertLimitError "between 1 and 50" (distillWith sid ["--limit", "51"]),
      testCase "distill accepts the top of its range" do
        sid <- genSessionId
        fmap (.candidateLimit) (distillWith sid ["--limit", "50"]) @?= Right 50,
      testCase "distill's default limit is unchanged" do
        sid <- genSessionId
        fmap (.candidateLimit) (distillWith sid []) @?= Right 5
    ]
  where
    recallWith extra =
      parseWith recallOptionsParser (["query", "--namespace-wide", "mori"] <> extra)

    distillWith sid extra =
      parseWith distillOptionsParser (["session", Text.unpack (idText sid)] <> extra)

    assertLimitError needle = \case
      Right _ -> assertBool ("expected a parse error mentioning " <> show needle) False
      Left err -> assertBool ("error should state the valid range: " <> err) (needle `isInfixOf` err)

-- | The demo commands append permanent events (kioku has no delete) to whatever
-- @PG_CONNECTION_STRING@ points at. Consent is a required flag, so a bare invocation dies in
-- the parser — before the environment is read and before anything is written.
demoGuardTests :: TestTree
demoGuardTests =
  testGroup
    "demo commands require --yes-write-events"
    [ testCase "bare `demo` does not parse" do
        assertMissingFlag (parseWith demoOptionsParser []),
      testCase "`demo --yes-write-events` parses" do
        parseWith demoOptionsParser ["--yes-write-events"] @?= Right DemoOptions,
      testCase "bare `demo-session` does not parse" do
        assertMissingFlag (parseWith demoSessionOptionsParser []),
      testCase "`demo-session --yes-write-events` parses" do
        parseWith demoSessionOptionsParser ["--yes-write-events"] @?= Right DemoSessionOptions,
      testCase "the demo writes into its own namespace, not rei" do
        demoScope @?= ScopeEntity (Namespace "kioku_demo") (ScopeKind "demo") "demo"
    ]
  where
    assertMissingFlag = \case
      Right _ -> assertBool "expected the demo command to refuse without --yes-write-events" False
      Left err ->
        assertBool
          ("failure should name the missing flag: " <> err)
          ("Missing: --yes-write-events" `isInfixOf` err)

-- | The preflight prints the target database. A password must not travel with it into a
-- terminal or a CI log.
redactionTests :: TestTree
redactionTests =
  testGroup
    "redactConnectionString"
    [ testCase "keyword form: the password is replaced" do
        let redacted = redactConnectionString "host=x dbname=y password=hunter2"
        assertBool "password should be redacted" ("password=REDACTED" `Text.isInfixOf` redacted)
        assertBool "the secret should not survive" (not ("hunter2" `Text.isInfixOf` redacted)),
      testCase "URI form: the userinfo password is replaced" do
        let redacted = redactConnectionString "postgres://me:hunter2@db:5432/kioku"
        assertBool
          ("host and user should survive: " <> Text.unpack redacted)
          ("me:REDACTED@db:5432" `Text.isInfixOf` redacted)
        assertBool "the secret should not survive" (not ("hunter2" `Text.isInfixOf` redacted)),
      testCase "a connection string with no password is unchanged" do
        redactConnectionString "host=x dbname=y user=me" @?= "host=x dbname=y user=me",
      testCase "a URI with no password is unchanged" do
        redactConnectionString "postgres://db:5432/kioku" @?= "postgres://db:5432/kioku"
    ]

-- | The two one-shot worker modes are unrelated, so passing both is a mistake. It used to be a
-- silent one: --timers-once was checked first and --backfill was ignored without a word.
workerModeTests :: TestTree
workerModeTests =
  testGroup
    "worker one-shot modes are mutually exclusive"
    [ testCase "no flags means the continuous worker" do
        parseWith workerOptionsParser [] @?= Right WorkerContinuous,
      testCase "--backfill covers every space unless one is named" do
        parseWith workerOptionsParser ["--backfill"] @?= Right (WorkerBackfill BackfillEverySpace),
      testCase "--backfill --space bounds the pass to one space" do
        parseWith workerOptionsParser ["--backfill", "--space", "space_prod"]
          @?= Right (WorkerBackfill (BackfillOneSpace (spaceNamed "space_prod"))),
      -- A space id that no caller could have constructed must not become one here either: the
      -- backfill would then scan for a partition value the database cannot hold and report a
      -- confident zero.
      testCase "--space rejects a malformed memory space id" do
        assertParseFailure (parseWith workerOptionsParser ["--backfill", "--space", "bad:space"]),
      testCase "--timers-once" do
        parseWith workerOptionsParser ["--timers-once"] @?= Right WorkerTimersOnce,
      testCase "both flags is a parse error" do
        assertConflict "--timers-once" (parseWith workerOptionsParser ["--backfill", "--timers-once"]),
      testCase "both flags in the other order is also a parse error" do
        assertConflict "--backfill" (parseWith workerOptionsParser ["--timers-once", "--backfill"])
    ]
  where
    assertConflict rejected = \case
      Right mode -> assertBool ("expected a conflict error, got: " <> show mode) False
      Left err ->
        assertBool
          ("failure should name the conflicting flag " <> rejected <> ": " <> err)
          (rejected `isInfixOf` err)

    assertParseFailure = \case
      Right mode -> assertBool ("expected a parse error, got: " <> show mode) False
      Left _ -> pure ()

    spaceNamed raw =
      either (error . Text.unpack) id (mkMemorySpaceId (Text.pack raw))
