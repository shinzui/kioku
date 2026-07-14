module Kioku.Cli.Commands.DemoSession
  ( DemoSessionOptions (..),
    demoSessionOptionsParser,
    runDemoSession,
  )
where

import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kioku.App (runAppIO, withNoopAppEnv)
import Kioku.Cli.Commands.Demo (demoScope)
import Kioku.Cli.Options (redactConnectionString, yesWriteEventsFlag)
import Kioku.Id (genSessionId, idText)
import Kioku.Session qualified as Session
import Kioku.Session.Domain (CompleteSessionData (..), RecordTurnData (..), StartSessionData (..))
import Kioku.Session.ReadModel (SessionRow (..), TurnRow (..))
import Kiroku.Store.Connection (defaultConnectionSettings)
import Options.Applicative
import System.Environment (lookupEnv)

data DemoSessionOptions = DemoSessionOptions
  deriving stock (Eq, Show)

demoSessionOptionsParser :: Parser DemoSessionOptions
demoSessionOptionsParser = DemoSessionOptions <$ yesWriteEventsFlag

runDemoSession :: DemoSessionOptions -> IO ()
runDemoSession DemoSessionOptions = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  putStrLn "kioku demo-session appends permanent session events (kioku has no delete)."
  putStrLn ("Target: " <> Text.unpack (redactConnectionString (Text.pack connStr)))
  putStrLn "Scope:  kioku_demo/demo/demo"
  putStrLn "Note:   completing this session schedules a distillation timer; a running worker will process it (an LLM call)."
  withNoopAppEnv (defaultConnectionSettings (Text.pack connStr)) \env -> do
    sid <- genSessionId
    now <- getCurrentTime
    let scope = demoScope
        startPayload =
          StartSessionData
            { sessionId = sid,
              agentId = "demo-agent",
              focus = "demo",
              scope = scope,
              subjectRef = Just "demo",
              previousSessionId = Nothing,
              parentSessionId = Nothing,
              delegationDepth = 0,
              startedAt = now
            }
        turnPayload =
          RecordTurnData
            { sessionId = sid,
              turnId = idText sid <> "-turn-1",
              turnIndex = 1,
              role = "user",
              content = "Please remember I prefer concise answers.",
              toolSummary = Nothing,
              promptTokens = Just 7,
              outputTokens = Nothing,
              recordedAt = now
            }
        completePayload =
          CompleteSessionData
            { sessionId = sid,
              completedAt = now,
              modelUsed = Just "demo-model",
              summary = Just "Demo session completed"
            }
    result <- runAppIO env do
      startResult <- Session.start startPayload
      turnResult <- Session.recordTurn turnPayload
      completeResult <- Session.complete completePayload
      rowResult <- Session.getById sid
      turnsResult <- Session.getTurns sid
      pure (startResult, turnResult, completeResult, rowResult, turnsResult)
    case result of
      Left storeErr -> ioError (userError ("kioku session demo store error: " <> show storeErr))
      Right (Left writeErr, _, _, _, _) -> ioError (userError ("kioku session demo start error: " <> show writeErr))
      Right (_, Left writeErr, _, _, _) -> ioError (userError ("kioku session demo turn error: " <> show writeErr))
      Right (_, _, Left writeErr, _, _) -> ioError (userError ("kioku session demo complete error: " <> show writeErr))
      Right (_, _, _, Left readErr, _) -> ioError (userError ("kioku session demo read error: " <> show readErr))
      Right (_, _, _, _, Left readErr) -> ioError (userError ("kioku session demo turns read error: " <> show readErr))
      Right (_, _, _, Right Nothing, Right _) -> ioError (userError "kioku session demo did not project the session row")
      Right (_, _, _, Right (Just row), Right turns) -> do
        putStrLn ("Recorded session " <> Text.unpack (idText sid) <> " with status " <> Text.unpack row.status)
        mapM_ printTurn turns

requireEnv :: String -> IO String
requireEnv name = do
  found <- lookupEnv name
  case found of
    Just value -> pure value
    Nothing -> ioError (userError (name <> " is not set"))

printTurn :: TurnRow -> IO ()
printTurn turn =
  putStrLn $
    "- turn "
      <> show turn.turnIndex
      <> " "
      <> Text.unpack turn.role
      <> ": "
      <> Text.unpack turn.content
