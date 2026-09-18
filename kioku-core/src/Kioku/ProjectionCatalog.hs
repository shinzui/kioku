-- | Kioku's complete application-owned projection inventory.
--
-- The catalog deliberately stops at the @kioku@ schema boundary. Timer
-- scheduling writes Keiro's shared @keiro.keiro_timers@ table and therefore
-- remains an explicitly unmanaged transactional side effect at command call
-- sites; declaring that table here would falsely give one Kioku projection
-- exclusive ownership of framework state.
module Kioku.ProjectionCatalog
  ( kiokuProjectionCatalog,
    validateKiokuProjectionCatalog,
    validateKiokuProjectionCatalogWith,
    memoryProjectionSet,
    sessionProjectionSet,
    kiokuCatalogInventory,
    kiokuCatalogFingerprint,
    renderKiokuCatalogDiagnostics,
  )
where

import Data.List.NonEmpty qualified as NonEmpty
import Data.Text qualified as Text
import Keiro.Projection (InlineProjection (..))
import Keiro.Projection.Catalog
  ( CatalogDiagnostic (..),
    CatalogFingerprint,
    CatalogInventory,
    ClaimSite,
    ProjectionCatalog (..),
    ProjectionDefinition (..),
    ProjectionHandler (..),
    ProjectionReplayPolicy (..),
    ProjectionSet (..),
    QualifiedTable (..),
    QueryModelBinding (..),
    RebuildGroupDeclaration (..),
    RebuildGroupId,
    SomeProjectionSet (..),
    SomeQueryModelBinding (..),
    SourceDeclaration (..),
    SourceId,
    SourceScope (..),
    TargetDeclaration (..),
    TargetId,
    TargetResetPolicy (..),
    ValidatedProjectionCatalog,
    Validation (..),
    catalogFingerprint,
    catalogInventory,
    diagnosticCodeText,
    mkClaimSite,
    mkProjectionId,
    mkQueryModelId,
    mkRebuildGroupId,
    mkSourceId,
    mkTargetId,
    replayAdapterFromCodec,
    validateProjectionCatalog,
  )
import Keiro.ReadModel (ReadModel (..))
import Kioku.Database.Schema (kiokuSchema, memoriesRelation, sessionsRelation, turnsRelation)
import Kioku.Memory.Domain (MemoryEvent)
import Kioku.Memory.EventStream (memoryCodec)
import Kioku.Memory.ReadModel
  ( memoriesByNamespaceReadModel,
    memoriesByNamespaceRowsReadModel,
    memoriesByScopeReadModel,
    memoriesByScopeRowsReadModel,
    memoriesBySessionReadModel,
    memoriesBySessionRowsReadModel,
    memoriesByTypeReadModel,
    memoriesByTypeRowsReadModel,
    memoryByIdReadModel,
    memoryInlineProjection,
    memorySupersessionChainReadModel,
  )
