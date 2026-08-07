{-# LANGUAGE DataKinds #-}

module Kioku.Distill.L2
  ( L2Error (..),
    SceneRow (..),
    fireL2SceneTimer,
    getScenesByScope,
    l2SceneProcessManagerName,
    l2SceneTimerId,
    l2SceneTimerScheduleProjection,
    SceneTimerPayload (..),
    mirrorSceneToCurrentWorkspace,
    mirrorSceneToWorkspace,
    regenerateScene,
    sceneMirrorPath,
    sceneRowId,
  )
where

import Control.Exception (IOException, try)
import Crypto.Hash (Digest, SHA256)
import Crypto.Hash qualified as Hash
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (withObject, (.:))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (for_)
import Data.Functor.Contravariant ((>$<))
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TextIO
import Data.Time (NominalDiffTime, addUTCTime)
import Data.UUID (UUID)
import Data.UUID qualified as UUID
import Data.UUID.V5 qualified as UUIDv5
import Effectful (Eff, IOE, (:>))
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Projection (InlineProjection (..))
import Keiro.ReadModel (ReadModelError)
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow (..), scheduleTimerTx)
import Kioku.Api.Access (MemoryContextProvider (..), MemorySpaceId, memoryContextSpace)
import Kioku.Api.Scope (MemoryScope, scopeFromColumns, scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.Distill.L3 (partitionedCorrelationId, scheduleL3PersonaTimerTx)
import Kioku.Distill.Runtime (DistillRuntime, distillWorkspaceRoot, runSceneDistillation)
import Kioku.Distill.Scene (SceneInput (..), SceneOutput (..))
import Kioku.Distill.ScopeIdentity (escapeScopeComponent, scopeIdentity, scopeSlugFromColumns)
import Kioku.Distill.Timer.Outcome (FireOutcome (..), fireRetryDelay, timerMarkerEventId)
import Kioku.Id (MemoryId, idText)
import Kioku.Memory.Domain
  ( MemoryArchivedData (..),
    MemoryConfidenceUpdatedData (..),
    MemoryEvent (..),
    MemoryMergedData (..),
    MemoryRecordedData (..),
    MemorySupersededData (..),
  )
import Kioku.Partition (memorySpaceColumn, memorySpaceParam, parsePartitionSpace)
import Kioku.Prelude
import Kioku.Recall qualified as Recall
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..), RecordedEvent (..))
import Shikumi.Schema.Types (field, unField)
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory, removeFile)
import System.FilePath ((</>))

data L2Error
  = L2MemoryReadFailed !ReadModelError
  | L2SceneReadFailed
  | L2SceneGenerationFailed !Text
  deriving stock (Generic, Show)

data SceneRow = SceneRow
  { memorySpaceId :: !MemorySpaceId,
    sceneId :: !Text,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text),
    sceneKey :: !Text,
    title :: !Text,
    bodyMd :: !Text,
    atomIds :: ![Text],
    sourceHash :: !Text,
    createdAt :: !UTCTime,
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

