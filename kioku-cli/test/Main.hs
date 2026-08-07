module Main where

import Kioku.Cli.ParserSpec qualified as ParserSpec
import Kioku.Cli.RecallEndToEndSpec qualified as RecallEndToEndSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "kioku-cli"
      [ ParserSpec.tests,
        RecallEndToEndSpec.tests
      ]
