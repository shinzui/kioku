-- | The memory-space access vocabulary, with every constructor exposed.
--
-- This module exists so that an adapter which has already obtained an authorization decision
-- by some other route can build a 'MemoryAccessContext' directly. Everything here is also
-- re-exported by "Kioku.Api.Access" /except/ the 'MemoryAccessContext' data constructor, which
-- is the one value in this vocabulary that asserts "a decision was made and it said yes".
--
-- Importing this module is a deliberate act. If you find yourself reaching for it because
-- 'Kioku.Api.Access.authorizeMemoryAccess' is inconvenient, use
-- 'Kioku.Api.Access.assumeAuthorizedMemoryContext' instead: it says the same thing, in one
-- grep-able name, and a reviewer can see it.
module Kioku.Api.Access.Internal
  ( -- * The isolation boundary
    MemorySpaceId (..),
    mkMemorySpaceId,
    memorySpaceIdText,
    legacyMemorySpaceId,

    -- * Principals
    PrincipalRef (..),
    mkPrincipalRef,
    principalRefText,
    MemoryActor (..),
    MemoryOwner (..),
    actorPrincipal,
    ownerPrincipal,

    -- * Principals as they appear on stored facts
    LegacyPrincipalRef (..),
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

    -- * Naming the authorization object (owned by the schema owner, not by Kioku)
    MemoryObjectType (..),
    mkMemoryObjectType,
    memoryObjectTypeText,
    MemoryPermissionName (..),
    mkMemoryPermissionName,
    memoryPermissionNameText,
    MemoryCoarseScope (..),
    mkMemoryCoarseScope,
    memoryCoarseScopeText,
    MemoryObjectRef (..),
    memoryObjectRefText,
    MemoryPermissionBinding (..),
    MemoryAuthorizationBinding (..),
    mkMemoryAuthorizationBinding,
    memoryPermissionBinding,
    memorySpaceObjectRef,

    -- * Freshness
    MemoryDecisionToken (..),
    mkMemoryDecisionToken,
    memoryDecisionTokenText,
    MemoryFreshness (..),
    atLeastAsFresh,

    -- * What an authorization port answers
    MemoryDecisionOutcome (..),
    MemoryDecision (..),

    -- * Why access was refused
    MemoryAccessDenial (..),

    -- * The authenticated caller, before any space-specific work
    AuthenticatedSubject (..),

    -- * The seams Kioku does not implement
    PrincipalDirectory (..),
    PermissionChecker (..),
    MemoryContextProvider (..),
    assumeAuthorizedContextProvider,

    -- * The authorized decision
    MemoryAccessContext (..),
    memoryContextSpace,
    memoryContextActor,
    memoryContextPermissions,
    memoryContextDecisionToken,
    memoryContextAllows,
    memoryContextFreshness,
    memoryContextRecordedActor,
    assumeAuthorizedMemoryContext,
  )
where

import Data.Aeson (withText)
import Data.Char qualified as Char
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Kioku.Prelude

-- | The outer isolation boundary: everything Kioku stores belongs to exactly one memory space,
-- and a caller authorized for one space is never thereby authorized for another.
--
-- This is deliberately /not/ a principal id. A person or a team can own or reach many spaces,
-- and "who may touch this space" is a relationship the authorization service answers, not a
-- property of the identifier. It is also deliberately opaque text rather than a Kioku-minted
-- TypeID: a host may create spaces in some other system entirely, and Kioku's job is to carry
-- whatever identifier that owner issues, not to mint one.
--
-- Compare with 'Kioku.Api.Scope.Namespace', which it does not replace. A namespace organizes
-- memories inside one deployment (@rei@, @mori@, @shikigami@); a memory space isolates them.
-- Two hosts sharing a database are separated by namespace; two tenants who must never see each
-- other's data are separated by memory space.
newtype MemorySpaceId = MemorySpaceId Text
  deriving stock (Eq, Ord, Show, Generic)

