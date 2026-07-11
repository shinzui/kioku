module Kioku.Cli
  ( main,
  )
where

import Kioku.Cli.Commands.Demo (DemoOptions, demoOptionsParser, runDemo)
import Kioku.Cli.Commands.DemoSession (DemoSessionOptions, demoSessionOptionsParser, runDemoSession)
import Kioku.Cli.Commands.Distill (DistillOptions, distillOptionsParser, runDistill)
import Kioku.Cli.Commands.Persona (PersonaOptions, personaOptionsParser, runPersona)
import Kioku.Cli.Commands.Recall (RecallOptions, recallOptionsParser, runRecall)
import Kioku.Cli.Commands.Scenes (ScenesOptions, runScenes, scenesOptionsParser)
import Kioku.Cli.Commands.Worker (WorkerOptions, runWorker, workerOptionsParser)
import Options.Applicative

data Command = Demo DemoOptions | DemoSession DemoSessionOptions | Distill DistillOptions | Persona PersonaOptions | Recall RecallOptions | Scenes ScenesOptions | Worker WorkerOptions

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
      (info (Demo <$> (helper <*> demoOptionsParser)) (progDesc "Run the memory/session demonstration (writes permanent events)"))
      <> command
        "demo-session"
        (info (DemoSession <$> (helper <*> demoSessionOptionsParser)) (progDesc "Run the session aggregate demonstration (writes permanent events)"))
      <> command
        "distill"
        (info (Distill <$> (helper <*> distillOptionsParser)) (progDesc "Run distillation commands"))
      <> command
        "persona"
        (info (Persona <$> (helper <*> personaOptionsParser)) (progDesc "Print distilled L3 persona"))
      <> command
        "recall"
        (info (Recall <$> (helper <*> recallOptionsParser)) (progDesc "Recall memories by query"))
      <> command
        "scenes"
        (info (Scenes <$> (helper <*> scenesOptionsParser)) (progDesc "Print distilled L2 scenes"))
      <> command
        "worker"
        (info (Worker <$> (helper <*> workerOptionsParser)) (progDesc "Run kioku background workers"))

run :: Command -> IO ()
run (Demo opts) = runDemo opts
run (DemoSession opts) = runDemoSession opts
run (Distill opts) = runDistill opts
run (Persona opts) = runPersona opts
run (Recall opts) = runRecall opts
run (Scenes opts) = runScenes opts
run (Worker opts) = runWorker opts
