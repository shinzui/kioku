module Kioku.Recall
  ( getActiveByScope,
    getGlobal,
    getBySession,
    getByType,
  )
where

import Effectful (Eff, IOE, (:>))
import Keiro.ReadModel (ConsistencyMode (..), ReadModelError, runQueryWith)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (MemoryRecord, MemoryType, memoryTypeToText)
import Kioku.Id (SessionId, idText)
import Kioku.Memory.ReadModel
  ( MemoriesByScopeQuery (..),
    MemoriesBySessionQuery (..),
    MemoriesByTypeQuery (..),
    memoriesByScopeReadModel,
    memoriesBySessionReadModel,
    memoriesByTypeReadModel,
  )
import Kiroku.Store.Effect (Store)

getActiveByScope ::
  (IOE :> es, Store :> es) =>
  MemoryScope ->
  Eff es (Either ReadModelError [MemoryRecord])
getActiveByScope scope =
  runQueryWith
    Nothing
    Eventual
    memoriesByScopeReadModel
    (MemoriesByScopeQuery (scopeNamespaceText scope) (scopeKindText scope) (scopeRefText scope))

getGlobal ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  Eff es (Either ReadModelError [MemoryRecord])
getGlobal ns =
  getActiveByScope (ScopeGlobal ns)

getBySession ::
  (IOE :> es, Store :> es) =>
  SessionId ->
  Eff es (Either ReadModelError [MemoryRecord])
getBySession sid =
  runQueryWith Nothing Eventual memoriesBySessionReadModel (MemoriesBySessionQuery (idText sid))

getByType ::
  (IOE :> es, Store :> es) =>
  Namespace ->
  MemoryType ->
  Eff es (Either ReadModelError [MemoryRecord])
getByType (Namespace ns) mt =
  runQueryWith Nothing Eventual memoriesByTypeReadModel (MemoriesByTypeQuery ns (memoryTypeToText mt))
