{-# LANGUAGE DataKinds #-}

module Kioku.Distill.L2
  ( L2Error (..),
    SceneRow (..),
    fireL2SceneTimer,
    getScenesByScope,
    l2SceneProcessManagerName,
    l2SceneTimerId,
    l2SceneTimerScheduleProjection,
    mirrorSceneToCurrentWorkspace,
    mirrorSceneToWorkspace,
    regenerateScene,
    sceneMirrorPath,
  )
where

import Contravariant.Extras (contrazip3, contrazip4)
import Control.Exception (IOException, try)
import Crypto.Hash (Digest, SHA256)
import Crypto.Hash qualified as Hash
import Data.Aeson qualified as Aeson
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
import Kioku.Api.Scope (MemoryScope, scopeFromColumns, scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.Distill.L3 (scheduleL3PersonaTimerTx)
import Kioku.Distill.Runtime (DistillRuntime, runSceneDistillation)
import Kioku.Distill.Scene (SceneInput (..), SceneOutput (..))
import Kioku.Distill.Timer.Outcome (FireOutcome (..), fireRetryDelay, timerMarkerEventId)
import Kioku.Id (MemoryId, idText)
import Kioku.Memory.Domain
  ( MemoryArchivedData (..),
    MemoryEvent (..),
    MemoryMergedData (..),
    MemoryRecordedData (..),
    MemorySupersededData (..),
  )
import Kioku.Prelude
import Kioku.Recall qualified as Recall
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikumi.Schema.Types (field, unField)
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.FilePath ((</>))

data L2Error
  = L2MemoryReadFailed !ReadModelError
  | L2SceneReadFailed
  | L2SceneGenerationFailed !Text
  deriving stock (Generic, Show)

data SceneRow = SceneRow
  { sceneId :: !Text,
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

newtype SceneTimerPayload = SceneTimerPayload
  { scope :: MemoryScope
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

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
      apply = \event _recorded -> scheduleSceneTimersForEvent event
    }

-- | Every event that changes which memories a scope's scene is built from must
-- schedule a regeneration. Forgetting is such a change: without this, archived,
-- superseded, and merged content survives in the scene row and its plaintext
-- mirror until some unrelated memory happens to be recorded in the same scope.
scheduleSceneTimersForEvent :: MemoryEvent -> Tx.Transaction ()
scheduleSceneTimersForEvent = \case
  MemoryRecorded d ->
    scheduleTimerTx $
      l2SceneTimerRequest
        d.scope
        (idText (d.memoryId :: MemoryId))
        (addUTCTime sceneDebounceSeconds d.recordedAt)
  MemoryArchived d -> scheduleForgetTimerTx d.memoryId "archived" d.archivedAt
  MemorySuperseded d -> scheduleForgetTimerTx d.memoryId "superseded" d.supersededAt
  MemoryMerged d -> scheduleForgetTimerTx d.memoryId "merged" d.mergedAt
  MemoryTagsUpdated _ -> pure ()
  MemoryConfidenceUpdated _ -> pure ()

-- | The forget events carry no scope, so it is read back from the read-model row
-- inside this same transaction. The row is guaranteed present: the aggregate only
-- accepts a forget command from @Active@, which implies a committed
-- @MemoryRecorded@ whose inline projection upserted the row.
--
-- The source id is suffixed with the event kind rather than reusing the record
-- path's bare memory id, because keiro's 'scheduleTimerTx' re-arms a conflicting
-- timer only while it is still @scheduled@ — reusing the record-time id would be
-- silently dropped once that timer has fired, which by then it almost always has.
scheduleForgetTimerTx :: MemoryId -> Text -> UTCTime -> Tx.Transaction ()
scheduleForgetTimerTx memoryId kind occurredAt = do
  scopeCols <- Tx.statement (idText memoryId) selectMemoryScopeColumnsStmt
  for_ scopeCols \(ns, sk, sr) ->
    scheduleTimerTx $
      l2SceneTimerRequest
        (scopeFromColumns ns sk sr)
        (idText memoryId <> ":" <> kind)
        (addUTCTime sceneDebounceSeconds occurredAt)

l2SceneTimerRequest :: MemoryScope -> Text -> UTCTime -> TimerRequest
l2SceneTimerRequest scope sourceId fireAt =
  TimerRequest
    { timerId = l2SceneTimerId scope sourceId,
      processManagerName = l2SceneProcessManagerName,
      correlationId = renderScope scope,
      fireAt,
      payload = Aeson.toJSON (SceneTimerPayload scope)
    }

l2SceneTimerId :: MemoryScope -> Text -> TimerId
l2SceneTimerId scope sourceId =
  TimerId $
    UUIDv5.generateNamed
      l2SceneTimerNamespace
      (BS.unpack (TE.encodeUtf8 raw))
  where
    raw =
      l2SceneProcessManagerName
        <> ":"
        <> renderScope scope
        <> ":"
        <> sourceId

regenerateScene ::
  (IOE :> es, Store :> es) =>
  DistillRuntime ->
  MemoryScope ->
  Eff es (Either L2Error (Maybe SceneRow))
regenerateScene rt scope = do
  memoryResult <- Recall.getActiveByScope scope
  case memoryResult of
    Left err -> pure (Left (L2MemoryReadFailed err))
    Right [] -> pure (Right Nothing)
    Right atoms -> do
      let sourceHash = sceneSourceHash atoms
          sceneId = sceneRowId scope
      existing <- lookupScene scope defaultSceneKey
      case existing of
        Left err -> pure (Left err)
        Right (Just row)
          | row.sourceHash == sourceHash -> do
              liftIO (bestEffortMirrorScene row)
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
                      { sceneId,
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
                scheduleL3PersonaTimerTx scope now
              liftIO (bestEffortMirrorScene row)
              pure (Right (Just row))

fireL2SceneTimer ::
  (IOE :> es, Store :> es) =>
  DistillRuntime ->
  TimerRow ->
  Eff es FireOutcome
fireL2SceneTimer rt row
  | row.processManagerName /= l2SceneProcessManagerName =
      pure FireNotMine
  | otherwise =
      case Aeson.fromJSON @SceneTimerPayload row.payload of
        -- A payload this handler cannot parse will not parse on the next attempt
        -- either. It used to be marked fired, which quietly lost the scene.
        Aeson.Error err ->
          pure (FireFailedPermanently ("L2 scene timer payload is malformed: " <> Text.pack err))
        Aeson.Success payload -> do
          result <- regenerateScene rt payload.scope
          pure $
            case result of
              Right _ -> FireCompleted (timerMarkerEventId row.timerId)
              Left err -> FireRetryLater (fireRetryDelay row.attempts) (Text.pack (show err))

lookupScene ::
  (Store :> es) =>
  MemoryScope ->
  Text ->
  Eff es (Either L2Error (Maybe SceneRow))
lookupScene scope sceneKey = do
  result <-
    runTransaction $
      Tx.statement
        (scopeNamespaceText scope, scopeKindText scope, scopeRefText scope, sceneKey)
        selectSceneByScopeKeyStmt
  pure (Right result)

getScenesByScope ::
  (Store :> es) =>
  MemoryScope ->
  Eff es [SceneRow]
getScenesByScope scope =
  runTransaction $
    Tx.statement
      (scopeNamespaceText scope, scopeKindText scope, scopeRefText scope)
      selectScenesByScopeStmt

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

bestEffortMirrorScene :: SceneRow -> IO ()
bestEffortMirrorScene row = do
  _ <- try (mirrorSceneToCurrentWorkspace row) :: IO (Either IOException FilePath)
  pure ()

renderSceneFile :: SceneRow -> Text
renderSceneFile row =
  "# " <> row.title <> "\n\n" <> row.bodyMd <> "\n"

sceneScopeSlug :: SceneRow -> Text
sceneScopeSlug row =
  sanitizeSlug $
    Text.intercalate "-" $
      row.namespace : catMaybes [row.scopeKind, row.scopeRef]

sanitizeSlug :: Text -> Text
sanitizeSlug =
  Text.map \ch ->
    if isSafeSlugChar ch then ch else '-'

isSafeSlugChar :: Char -> Bool
isSafeSlugChar ch =
  (ch >= 'a' && ch <= 'z')
    || (ch >= 'A' && ch <= 'Z')
    || (ch >= '0' && ch <= '9')
    || ch == '-'
    || ch == '_'

sceneRowId :: MemoryScope -> Text
sceneRowId scope =
  "kioku_scene:" <> renderScope scope <> ":" <> defaultSceneKey

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
    <$> D.column (D.nonNullable D.text)
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
  ((\row -> row.sceneId) >$< E.param (E.nonNullable E.text))
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

selectMemoryScopeColumnsStmt :: Statement Text (Maybe (Text, Maybe Text, Maybe Text))
selectMemoryScopeColumnsStmt =
  preparable
    "SELECT namespace, scope_kind, scope_ref FROM kioku_memories WHERE memory_id = $1"
    (E.param (E.nonNullable E.text))
    ( D.rowMaybe
        ( (,,)
            <$> D.column (D.nonNullable D.text)
            <*> D.column (D.nullable D.text)
            <*> D.column (D.nullable D.text)
        )
    )

selectSceneByScopeKeyStmt :: Statement (Text, Maybe Text, Maybe Text, Text) (Maybe SceneRow)
selectSceneByScopeKeyStmt =
  preparable
    """
    SELECT scene_id, namespace, scope_kind, scope_ref, scene_key, title, body_md,
           atom_ids::text, source_hash, created_at, updated_at
    FROM kioku_scenes
    WHERE namespace = $1
      AND ((scope_kind = $2 AND scope_ref = $3)
           OR ($2 IS NULL AND scope_kind IS NULL AND $3 IS NULL AND scope_ref IS NULL))
      AND scene_key = $4
    """
    ( contrazip4
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nonNullable E.text))
    )
    (D.rowMaybe sceneRowDecoder)

selectScenesByScopeStmt :: Statement (Text, Maybe Text, Maybe Text) [SceneRow]
selectScenesByScopeStmt =
  preparable
    """
    SELECT scene_id, namespace, scope_kind, scope_ref, scene_key, title, body_md,
           atom_ids::text, source_hash, created_at, updated_at
    FROM kioku_scenes
    WHERE namespace = $1
      AND ((scope_kind = $2 AND scope_ref = $3)
           OR ($2 IS NULL AND scope_kind IS NULL AND $3 IS NULL AND scope_ref IS NULL))
    ORDER BY scene_key ASC, updated_at DESC
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.text))
    )
    (D.rowList sceneRowDecoder)

upsertSceneStmt :: Statement SceneRow ()
upsertSceneStmt =
  preparable
    """
    INSERT INTO kioku_scenes
      (scene_id, namespace, scope_kind, scope_ref, scene_key, title, body_md,
       atom_ids, source_hash, created_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8::jsonb, $9, $10, $11)
    ON CONFLICT (scene_id) DO UPDATE SET
      title = EXCLUDED.title,
      body_md = EXCLUDED.body_md,
      atom_ids = EXCLUDED.atom_ids,
      source_hash = EXCLUDED.source_hash,
      updated_at = EXCLUDED.updated_at
    """
    sceneRowEncoder
    D.noResult