-- | What a scheduled scene regeneration needs to know.
--
-- @memorySpaceId@ is what keeps two spaces that happen to share a namespace and scope from
-- regenerating each other's scene. Timers scheduled before the field existed decode into
-- 'Kioku.Api.Access.legacyMemorySpaceId', the same rule stored events follow.
data SceneTimerPayload = SceneTimerPayload
  { memorySpaceId :: !MemorySpaceId,
    scope :: !MemoryScope
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON SceneTimerPayload where
  parseJSON =
    withObject "SceneTimerPayload" \o ->
      SceneTimerPayload <$> parsePartitionSpace o <*> o .: "scope"

l2SceneProcessManagerName :: Text
l2SceneProcessManagerName = "kioku-l2-scene"

defaultSceneKey :: Text
defaultSceneKey = "default"

sceneDebounceSeconds :: NominalDiffTime
sceneDebounceSeconds = 5

l2SceneTimerScheduleProjection :: InlineProjection MemoryEvent
l2SceneTimerScheduleProjection =
  InlineProjection
    { name = "kioku-l2-scene-timer-schedule",
      apply = scheduleSceneTimersForEvent
    }

-- | Every event that changes which memories a scope's scene is built from, or what
-- those memories say, must schedule a regeneration. Forgetting is such a change:
-- without this, archived, superseded, and merged content survives in the scene row
-- and its plaintext mirror until some unrelated memory happens to be recorded in
-- the same scope. So is a confidence change, for the same reason.
scheduleSceneTimersForEvent :: MemoryEvent -> RecordedEvent -> Tx.Transaction ()
scheduleSceneTimersForEvent event recorded = case event of
  MemoryRecorded d ->
    scheduleTimerTx $
      l2SceneTimerRequest
        d.memorySpaceId
        d.scope
        (idText (d.memoryId :: MemoryId))
        (addUTCTime sceneDebounceSeconds d.recordedAt)
  MemoryArchived d ->
    scheduleScopedSceneTimerTx d.memorySpaceId d.memoryId (kindSourceId d.memoryId "archived") d.archivedAt
  MemorySuperseded d ->
    scheduleScopedSceneTimerTx d.memorySpaceId d.memoryId (kindSourceId d.memoryId "superseded") d.supersededAt
  MemoryMerged d ->
    scheduleScopedSceneTimerTx d.memorySpaceId d.memoryId (kindSourceId d.memoryId "merged") d.mergedAt
  -- Confidence is in the scene's source hash ('atomSource') and in the LLM prompt
  -- ('renderAtom'), so changing it makes the scene stale exactly as forgetting does.
  --
  -- The source id must carry the event id. Unlike the forget events, which are
  -- terminal, confidence can change repeatedly on one memory — and keiro re-arms a
  -- conflicting timer only while it is still @scheduled@ (see 'scheduleScopedSceneTimerTx').
  -- A fixed @\<memoryId\>:confidence@ would therefore be silently dropped on every
  -- change after the first, which would look fixed and be worse than the bug. The
  -- event id is stable across replay, so it cannot double-schedule either.
  MemoryConfidenceUpdated d ->
    scheduleScopedSceneTimerTx
      d.memorySpaceId
      d.memoryId
      (idText d.memoryId <> ":confidence:" <> eventIdText recorded.eventId)
      d.updatedAt
  -- Tags are in neither 'atomSource' nor 'renderAtom', so a tag change cannot alter
  -- the scene. Scheduling here would spend an LLM call to rewrite a byte-identical row.
  MemoryTagsUpdated _ -> pure ()

-- | Schedule a scene regeneration for a memory whose event does not carry its scope.
--
-- The scope is read back from the read-model row inside this same transaction. The
-- row is guaranteed present: the aggregate only accepts these commands for an
-- @Active@ memory, which implies a committed @MemoryRecorded@ whose inline
-- projection upserted the row.
--
-- The caller supplies the source id rather than reusing the record path's bare
-- memory id, because keiro's 'scheduleTimerTx' re-arms a conflicting timer only
-- while it is still @scheduled@ — reusing the record-time id would be silently
-- dropped once that timer has fired, which by then it almost always has.
scheduleScopedSceneTimerTx :: MemorySpaceId -> MemoryId -> Text -> UTCTime -> Tx.Transaction ()
scheduleScopedSceneTimerTx memorySpaceId memoryId sourceId occurredAt = do
  scopeCols <- Tx.statement (MemoryScopeLookup memorySpaceId (idText memoryId)) selectMemoryScopeColumnsStmt
  for_ scopeCols \(ns, sk, sr) ->
    scheduleTimerTx $
      l2SceneTimerRequest
        memorySpaceId
        (scopeFromColumns ns sk sr)
        sourceId
        (addUTCTime sceneDebounceSeconds occurredAt)

-- | The forget events are terminal, so one timer per (memory, event kind) is both
-- unique and stable across replay.
kindSourceId :: MemoryId -> Text -> Text
kindSourceId memoryId kind = idText memoryId <> ":" <> kind

eventIdText :: EventId -> Text
eventIdText (EventId uuid) = UUID.toText uuid

l2SceneTimerRequest :: MemorySpaceId -> MemoryScope -> Text -> UTCTime -> TimerRequest
l2SceneTimerRequest memorySpaceId scope sourceId fireAt =
  TimerRequest
    { timerId = l2SceneTimerId memorySpaceId scope sourceId,
      processManagerName = l2SceneProcessManagerName,
      correlationId = partitionedCorrelationId memorySpaceId scope,
      fireAt,
      payload = Aeson.toJSON SceneTimerPayload {memorySpaceId, scope}
    }

-- | The timer id and correlation id both carry the memory space, for the reason given at
-- 'Kioku.Distill.L3.l3PersonaTimerId': these timers are keyed by a scope, and two spaces are
-- allowed to use the same one.
l2SceneTimerId :: MemorySpaceId -> MemoryScope -> Text -> TimerId
l2SceneTimerId memorySpaceId scope sourceId =
  TimerId $
    UUIDv5.generateNamed
      l2SceneTimerNamespace
      (BS.unpack (TE.encodeUtf8 raw))
  where
    raw =
      l2SceneProcessManagerName
        <> ":"
        <> partitionedCorrelationId memorySpaceId scope
        <> ":"
        <> sourceId

regenerateScene ::
  (IOE :> es, Store :> es) =>
  DistillRuntime ->
  MemorySpaceId ->
  MemoryScope ->
  Eff es (Either L2Error (Maybe SceneRow))
regenerateScene rt memorySpaceId scope = do
  memoryResult <- Recall.getActiveByScope memorySpaceId scope
  case memoryResult of
    Left err -> pure (Left (L2MemoryReadFailed err))
    -- Every memory in this scope has been forgotten. Delete the scene outright
    -- rather than leaving it or blanking it: a surviving row keeps feeding
    -- persona regeneration and keeps stale atom_ids pointing at forgotten
    -- memories, and a blank mirror file is just a confusing way to still be
    -- there. No LLM runs on this path -- there is nothing left to summarize.
    Right [] -> do
      existing <- lookupScene memorySpaceId scope defaultSceneKey
      case existing of
        Left err -> pure (Left err)
        Right Nothing -> pure (Right Nothing)
        Right (Just row) -> do
          now <- liftIO getCurrentTime
          runTransaction do
            Tx.statement (SceneKey memorySpaceId row.sceneId) deleteSceneStmt
            scheduleL3PersonaTimerTx memorySpaceId scope now
          liftIO (bestEffortRemoveSceneMirror rt row)
          pure (Right Nothing)
    Right atoms -> do
      let sourceHash = sceneSourceHash atoms
          sceneId = sceneRowId scope
      existing <- lookupScene memorySpaceId scope defaultSceneKey
      case existing of
        Left err -> pure (Left err)
        Right (Just row)
          | row.sourceHash == sourceHash -> do
              liftIO (bestEffortMirrorScene rt row)
              pure (Right (Just row))
        _ -> do
          outputResult <-
            liftIO $
              runSceneDistillation
                rt
                SceneInput
                  { scopeLabel = field (renderScope scope),
                    atoms = field (renderAtoms atoms)
                  }
          case outputResult of
            Left err -> pure (Left (L2SceneGenerationFailed (Text.pack (show err))))
            Right output -> do
              now <- liftIO getCurrentTime
              let row =
                    SceneRow
                      { memorySpaceId,
                        sceneId,
                        namespace = scopeNamespaceText scope,
                        scopeKind = scopeKindText scope,
                        scopeRef = scopeRefText scope,
                        sceneKey = defaultSceneKey,
                        title = unField output.title,
                        bodyMd = unField output.bodyMd,
                        atomIds = (.memoryId) <$> atoms,
                        sourceHash,
                        createdAt = now,
                        updatedAt = now
                      }
              runTransaction do
                Tx.statement row upsertSceneStmt
                scheduleL3PersonaTimerTx memorySpaceId scope now
              liftIO (bestEffortMirrorScene rt row)
              pure (Right (Just row))

-- | Fire one L2 scene timer.
--
-- Like the L1 handler, a background pass cannot arrive holding an authorization context: it
-- reads the memory space out of the payload and asks the provider for a decision about /that/
-- space. A refusal is a configuration fact, so it dead-letters rather than retrying forever.
fireL2SceneTimer ::
  (IOE :> es, Store :> es) =>
  MemoryContextProvider (Eff es) ->
  DistillRuntime ->
  TimerRow ->
  Eff es FireOutcome
fireL2SceneTimer contexts rt row
  | row.processManagerName /= l2SceneProcessManagerName =
      pure FireNotMine
  | otherwise =
      case Aeson.fromJSON @SceneTimerPayload row.payload of
        -- A payload this handler cannot parse will not parse on the next attempt
        -- either. It used to be marked fired, which quietly lost the scene.
        Aeson.Error err ->
          pure (FireFailedPermanently ("L2 scene timer payload is malformed: " <> Text.pack err))
        Aeson.Success payload -> do
          decision <- contexts.contextForSpace payload.memorySpaceId
          case decision of
            Left denial ->
              pure
                ( FireFailedPermanently
                    ("L2 scene timer is not authorized for its memory space: " <> Text.pack (show denial))
                )
            Right context -> do
              result <- regenerateScene rt (memoryContextSpace context) payload.scope
              pure $
                case result of
                  Right _ -> FireCompleted (timerMarkerEventId row.timerId)
                  Left err -> FireRetryLater (fireRetryDelay row.attempts) (Text.pack (show err))

lookupScene ::
  (Store :> es) =>
  MemorySpaceId ->
  MemoryScope ->
  Text ->
  Eff es (Either L2Error (Maybe SceneRow))
lookupScene memorySpaceId scope sceneKey = do
  result <-
    runTransaction $
      Tx.statement (SceneScopeKey (scopeKey memorySpaceId scope) sceneKey) selectSceneByScopeKeyStmt
  pure (Right result)

getScenesByScope ::
  (Store :> es) =>
  MemorySpaceId ->
  MemoryScope ->
  Eff es [SceneRow]
getScenesByScope memorySpaceId scope =
  runTransaction $
    Tx.statement (scopeKey memorySpaceId scope) selectScenesByScopeStmt

-- | A scope lookup inside one memory space, as a record rather than a tuple so that the
-- partition cannot be transposed with the namespace it sits beside.
data PartitionedScope = PartitionedScope
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text)
  }

