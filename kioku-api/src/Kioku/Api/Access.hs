-- | Memory spaces, principals, and the authorization context Kioku's core requires.
--
-- Kioku stores memory. It does not authenticate anyone, hold a roster of users or teams, or
-- decide who may read what — and it takes no dependency on anything that does. What it requires
-- is that somebody else has already decided, and says so by handing it a 'MemoryAccessContext'.
--
-- There are exactly two ways to obtain one.
--
-- A trusted in-process host — a CLI, a test, an application that authenticated its user long
-- before it reached the memory layer — calls 'assumeAuthorizedMemoryContext'. Nothing else is
-- required: no directory, no authorization engine, no configuration. This is the ordinary case
-- and it is why Kioku is usable standalone.
--
-- A host serving untrusted callers uses 'authorizeMemoryAccess', which runs three gates in a
-- fixed order and refuses to skip any of them:
--
-- 1. a coarse credential claim ('MemoryCoarseScope') proves the caller may talk to Kioku about
--    this /kind/ of action at all;
-- 2. a directory ('PrincipalDirectory') resolves the authenticated subject to a
--    'PrincipalRef', which is what makes an unlinked credential or a paused agent fail closed;
-- 3. an authorization engine ('PermissionChecker') decides whether that principal may perform
--    this action on /this memory space/.
--
-- Each gate answers a question the others cannot. A coarse @kioku:read@ scope says nothing about
-- which space; a resolved principal says nothing about permission; and a permission check on a
-- subject nobody vouched for is a check on a string the caller made up.
--
-- The two seams in steps 2 and 3 are records of plain functions. Kioku names no identity
-- service, and the object type and permission names it asks about come from the host as a
-- 'MemoryAuthorizationBinding'. See @docs\/user\/integrations.md@ for a worked integration.
module Kioku.Api.Access
  ( -- * The isolation boundary
    MemorySpaceId,
    mkMemorySpaceId,
    memorySpaceIdText,
    legacyMemorySpaceId,

    -- * Principals
    PrincipalRef,
    mkPrincipalRef,
    principalRefText,
    MemoryActor (..),
    MemoryOwner (..),
    actorPrincipal,
    ownerPrincipal,

    -- * Principals as they appear on stored facts
    LegacyPrincipalRef,
    legacyPrincipalRef,
    legacyPrincipalRefText,
    RecordedPrincipal (..),
    recordedPrincipalText,
    parseRecordedPrincipal,

    -- * Kioku's own action vocabulary
    MemoryPermission (..),
    allMemoryPermissions,
    memoryPermissionText,
    parseMemoryPermission,

    -- * Naming the authorization object, which Kioku does not own
    MemoryObjectType,
    mkMemoryObjectType,
    memoryObjectTypeText,
    MemoryPermissionName,
    mkMemoryPermissionName,
    memoryPermissionNameText,
    MemoryCoarseScope,
    mkMemoryCoarseScope,
    memoryCoarseScopeText,
    MemoryObjectRef (..),
    memoryObjectRefText,
    MemoryPermissionBinding (..),
    MemoryAuthorizationBinding,
    mkMemoryAuthorizationBinding,
    memoryPermissionBinding,
    memorySpaceObjectRef,

    -- * Freshness
    MemoryDecisionToken,
    mkMemoryDecisionToken,
    memoryDecisionTokenText,
    MemoryFreshness (..),
    atLeastAsFresh,

    -- * What an authorization seam answers
    MemoryDecisionOutcome (..),
    MemoryDecision (..),

    -- * Why access was refused
    MemoryAccessDenial (..),

    -- * The authenticated caller
    AuthenticatedSubject (..),

    -- * The seams Kioku does not implement
    PrincipalDirectory (..),
    PermissionChecker (..),
    MemoryContextProvider (..),
    assumeAuthorizedContextProvider,

    -- * The authorized decision
    MemoryAccessContext,
    memoryContextSpace,
    memoryContextActor,
    memoryContextPermissions,
    memoryContextDecisionToken,
    memoryContextAllows,
    memoryContextFreshness,
    memoryContextRecordedActor,
    assumeAuthorizedMemoryContext,
    authorizeMemoryAccess,

    -- * Applying an authorized decision
    underMemoryContext,
    inLegacyMemorySpaceOnly,
  )
where

import Data.List.NonEmpty qualified as NonEmpty
import Data.Set qualified as Set
import Kioku.Api.Access.Internal
import Kioku.Prelude

