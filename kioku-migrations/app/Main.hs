module Main where

import Codd.Environment (getCoddSettings)
import Data.Time (secondsToDiffTime)
import Kioku.Migrations (runKiokuMigrationsNoCheck)

main :: IO ()
main = do
  settings <- getCoddSettings
  _ <- runKiokuMigrationsNoCheck settings (secondsToDiffTime 5)
  pure ()