-- | Validating constructor. A space id becomes an authorization object id, an indexed database
-- column, and part of a rendered object reference, so it must not contain the characters those
-- encodings give meaning to: @%@, @\/@ and @:@ (reserved by
-- 'Kioku.Api.Scope.mkNamespace' and by the scope-identity encoding) and @#@ (which separates an
-- object from a relation in a relationship tuple). Whitespace and control characters are
-- rejected too — no legitimate identifier contains them, and they corrupt logs and query plans.
mkMemorySpaceId :: Text -> Either Text MemorySpaceId
mkMemorySpaceId = fmap MemorySpaceId . validateOpaqueId "memory space id" reservedRefChars

memorySpaceIdText :: MemorySpaceId -> Text
memorySpaceIdText (MemorySpaceId value) = value

-- | The single explicit space that data written before memory spaces existed is backfilled into.
--
-- The important word is /explicit/. It would be simpler to let a missing space mean "visible
-- everywhere", and that is exactly the mistake this constant exists to prevent: absence of a
-- partition must never read as unrestricted access. An upgraded single-space deployment keeps
-- its old behaviour because all of its rows land in this one space — not because unpartitioned
-- rows are special.
legacyMemorySpaceId :: MemorySpaceId
legacyMemorySpaceId = MemorySpaceId "kioku_legacy"

-- | A principal identifier issued by whatever directory the host uses, carried verbatim.
--
-- The wire form is exactly that directory's rendered form — @person_01h9x…@, @team_01h9x…@,
-- @agent_01h9x…@, @service_01h9x…@, @org_01h9x…@ and so on. Kioku stores it, compares it by
-- string equality, and does nothing else with it. In particular it never splits the prefix off
-- to learn the principal's kind, and it holds no profile, handle, membership, or lifecycle
-- state: a paused agent, a departed person, and a renamed team are all the directory's business,
-- and they reach Kioku as a subject that no longer resolves.
newtype PrincipalRef = PrincipalRef Text
  deriving stock (Eq, Ord, Show, Generic)

-- | Validating constructor. This is edge hygiene, not a directory parser: it rejects the empty
-- string, whitespace, control characters, and the @:@ and @#@ that a relationship tuple gives
-- meaning to. It deliberately does not check the prefix against a list of kinds — that list
-- belongs to the directory, and duplicating it here would fork it on the day it grows.
mkPrincipalRef :: Text -> Either Text PrincipalRef
mkPrincipalRef = fmap PrincipalRef . validateOpaqueId "principal reference" tupleRefChars

principalRefText :: PrincipalRef -> Text
principalRefText (PrincipalRef value) = value

-- | The principal responsible for an action: whoever the request was authorized as.
newtype MemoryActor = MemoryActor PrincipalRef
  deriving stock (Eq, Ord, Show, Generic)

-- | The principal a memory belongs to, where that differs from the actor.
--
-- An agent recording on a person's behalf is the motivating case: the actor is the agent, the
-- owner is the person, and later retention or deletion questions are asked about the owner.
newtype MemoryOwner = MemoryOwner PrincipalRef
  deriving stock (Eq, Ord, Show, Generic)

actorPrincipal :: MemoryActor -> PrincipalRef
actorPrincipal (MemoryActor value) = value

ownerPrincipal :: MemoryOwner -> PrincipalRef
ownerPrincipal (MemoryOwner value) = value

-- | A free-text agent label from before canonical principals existed, carried verbatim.
--
-- Kioku's events used to record an @agentId@ that was whatever string the host felt like
-- sending: @rei@, @demo-agent@, @claude@. That is not a principal — nobody issued it, nobody
-- can resolve it, and two hosts can pick the same one — so it must never be laundered into a
-- 'PrincipalRef' by pasting a kind prefix onto it. It is kept exactly as it was written and
-- marked as legacy wherever it appears.
--
-- The constructor is deliberately total and validates nothing. This value only ever comes from
-- data that is already on disk, and a validating constructor here would mean a historical event
-- that fails to decode — which is to say, an aggregate that can no longer be rebuilt.
newtype LegacyPrincipalRef = LegacyPrincipalRef Text
  deriving stock (Eq, Ord, Show, Generic)

