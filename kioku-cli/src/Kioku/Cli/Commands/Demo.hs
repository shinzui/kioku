module Kioku.Cli.Commands.Demo
  ( runDemo,
  )
where

import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (Confidence (..), MemoryRecord (..), MemoryType (..))
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Id (genMemoryId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Recall qualified as Recall
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import System.Environment (lookupEnv)

runDemo :: IO ()
runDemo = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  withStore (defaultConnectionSettings (Text.pack connStr)) $ \st -> do
    tr <- noopTracer
    mid <- genMemoryId
    now <- getCurrentTime
    let scope = ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_demo"
        payload =
          RecordMemoryData
            { memoryId = mid,
              agentId = "demo-agent",
              sessionId = Nothing,
              scope = scope,
              memoryType = MemoryPreference,
              content = "prefers concise answers",
              priority = 100,
              confidence = HighConfidence,
              tags = Set.fromList ["style"],
              supersedes = Nothing,
              recordedAt = now
            }
        env = AppEnv {store = st, tracer = tr, metrics = Nothing}
    result <- runAppIO env do
      writeResult <- Memory.record payload
      recallResult <- Recall.getActiveByScope scope
      pure (writeResult, recallResult)
    case result of
      Left storeErr -> ioError (userError ("kioku demo store error: " <> show storeErr))
      Right (Left writeErr, _) -> ioError (userError ("kioku demo write error: " <> show writeErr))
      Right (Right writtenId, Left recallErr) ->
        ioError (userError ("kioku demo recall error after writing " <> show writtenId <> ": " <> show recallErr))
      Right (Right writtenId, Right records) -> do
        putStrLn ("Recorded memory " <> Text.unpack (idText writtenId) <> " in scope rei/intention/intention_demo")
        mapM_ printRecord records

requireEnv :: String -> IO String
requireEnv name = do
  found <- lookupEnv name
  case found of
    Just value -> pure value
    Nothing -> ioError (userError (name <> " is not set"))

printRecord :: MemoryRecord -> IO ()
printRecord record =
  putStrLn $
    "- "
      <> Text.unpack record.memoryId
      <> " ["
      <> Text.unpack record.memoryType
      <> "/"
      <> Text.unpack record.confidence
      <> "] "
      <> Text.unpack record.content
