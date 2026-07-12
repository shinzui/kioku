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
    MemoryRecordedData (..),
    MemorySupersededData (..),
    MemoryArchivedData (..),
    MemoryTagsUpdatedData (..),
    MemoryConfidenceUpdatedData (..),
    MemoryMergedData (..),
    MemoryEvent (..),
    eventMemoryId,
    memoryTransducer,
  )
where

import Data.Set (Set)
import Keiki.Builder qualified as B
import Keiki.Core (HsPred, SymTransducer)
import Keiki.Generics (emptyRegFile)
import Keiki.Generics.TH (deriveAggregate)
import Kioku.Api.Scope (MemoryScope)
import Kioku.Api.Types (Confidence, MemoryType)
import Kioku.Id (MemoryId, SessionId)
import Kioku.Prelude

data MemoryVertex = NotCreated | Active | Superseded | Merged | Archived
  deriving stock (Eq, Ord, Show, Enum, Bounded)

type MemoryRegs = '[]

data RecordMemoryData = RecordMemoryData
  { memoryId :: !MemoryId,
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
    supersededBy :: !MemoryId,
    supersededAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data ArchiveMemoryData = ArchiveMemoryData
  { memoryId :: !MemoryId,
    archivedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data UpdateMemoryTagsData = UpdateMemoryTagsData
  { memoryId :: !MemoryId,
    tags :: !(Set Text),
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data UpdateMemoryConfidenceData = UpdateMemoryConfidenceData
  { memoryId :: !MemoryId,
    confidence :: !Confidence,
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data MergeMemoryData = MergeMemoryData
  { memoryId :: !MemoryId,
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

data MemoryRecordedData = MemoryRecordedData
  { memoryId :: !MemoryId,
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
  deriving anyclass (FromJSON, ToJSON)

data MemorySupersededData = MemorySupersededData
  { memoryId :: !MemoryId,
    supersededBy :: !MemoryId,
    supersededAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data MemoryArchivedData = MemoryArchivedData
  { memoryId :: !MemoryId,
    archivedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data MemoryTagsUpdatedData = MemoryTagsUpdatedData
  { memoryId :: !MemoryId,
    tags :: !(Set Text),
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data MemoryConfidenceUpdatedData = MemoryConfidenceUpdatedData
  { memoryId :: !MemoryId,
    confidence :: !Confidence,
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

data MemoryMergedData = MemoryMergedData
  { memoryId :: !MemoryId,
    mergedInto :: !MemoryId,
    mergedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

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
        B.emit
          wireMemoryRecorded
          MemoryRecordedTermFields
            { memoryId = d.memoryId,
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
      B.onCmd inCtorSupersedeMemory $ \d -> B.do
        B.emit
          wireMemorySuperseded
          MemorySupersededTermFields
            { memoryId = d.memoryId,
              supersededBy = d.supersededBy,
              supersededAt = d.supersededAt
            }
        B.goto Superseded

      B.onCmd inCtorArchiveMemory $ \d -> B.do
        B.emit
          wireMemoryArchived
          MemoryArchivedTermFields
            { memoryId = d.memoryId,
              archivedAt = d.archivedAt
            }
        B.goto Archived

      B.onCmd inCtorUpdateMemoryTags $ \d -> B.do
        B.emit
          wireMemoryTagsUpdated
          MemoryTagsUpdatedTermFields
            { memoryId = d.memoryId,
              tags = d.tags,
              updatedAt = d.updatedAt
            }
        B.goto Active

      B.onCmd inCtorUpdateMemoryConfidence $ \d -> B.do
        B.emit
          wireMemoryConfidenceUpdated
          MemoryConfidenceUpdatedTermFields
            { memoryId = d.memoryId,
              confidence = d.confidence,
              updatedAt = d.updatedAt
            }
        B.goto Active

      B.onCmd inCtorMergeMemory $ \d -> B.do
        B.emit
          wireMemoryMerged
          MemoryMergedTermFields
            { memoryId = d.memoryId,
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
