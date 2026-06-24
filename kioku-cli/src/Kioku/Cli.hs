module Kioku.Cli
  ( main,
  )
where

import Kioku.Cli.Commands.Demo (runDemo)
import Kioku.Cli.Commands.DemoSession (runDemoSession)
import Kioku.Cli.Commands.Distill (DistillOptions, distillOptionsParser, runDistill)
import Kioku.Cli.Commands.Recall (RecallOptions, recallOptionsParser, runRecall)
import Kioku.Cli.Commands.Worker (WorkerOptions, runWorker, workerOptionsParser)
import Options.Applicative

data Command = Demo | DemoSession | Distill DistillOptions | Recall RecallOptions | Worker WorkerOptions

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
      <> command
        "distill"
        (info (Distill <$> (helper <*> distillOptionsParser)) (progDesc "Run distillation commands"))
      <> command
        "recall"
        (info (Recall <$> (helper <*> recallOptionsParser)) (progDesc "Recall memories by query"))
      <> command
        "worker"
        (info (Worker <$> (helper <*> workerOptionsParser)) (progDesc "Run kioku background workers"))

run :: Command -> IO ()
run Demo = runDemo
run DemoSession = runDemoSession
run (Distill opts) = runDistill opts
run (Recall opts) = runRecall opts
run (Worker opts) = runWorker opts