legacyPrincipalRef :: Text -> LegacyPrincipalRef
legacyPrincipalRef = LegacyPrincipalRef

legacyPrincipalRefText :: LegacyPrincipalRef -> Text
legacyPrincipalRefText (LegacyPrincipalRef value) = value

-- | Who a stored fact says acted, as far as the event stream knows.
--
-- Three cases, and the last two exist because history is not uniform. Everything written through
-- the memory-space API names a real principal. Events written before it carry a legacy agent
-- label, or — for the many events that never recorded an agent at all, such as archiving a
-- memory or completing a session — nothing.
--
-- 'UnattributedPrincipal' is the honest answer for that last group. The alternative is inventing
-- an actor for a fact that did not record one, which would put a fabricated identity into an
-- audit trail.
data RecordedPrincipal
  = -- | a principal a directory issued and vouched for
    KnownPrincipal !PrincipalRef
  | -- | a pre-memory-space free-text agent label, marked as such
    LegacyPrincipal !LegacyPrincipalRef
  | -- | a pre-memory-space event that recorded no actor
    UnattributedPrincipal
  deriving stock (Eq, Ord, Show, Generic)

-- | The canonical text rendering, which is also the wire form.
--
-- The two non-canonical cases are spelled with a @kioku:@ prefix, and that is unambiguous rather
-- than merely unlikely: 'mkPrincipalRef' rejects @:@ outright, so no principal a directory can
-- issue is spellable as either marker. Round-tripping is exact even for a legacy label that
-- itself begins with @kioku:legacy:@, because only the first marker is stripped.
recordedPrincipalText :: RecordedPrincipal -> Text
recordedPrincipalText = \case
  KnownPrincipal principal -> principalRefText principal
  LegacyPrincipal legacy -> legacyPrincipalMarker <> legacyPrincipalRefText legacy
  UnattributedPrincipal -> unattributedPrincipalMarker

-- | Parse the rendering above. An unrecognized @kioku:@ form is an error rather than a legacy
-- label, so a marker added by a later version fails loudly here instead of being silently
-- demoted to free text.
parseRecordedPrincipal :: Text -> Either Text RecordedPrincipal
parseRecordedPrincipal value
  | value == unattributedPrincipalMarker = Right UnattributedPrincipal
  | Just legacy <- Text.stripPrefix legacyPrincipalMarker value =
      Right (LegacyPrincipal (LegacyPrincipalRef legacy))
  | Just unknown <- Text.stripPrefix kiokuPrincipalMarker value =
      Left ("unknown kioku principal marker: " <> unknown)
  | otherwise = KnownPrincipal <$> mkPrincipalRef value

kiokuPrincipalMarker :: Text
kiokuPrincipalMarker = "kioku:"

legacyPrincipalMarker :: Text
legacyPrincipalMarker = kiokuPrincipalMarker <> "legacy:"

unattributedPrincipalMarker :: Text
unattributedPrincipalMarker = kiokuPrincipalMarker <> "unattributed"

-- | What a caller wants to do to a memory space, in Kioku's own words.
--
-- These name Kioku's operations, not the authorization service's schema. The mapping from one
-- to the other is a 'MemoryAuthorizationBinding' the host supplies, because the names on the
-- other side belong to whoever owns that schema.
data MemoryPermission
  = -- | recall, scene reads, persona reads — anything that returns stored memory
    MemoryRead
  | -- | record a memory, start a session, append a turn
    MemoryRecord
  | -- | run distillation, which reads evidence and writes derived memory
    MemoryDistill
  | -- | forget, retire, or otherwise remove memory
    MemoryForget
  | -- | administer the space itself, including sharing it with another principal
    MemoryAdmin
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

-- | Every permission, in declaration order. Used to prove a binding is total.
allMemoryPermissions :: [MemoryPermission]
allMemoryPermissions = [minBound .. maxBound]

