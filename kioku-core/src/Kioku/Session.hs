module Kioku.Session
  ( SessionWriteError (..),
    start,
    complete,
    failSession,
    recordInteractive,
    recordTurn,
    getById,
    getTurns,
  )
where

import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Command (CommandError, defaultRunCommandOptions)
import Keiro.Projection (runCommandWithProjections)
import Keiro.ReadModel (ConsistencyMode (..), ReadModelError, runQueryWith)
import Kioku.Distill.Timer (l1TimerScheduleProjection)
import Kioku.Id (SessionId, idText)
import Kioku.Prelude
import Kioku.Session.Domain
import Kioku.Session.EventStream (sessionEventStream, sessionStream)
import Kioku.Session.ReadModel
  ( SessionByIdQuery (..),
    SessionRow (..),
    TurnRow,
    TurnsBySessionQuery (..),
    sessionByIdReadModel,
    sessionInlineProjection,
    turnsBySessionReadModel,
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)

data SessionWriteError
  = SessionCommandRejected !CommandError
  | SessionReadFailed !ReadModelError
  | SessionNotFound
  | SessionNotRunning
  deriving stock (Generic, Show)

start ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  StartSessionData ->
  Eff es (Either SessionWriteError SessionId)
start cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right (Just _) -> pure (Right cmdData.sessionId)
    Right Nothing -> runSessionCommand cmdData.sessionId (StartSession cmdData)

complete ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  CompleteSessionData ->
  Eff es (Either SessionWriteError SessionId)
complete cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right Nothing -> pure (Left SessionNotFound)
    Right (Just row)
      | row.status /= "running" -> pure (Right cmdData.sessionId)
      | otherwise -> runSessionCommand cmdData.sessionId (CompleteSession cmdData)

failSession ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  FailSessionData ->
  Eff es (Either SessionWriteError SessionId)
failSession cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right Nothing -> pure (Left SessionNotFound)
    Right (Just row)
      | row.status /= "running" -> pure (Right cmdData.sessionId)
      | otherwise -> runSessionCommand cmdData.sessionId (FailSession cmdData)

recordInteractive ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  RecordInteractiveSessionData ->
  Eff es (Either SessionWriteError SessionId)
recordInteractive cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right (Just _) -> pure (Right cmdData.sessionId)
    Right Nothing -> runSessionCommand cmdData.sessionId (RecordInteractiveSession cmdData)

recordTurn ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  RecordTurnData ->
  Eff es (Either SessionWriteError SessionId)
recordTurn cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right Nothing -> pure (Left SessionNotFound)
    Right (Just row)
      | row.status /= "running" -> pure (Left SessionNotRunning)
      | otherwise -> runSessionCommand cmdData.sessionId (RecordTurn cmdData)

getById ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es (Either ReadModelError (Maybe SessionRow))
getById sid =
  runQueryWith Nothing Eventual sessionByIdReadModel (SessionByIdQuery (idText sid))

getTurns ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es (Either ReadModelError [TurnRow])
getTurns sid =
  runQueryWith Nothing Eventual turnsBySessionReadModel (TurnsBySessionQuery (idText sid))

runSessionCommand ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  SessionCommand ->
  Eff es (Either SessionWriteError SessionId)
runSessionCommand sid cmd = do
  result <-
    runCommandWithProjections
      defaultRunCommandOptions
      sessionEventStream
      (sessionStream sid)
      cmd
      [sessionInlineProjection, l1TimerScheduleProjection]
  pure $
    case result of
      Left err -> Left (SessionCommandRejected err)
      Right _ -> Right sid
