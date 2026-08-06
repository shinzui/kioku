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
module Kioku.Partition
  ( parsePartitionSpace,
    parseRecordedActor,
    parseRecordedActorFromAgent,
    parseRecordedOwner,
  )
where

import Data.Aeson.Types (Object, Parser, (.!=), (.:), (.:?))
import Kioku.Api.Access
  ( LegacyPrincipalRef,
    MemorySpaceId,
    PrincipalRef,
    RecordedPrincipal (..),
    legacyMemorySpaceId,
    legacyPrincipalRef,
  )
import Kioku.Prelude

-- | The memory space a payload belongs to, defaulting an older payload into the legacy space.
parsePartitionSpace :: Object -> Parser MemorySpaceId
parsePartitionSpace o = o .:? "memorySpaceId" .!= legacyMemorySpaceId

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