data SceneScopeKey = SceneScopeKey !PartitionedScope !Text

data SceneKey = SceneKey !MemorySpaceId !Text

data MemoryScopeLookup = MemoryScopeLookup !MemorySpaceId !Text

scopeKey :: MemorySpaceId -> MemoryScope -> PartitionedScope
scopeKey memorySpaceId scope =
  PartitionedScope
    { memorySpaceId,
      namespace = scopeNamespaceText scope,
      scopeKind = scopeKindText scope,
      scopeRef = scopeRefText scope
    }

partitionedScopeEncoder :: E.Params PartitionedScope
partitionedScopeEncoder =
  ((\q -> q.memorySpaceId) >$< memorySpaceParam)
    <> ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\q -> q.scopeRef) >$< E.param (E.nullable E.text))

mirrorSceneToCurrentWorkspace :: SceneRow -> IO FilePath
mirrorSceneToCurrentWorkspace row = do
  workspace <- getCurrentDirectory
  mirrorSceneToWorkspace workspace row

mirrorSceneToWorkspace :: FilePath -> SceneRow -> IO FilePath
mirrorSceneToWorkspace workspace row = do
  let path = sceneMirrorPath workspace row
  createDirectoryIfMissing True (workspace </> ".kioku" </> "scenes")
  TextIO.writeFile path (renderSceneFile row)
  pure path

