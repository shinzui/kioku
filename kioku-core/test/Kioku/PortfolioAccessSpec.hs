-- | Conformance fixtures for the access contract in "Kioku.Api.Access".
--
-- Kioku takes no dependency on any identity service, so this suite stands in for one. It models
-- the two seams Kioku consumes — a directory that maps an authenticated credential subject to a
-- principal, and a relationship-based authorizer with grants, team-derived access, and a lagging
-- replica — and pins what Kioku expects of any real implementation.
--
-- The point of a model rather than a mock is the replica. Several of the rules below (a
-- just-written grant that a stale read cannot see, a retry that forwards a freshness token) only
-- have observable behaviour if the fake actually has revisions, and those are exactly the rules
-- a naive integration gets wrong.
module Kioku.PortfolioAccessSpec (tests) where

import Data.IORef (IORef, atomicModifyIORef', modifyIORef', newIORef, readIORef)
import Data.List.NonEmpty (NonEmpty (..))
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (fromMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.Api.Access
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..), scopeNamespaceText)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertEqual, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Portfolio access contract"
    [ directAccessTests,
      derivedAccessTests,
      isolationTests,
      failClosedTests,
      freshnessTests
    ]

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

-- Rendered principal identifiers in the shape a directory produces. Kioku never parses these;
-- they are here so the fixtures exercise the real wire form rather than a placeholder.
personAlice, personBob, teamPlatform, agentWatcher, servicePipeline :: Text
personAlice = "person_01h9xk3v7hf8b9c0d1e2f3g4h5"
personBob = "person_01h9xk3v7hf8b9c0d1e2f3g4h6"
teamPlatform = "team_01h9xk3v7hf8b9c0d1e2f3g4h7"
agentWatcher = "agent_01h9xk3v7hf8b9c0d1e2f3g4h8"
servicePipeline = "service_01h9xk3v7hf8b9c0d1e2f3g4h9"

spaceAlpha, spaceBeta :: MemorySpaceId
spaceAlpha = expectRight (mkMemorySpaceId "space_alpha")
spaceBeta = expectRight (mkMemorySpaceId "space_beta")

-- | The scope both spaces use. Identical on purpose: a scope organizes memory /inside/ a space
-- and contributes nothing to the space's identity as an authorization object.
sharedScope :: MemoryScope
sharedScope = ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_01h9xk"

-- | The host-supplied translation from Kioku's actions to a schema's names. Kioku ships no
-- default, so every caller — including this suite — writes its own.
binding :: MemoryAuthorizationBinding
binding =
  expectRight
    ( mkMemoryAuthorizationBinding
        (expectRight (mkMemoryObjectType "memory_space"))
        [ bind MemoryRead "kioku:read" "can_read",
          bind MemoryRecord "kioku:record" "can_record",
          bind MemoryDistill "kioku:distill" "can_distill",
          bind MemoryForget "kioku:forget" "can_forget",
          bind MemoryAdmin "kioku:admin" "can_administer"
        ]
    )
  where
    bind permission scope name =
      ( permission,
        MemoryPermissionBinding
          { coarseScope = expectRight (mkMemoryCoarseScope scope),
            objectPermission = expectRight (mkMemoryPermissionName name)
          }
      )

-- | A caller whose credential carries every coarse claim. Passing the coarse gate is necessary
-- and nowhere near sufficient — everything interesting below happens after it.
fullyScoped :: Text -> AuthenticatedSubject
fullyScoped subjectId =
  AuthenticatedSubject
    { subjectId,
      grantedScopes =
        Set.fromList
          [ (memoryPermissionBinding binding permission).coarseScope
          | permission <- allMemoryPermissions
          ]
    }

scopedFor :: Text -> [MemoryPermission] -> AuthenticatedSubject
scopedFor subjectId permissions =
  AuthenticatedSubject
    { subjectId,
      grantedScopes =
        Set.fromList [(memoryPermissionBinding binding permission).coarseScope | permission <- permissions]
    }

-- ---------------------------------------------------------------------------
-- The modelled identity stack
-- ---------------------------------------------------------------------------

-- | Who a grant is written for: a named principal, or every member of a team.
data GrantSubject
  = GrantPrincipal Text
  | GrantTeamMember Text
  deriving stock (Eq, Show)

data Grant = Grant
  { grantObject :: Text,
    grantPermission :: Text,
    grantSubject :: GrantSubject,
    -- | the revision at which this grant became visible
    grantVisibleAt :: Int
  }
  deriving stock (Eq, Show)

