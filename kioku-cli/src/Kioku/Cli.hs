module Kioku.Cli
  ( main,
  )
where

import Kioku.Cli.Commands.Demo (runDemo)
import Options.Applicative

data Command = Demo

main :: IO ()
main = run =<< execParser opts
  where
    opts =
      info
        (commandParser <**> helper)
        ( fullDesc
            <> progDesc "kioku reusable agent memory tools"
            <> header "kioku"
        )

commandParser :: Parser Command
commandParser =
  subparser $
    command
      "demo"
      (info (pure Demo) (progDesc "Run the memory/session demonstration"))

run :: Command -> IO ()
run Demo = runDemo
