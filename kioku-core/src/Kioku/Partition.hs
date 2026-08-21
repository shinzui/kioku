-- | Reading the memory-space partition off events that predate it.
--
-- Every command and event Kioku writes now names the memory space it belongs to and the
-- principal that acted. Events already on disk name neither, and they must keep decoding
-- forever: an event that stops parsing is an aggregate that can no longer be rebuilt and a
-- projection that can no longer be replayed.
--
-- These helpers are the single place that decides what an older payload means, so that no
-- module invents its own default. The rules are:
--
-- * A payload with no @memorySpaceId@ belongs to 'legacyMemorySpaceId'. Absence of a partition
--   never means "visible everywhere" — see @docs\/adr\/legacy-data-lands-in-one-explicit-space.md@.
-- * A payload with no @actorPrincipal@ but with the old free-text @agentId@ is attributed to
--   that label, marked as legacy. It is never rewritten into a directory-issued principal id.
-- * A payload with neither is 'UnattributedPrincipal'. Most pre-partition events — archiving a
--   memory, completing a session, recording a turn — genuinely recorded no actor, and inventing
--   one would put a fabricated identity into an audit trail.
--
-- Encoding always writes the new form. There is no path that emits a payload without a space.
--
-- The same module owns how a memory space is written down in PostgreSQL, for the same reason:
-- @memory_space_id@ is a plain @text@ column, and exactly one pair of functions turns a
-- 'MemorySpaceId' into it and back.
module Kioku.Partition
  ( PartitionedScope (..),
    partitionedScope,
    partitionedScopeEncoder,
    parseOptionalPartitionSpace,
    parsePartitionSpace,
    parseRecordedActor,
    parseRecordedActorFromAgent,
    parseRecordedOwner,
    memorySpaceColumn,
    memorySpaceParam,
  )
where

import Data.Aeson.Types (Object, Parser, (.!=), (.:), (.:?))
import Data.Functor.Contravariant ((>$<))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Kioku.Api.Access
  ( LegacyPrincipalRef,
    MemorySpaceId,
    PrincipalRef,
    RecordedPrincipal (..),
    legacyMemorySpaceId,
    legacyPrincipalRef,
    memorySpaceIdText,
    mkMemorySpaceId,
  )
import Kioku.Api.Scope (MemoryScope, scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Prelude

-- | A scope lookup qualified by its memory space.
--
-- The record fixes the PostgreSQL parameter order used by every L2/L3 statement and makes the
-- partition impossible to transpose with the namespace beside it.
data PartitionedScope = PartitionedScope
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

-- | Qualify a public scope value with the memory space in which it is being queried.
partitionedScope :: MemorySpaceId -> MemoryScope -> PartitionedScope
partitionedScope memorySpaceId scope =
  PartitionedScope
    { memorySpaceId,
      namespace = scopeNamespaceText scope,
      scopeKind = scopeKindText scope,
      scopeRef = scopeRefText scope
    }

-- | Encode @memory_space_id@, namespace, scope kind, and scope reference as @$1@ through @$4@.
partitionedScopeEncoder :: E.Params PartitionedScope
partitionedScopeEncoder =
  ((\q -> q.memorySpaceId) >$< memorySpaceParam)
    <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\q -> q.scopeRef) >$< E.param (E.nullable E.text))

-- | The memory space a payload belongs to, defaulting an older payload into the legacy space.
parsePartitionSpace :: Object -> Parser MemorySpaceId
parsePartitionSpace o = o .:? "memorySpaceId" .!= legacyMemorySpaceId

-- | The memory space a payload explicitly names, without inventing one for diagnostics.
--
-- Action decoders use 'parsePartitionSpace' so native payloads written before partitioning keep
-- executing in the legacy space. Generic diagnostics have a different question: absent or
-- unreadable ownership is unknown rather than evidence that the payload named that space.
parseOptionalPartitionSpace :: Object -> Parser (Maybe MemorySpaceId)
parseOptionalPartitionSpace o = o .:? "memorySpaceId"

-- | The actor a payload records, for events that never carried an agent label.
parseRecordedActor :: Object -> Parser RecordedPrincipal
parseRecordedActor o = o .:? "actorPrincipal" .!= UnattributedPrincipal

-- | The actor a payload records, for events that carried the old free-text @agentId@.
--
-- The legacy label is kept verbatim and marked. Turning @demo-agent@ into @agent_demo-agent@
-- would manufacture an identifier no directory ever issued, and every later authorization
-- decision made against it would be a decision about a string somebody typed.
parseRecordedActorFromAgent :: Object -> Parser RecordedPrincipal
parseRecordedActorFromAgent o = do
  explicit <- o .:? "actorPrincipal"
  case explicit of
    Just actor -> pure actor
    Nothing -> legacyActor <$> o .: "agentId"
  where
    legacyActor :: Text -> RecordedPrincipal
    legacyActor = LegacyPrincipal . (legacyPrincipalRef :: Text -> LegacyPrincipalRef)

-- | The owning principal, which only writes made through the memory-space API can carry.
--
-- There is no legacy fallback and there must not be one: ownership did not exist before this
-- field did, so an older payload has no owner rather than an implied one.
parseRecordedOwner :: Object -> Parser (Maybe PrincipalRef)
parseRecordedOwner o = o .:? "ownerPrincipal"

-- | Decode a non-null @memory_space_id@ column.
--
-- It goes through 'mkMemorySpaceId' rather than being taken as raw text, so a row that somehow
-- holds a value no caller could have constructed — an empty string, something with a @:@ in it —
-- fails the read loudly instead of becoming a space id that compares equal to nothing.
memorySpaceColumn :: D.Row MemorySpaceId
memorySpaceColumn =
  D.column (D.nonNullable (D.refine mkMemorySpaceId D.text))

-- | Encode one @memory_space_id@ query parameter.
memorySpaceParam :: E.Params MemorySpaceId
memorySpaceParam =
  memorySpaceIdText >$< E.param (E.nonNullable E.text)