-- | The stable wire spelling. Changing one of these is a breaking change to stored events.
memoryPermissionText :: MemoryPermission -> Text
memoryPermissionText = \case
  MemoryRead -> "read"
  MemoryRecord -> "record"
  MemoryDistill -> "distill"
  MemoryForget -> "forget"
  MemoryAdmin -> "admin"

parseMemoryPermission :: Text -> Either Text MemoryPermission
parseMemoryPermission = \case
  "read" -> Right MemoryRead
  "record" -> Right MemoryRecord
  "distill" -> Right MemoryDistill
  "forget" -> Right MemoryForget
  "admin" -> Right MemoryAdmin
  other -> Left ("unknown memory permission: " <> other)

-- | The object type a memory space is represented by in the authorization schema.
--
-- Kioku does not choose this string, because Kioku does not own that schema. The host passes it
-- in through 'mkMemoryAuthorizationBinding'.
newtype MemoryObjectType = MemoryObjectType Text
  deriving stock (Eq, Ord, Show, Generic)

mkMemoryObjectType :: Text -> Either Text MemoryObjectType
mkMemoryObjectType = fmap MemoryObjectType . validateOpaqueId "object type" tupleRefChars

memoryObjectTypeText :: MemoryObjectType -> Text
memoryObjectTypeText (MemoryObjectType value) = value

-- | The permission (relation) name asked of the authorization schema. Also not Kioku's to
-- choose — see 'MemoryObjectType'.
newtype MemoryPermissionName = MemoryPermissionName Text
  deriving stock (Eq, Ord, Show, Generic)

mkMemoryPermissionName :: Text -> Either Text MemoryPermissionName
mkMemoryPermissionName = fmap MemoryPermissionName . validateOpaqueId "permission name" tupleRefChars

memoryPermissionNameText :: MemoryPermissionName -> Text
memoryPermissionNameText (MemoryPermissionName value) = value

-- | A coarse claim the authentication service must have minted onto the caller's credential
-- before Kioku will do any space-specific work — an OAuth-style scope such as @kioku:read@.
--
-- It is coarse on purpose: it says "this credential is allowed to talk to Kioku at all about
-- reads", never "…about this space". Passing this gate is necessary and nowhere near sufficient.
newtype MemoryCoarseScope = MemoryCoarseScope Text
  deriving stock (Eq, Ord, Show, Generic)

mkMemoryCoarseScope :: Text -> Either Text MemoryCoarseScope
mkMemoryCoarseScope = fmap MemoryCoarseScope . validateOpaqueId "coarse scope" ""

memoryCoarseScopeText :: MemoryCoarseScope -> Text
memoryCoarseScopeText (MemoryCoarseScope value) = value