data World = World
  { -- | credential subject → principal reference. A principal that has been paused, removed, or
    -- never linked is simply absent, which is all Kioku is entitled to know.
    credentials :: Map Text Text,
    -- | team principal → its members
    teams :: Map Text (Set Text),
    grants :: [Grant],
    -- | what an ordinary read sees: a replica that may lag
    replicaRevision :: Int,
    headRevision :: Int
  }

-- | A world where the replica is fully caught up.
world :: [(Text, Text)] -> [(Text, [Text])] -> [Grant] -> World
world credentialPairs teamPairs grantList =
  World
    { credentials = Map.fromList credentialPairs,
      teams = Map.fromList [(team, Set.fromList members) | (team, members) <- teamPairs],
      grants = grantList,
      replicaRevision = 1,
      headRevision = 1
    }

-- | A grant visible from the start of the world.
grantNow :: MemorySpaceId -> Text -> GrantSubject -> Grant
grantNow spaceId permission subject =
  Grant
    { grantObject = memoryObjectRefText (memorySpaceObjectRef binding spaceId),
      grantPermission = permission,
      grantSubject = subject,
      grantVisibleAt = 1
    }

data Harness = Harness
  { directory :: PrincipalDirectory IO,
    checker :: PermissionChecker IO,
    directoryCalls :: IORef Int,
    checkCalls :: IORef Int,
    worldRef :: IORef World
  }

newHarness :: World -> IO Harness
newHarness initial = do
  worldRef <- newIORef initial
  directoryCalls <- newIORef (0 :: Int)
  checkCalls <- newIORef (0 :: Int)
  let directory = PrincipalDirectory \subjectId -> do
        modifyIORef' directoryCalls (+ 1)
        current <- readIORef worldRef
        pure (either (const Nothing) Just . mkPrincipalRef =<< Map.lookup subjectId current.credentials)

      checker = PermissionChecker \freshness principal permissionName object -> do
        modifyIORef' checkCalls (+ 1)
        current <- readIORef worldRef
        let readAt = case freshness of
              MemoryFreshnessDefault -> current.replicaRevision
              MemoryFreshnessAtLeast token -> max current.replicaRevision (revisionOfToken token)
            visible =
              [ grant
              | grant <- current.grants,
                grant.grantVisibleAt <= readAt,
                grant.grantObject == memoryObjectRefText object,
                grant.grantPermission == memoryPermissionNameText permissionName
              ]
            subject = principalRefText principal
            matches grant = case grant.grantSubject of
              GrantPrincipal named -> named == subject
              GrantTeamMember team ->
                Set.member subject (fromMaybe Set.empty (Map.lookup team current.teams))
        pure
          MemoryDecision
            { outcome = if any matches visible then MemoryAllowed else MemoryDenied,
              checkedAt = tokenForRevision readAt
            }
  pure Harness {directory, checker, directoryCalls, checkCalls, worldRef}

-- | Write a grant at a new head revision and return the token naming it. The replica is left
-- behind on purpose: this is the situation a caller is in immediately after granting access.
writeGrantAheadOfReplica :: Harness -> MemorySpaceId -> Text -> GrantSubject -> IO MemoryDecisionToken
writeGrantAheadOfReplica harness spaceId permission subject =
  atomicModifyIORef' harness.worldRef \current ->
    let next = current.headRevision + 1
        grant =
          Grant
            { grantObject = memoryObjectRefText (memorySpaceObjectRef binding spaceId),
              grantPermission = permission,
              grantSubject = subject,
              grantVisibleAt = next
            }
     in (current {grants = grant : current.grants, headRevision = next}, tokenForRevision next)

-- The token is opaque to Kioku; the model gives it a readable encoding so a test can assert
-- which revision a read landed on.
tokenForRevision :: Int -> MemoryDecisionToken
tokenForRevision revision = expectRight (mkMemoryDecisionToken ("rev-" <> Text.pack (show revision)))

revisionOfToken :: MemoryDecisionToken -> Int
revisionOfToken token =
  case Text.stripPrefix "rev-" (memoryDecisionTokenText token) >>= readInt of
    Just revision -> revision
    Nothing -> error ("unrecognised decision token: " <> Text.unpack (memoryDecisionTokenText token))
  where
    readInt text = case reads (Text.unpack text) of
      [(value, "")] -> Just value
      _ -> Nothing

authorize ::
  Harness ->
  AuthenticatedSubject ->
  MemorySpaceId ->
  NonEmpty MemoryPermission ->
  IO (Either MemoryAccessDenial MemoryAccessContext)
