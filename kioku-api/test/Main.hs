module Main where

import Kioku.Api.AccessSpec qualified as AccessSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "kioku-api"
      [ AccessSpec.tests
      ]