import Kioku.Prelude
import Kioku.Session.Domain (SessionEvent)
import Kioku.Session.EventStream (sessionCodec)
import Kioku.Session.ReadModel
  ( awaitingSessionsByCorrelationKeyReadModel,
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
import Kiroku.Store.Types (CategoryName (..))

memorySourceId, sessionSourceId :: SourceId
memorySourceId = must (mkSourceId "kioku-memory-events")
sessionSourceId = must (mkSourceId "kioku-session-events")

memoriesTargetId, sessionsTargetId, turnsTargetId :: TargetId
memoriesTargetId = must (mkTargetId "kioku-memories")
sessionsTargetId = must (mkTargetId "kioku-sessions")
turnsTargetId = must (mkTargetId "kioku-turns")

memoryGroupId, sessionGroupId :: RebuildGroupId
memoryGroupId = must (mkRebuildGroupId "kioku-memory")
sessionGroupId = must (mkRebuildGroupId "kioku-session")

memoryProjectionSet :: ProjectionSet MemoryEvent
memoryProjectionSet =
  ProjectionSet
    { projectionSource = memorySourceId,
      projectionDefinitions =
        ProjectionDefinition
          { projectionId = must (mkProjectionId "kioku-memory-inline"),
            rebuildGroup = memoryGroupId,
            ownedTargets = memoriesTargetId :| [],
            replayPolicy = Replayable (replayAdapterFromCodec memoryCodec memoryInlineProjection.apply),
            handlers = InlineHandler memoryInlineProjection (site "memory inline handler") :| [],
            claimSite = site "memory projection owner"
          }
          :| [],
      claimSite = site "memory projection set"
    }

sessionProjectionSet :: ProjectionSet SessionEvent
sessionProjectionSet =
  ProjectionSet
    { projectionSource = sessionSourceId,
      projectionDefinitions =
        ProjectionDefinition
          { projectionId = must (mkProjectionId "kioku-session-inline"),
            rebuildGroup = sessionGroupId,
            ownedTargets = sessionsTargetId :| [turnsTargetId],
            replayPolicy = Replayable (replayAdapterFromCodec sessionCodec sessionInlineProjection.apply),
            handlers = InlineHandler sessionInlineProjection (site "session inline handler") :| [],
            claimSite = site "session projection owner"
          }
          :| [],
      claimSite = site "session projection set"
    }

kiokuProjectionCatalogDefinition :: ProjectionCatalog
kiokuProjectionCatalogDefinition =
  ProjectionCatalog
    { sources =
        [ SourceDeclaration memorySourceId (CategorySource (CategoryName "kioku_memory")) "kioku-memory-codec-v1" (site "memory event source"),
          SourceDeclaration sessionSourceId (CategorySource (CategoryName "kioku_session")) "kioku-session-codec-v1" (site "session event source")
        ],
      targets =
        [ TargetDeclaration memoriesTargetId (QualifiedTable kiokuSchema memoriesRelation) ClearBeforeReplay [] (site "memories target"),
          TargetDeclaration sessionsTargetId (QualifiedTable kiokuSchema sessionsRelation) ClearBeforeReplay [] (site "sessions target"),
          TargetDeclaration turnsTargetId (QualifiedTable kiokuSchema turnsRelation) ClearBeforeReplay [sessionsTargetId] (site "turns target")
        ],
      rebuildGroups =
        [ RebuildGroupDeclaration memoryGroupId [memoriesTargetId] [] (site "memory rebuild group"),
          RebuildGroupDeclaration sessionGroupId [sessionsTargetId, turnsTargetId] [] (site "session rebuild group")
        ],
      projectionRevisions = [],
      externalReadContracts = [],
      subscriptions = [],
      dedupKeys = [],
      queryModels = memoryQueryBindings <> sessionQueryBindings,
      projectionSets =
        [ SomeProjectionSet memoryProjectionSet,
          SomeProjectionSet sessionProjectionSet
        ]
    }

memoryQueryBindings :: [SomeQueryModelBinding]
memoryQueryBindings =
  [ binding memoryByIdReadModel memoryGroupId memoriesTargetId,
    binding memoriesByNamespaceReadModel memoryGroupId memoriesTargetId,
    binding memoriesByNamespaceRowsReadModel memoryGroupId memoriesTargetId,
    binding memoriesByScopeReadModel memoryGroupId memoriesTargetId,
    binding memoriesByScopeRowsReadModel memoryGroupId memoriesTargetId,
    binding memoriesBySessionReadModel memoryGroupId memoriesTargetId,
    binding memoriesBySessionRowsReadModel memoryGroupId memoriesTargetId,
    binding memoriesByTypeReadModel memoryGroupId memoriesTargetId,
    binding memoriesByTypeRowsReadModel memoryGroupId memoriesTargetId,
    binding memorySupersessionChainReadModel memoryGroupId memoriesTargetId
  ]

sessionQueryBindings :: [SomeQueryModelBinding]
sessionQueryBindings =
  [ binding sessionByIdReadModel sessionGroupId sessionsTargetId,
    binding sessionsByNamespaceReadModel sessionGroupId sessionsTargetId,
    binding sessionsByScopeReadModel sessionGroupId sessionsTargetId,
    binding sessionsByFocusReadModel sessionGroupId sessionsTargetId,
    binding sessionsByStartedRangeReadModel sessionGroupId sessionsTargetId,
    binding sessionChainReadModel sessionGroupId sessionsTargetId,
    binding sessionDelegationChildrenReadModel sessionGroupId sessionsTargetId,
    binding awaitingSessionsByCorrelationKeyReadModel sessionGroupId sessionsTargetId,
    binding turnsBySessionReadModel sessionGroupId turnsTargetId
  ]

binding :: ReadModel q r -> RebuildGroupId -> TargetId -> SomeQueryModelBinding
binding readModel rebuildGroup observedTarget =
  SomeQueryModelBinding
    QueryModelBinding
      { queryModelId = must (mkQueryModelId readModel.name),
        readModel,
        rebuildGroup,
        observedTargets = [observedTarget],
        claimSite = site ("query model " <> readModel.name)
      }

validateKiokuProjectionCatalog :: Validation (NonEmpty CatalogDiagnostic) ValidatedProjectionCatalog
validateKiokuProjectionCatalog = validateKiokuProjectionCatalogWith id

-- | Validate a deliberately transformed definition. Production code should
-- use 'validateKiokuProjectionCatalog'; this seam exists so tests can prove
-- malformed ownership and fingerprint declarations fail closed without
-- exporting Kioku's unvalidated catalog as a runtime value.
validateKiokuProjectionCatalogWith ::
  (ProjectionCatalog -> ProjectionCatalog) ->
  Validation (NonEmpty CatalogDiagnostic) ValidatedProjectionCatalog
validateKiokuProjectionCatalogWith modifyCatalog =
  validateProjectionCatalog (modifyCatalog kiokuProjectionCatalogDefinition)

kiokuProjectionCatalog :: ValidatedProjectionCatalog
kiokuProjectionCatalog =
  case validateKiokuProjectionCatalog of
    Success catalog -> catalog
    Failure diagnostics ->
      error (Text.unpack (renderKiokuCatalogDiagnostics diagnostics))

kiokuCatalogInventory :: CatalogInventory
kiokuCatalogInventory = catalogInventory kiokuProjectionCatalog

kiokuCatalogFingerprint :: CatalogFingerprint
kiokuCatalogFingerprint = catalogFingerprint kiokuProjectionCatalog

renderKiokuCatalogDiagnostics :: NonEmpty CatalogDiagnostic -> Text
renderKiokuCatalogDiagnostics diagnostics =
  Text.intercalate
    "; "
    [ diagnosticCodeText diagnostic.diagnosticCode
        <> " ("
        <> diagnostic.diagnosticIdentity
        <> "): "
        <> diagnostic.diagnosticMessage
    | diagnostic <- NonEmpty.toList diagnostics
    ]

site :: Text -> ClaimSite
site = must . mkClaimSite

must :: (Show error) => Either error value -> value
must = either (error . show) id