authorize harness = authorizeAt harness MemoryFreshnessDefault

authorizeAt ::
  Harness ->
  MemoryFreshness ->
  AuthenticatedSubject ->
  MemorySpaceId ->
  NonEmpty MemoryPermission ->
  IO (Either MemoryAccessDenial MemoryAccessContext)
authorizeAt harness freshness subject spaceId permissions =
  authorizeMemoryAccess binding harness.directory harness.checker freshness subject spaceId permissions

-- ---------------------------------------------------------------------------
-- Fixtures: access that should be granted
-- ---------------------------------------------------------------------------

directAccessTests :: TestTree
directAccessTests =
  testGroup
    "authorized access"
    [ testCase "a person with a direct grant may read their own space" do
        harness <-
          newHarness
            ( world
                [("sub-alice", personAlice)]
                []
                [grantNow spaceAlpha "can_read" (GrantPrincipal personAlice)]
            )
        result <- authorize harness (fullyScoped "sub-alice") spaceAlpha (MemoryRead :| [])
        context <- expectAuthorized result
        memoryContextSpace context @?= spaceAlpha
        memoryContextActor context @?= MemoryActor (expectRight (mkPrincipalRef personAlice))
        assertBool "read granted" (memoryContextAllows MemoryRead context),
      testCase "an agent that owns a space may record into it" do
        harness <-
          newHarness
            ( world
                [("sub-watcher", agentWatcher)]
                []
                [grantNow spaceAlpha "can_record" (GrantPrincipal agentWatcher)]
            )
        result <- authorize harness (fullyScoped "sub-watcher") spaceAlpha (MemoryRecord :| [])
        context <- expectAuthorized result
        memoryContextActor context @?= MemoryActor (expectRight (mkPrincipalRef agentWatcher))
        assertBool "record granted" (memoryContextAllows MemoryRecord context),
      testCase "a service principal is authorized exactly like any other principal" do
        -- Kioku holds no principal-kind vocabulary, so a service must need no special case. If
        -- this test ever required different setup from the person case above, that would be the
        -- symptom of a kind vocabulary leaking in.
        harness <-
          newHarness
            ( world
                [("sub-pipeline", servicePipeline)]
                []
                [grantNow spaceAlpha "can_distill" (GrantPrincipal servicePipeline)]
            )
        result <- authorize harness (fullyScoped "sub-pipeline") spaceAlpha (MemoryDistill :| [])
        context <- expectAuthorized result
        memoryContextActor context @?= MemoryActor (expectRight (mkPrincipalRef servicePipeline)),
      testCase "a context authorizes every action it was minted for" do
        harness <-
          newHarness
            ( world
                [("sub-alice", personAlice)]
                []
                [ grantNow spaceAlpha "can_read" (GrantPrincipal personAlice),
                  grantNow spaceAlpha "can_record" (GrantPrincipal personAlice)
                ]
            )
        result <- authorize harness (fullyScoped "sub-alice") spaceAlpha (MemoryRead :| [MemoryRecord])
        context <- expectAuthorized result
        memoryContextPermissions context @?= Set.fromList [MemoryRead, MemoryRecord]
        assertBool "forget withheld" (not (memoryContextAllows MemoryForget context))
        checks <- readIORef harness.checkCalls
        assertEqual "one check per requested action" 2 checks
    ]

derivedAccessTests :: TestTree
derivedAccessTests =
  testGroup
    "relationship-derived access"
    [ testCase "a person reaches a space through team membership" do
        -- The grant names the team, never the person. Kioku stores no membership of its own and
        -- could not compute this answer; it exists entirely on the other side of the seam.
        harness <-
          newHarness
            ( world
                [("sub-bob", personBob)]
                [(teamPlatform, [personBob])]
                [grantNow spaceAlpha "can_read" (GrantTeamMember teamPlatform)]
            )
        result <- authorize harness (fullyScoped "sub-bob") spaceAlpha (MemoryRead :| [])
        context <- expectAuthorized result
        memoryContextActor context @?= MemoryActor (expectRight (mkPrincipalRef personBob)),
      testCase "leaving the team removes the derived access" do
        harness <-
          newHarness
            ( world
                [("sub-bob", personBob)]
                [(teamPlatform, [])]
                [grantNow spaceAlpha "can_read" (GrantTeamMember teamPlatform)]
            )
        result <- authorize harness (fullyScoped "sub-bob") spaceAlpha (MemoryRead :| [])
        result @?= Left (MemoryPermissionDenied spaceAlpha MemoryRead)
    ]

