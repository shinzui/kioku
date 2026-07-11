module Kioku.Cli.Commands.Demo
  ( DemoOptions (..),
    demoOptionsParser,
    demoScope,
    runDemo,
  )
where

import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Time (getCurrentTime)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (Confidence (..), MemoryRecord (..), MemoryType (..))
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Cli.Options (redactConnectionString, yesWriteEventsFlag)
import Kioku.Id (genMemoryId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (RecordMemoryData (..))
import Kioku.Recall qualified as Recall
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Options.Applicative
import System.Environment (lookupEnv)

data DemoOptions = DemoOptions
  deriving stock (Eq, Show)

demoOptionsParser :: Parser DemoOptions
demoOptionsParser = DemoOptions <$ yesWriteEventsFlag

-- | The demo writes into a namespace nothing else reads.
--
-- It used to write into @rei:intention:intention_demo@ — the same namespace real Rei data
-- lives in — and those events are permanent, because kioku has no delete. They also fed the
-- distillation timers. A dedicated @kioku_demo@ namespace makes demo residue unmistakable and
-- keeps distillation of demo data confined to a namespace nothing else reads.
demoScope :: MemoryScope
demoScope = ScopeEntity (Namespace "kioku_demo") (ScopeKind "demo") "demo"

runDemo :: DemoOptions -> IO ()
runDemo DemoOptions = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  putStrLn "kioku demo appends permanent memory events (kioku has no delete)."
  putStrLn ("Target: " <> Text.unpack (redactConnectionString (Text.pack connStr)))
  putStrLn "Scope:  kioku_demo/demo/demo"
  withStore (defaultConnectionSettings (Text.pack connStr)) $ \st -> do
    tr <- noopTracer
    mid <- genMemoryId
    now <- getCurrentTime
    let scope = demoScope
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
        putStrLn ("Recorded memory " <> Text.unpack (idText writtenId) <> " in scope kioku_demo/demo/demo")
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
