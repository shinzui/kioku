{-# OPTIONS_GHC -Wno-deprecations #-}

module Kioku.ProjectionCatalogSpec (tests) where

import Data.Foldable (for_)
import Data.List.NonEmpty (NonEmpty (..))
import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Data.Time (getCurrentTime)
import Data.Vector qualified as Vector
import Effectful (liftIO)
import Keiro.Command
  ( SqlCommandOutcome (..),
    SqlTransactionDecision (..),
    defaultRunCommandOptions,
    runCommandWithSqlEventsControlled,
  )
import Keiro.Projection (InlineProjection (..))
import Keiro.Projection.Catalog
  ( CatalogDiagnostic (..),
    CatalogDiagnosticCode (..),
    CatalogInventory (..),
    InventoryQueryCursor,
    InventoryQueryFreshness (..),
    InventoryQueryModel (..),
    ProjectionCatalog (..),
    ProjectionDefinition (..),
    ProjectionSet (..),
    QueryModelBinding (..),
    SomeProjectionSet (..),
    SomeQueryModelBinding (..),
    SourceDeclaration (..),
    Validation (..),
    catalogFingerprintText,
    catalogRegistrations,
    mkClaimSite,
    mkProjectionId,
    mkTargetId,
    typedInlineProjections,
  )
import Keiro.ReadModel (ConsistencyMode (Strong), ReadModel (..), StrongScope (EntireLog))
import Keiro.ReadModel.Rebuild (registerProjectionCatalog)
import Keiro.Stream qualified as Stream
import Keiro.Timer (lookupTimer)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..))
import Kioku.Api.Types (Confidence (..), MemoryType (..))
import Kioku.App (runAppIO, withNoopAppEnv)
import Kioku.Distill.L2 (l2SceneTimerId, l2SceneTimerScheduleProjection)
import Kioku.Id (genMemoryId, genSessionId, idText)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain (MemoryCommand (..), RecordMemoryData (..))
import Kioku.Memory.EventStream (memoryEventStream, memoryStream, validateMemoryEventStream)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.ProjectionCatalog
  ( kiokuCatalogFingerprint,
    kiokuCatalogInventory,
    kiokuProjectionCatalog,
    memoryProjectionSet,
    sessionProjectionSet,
    validateKiokuProjectionCatalog,
    validateKiokuProjectionCatalogWith,
  )
