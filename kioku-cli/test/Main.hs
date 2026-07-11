module Main where

import Kioku.Cli.ParserSpec qualified as ParserSpec
import Test.Tasty (defaultMain)

main :: IO ()
main = defaultMain ParserSpec.tests
