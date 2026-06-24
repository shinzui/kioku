{-# LANGUAGE DataKinds #-}

module Kioku.Distill.L2
  ( L2Error (..),
    SceneRow (..),
    fireL2SceneTimer,
    l2SceneProcessManagerName,
    l2SceneTimerId,
    l2SceneTimerScheduleProjection,
    regenerateScene,
  )
where

import Contravariant.Extras (contrazip4)
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
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
import Kioku.Api.Scope (MemoryScope, scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.Distill.Runtime (DistillRuntime, runDistillProgram)
import Kioku.Distill.Scene (SceneInput (..), SceneOutput (..), sceneProgram)
import Kioku.Id (MemoryId, idText)
import Kioku.Memory.Domain (MemoryEvent (..), MemoryRecordedData (..))
import Kioku.Prelude
import Kioku.Recall qualified as Recall
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..))
import Shikumi.Schema.Types (field, unField)

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
      apply = \event _recorded -> traverse_ scheduleTimerTx (timerRequestsForEvent event)
    }

timerRequestsForEvent :: MemoryEvent -> [TimerRequest]
timerRequestsForEvent = \case
  MemoryRecorded d ->
    [ l2SceneTimerRequest
        d.scope
        (idText (d.memoryId :: MemoryId))
        (addUTCTime sceneDebounceSeconds d.recordedAt)
    ]
  _ -> []

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
          | row.sourceHash == sourceHash -> pure (Right (Just row))
        _ -> do
          outputResult <-
            liftIO $
              runDistillProgram
                rt
                sceneProgram
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
              runTransaction (Tx.statement row upsertSceneStmt)
              pure (Right (Just row))

fireL2SceneTimer ::
  (IOE :> es, Store :> es) =>
  DistillRuntime ->
  TimerRow ->
  Eff es (Maybe EventId)
fireL2SceneTimer rt row
  | row.processManagerName /= l2SceneProcessManagerName =
      pure Nothing
  | otherwise =
      case Aeson.fromJSON @SceneTimerPayload row.payload of
        Aeson.Error _err ->
          pure (Just (timerMarkerEventId row.timerId))
        Aeson.Success payload -> do
          result <- regenerateScene rt payload.scope
          pure $
            case result of
              Right _ -> Just (timerMarkerEventId row.timerId)
              Left _ -> Nothing

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

sceneRowId :: MemoryScope -> Text
sceneRowId scope =
  "kioku_scene:" <> renderScope scope <> ":" <> defaultSceneKey

sceneSourceHash :: [MemoryRecord] -> Text
sceneSourceHash atoms =
  "v1:" <> TE.decodeUtf8 (BL.toStrict (Aeson.encode (atomSource <$> atoms)))

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

timerMarkerEventId :: TimerId -> EventId
timerMarkerEventId (TimerId uuid) = EventId uuid

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
