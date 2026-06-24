module Main where

import Kioku.ReiCompatSpec qualified as ReiCompatSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main =
  defaultMain $
    testGroup
      "kioku"
      [ ReiCompatSpec.tests
      ]