sceneMirrorPath :: FilePath -> SceneRow -> FilePath
sceneMirrorPath workspace row =
  workspace </> ".kioku" </> "scenes" </> Text.unpack (sceneScopeSlug row <> ".md")

bestEffortMirrorScene :: DistillRuntime -> SceneRow -> IO ()
bestEffortMirrorScene rt row = do
  let write = do
        workspace <- distillWorkspaceRoot rt
        mirrorSceneToWorkspace workspace row
  _ <- try write :: IO (Either IOException FilePath)
  pure ()

-- | Remove a scene's mirror file, best-effort in exactly the way writing it is.
-- The durable artifact is the database row, and it is already gone by the time
-- this runs; a failure to unlink the file must not fail the timer, and the next
-- regeneration in this workspace rewrites or removes it anyway.
bestEffortRemoveSceneMirror :: DistillRuntime -> SceneRow -> IO ()
bestEffortRemoveSceneMirror rt row = do
  let remove = do
        workspace <- distillWorkspaceRoot rt
        let path = sceneMirrorPath workspace row
        exists <- doesFileExist path
        when exists (removeFile path)
  _ <- try remove :: IO (Either IOException ())
  pure ()

renderSceneFile :: SceneRow -> Text
renderSceneFile row =
  "# " <> row.title <> "\n\n" <> row.bodyMd <> "\n"

