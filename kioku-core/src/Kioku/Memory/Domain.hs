{-# LANGUAGE TemplateHaskell #-}
{-# OPTIONS_GHC -Wno-unused-top-binds #-}

module Kioku.Memory.Domain
  ( MemoryVertex (..),
    MemoryRegs,
    RecordMemoryData (..),
    SupersedeMemoryData (..),
    ArchiveMemoryData (..),
    UpdateMemoryTagsData (..),
    UpdateMemoryConfidenceData (..),
    MergeMemoryData (..),
    MemoryCommand (..),
    commandMemoryId,
    commandMemorySpaceId,
    MemoryRecordedData (..),
    MemorySupersededData (..),
    MemoryArchivedData (..),
    MemoryTagsUpdatedData (..),
    MemoryConfidenceUpdatedData (..),
    MemoryMergedData (..),
    MemoryEvent (..),
    eventMemoryId,
    eventMemorySpaceId,
    memoryTransducer,
  )
where

import Data.Aeson.Types (withObject, (.:), (.:?))
import Data.Set (Set)
import Keiki.Builder ((=:))
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer, (.==))
import Keiki.Generics (emptyRegFile)
import Keiki.Generics.TH (deriveAggregate)
import Kioku.Api.Access (MemorySpaceId, PrincipalRef, RecordedPrincipal)
import Kioku.Api.Scope (MemoryScope)
import Kioku.Api.Types (Confidence, MemoryType)
import Kioku.Id (MemoryId, SessionId)
import Kioku.Partition (parsePartitionSpace, parseRecordedActor, parseRecordedActorFromAgent, parseRecordedOwner)
import Kioku.Prelude

data MemoryVertex = NotCreated | Active | Superseded | Merged | Archived
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | The memory space this aggregate was created in, replayed from its @MemoryRecorded@ event.
--
-- It is aggregate state rather than a read-model lookup because that is what makes the
-- cross-space check survive a concurrency retry: keiro re-runs the edge against the post-conflict
-- state, so a command naming a different space is refused by the state machine itself and never
-- by a racy precheck. A memory is created in exactly one space and never moves.
type MemoryRegs = '[ '("memorySpaceId", MemorySpaceId)]