import Kioku.Session qualified as Session
import Kioku.Session.Domain (StartSessionData (..))
import Kioku.Session.EventStream (validateSessionEventStream)
import Kioku.SpaceFixtures (testActorPrincipal, testContext, testSpace)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Types (StreamVersion (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertEqual, assertFailure, testCase)

tests :: TestTree
tests =
  testGroup
    "ProjectionCatalog"
    [ testCase "the Kioku catalog has one stable complete inventory" testInventory,
      testCase "typed projection sets select only application-owned handlers" testTypedHandlers,
      testCase "both hand-written event streams validate explicitly" testEventStreams,
      testCase "duplicate target ownership is rejected with a stable diagnostic" testDuplicateOwnership,
      testCase "an unknown owned target is rejected with a stable diagnostic" testUnknownOwnership,
      testCase "a target without its supplier is rejected at validation" testMissingSupplier,
      testCase "a waiting query without a cursor is rejected at validation" testWaitingWithoutCursor,
      testCase "registered catalog serves immediate memory and session queries" testImmediateQueries,
      testCase "a late projection failure rolls back events, rows, and timers" testProjectionRollback,
      testCase "persisted catalog fingerprint drift refuses registration" testFingerprintDrift
    ]

testInventory :: Assertion
testInventory = do
  case validateKiokuProjectionCatalog of
    Failure diagnostics -> assertFailure ("valid Kioku catalog was rejected: " <> show diagnostics)
    Success _ -> pure ()
  assertEqual "sources" 2 (length kiokuCatalogInventory.inventorySources)
  assertEqual "targets" 3 (length kiokuCatalogInventory.inventoryTargets)
  assertEqual "groups" 2 (length kiokuCatalogInventory.inventoryGroups)
  assertEqual "projection owners" 2 (length kiokuCatalogInventory.inventoryProjections)
  assertEqual "query models" 19 (length kiokuCatalogInventory.inventoryQueryModels)
  assertEqual "registrations" 19 (length (catalogRegistrations kiokuProjectionCatalog))
  assertBool
    "every query is immediate and cursorless"
    ( all
        (\query -> query.freshness == InventoryImmediate && noCursor query.cursor)
        kiokuCatalogInventory.inventoryQueryModels
    )
  assertEqual
    "canonical fingerprint"
    "catalog-v7:54f9ac55d73f40160d87b0ae49c2477a0de860c2e6e1e38df0591a2036d002e4"
    (catalogFingerprintText kiokuCatalogFingerprint)
  where
    noCursor :: Maybe InventoryQueryCursor -> Bool
    noCursor = maybe True (const False)

testTypedHandlers :: Assertion
testTypedHandlers = do
  assertEqual
    "memory handler"
    ["kioku-memory-inline"]
    (map (.name) (typedInlineProjections kiokuProjectionCatalog memoryProjectionSet))
  assertEqual
    "session handler"
    ["kioku-session-inline"]
    (map (.name) (typedInlineProjections kiokuProjectionCatalog sessionProjectionSet))

testEventStreams :: Assertion
testEventStreams = do
  assertBool "memory stream" (isRight validateMemoryEventStream)
  assertBool "session stream" (isRight validateSessionEventStream)

testDuplicateOwnership :: Assertion
testDuplicateOwnership =
  diagnosticsFor addDuplicateMemoryOwner
    `shouldContainCode` TargetWithMultipleOwners
  where
    addDuplicateMemoryOwner catalog =
      catalog
        { projectionSets = catalog.projectionSets <> [SomeProjectionSet duplicateMemoryProjectionSet]
        }
    duplicateMemoryProjectionSet =
      memoryProjectionSet
        { projectionDefinitions = duplicateDefinition :| []
        }
    duplicateDefinition =
      case memoryProjectionSet.projectionDefinitions of
        definition :| _ ->
          definition
            { projectionId = must (mkProjectionId "kioku-memory-inline-duplicate"),
              claimSite = must (mkClaimSite "duplicate memory owner test")
            }

testMissingSupplier :: Assertion
testMissingSupplier =
  diagnosticsFor (\catalog -> catalog {projectionSets = []})
    `shouldContainCode` TargetWithoutOwner

testUnknownOwnership :: Assertion
testUnknownOwnership =
  diagnosticsFor addUnknownTarget
    `shouldContainCode` UnknownTargetReference
  where
    addUnknownTarget catalog =
      catalog
        { projectionSets =
            [ SomeProjectionSet
                memoryProjectionSet
                  { projectionDefinitions =
                      addTarget <$> memoryProjectionSet.projectionDefinitions
                  }
            ]
              <> drop 1 catalog.projectionSets
        }
    addTarget definition =
      definition
        { ownedTargets =
            definition.ownedTargets
              <> (must (mkTargetId "kioku-unknown") :| [])
        }

testWaitingWithoutCursor :: Assertion
testWaitingWithoutCursor =
  diagnosticsFor makeQueriesWait
    `shouldContainCode` QueryWaitWithoutCompatibleCursor
  where
    makeQueriesWait catalog = catalog {queryModels = makeWaiting <$> catalog.queryModels}
    makeWaiting (SomeQueryModelBinding binding) =
      SomeQueryModelBinding
        binding
          { readModel =
              binding.readModel
                { defaultConsistency = Strong,
                  strongScope = EntireLog
                }
          }

testImmediateQueries :: Assertion
testImmediateQueries =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
      result <- runAppIO env do
        now <- liftIO getCurrentTime
        sid <- liftIO genSessionId
        sessionWrite <-
          Session.startWithContext
            testContext
            StartSessionData
              { sessionId = sid,
                memorySpaceId = testSpace,
                actorPrincipal = testActorPrincipal,
                ownerPrincipal = Nothing,
                agentId = "catalog-test",
                focus = "prove immediate catalog queries",
                scope = testScope,
                subjectRef = Nothing,
                previousSessionId = Nothing,
                parentSessionId = Nothing,
                delegationDepth = 0,
                startedAt = now
              }
        liftIO case sessionWrite of
          Left err -> assertFailure ("session command failed: " <> show err)
          Right _ -> pure ()
        sessionRead <- Session.getById testSpace sid
        liftIO case sessionRead of
          Right (Just _) -> pure ()
          other -> assertFailure ("immediate session query failed: " <> show (() <$ other))

        mid <- liftIO genMemoryId
        memoryWrite <-
          Memory.recordWithContext
            testContext
            RecordMemoryData
              { memoryId = mid,
                memorySpaceId = testSpace,
                actorPrincipal = testActorPrincipal,
                ownerPrincipal = Nothing,
                agentId = "catalog-test",
                sessionId = Just sid,
                scope = testScope,
                memoryType = MemoryFact,
                content = "catalog registration is live",
                priority = 50,
                confidence = HighConfidence,
                tags = Set.singleton "catalog",
                supersedes = Nothing,
                recordedAt = now
              }
        liftIO case memoryWrite of
          Left err -> assertFailure ("memory command failed: " <> show err)
          Right _ -> pure ()
        memoryRead <- Memory.getMemoryRowById testSpace mid
        liftIO case memoryRead of
          Right (Just _) -> pure ()
          other -> assertFailure ("immediate memory query failed: " <> show (() <$ other))
      case result of
        Left err -> assertFailure ("store error while exercising catalog queries: " <> show err)
        Right () -> pure ()
  where
    testScope :: MemoryScope
    testScope = ScopeGlobal (Namespace "kioku-catalog-test")

testProjectionRollback :: Assertion
testProjectionRollback =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env -> do
      mid <- genMemoryId
      now <- getCurrentTime
      let record =
            RecordMemoryData
              { memoryId = mid,
                memorySpaceId = testSpace,
                actorPrincipal = testActorPrincipal,
                ownerPrincipal = Nothing,
                agentId = "catalog-test",
                sessionId = Nothing,
                scope = testScope,
                memoryType = MemoryFact,
                content = "must roll back",
                priority = 50,
                confidence = HighConfidence,
                tags = Set.singleton "rollback",
                supersedes = Nothing,
                recordedAt = now
              }
          handlers =
            typedInlineProjections kiokuProjectionCatalog memoryProjectionSet
              <> [l2SceneTimerScheduleProjection]
      failed <-
        runAppIO env $
          runCommandWithSqlEventsControlled
            defaultRunCommandOptions
            memoryEventStream
            (memoryStream mid)
            (RecordMemory record)
            ( \pairs _ -> do
                for_ handlers \handler ->
                  for_ pairs \(event, recorded) -> handler.apply event recorded
                pure (RollbackSqlTransaction ())
            )
      case failed of
        Left err -> assertFailure ("store error while injecting rollback: " <> show err)
        Right (Left err) -> assertFailure ("command failed before the injected rollback: " <> show err)
        Right (Right (SqlCommandRolledBack ())) -> pure ()
        Right (Right other) -> assertFailure ("injected rollback committed: " <> show other)

      probe <- runAppIO env do
        events <- readStreamForward (Stream.streamName (memoryStream mid)) (StreamVersion 0) 10
        row <- Memory.getMemoryRowById testSpace mid
        timer <- lookupTimer (l2SceneTimerId testSpace testScope (idText mid))
        pure (Vector.length events, row, timer)
      case probe of
        Left err -> assertFailure ("store error while checking rollback: " <> show err)
        Right (eventCount, row, timer) -> do
          assertEqual "event append rolled back" 0 eventCount
          assertEqual "application projection rolled back" (Right Nothing) row
          assertEqual "framework timer rolled back" Nothing timer
  where
    testScope :: MemoryScope
    testScope = ScopeGlobal (Namespace "kioku-catalog-rollback")

testFingerprintDrift :: Assertion
testFingerprintDrift =
  withKiokuMigratedDatabase \connStr ->
    withNoopAppEnv (defaultConnectionSettings connStr) \env ->
      case validateKiokuProjectionCatalogWith driftSources of
        Failure diagnostics -> assertFailure ("drift fixture was structurally invalid: " <> show diagnostics)
        Success drifted -> do
          result <- runAppIO env (registerProjectionCatalog drifted)
          case result of
            Left err -> assertFailure ("store error while checking catalog drift: " <> show err)
            Right (Left _) -> pure ()
            Right (Right _) -> assertFailure "registration accepted a changed persisted catalog fingerprint"
  where
    driftSources catalog =
      catalog
        { sources =
            [ source {codecFingerprint = source.codecFingerprint <> "-drift"}
            | source <- catalog.sources
            ]
        }

diagnosticsFor :: (ProjectionCatalog -> ProjectionCatalog) -> [CatalogDiagnostic]
diagnosticsFor transform =
  case validateKiokuProjectionCatalogWith transform of
    Failure diagnostics -> NonEmpty.toList diagnostics
    Success _ -> []

shouldContainCode :: [CatalogDiagnostic] -> CatalogDiagnosticCode -> Assertion
shouldContainCode diagnostics expected =
  assertBool
    ("expected diagnostic " <> show expected <> ", got " <> show diagnostics)
    (any ((== expected) . (.diagnosticCode)) diagnostics)

isRight :: Either left right -> Bool
isRight = either (const False) (const True)

must :: (Show error) => Either error value -> value
must = either (error . show) id