sceneScopeSlug :: SceneRow -> Text
sceneScopeSlug row =
  scopeSlugFromColumns row.namespace row.scopeKind row.scopeRef

-- | The persistent primary key of a scene row. Escaped, so two distinct scopes can never
-- derive the same id; the scene key is escaped too, purely to future-proof the format
-- (today's only key, @default@, is unchanged by escaping).
sceneRowId :: MemoryScope -> Text
sceneRowId scope =
  "kioku_scene:" <> scopeIdentity scope <> ":" <> escapeScopeComponent defaultSceneKey

sceneSourceHash :: [MemoryRecord] -> Text
sceneSourceHash atoms =
  "v1:" <> Text.pack (show (Hash.hash (BL.toStrict (Aeson.encode (atomSource <$> atoms))) :: Digest SHA256))

atomSource :: MemoryRecord -> (Text, Text, Int, Text, UTCTime)
atomSource atom =
  (atom.memoryId, atom.content, atom.priority, atom.confidence, atom.createdAt)

renderAtoms :: [MemoryRecord] -> Text
renderAtoms =
  Text.intercalate "\n" . fmap renderAtom

renderAtom :: MemoryRecord -> Text
renderAtom atom =
  "- "
    <> atom.memoryId
    <> " ("
    <> atom.memoryType
    <> ", "
    <> atom.confidence
    <> "): "
    <> atom.content

-- | A human-readable scope label for the LLM prompt. Deliberately *not* escaped and
-- deliberately not used for identity: a collision here is cosmetic. Identity comes from
-- 'scopeIdentity'.
renderScope :: MemoryScope -> Text
renderScope scope =
  Text.intercalate "/" $
    scopeNamespaceText scope : catMaybes [scopeKindText scope, scopeRefText scope]

l2SceneTimerNamespace :: UUID
l2SceneTimerNamespace =
  fromMaybe UUID.nil $
    UUID.fromString "6b696f6b-752d-7132-8000-7363656e6573"

encodeAtomIds :: [Text] -> Text
encodeAtomIds =
  TE.decodeUtf8 . BL.toStrict . Aeson.encode

decodeAtomIds :: Text -> [Text]
decodeAtomIds =
  fromMaybe [] . Aeson.decode . BL.fromStrict . TE.encodeUtf8

sceneRowDecoder :: D.Row SceneRow
sceneRowDecoder =
  SceneRow
    <$> memorySpaceColumn
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> (decodeAtomIds <$> D.column (D.nonNullable D.text))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)

sceneRowEncoder :: E.Params SceneRow
sceneRowEncoder =
  ((\row -> row.memorySpaceId) >$< memorySpaceParam)
    <> ((\row -> row.sceneId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\row -> row.scopeRef) >$< E.param (E.nullable E.text))
    <> ((\row -> row.sceneKey) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.title) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.bodyMd) >$< E.param (E.nonNullable E.text))
    <> ((encodeAtomIds . \row -> row.atomIds) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.sourceHash) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.createdAt) >$< E.param (E.nonNullable E.timestamptz))
    <> ((\row -> row.updatedAt) >$< E.param (E.nonNullable E.timestamptz))