data RecordMemoryData = RecordMemoryData
  { memoryId :: !MemoryId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    ownerPrincipal :: !(Maybe PrincipalRef),
    agentId :: !Text,
    sessionId :: !(Maybe SessionId),
    scope :: !MemoryScope,
    memoryType :: !MemoryType,
    content :: !Text,
    priority :: !Int,
    confidence :: !Confidence,
    tags :: !(Set Text),
    supersedes :: !(Maybe MemoryId),
    recordedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data SupersedeMemoryData = SupersedeMemoryData
  { memoryId :: !MemoryId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    supersededBy :: !MemoryId,
    supersededAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data ArchiveMemoryData = ArchiveMemoryData
  { memoryId :: !MemoryId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    archivedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data UpdateMemoryTagsData = UpdateMemoryTagsData
  { memoryId :: !MemoryId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    tags :: !(Set Text),
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data UpdateMemoryConfidenceData = UpdateMemoryConfidenceData
  { memoryId :: !MemoryId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    confidence :: !Confidence,
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data MergeMemoryData = MergeMemoryData
  { memoryId :: !MemoryId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    mergedInto :: !MemoryId,
    mergedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data MemoryCommand
  = RecordMemory !RecordMemoryData
  | SupersedeMemory !SupersedeMemoryData
  | ArchiveMemory !ArchiveMemoryData
  | UpdateMemoryTags !UpdateMemoryTagsData
  | UpdateMemoryConfidence !UpdateMemoryConfidenceData
  | MergeMemory !MergeMemoryData
  deriving stock (Generic, Eq, Show)

commandMemoryId :: MemoryCommand -> MemoryId
commandMemoryId = \case
  RecordMemory d -> d.memoryId
  SupersedeMemory d -> d.memoryId
  ArchiveMemory d -> d.memoryId
  UpdateMemoryTags d -> d.memoryId
  UpdateMemoryConfidence d -> d.memoryId
  MergeMemory d -> d.memoryId

-- | The memory space a command claims to act in. Every command names one; the aggregate refuses
-- any that disagrees with the space the memory was created in.
commandMemorySpaceId :: MemoryCommand -> MemorySpaceId
commandMemorySpaceId = \case
  RecordMemory d -> d.memorySpaceId
  SupersedeMemory d -> d.memorySpaceId
  ArchiveMemory d -> d.memorySpaceId
  UpdateMemoryTags d -> d.memorySpaceId
  UpdateMemoryConfidence d -> d.memorySpaceId
  MergeMemory d -> d.memorySpaceId

-- | The @FromJSON@ instances below are hand-written for one reason: every payload already on
-- disk was written before memory spaces existed, and it has to keep decoding. 'Kioku.Partition'
-- owns what an older payload means; these instances only say which rule applies to which event.
--
-- @ToJSON@ stays derived, so encoding only ever emits the new form.
data MemoryRecordedData = MemoryRecordedData
  { memoryId :: !MemoryId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    ownerPrincipal :: !(Maybe PrincipalRef),
    agentId :: !Text,
    sessionId :: !(Maybe SessionId),
    scope :: !MemoryScope,
    memoryType :: !MemoryType,
    content :: !Text,
    priority :: !Int,
    confidence :: !Confidence,
    tags :: !(Set Text),
    supersedes :: !(Maybe MemoryId),
    recordedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

-- | The one memory event that carried an agent label, so the one whose legacy actor is a real
-- value rather than "unrecorded".
instance FromJSON MemoryRecordedData where
  parseJSON =
    withObject "MemoryRecordedData" \o ->
      MemoryRecordedData
        <$> o .: "memoryId"
        <*> parsePartitionSpace o
        <*> parseRecordedActorFromAgent o
        <*> parseRecordedOwner o
        <*> o .: "agentId"
        <*> o .:? "sessionId"
        <*> o .: "scope"
        <*> o .: "memoryType"
        <*> o .: "content"
        <*> o .: "priority"
        <*> o .: "confidence"
        <*> o .: "tags"
        <*> o .:? "supersedes"
        <*> o .: "recordedAt"

data MemorySupersededData = MemorySupersededData
  { memoryId :: !MemoryId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    supersededBy :: !MemoryId,
    supersededAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON MemorySupersededData where
  parseJSON =
    withObject "MemorySupersededData" \o ->
      MemorySupersededData
        <$> o .: "memoryId"
        <*> parsePartitionSpace o
        <*> parseRecordedActor o
        <*> o .: "supersededBy"
        <*> o .: "supersededAt"

data MemoryArchivedData = MemoryArchivedData
  { memoryId :: !MemoryId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    archivedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON MemoryArchivedData where
  parseJSON =
    withObject "MemoryArchivedData" \o ->
      MemoryArchivedData
        <$> o .: "memoryId"
        <*> parsePartitionSpace o
        <*> parseRecordedActor o
        <*> o .: "archivedAt"

data MemoryTagsUpdatedData = MemoryTagsUpdatedData
  { memoryId :: !MemoryId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    tags :: !(Set Text),
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON MemoryTagsUpdatedData where
  parseJSON =
    withObject "MemoryTagsUpdatedData" \o ->
      MemoryTagsUpdatedData
        <$> o .: "memoryId"
        <*> parsePartitionSpace o
        <*> parseRecordedActor o
        <*> o .: "tags"
        <*> o .: "updatedAt"

data MemoryConfidenceUpdatedData = MemoryConfidenceUpdatedData
  { memoryId :: !MemoryId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    confidence :: !Confidence,
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON MemoryConfidenceUpdatedData where
  parseJSON =
    withObject "MemoryConfidenceUpdatedData" \o ->
      MemoryConfidenceUpdatedData
        <$> o .: "memoryId"
        <*> parsePartitionSpace o
        <*> parseRecordedActor o
        <*> o .: "confidence"
        <*> o .: "updatedAt"

data MemoryMergedData = MemoryMergedData
  { memoryId :: !MemoryId,
    memorySpaceId :: !MemorySpaceId,
    actorPrincipal :: !RecordedPrincipal,
    mergedInto :: !MemoryId,
    mergedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON MemoryMergedData where
  parseJSON =
    withObject "MemoryMergedData" \o ->
      MemoryMergedData
        <$> o .: "memoryId"
        <*> parsePartitionSpace o
        <*> parseRecordedActor o
        <*> o .: "mergedInto"
        <*> o .: "mergedAt"

data MemoryEvent
  = MemoryRecorded !MemoryRecordedData
  | MemorySuperseded !MemorySupersededData
  | MemoryArchived !MemoryArchivedData
  | MemoryTagsUpdated !MemoryTagsUpdatedData
  | MemoryConfidenceUpdated !MemoryConfidenceUpdatedData
  | MemoryMerged !MemoryMergedData
  deriving stock (Generic, Eq, Show)

instance FromJSON MemoryEvent where
  parseJSON = genericParseJSON eventAesonOptions

instance ToJSON MemoryEvent where
  toJSON = genericToJSON eventAesonOptions

eventMemoryId :: MemoryEvent -> MemoryId
eventMemoryId = \case
  MemoryRecorded d -> d.memoryId
  MemorySuperseded d -> d.memoryId
  MemoryArchived d -> d.memoryId
  MemoryTagsUpdated d -> d.memoryId
  MemoryConfidenceUpdated d -> d.memoryId
  MemoryMerged d -> d.memoryId

-- | The memory space a stored event belongs to. Every event carries one, including every event
-- written before memory spaces existed: those decode into 'legacyMemorySpaceId'.
eventMemorySpaceId :: MemoryEvent -> MemorySpaceId
eventMemorySpaceId = \case
  MemoryRecorded d -> d.memorySpaceId
  MemorySuperseded d -> d.memorySpaceId
  MemoryArchived d -> d.memorySpaceId
  MemoryTagsUpdated d -> d.memorySpaceId
  MemoryConfidenceUpdated d -> d.memorySpaceId
  MemoryMerged d -> d.memorySpaceId

$(deriveAggregate ''MemoryCommand ''MemoryRegs ''MemoryEvent)

memoryTransducer ::
  SymTransducer
    (HsPred MemoryRegs MemoryCommand)
    MemoryRegs
    MemoryVertex
    MemoryCommand
    MemoryEvent
memoryTransducer =
  B.buildTransducer NotCreated emptyRegFile isTerminal do
    B.from NotCreated do
      B.onCmd inCtorRecordMemory $ \d -> B.do
        -- 'emptyRegFile' binds the slot to a deferred error, so this edge -- the only way into
        -- Active, and thus the only way to reach any guard below -- must initialize it.
        B.slot @"memorySpaceId" =: d.memorySpaceId
        B.emit
          wireMemoryRecorded
          MemoryRecordedTermFields
            { memoryId = d.memoryId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              ownerPrincipal = d.ownerPrincipal,
              agentId = d.agentId,
              sessionId = d.sessionId,
              scope = d.scope,
              memoryType = d.memoryType,
              content = d.content,
              priority = d.priority,
              confidence = d.confidence,
              tags = d.tags,
              supersedes = d.supersedes,
              recordedAt = d.recordedAt
            }
        B.goto Active

    B.from Active do
      -- Every edge below repeats the same guard: the command must name the space this memory
      -- was created in. A caller holding a context for one space cannot supersede, archive,
      -- retag, re-score, or merge a memory that lives in another, and the refusal comes from the
      -- state machine rather than from a read-model precheck that a concurrent write could stale.
      B.onCmd inCtorSupersedeMemory $ \d -> B.do
        B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
        B.emit
          wireMemorySuperseded
          MemorySupersededTermFields
            { memoryId = d.memoryId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              supersededBy = d.supersededBy,
              supersededAt = d.supersededAt
            }
        B.goto Superseded

      B.onCmd inCtorArchiveMemory $ \d -> B.do
        B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
        B.emit
          wireMemoryArchived
          MemoryArchivedTermFields
            { memoryId = d.memoryId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              archivedAt = d.archivedAt
            }
        B.goto Archived

      B.onCmd inCtorUpdateMemoryTags $ \d -> B.do
        B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
        B.emit
          wireMemoryTagsUpdated
          MemoryTagsUpdatedTermFields
            { memoryId = d.memoryId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              tags = d.tags,
              updatedAt = d.updatedAt
            }
        B.goto Active

      B.onCmd inCtorUpdateMemoryConfidence $ \d -> B.do
        B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
        B.emit
          wireMemoryConfidenceUpdated
          MemoryConfidenceUpdatedTermFields
            { memoryId = d.memoryId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              confidence = d.confidence,
              updatedAt = d.updatedAt
            }
        B.goto Active

      B.onCmd inCtorMergeMemory $ \d -> B.do
        B.requireGuard (d.memorySpaceId .== B.reg @"memorySpaceId")
        B.emit
          wireMemoryMerged
          MemoryMergedTermFields
            { memoryId = d.memoryId,
              memorySpaceId = d.memorySpaceId,
              actorPrincipal = d.actorPrincipal,
              mergedInto = d.mergedInto,
              mergedAt = d.mergedAt
            }
        B.goto Merged
  where
    isTerminal = \case
      Superseded -> True
      Merged -> True
      Archived -> True
      _ -> False