-- | A concrete object in the authorization schema: a type and an id within that type.
data MemoryObjectRef = MemoryObjectRef
  { objectType :: !MemoryObjectType,
    objectId :: !Text
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | The canonical @type:id@ rendering. Both halves reject @:@ and @#@ at construction, so this
-- rendering is injective: two different object references can never produce the same text.
memoryObjectRefText :: MemoryObjectRef -> Text
memoryObjectRefText ref = memoryObjectTypeText ref.objectType <> ":" <> ref.objectId

-- | How one Kioku action is expressed on the other side of the boundary.
data MemoryPermissionBinding = MemoryPermissionBinding
  { -- | the credential claim the authentication service must have minted
    coarseScope :: !MemoryCoarseScope,
    -- | the permission asked of the authorization service
    objectPermission :: !MemoryPermissionName
  }
  deriving stock (Eq, Ord, Show, Generic)

-- | The complete translation from Kioku's actions to a host's identity stack.
--
-- Kioku ships no default value for this, and that absence is the design. The object type and
-- permission names live in a schema Kioku does not own and which, at the time of writing, does
-- not yet contain a memory-space object at all. Inventing plausible names here would let Kioku
-- claim a compatibility it cannot demonstrate; requiring the host to supply them makes the
-- dependency visible at the call site.
data MemoryAuthorizationBinding = MemoryAuthorizationBinding
  { spaceObjectType :: !MemoryObjectType,
    permissionBindings :: !(Map MemoryPermission MemoryPermissionBinding)
  }
  deriving stock (Eq, Show, Generic)

-- | Build a binding, refusing anything partial.
--
-- Every one of 'allMemoryPermissions' must be present. A binding with a hole in it would fail
-- at the moment some rarely-exercised path — forgetting, say — first ran in production, which is
-- the worst possible time to discover it. Making construction total makes
-- 'memoryPermissionBinding' total.
mkMemoryAuthorizationBinding ::
  MemoryObjectType ->
  [(MemoryPermission, MemoryPermissionBinding)] ->
  Either Text MemoryAuthorizationBinding
mkMemoryAuthorizationBinding spaceObjectType entries
  | not (null missing) =
      Left
        ( "authorization binding is missing: "
            <> Text.intercalate ", " (fmap memoryPermissionText missing)
        )
  | otherwise = Right MemoryAuthorizationBinding {spaceObjectType, permissionBindings}
  where
    permissionBindings = Map.fromList entries
    missing = filter (`Map.notMember` permissionBindings) allMemoryPermissions

-- | Total, because 'mkMemoryAuthorizationBinding' rejects incomplete bindings.
memoryPermissionBinding :: MemoryAuthorizationBinding -> MemoryPermission -> MemoryPermissionBinding
memoryPermissionBinding binding permission =
  case Map.lookup permission binding.permissionBindings of
    Just found -> found
    Nothing ->
      -- Unreachable: the smart constructor is the only way to build a binding and it requires
      -- every permission. Kept as an error rather than a default so a future constructor that
      -- forgets the check fails loudly instead of silently authorizing against the wrong name.
      error
        ( "kioku: incomplete MemoryAuthorizationBinding, missing "
            <> Text.unpack (memoryPermissionText permission)
        )

-- | The authorization object for a memory space under a given binding.
--
-- Note what makes two spaces distinct here: the space id, and nothing else. The same namespace
-- and scope in two different spaces produce two different object references, so a decision about
-- one can never be replayed as a decision about the other.
memorySpaceObjectRef :: MemoryAuthorizationBinding -> MemorySpaceId -> MemoryObjectRef
memorySpaceObjectRef binding spaceId =
  MemoryObjectRef
    { objectType = binding.spaceObjectType,
      objectId = memorySpaceIdText spaceId
    }

-- | An opaque token naming the revision an authorization decision was made at.
--
-- The authorization service mints it; Kioku only carries it. Presenting it on a later call is
-- what makes that call observe at least everything the first one did — the fix for the case
-- where a grant is written, the caller immediately retries, and a replica that has not caught up
-- answers "denied" about a permission that now exists.
newtype MemoryDecisionToken = MemoryDecisionToken Text
  deriving stock (Eq, Ord, Show, Generic)

-- | Wrap a token minted elsewhere. The only rule Kioku imposes is that it is not empty: the
-- encoding belongs entirely to whoever issued it, and an adapter that invented structure here
-- would break the first time that issuer changed its own.
mkMemoryDecisionToken :: Text -> Either Text MemoryDecisionToken
mkMemoryDecisionToken value
  | Text.null value = Left "decision token must not be empty"
  | otherwise = Right (MemoryDecisionToken value)

memoryDecisionTokenText :: MemoryDecisionToken -> Text
memoryDecisionTokenText (MemoryDecisionToken value) = value

-- | How fresh an authorization read has to be.
--
-- Two cases, not four. The authorization service offers more (an exact snapshot, a fully
-- consistent head read), but Kioku only ever needs "whatever is cheap" and "at least as fresh as
-- this decision", and offering the others would invite a caller to pin a snapshot that ages.
data MemoryFreshness
  = -- | cheapest available; may be slightly stale
    MemoryFreshnessDefault
  | -- | at least as fresh as the named decision
    MemoryFreshnessAtLeast !MemoryDecisionToken
  deriving stock (Eq, Show, Generic)

-- | Request a read at least as fresh as a decision already observed. This is what a caller does
-- after a membership or grant write, and what a caller does when retrying a denial that a
-- just-written grant should have turned into an allow.
atLeastAsFresh :: MemoryDecisionToken -> MemoryFreshness
atLeastAsFresh = MemoryFreshnessAtLeast

-- | What an authorization check can answer.
--
-- @MemoryConditional@ is the one that catches people out. It means the relationship exists but
-- is gated on context the request did not supply, and it is /not/ an allow. Treating it as one
-- is how a time-limited or condition-limited grant becomes a permanent one.
data MemoryDecisionOutcome
  = MemoryAllowed
  | MemoryDenied
  | -- | names of the unmet conditions
    MemoryConditional ![Text]
  deriving stock (Eq, Show, Generic)

-- | A decision, and the revision it was decided at.
data MemoryDecision = MemoryDecision
  { outcome :: !MemoryDecisionOutcome,
    checkedAt :: !MemoryDecisionToken
  }
  deriving stock (Eq, Show, Generic)

-- | Why a request was refused. These stay distinct all the way to the caller.
--
-- Collapsing them is tempting and wrong. In particular none of them may be turned into a
-- successful recall that happens to return no rows: a caller cannot distinguish "you may not
-- look here" from "there is nothing here", and only one of those is worth retrying with
-- different credentials.
data MemoryAccessDenial
  = -- | the credential lacks the coarse claim for this action
    MemoryCoarseScopeMissing !MemoryCoarseScope
  | -- | the authenticated subject maps to no principal: unlinked, departed, or paused
    MemoryPrincipalUnresolved !Text
  | -- | the authorization service said no for this space and action
    MemoryPermissionDenied !MemorySpaceId !MemoryPermission
  | -- | allowed only under conditions the request did not satisfy
    MemoryDecisionConditional !MemorySpaceId !MemoryPermission ![Text]
  deriving stock (Eq, Show, Generic)

-- | What the authentication service established: who is calling, and what coarse claims they
-- carry. The subject is the credential's subject identifier, which is /not/ a principal
-- reference — resolving one to the other is the directory's job.
data AuthenticatedSubject = AuthenticatedSubject
  { subjectId :: !Text,
    grantedScopes :: !(Set MemoryCoarseScope)
  }
  deriving stock (Eq, Show, Generic)

-- | The directory seam: turn an authenticated credential subject into a principal reference.
--
-- 'Nothing' covers every reason a subject has no usable principal — never linked, since removed,
-- or an agent the directory has paused. Kioku deliberately cannot tell those apart, because
-- distinguishing them would mean holding directory state it has no business holding.
--
-- This is a record of plain functions, not an interface to any particular service. A host wires
-- it to whatever it already has; a host with no directory at all does not build one, and uses
-- 'assumeAuthorizedMemoryContext' instead.
newtype PrincipalDirectory m = PrincipalDirectory
  { resolvePrincipal :: Text -> m (Maybe PrincipalRef)
  }

-- | The authorization seam: may this principal do this to this object, read at this freshness?
newtype PermissionChecker m = PermissionChecker
  { checkMemoryPermission ::
      MemoryFreshness ->
      PrincipalRef ->
      MemoryPermissionName ->
      MemoryObjectRef ->
      m MemoryDecision
  }

-- | How a process that /discovers/ its own work obtains authorization for it.
--
-- Interactive callers arrive holding a context. A background worker does not: it claims a due
-- timer or a queued task, reads which memory space that work belongs to, and only then needs a
-- decision about that space. This is the seam that lets it ask for one without inventing it.
--
-- A trusted in-process host uses 'assumeAuthorizedContextProvider'. A host behind a service
-- boundary wires this to its own authorizer, typically a partially applied
-- 'Kioku.Api.Access.authorizeMemoryAccess' over the credential the worker runs under.
newtype MemoryContextProvider m = MemoryContextProvider
  { contextForSpace :: MemorySpaceId -> m (Either MemoryAccessDenial MemoryAccessContext)
  }

-- | The embedded-host provider: assume authorization for every space, as one named actor.
--
-- Named to be conspicuous for the same reason 'assumeAuthorizedMemoryContext' is. A worker
-- wired to this one will happily act in any space a timer names.
assumeAuthorizedContextProvider :: (Applicative m) => MemoryActor -> MemoryContextProvider m
assumeAuthorizedContextProvider actor =
  MemoryContextProvider (pure . Right . (`assumeAuthorizedMemoryContext` actor))

-- | The proof that an authorization decision was made, carried into Kioku's core.
--
-- Holding one of these means the three gates have already been passed for the listed
-- permissions on the named space. Kioku's core does not re-derive it, cannot re-derive it, and
-- must not proceed without it.
--
-- The data constructor is not exported from "Kioku.Api.Access" precisely because constructing
-- one is an assertion. Use 'Kioku.Api.Access.authorizeMemoryAccess' to earn one, or
-- 'assumeAuthorizedMemoryContext' to state plainly that you are not checking.
data MemoryAccessContext = MemoryAccessContext
  { memorySpaceId :: !MemorySpaceId,
    actor :: !MemoryActor,
    grantedPermissions :: !(Set MemoryPermission),
    decisionToken :: !(Maybe MemoryDecisionToken)
  }
  deriving stock (Eq, Show, Generic)

-- Read-only accessors rather than exported field selectors.
--
-- Exporting the fields would export record-update syntax with them, and
-- @context { grantedPermissions = everything }@ widens an authorized decision without ever
-- naming the constructor — which is the exact hole keeping the constructor internal is meant to
-- close. Reading is safe; rewriting is not.

memoryContextSpace :: MemoryAccessContext -> MemorySpaceId
memoryContextSpace context = context.memorySpaceId

memoryContextActor :: MemoryAccessContext -> MemoryActor
memoryContextActor context = context.actor

memoryContextPermissions :: MemoryAccessContext -> Set MemoryPermission
memoryContextPermissions context = context.grantedPermissions

-- | The revision this context's decision was made at, if a decision was actually made.
memoryContextDecisionToken :: MemoryAccessContext -> Maybe MemoryDecisionToken
memoryContextDecisionToken context = context.decisionToken

-- | Was this particular action authorized? A context authorizes exactly the permissions it was
-- minted for, so a read context cannot be spent on a write.
memoryContextAllows :: MemoryPermission -> MemoryAccessContext -> Bool
memoryContextAllows permission context =
  Set.member permission context.grantedPermissions

-- | The actor to record on a fact written under this context.
--
-- Every write Kioku accepts through the memory-space API is attributed to the principal the
-- context was minted for, never to one the caller names separately. That is what stops a caller
-- authorized as one principal from writing an event claiming another one acted.
memoryContextRecordedActor :: MemoryAccessContext -> RecordedPrincipal
memoryContextRecordedActor context =
  KnownPrincipal (actorPrincipal context.actor)

-- | The freshness a follow-up authorization read should use, given what this context already
-- observed. This is the forwarding rule: a context minted from a real decision pins later reads
-- to at least that revision, and an assumed context pins nothing because it observed nothing.
memoryContextFreshness :: MemoryAccessContext -> MemoryFreshness
memoryContextFreshness context =
  maybe MemoryFreshnessDefault MemoryFreshnessAtLeast context.decisionToken

-- | Build a context without consulting anyone: the embedded-host escape hatch.
--
-- This is for a single-tenant, in-process host that owns its own database and has no
-- authentication boundary — a CLI, a test, a library embedded in an application that has already
-- authorized the user by other means. It grants every permission on the named space and carries
-- no decision token, because no decision was made.
--
-- It is named the way it is so that it cannot be used by accident and cannot be missed in
-- review. A service that reaches for this is shipping an unauthenticated endpoint.
assumeAuthorizedMemoryContext :: MemorySpaceId -> MemoryActor -> MemoryAccessContext
assumeAuthorizedMemoryContext memorySpaceId actor =
  MemoryAccessContext
    { memorySpaceId,
      actor,
      grantedPermissions = Set.fromList allMemoryPermissions,
      decisionToken = Nothing
    }

-- Wire instances. The leaf identifiers cross the wire as plain strings and decode through their
-- validating constructors, so a decoded value obeys the same rules as a constructed one.
--
-- 'MemoryAccessContext' has none, deliberately. It is a decision, not a document: giving it a
-- 'FromJSON' instance would let an authorized context be written down, stored, and replayed
-- later against a grant that has since been revoked.

instance ToJSON MemorySpaceId where
  toJSON = toJSON . memorySpaceIdText

instance FromJSON MemorySpaceId where
  parseJSON = withText "MemorySpaceId" (orFail . mkMemorySpaceId)

instance ToJSON PrincipalRef where
  toJSON = toJSON . principalRefText

instance FromJSON PrincipalRef where
  parseJSON = withText "PrincipalRef" (orFail . mkPrincipalRef)

instance ToJSON RecordedPrincipal where
  toJSON = toJSON . recordedPrincipalText

instance FromJSON RecordedPrincipal where
  parseJSON = withText "RecordedPrincipal" (orFail . parseRecordedPrincipal)

instance ToJSON MemoryActor where
  toJSON = toJSON . actorPrincipal

instance FromJSON MemoryActor where
  parseJSON = fmap MemoryActor . parseJSON

instance ToJSON MemoryOwner where
  toJSON = toJSON . ownerPrincipal

instance FromJSON MemoryOwner where
  parseJSON = fmap MemoryOwner . parseJSON

instance ToJSON MemoryPermission where
  toJSON = toJSON . memoryPermissionText

instance FromJSON MemoryPermission where
  parseJSON = withText "MemoryPermission" (orFail . parseMemoryPermission)

instance ToJSON MemoryDecisionToken where
  toJSON = toJSON . memoryDecisionTokenText

instance FromJSON MemoryDecisionToken where
  parseJSON = withText "MemoryDecisionToken" (orFail . mkMemoryDecisionToken)

orFail :: (MonadFail m) => Either Text a -> m a
orFail = either (fail . Text.unpack) pure

-- | Characters a rendered object reference gives meaning to: @:@ separates type from id and @#@
-- separates an object from a relation.
tupleRefChars :: Text
tupleRefChars = ":#"

-- | Everything 'tupleRefChars' reserves, plus the characters Kioku's own scope-identity encoding
-- reserves (see 'Kioku.Api.Scope.mkNamespace').
reservedRefChars :: Text
reservedRefChars = tupleRefChars <> "%/"

-- | Shared edge validation for the opaque identifiers Kioku carries but does not own: reject the
-- empty string, anything unprintable, and any character the caller's own encodings reserve.
validateOpaqueId :: Text -> Text -> Text -> Either Text Text
validateOpaqueId label reserved value
  | Text.null value = Left (label <> " must not be empty")
  | Text.length value > maxOpaqueIdLength =
      Left (label <> " must be at most " <> Text.pack (show maxOpaqueIdLength) <> " characters")
  | Just offending <- Text.find (\c -> Char.isSpace c || Char.isControl c) value =
      Left (label <> " must not contain whitespace or control characters: " <> Text.pack (show offending))
  | Just offending <- Text.find (`Text.elem` reserved) value =
      Left (label <> " must not contain " <> Text.singleton offending <> ": " <> value)
  | otherwise = Right value

-- | A bound generous enough for any rendered TypeID or scope name and small enough to keep a
-- hostile caller from turning an identifier column into a blob.
maxOpaqueIdLength :: Int
maxOpaqueIdLength = 128