selectMemoryScopeColumnsStmt :: Statement MemoryScopeLookup (Maybe (Text, Maybe Text, Maybe Text))
selectMemoryScopeColumnsStmt =
  preparable
    "SELECT namespace, scope_kind, scope_ref FROM kioku_memories WHERE memory_space_id = $1 AND memory_id = $2"
    ( ((\(MemoryScopeLookup space _) -> space) >$< memorySpaceParam)
        <> ((\(MemoryScopeLookup _ memoryId) -> memoryId) >$< E.param (E.nonNullable E.text))
    )
    ( D.rowMaybe
        ( (,,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nullable D.text)
        )
    )

selectSceneByScopeKeyStmt :: Statement SceneScopeKey (Maybe SceneRow)
selectSceneByScopeKeyStmt =
  preparable
    """
    SELECT memory_space_id, scene_id, namespace, scope_kind, scope_ref, scene_key, title, body_md,
           atom_ids::text, source_hash, created_at, updated_at
    FROM kioku_scenes
    WHERE memory_space_id = $1
      AND namespace = $2
      AND ((scope_kind = $3 AND scope_ref = $4)
           OR ($3 IS NULL AND scope_kind IS NULL AND $4 IS NULL AND scope_ref IS NULL))
      AND scene_key = $5
    """
    ( ((\(SceneScopeKey scope _) -> scope) >$< partitionedScopeEncoder)
        <> ((\(SceneScopeKey _ sceneKey) -> sceneKey) >$< E.param (E.nonNullable E.text))
    )
    (D.rowMaybe sceneRowDecoder)

selectScenesByScopeStmt :: Statement PartitionedScope [SceneRow]
selectScenesByScopeStmt =
  preparable
    """
    SELECT memory_space_id, scene_id, namespace, scope_kind, scope_ref, scene_key, title, body_md,
           atom_ids::text, source_hash, created_at, updated_at
    FROM kioku_scenes
    WHERE memory_space_id = $1
      AND namespace = $2
      AND ((scope_kind = $3 AND scope_ref = $4)
           OR ($3 IS NULL AND scope_kind IS NULL AND $4 IS NULL AND scope_ref IS NULL))
    ORDER BY scene_key ASC, updated_at DESC
    """
    partitionedScopeEncoder
    (D.rowList sceneRowDecoder)

-- | Delete by the row's own primary key, which was written from @sceneRowId@.
-- Deriving the key here instead would re-implement the scope-identity format
-- that docs/plans/13-... owns changing. That key is now composite: @sceneRowId@ is derived
-- from the scope alone, and two memory spaces may hold the same scope.
deleteSceneStmt :: Statement SceneKey ()
deleteSceneStmt =
  preparable
    "DELETE FROM kioku_scenes WHERE memory_space_id = $1 AND scene_id = $2"
    ( ((\(SceneKey space _) -> space) >$< memorySpaceParam)
        <> ((\(SceneKey _ sceneId) -> sceneId) >$< E.param (E.nonNullable E.text))
    )
    D.noResult

upsertSceneStmt :: Statement SceneRow ()
upsertSceneStmt =
  preparable
    """
    INSERT INTO kioku_scenes
      (memory_space_id, scene_id, namespace, scope_kind, scope_ref, scene_key, title, body_md,
       atom_ids, source_hash, created_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9::jsonb, $10, $11, $12)
    ON CONFLICT (memory_space_id, scene_id) DO UPDATE SET
      title = EXCLUDED.title,
      body_md = EXCLUDED.body_md,
      atom_ids = EXCLUDED.atom_ids,
      source_hash = EXCLUDED.source_hash,
      updated_at = EXCLUDED.updated_at
    """
    sceneRowEncoder
    D.noResult