-- | Gate an operation on the permission, space, and actor already captured by a context.
--
-- The three error constructors keep this policy independent of any caller's error vocabulary.
-- Permission is deliberately checked first so an unauthorized caller cannot use later mismatch
-- errors to inspect the context's space or actor.
underMemoryContext ::
  (Applicative f) =>
  (MemoryPermission -> err) ->
  (MemorySpaceId -> MemorySpaceId -> err) ->
  (RecordedPrincipal -> RecordedPrincipal -> err) ->
  MemoryAccessContext ->
  MemoryPermission ->
  MemorySpaceId ->
  RecordedPrincipal ->
  f (Either err a) ->
  f (Either err a)
underMemoryContext permissionError spaceError actorError context permission space actor run
  | not (memoryContextAllows permission context) = pure (Left (permissionError permission))
  | space /= authorizedSpace = pure (Left (spaceError space authorizedSpace))
  | actor /= authorizedActor = pure (Left (actorError actor authorizedActor))
  | otherwise = run
  where
    authorizedSpace = memoryContextSpace context
    authorizedActor = memoryContextRecordedActor context

-- | Confine a deprecated compatibility operation to the explicit legacy memory space.
inLegacyMemorySpaceOnly ::
  (Applicative f) =>
  (MemorySpaceId -> MemorySpaceId -> err) ->
  MemorySpaceId ->
  f (Either err a) ->
  f (Either err a)
inLegacyMemorySpaceOnly spaceError space run
  | space /= legacyMemorySpaceId = pure (Left (spaceError space legacyMemorySpaceId))
  | otherwise = run

-- | Run the three gates for one memory space and a set of requested actions, and mint a
-- 'MemoryAccessContext' only if every one of them passes.
--
-- The order is fixed and the failures stay distinct. A missing coarse scope, an unresolved
-- principal, a denial, and a conditional answer are four different 'MemoryAccessDenial'
-- constructors, and a caller must keep them apart all the way out: none of them may become a
-- successful recall that happens to return no rows. A caller cannot tell "you may not look here"
-- from "there is nothing here", and only one of those is worth acting on.
--
-- All requested permissions are checked, not just the first. A context that claimed five
-- permissions on the strength of one check would be exactly the confused-deputy bug the whole
-- boundary exists to prevent.
--
-- The @freshness@ argument is what a caller passes after writing a grant or a membership: hand
-- back the 'MemoryDecisionToken' from the write (or from a previous decision, via
-- 'memoryContextFreshness') and the check is guaranteed to observe it. Without it a replica that
-- has not caught up can deny a permission that already exists. The minted context carries the
-- token of the last check it ran, so a follow-up read can chain from it.
--
-- A 'MemoryConditional' answer is treated as a refusal. The relationship exists but is gated on
-- context this request did not supply, and quietly promoting that to an allow is how a
-- time-limited grant becomes a permanent one.
authorizeMemoryAccess ::
  (Monad m) =>
  MemoryAuthorizationBinding ->
  PrincipalDirectory m ->
  PermissionChecker m ->
  MemoryFreshness ->
  AuthenticatedSubject ->
  MemorySpaceId ->
  NonEmpty MemoryPermission ->
  m (Either MemoryAccessDenial MemoryAccessContext)
authorizeMemoryAccess binding directory authorizer freshness subject spaceId requested =
  case coarseGate of
    Left denial -> pure (Left denial)
    Right () -> do
      resolved <- directory.resolvePrincipal subject.subjectId
      case resolved of
        Nothing -> pure (Left (MemoryPrincipalUnresolved subject.subjectId))
        Just principal -> checkAll principal Nothing permissions
  where
    permissions = NonEmpty.toList requested
    object = memorySpaceObjectRef binding spaceId

    -- Every requested action must clear its coarse claim before the directory is consulted, so
    -- an unauthorized caller cannot use Kioku as an oracle for which subjects exist.
    coarseGate =
      case filter scopeMissing permissions of
        [] -> Right ()
        permission : _ ->
          Left (MemoryCoarseScopeMissing (memoryPermissionBinding binding permission).coarseScope)

    scopeMissing permission =
      not (Set.member (memoryPermissionBinding binding permission).coarseScope subject.grantedScopes)

    checkAll principal latestToken = \case
      [] ->
        pure
          ( Right
              MemoryAccessContext
                { memorySpaceId = spaceId,
                  actor = MemoryActor principal,
                  grantedPermissions = Set.fromList permissions,
                  decisionToken = latestToken
                }
          )
      permission : rest -> do
        decision <-
          authorizer.checkMemoryPermission
            freshness
            principal
            (memoryPermissionBinding binding permission).objectPermission
            object
        case decision.outcome of
          MemoryDenied -> pure (Left (MemoryPermissionDenied spaceId permission))
          MemoryConditional obligations ->
            pure (Left (MemoryDecisionConditional spaceId permission obligations))
          MemoryAllowed -> checkAll principal (Just decision.checkedAt) rest