-- ---------------------------------------------------------------------------
-- Fixtures: isolation between spaces
-- ---------------------------------------------------------------------------

isolationTests :: TestTree
isolationTests =
  testGroup
    "memory spaces are isolated"
    [ testCase "a grant on one space never authorizes another" do
        harness <-
          newHarness
            ( world
                [("sub-alice", personAlice)]
                []
                [grantNow spaceAlpha "can_read" (GrantPrincipal personAlice)]
            )
        allowed <- authorize harness (fullyScoped "sub-alice") spaceAlpha (MemoryRead :| [])
        _ <- expectAuthorized allowed
        denied <- authorize harness (fullyScoped "sub-alice") spaceBeta (MemoryRead :| [])
        denied @?= Left (MemoryPermissionDenied spaceBeta MemoryRead),
      testCase "the same namespace and scope in two spaces are two different questions" do
        -- Both spaces are asked about under one identical scope. What separates them is the
        -- space alone, which is why a namespace can never be pressed into service as a tenancy
        -- boundary.
        scopeNamespaceText sharedScope @?= "rei"
        assertBool
          "distinct authorization objects"
          ( memoryObjectRefText (memorySpaceObjectRef binding spaceAlpha)
              /= memoryObjectRefText (memorySpaceObjectRef binding spaceBeta)
          ),
      testCase "a denial names the space that was refused" do
        harness <- newHarness (world [("sub-alice", personAlice)] [] [])
        result <- authorize harness (fullyScoped "sub-alice") spaceBeta (MemoryForget :| [])
        result @?= Left (MemoryPermissionDenied spaceBeta MemoryForget)
    ]

-- ---------------------------------------------------------------------------
-- Fixtures: the ways access is refused
-- ---------------------------------------------------------------------------

failClosedTests :: TestTree
failClosedTests =
  testGroup
    "refusals stay distinct and fail closed"
    [ testCase "a missing coarse claim is refused before anyone is looked up" do
        harness <-
          newHarness
            ( world
                [("sub-alice", personAlice)]
                []
                [grantNow spaceAlpha "can_forget" (GrantPrincipal personAlice)]
            )
        -- The credential carries kioku:read but not kioku:forget, even though the grant exists.
        result <- authorize harness (scopedFor "sub-alice" [MemoryRead]) spaceAlpha (MemoryForget :| [])
        result
          @?= Left
            (MemoryCoarseScopeMissing (memoryPermissionBinding binding MemoryForget).coarseScope)
        lookups <- readIORef harness.directoryCalls
        checks <- readIORef harness.checkCalls
        assertEqual "directory not consulted" 0 lookups
        assertEqual "authorizer not consulted" 0 checks,
      testCase "a paused agent's credential resolves to nothing and is refused" do
        -- Agent lifecycle belongs to the directory. Kioku holds no paused/active state, so a
        -- paused agent reaches it as a subject that no longer resolves — and that must fail
        -- closed rather than fall through to an unauthenticated path.
        harness <- newHarness (world [] [] [grantNow spaceAlpha "can_record" (GrantPrincipal agentWatcher)])
        result <- authorize harness (fullyScoped "sub-watcher") spaceAlpha (MemoryRecord :| [])
        result @?= Left (MemoryPrincipalUnresolved "sub-watcher")
        checks <- readIORef harness.checkCalls
        assertEqual "no permission check on an unresolved subject" 0 checks,
      testCase "an unresolved subject is not confused with a denial" do
        harness <- newHarness (world [] [] [])
        unresolved <- authorize harness (fullyScoped "sub-nobody") spaceAlpha (MemoryRead :| [])
        harnessWithPrincipal <- newHarness (world [("sub-alice", personAlice)] [] [])
        denied <- authorize harnessWithPrincipal (fullyScoped "sub-alice") spaceAlpha (MemoryRead :| [])
        assertBool "different refusals" (unresolved /= denied),
      testCase "a conditional decision is a refusal, not an allow" do
        -- A relationship exists but is gated on context this request did not supply. Promoting
        -- that to an allow is how a time-limited grant silently becomes permanent.
        conditionalHarness <- newConditionalHarness ["within_autonomy"]
        result <-
          authorizeMemoryAccess
            binding
            conditionalHarness.directory
            conditionalHarness.checker
            MemoryFreshnessDefault
            (fullyScoped "sub-alice")
            spaceAlpha
            (MemoryRead :| [])
        result @?= Left (MemoryDecisionConditional spaceAlpha MemoryRead ["within_autonomy"]),
      testCase "one denied action refuses the whole request" do
        harness <-
          newHarness
            ( world
                [("sub-alice", personAlice)]
                []
                [grantNow spaceAlpha "can_read" (GrantPrincipal personAlice)]
            )
        result <- authorize harness (fullyScoped "sub-alice") spaceAlpha (MemoryRead :| [MemoryForget])
        result @?= Left (MemoryPermissionDenied spaceAlpha MemoryForget)
    ]

