module Kioku.Cli
  ( main,
  )
where

import Kioku.Cli.Commands.Demo (runDemo)
import Kioku.Cli.Commands.DemoSession (runDemoSession)
import Options.Applicative

data Command = Demo | DemoSession

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
      <> command
        "demo-session"
        (info (pure DemoSession) (progDesc "Run the session aggregate demonstration"))

run :: Command -> IO ()
run Demo = runDemo
run DemoSession = runDemoSession
