module Kioku.Session
  ( SessionRow (..),
    SessionWriteError (..),
    start,
    awaitInput,
    resume,
    complete,
    failSession,
    recordInteractive,
    recordTurn,
    getById,
    getRecentInNamespace,
    getByScope,
    getByFocus,
    getByStartedRange,
    getChain,
    getDelegationChildren,
    getAwaitingByCorrelationKey,
    getTurns,
  )
where

import Effectful (Eff, IOE, (:>))
import Effectful.Error.Static (Error)
import Keiro.Command (CommandError, defaultRunCommandOptions)
import Keiro.Projection (runCommandWithProjections)
import Keiro.ReadModel (ConsistencyMode (..), ReadModelError, runQueryWith)
import Kioku.Api.Scope (MemoryScope, Namespace (..), scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Distill.Timer (l1TimerScheduleProjection)
import Kioku.Id (SessionId, idText)
import Kioku.Prelude
import Kioku.Session.Domain
import Kioku.Session.EventStream (sessionEventStream, sessionStream)
import Kioku.Session.ReadModel
  ( AwaitingSessionsByCorrelationKeyQuery (..),
    SessionByIdQuery (..),
    SessionChainQuery (..),
    SessionDelegationChildrenQuery (..),
    SessionRow (..),
    SessionsByFocusQuery (..),
    SessionsByNamespaceQuery (..),
    SessionsByScopeQuery (..),
    SessionsByStartedRangeQuery (..),
    TurnRow,
    TurnsBySessionQuery (..),
    awaitingSessionsByCorrelationKeyReadModel,
    sessionByIdReadModel,
    sessionChainReadModel,
    sessionDelegationChildrenReadModel,
    sessionInlineProjection,
    sessionsByFocusReadModel,
    sessionsByNamespaceReadModel,
    sessionsByScopeReadModel,
    sessionsByStartedRangeReadModel,
    turnsBySessionReadModel,
  )
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)

data SessionWriteError
  = SessionCommandRejected !CommandError
  | SessionReadFailed !ReadModelError
  | SessionNotFound
  | SessionNotRunning
  | SessionNotAwaiting
  | SessionCorrelationMismatch
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
      | row.status == "running" || row.status == "awaiting" -> runSessionCommand cmdData.sessionId (CompleteSession cmdData)
      | otherwise -> pure (Right cmdData.sessionId)

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
      | row.status == "running" || row.status == "awaiting" -> runSessionCommand cmdData.sessionId (FailSession cmdData)
      | otherwise -> pure (Right cmdData.sessionId)

awaitInput ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  AwaitInputData ->
  Eff es (Either SessionWriteError SessionId)
awaitInput cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right Nothing -> pure (Left SessionNotFound)
    Right (Just row)
      | row.status == "awaiting" -> pure (Right cmdData.sessionId)
      | row.status /= "running" -> pure (Left SessionNotRunning)
      | otherwise -> runSessionCommand cmdData.sessionId (AwaitInput cmdData)

resume ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  ResumeSessionData ->
  Eff es (Either SessionWriteError SessionId)
resume cmdData = do
  existing <- getById cmdData.sessionId
  case existing of
    Left err -> pure (Left (SessionReadFailed err))
    Right Nothing -> pure (Left SessionNotFound)
    Right (Just row)
      | row.status == "running" -> pure (Right cmdData.sessionId)
      | row.status /= "awaiting" -> pure (Left SessionNotAwaiting)
      | not (correlationMatches row cmdData) -> pure (Left SessionCorrelationMismatch)
      | otherwise -> runSessionCommand cmdData.sessionId (ResumeSession cmdData)
  where
    correlationMatches row d =
      case d.correlationKey of
        Nothing -> True
        Just key -> row.awaitingCorrelationKey == Just key

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

getRecentInNamespace ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  Int ->
  Eff es (Either ReadModelError [SessionRow])
getRecentInNamespace ns limit =
  runQueryWith Nothing Eventual sessionsByNamespaceReadModel (SessionsByNamespaceQuery (namespaceText ns) limit)

getByScope ::
  (IOE :> es, Store :> es) =>
  MemoryScope ->
  Eff es (Either ReadModelError [SessionRow])
getByScope scope =
  runQueryWith
    Nothing
    Eventual
    sessionsByScopeReadModel
    (SessionsByScopeQuery (scopeNamespaceText scope) (scopeKindText scope) (scopeRefText scope))

getByFocus ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  Text ->
  Eff es (Either ReadModelError [SessionRow])
getByFocus ns focus =
  runQueryWith Nothing Eventual sessionsByFocusReadModel (SessionsByFocusQuery (namespaceText ns) focus)

getByStartedRange ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  UTCTime ->
  UTCTime ->
  Eff es (Either ReadModelError [SessionRow])
getByStartedRange ns startedAfter startedBefore =
  runQueryWith Nothing Eventual sessionsByStartedRangeReadModel (SessionsByStartedRangeQuery (namespaceText ns) startedAfter startedBefore)

getChain ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es (Either ReadModelError [SessionRow])
getChain sid =
  runQueryWith Nothing Eventual sessionChainReadModel (SessionChainQuery (idText sid))

getDelegationChildren ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es (Either ReadModelError [SessionRow])
getDelegationChildren sid =
  runQueryWith Nothing Eventual sessionDelegationChildrenReadModel (SessionDelegationChildrenQuery (idText sid))

getAwaitingByCorrelationKey ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  Text ->
  Eff es (Either ReadModelError [SessionRow])
getAwaitingByCorrelationKey ns correlationKey =
  runQueryWith Nothing Eventual awaitingSessionsByCorrelationKeyReadModel (AwaitingSessionsByCorrelationKeyQuery (namespaceText ns) correlationKey)

namespaceText :: Namespace -> Text
namespaceText (Namespace ns) = ns

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