-- | A harness whose authorizer always answers conditionally.
newConditionalHarness :: [Text] -> IO Harness
newConditionalHarness obligations = do
  base <- newHarness (world [("sub-alice", personAlice)] [] [])
  pure
    base
      { checker =
          PermissionChecker \_ _ _ _ ->
            pure
              MemoryDecision
                { outcome = MemoryConditional obligations,
                  checkedAt = tokenForRevision 1
                }
      }

-- ---------------------------------------------------------------------------
-- Fixtures: freshness
-- ---------------------------------------------------------------------------

freshnessTests :: TestTree
freshnessTests =
  testGroup
    "freshness and the stale-decision retry"
    [ testCase "a lagging replica denies a just-written grant" do
        harness <- newHarness (world [("sub-alice", personAlice)] [] [])
        _ <- writeGrantAheadOfReplica harness spaceAlpha "can_read" (GrantPrincipal personAlice)
        result <- authorize harness (fullyScoped "sub-alice") spaceAlpha (MemoryRead :| [])
        result @?= Left (MemoryPermissionDenied spaceAlpha MemoryRead),
      testCase "retrying with the write's token observes the new grant" do
        harness <- newHarness (world [("sub-alice", personAlice)] [] [])
        token <- writeGrantAheadOfReplica harness spaceAlpha "can_read" (GrantPrincipal personAlice)
        stale <- authorize harness (fullyScoped "sub-alice") spaceAlpha (MemoryRead :| [])
        stale @?= Left (MemoryPermissionDenied spaceAlpha MemoryRead)
        retried <-
          authorizeAt harness (atLeastAsFresh token) (fullyScoped "sub-alice") spaceAlpha (MemoryRead :| [])
        context <- expectAuthorized retried
        assertBool "read granted after retry" (memoryContextAllows MemoryRead context),
      testCase "the minted context carries the revision it was decided at" do
        harness <- newHarness (world [("sub-alice", personAlice)] [] [])
        token <- writeGrantAheadOfReplica harness spaceAlpha "can_read" (GrantPrincipal personAlice)
        retried <-
          authorizeAt harness (atLeastAsFresh token) (fullyScoped "sub-alice") spaceAlpha (MemoryRead :| [])
        context <- expectAuthorized retried
        memoryContextDecisionToken context @?= Just token,
      testCase "a follow-up read chains from the context, never falling back to stale" do
        -- This is the forwarding rule EP-2 and later plans depend on: once a caller has observed
        -- a revision, everything downstream of that decision observes it too.
        harness <- newHarness (world [("sub-alice", personAlice)] [] [])
        token <- writeGrantAheadOfReplica harness spaceAlpha "can_read" (GrantPrincipal personAlice)
        _ <- writeGrantAheadOfReplica harness spaceAlpha "can_record" (GrantPrincipal personAlice)
        first <-
          authorizeAt harness (atLeastAsFresh token) (fullyScoped "sub-alice") spaceAlpha (MemoryRead :| [])
        firstContext <- expectAuthorized first
        memoryContextFreshness firstContext @?= atLeastAsFresh token
        second <-
          authorizeAt
            harness
            (memoryContextFreshness firstContext)
            (fullyScoped "sub-alice")
            spaceAlpha
            (MemoryRead :| [])
        _ <- expectAuthorized second
        pure (),
      testCase "an assumed context observed nothing and pins nothing" do
        memoryContextFreshness
          (assumeAuthorizedMemoryContext spaceAlpha (MemoryActor (expectRight (mkPrincipalRef personAlice))))
          @?= MemoryFreshnessDefault
    ]

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

expectAuthorized :: Either MemoryAccessDenial MemoryAccessContext -> IO MemoryAccessContext
expectAuthorized = \case
  Right context -> pure context
  Left denial -> fail ("expected authorization, got: " <> show denial)

expectRight :: Either Text a -> a
expectRight = either (error . Text.unpack) id
