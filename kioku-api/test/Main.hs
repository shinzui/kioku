module Main where

import Kioku.Api.AccessSpec qualified as AccessSpec
import Kioku.Api.RecallSpec qualified as RecallSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "kioku-api"
      [ AccessSpec.tests,
        RecallSpec.tests
      ]
