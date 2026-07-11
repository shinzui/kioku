-- | Pure tests for the CLI's parsing boundary: no database, no network, no environment.
--
-- optparse-applicative parsers are ordinary values, so 'execParserPure' exercises exactly what
-- an operator's argv hits — including the failure text they will read.
module Kioku.Cli.ParserSpec (tests) where

import Data.List (isInfixOf)
import Data.Text qualified as Text
import Kioku.Cli.Commands.Distill (DistillOptions (..), distillOptionsParser)
import Kioku.Id (genMemoryId, genSessionId, idText)
import Options.Applicative
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Kioku.Cli parsers"
    [ sessionIdTests
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
