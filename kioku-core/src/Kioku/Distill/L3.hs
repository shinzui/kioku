{-# LANGUAGE DataKinds #-}

module Kioku.Distill.L3
  ( L3Error (..),
    PersonaRow (..),
    fireL3PersonaTimer,
    getPersonaByScope,
    l3PersonaProcessManagerName,
    l3PersonaTimerId,
    mirrorPersonaToCurrentWorkspace,
    mirrorPersonaToWorkspace,
    personaMirrorPath,
    regeneratePersona,
    scheduleL3PersonaTimerTx,
  )
where

import Contravariant.Extras (contrazip3)
import Control.Exception (IOException, try)
import Crypto.Hash (Digest, SHA256)
import Crypto.Hash qualified as Hash
import Data.Aeson qualified as Aeson
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BL
import Data.Functor.Contravariant ((>$<))
import Data.Int (Int32)
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
import Keiro.Timer (TimerId (..), TimerRequest (..), TimerRow (..), scheduleTimerTx)
import Kioku.Api.Scope (MemoryScope, scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Distill.Persona (PersonaInput (..), PersonaOutput (..))
import Kioku.Distill.Runtime (DistillRuntime, runPersonaDistillation)
import Kioku.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventId (..))
import Shikumi.Schema.Types (field, unField)
import System.Directory (createDirectoryIfMissing, getCurrentDirectory)
import System.FilePath ((</>))

data L3Error
  = L3SceneGenerationUnavailable
  | L3PersonaGenerationFailed !Text
  deriving stock (Generic, Show)

data PersonaRow = PersonaRow
  { personaId :: !Text,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text),
    bodyMd :: !Text,
    sceneCount :: !Int,
    sourceHash :: !Text,
    createdAt :: !UTCTime,
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data PersonaSceneRow = PersonaSceneRow
  { sceneId :: !Text,
    title :: !Text,
    bodyMd :: !Text,
    updatedAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

newtype PersonaTimerPayload = PersonaTimerPayload
  { scope :: MemoryScope
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (FromJSON, ToJSON)

l3PersonaProcessManagerName :: Text
l3PersonaProcessManagerName = "kioku-l3-persona"

personaDebounceSeconds :: NominalDiffTime
personaDebounceSeconds = 5

scheduleL3PersonaTimerTx :: MemoryScope -> UTCTime -> Tx.Transaction ()
scheduleL3PersonaTimerTx scope now =
  scheduleTimerTx $
    TimerRequest
      { timerId = l3PersonaTimerId scope fireAt,
        processManagerName = l3PersonaProcessManagerName,
        correlationId = renderScope scope,
        fireAt,
        payload = Aeson.toJSON (PersonaTimerPayload scope)
      }
  where
    fireAt = addUTCTime personaDebounceSeconds now

l3PersonaTimerId :: MemoryScope -> UTCTime -> TimerId
l3PersonaTimerId scope fireAt =
  TimerId $
    UUIDv5.generateNamed
      l3PersonaTimerNamespace
      (BS.unpack (TE.encodeUtf8 raw))
  where
    raw =
      l3PersonaProcessManagerName
        <> ":"
        <> renderScope scope
        <> ":"
        <> Text.pack (show fireAt)

regeneratePersona ::
  (IOE :> es, Store :> es) =>
  DistillRuntime ->
  MemoryScope ->
  Eff es (Either L3Error (Maybe PersonaRow))
regeneratePersona rt scope = do
  scenes <- getPersonaScenesByScope scope
  case scenes of
    [] -> pure (Right Nothing)
    _ -> do
      let sourceHash = personaSourceHash scenes
          personaId = personaRowId scope
      existing <- getPersonaByScope scope
      case existing of
        Just row
          | row.sourceHash == sourceHash -> do
              liftIO (bestEffortMirrorPersona row)
              pure (Right (Just row))
        _ -> do
          outputResult <-
            liftIO $
              runPersonaDistillation
                rt
                PersonaInput
                  { scopeLabel = field (renderScope scope),
                    scenes = field (renderScenes scenes)
                  }
          case outputResult of
            Left err -> pure (Left (L3PersonaGenerationFailed (Text.pack (show err))))
            Right output -> do
              now <- liftIO getCurrentTime
              let row =
                    PersonaRow
                      { personaId,
                        namespace = scopeNamespaceText scope,
                        scopeKind = scopeKindText scope,
                        scopeRef = scopeRefText scope,
                        bodyMd = unField output.bodyMd,
                        sceneCount = length scenes,
                        sourceHash,
                        createdAt = now,
                        updatedAt = now
                      }
              runTransaction (Tx.statement row upsertPersonaStmt)
              liftIO (bestEffortMirrorPersona row)
              pure (Right (Just row))

fireL3PersonaTimer ::
  (IOE :> es, Store :> es) =>
  DistillRuntime ->
  TimerRow ->
  Eff es (Maybe EventId)
fireL3PersonaTimer rt row
  | row.processManagerName /= l3PersonaProcessManagerName =
      pure Nothing
  | otherwise =
      case Aeson.fromJSON @PersonaTimerPayload row.payload of
        Aeson.Error _err ->
          pure (Just (timerMarkerEventId row.timerId))
        Aeson.Success payload -> do
          result <- regeneratePersona rt payload.scope
          pure $
            case result of
              Right _ -> Just (timerMarkerEventId row.timerId)
              Left _ -> Nothing

getPersonaByScope ::
  (Store :> es) =>
  MemoryScope ->
  Eff es (Maybe PersonaRow)
getPersonaByScope scope =
  runTransaction $
    Tx.statement
      (scopeNamespaceText scope, scopeKindText scope, scopeRefText scope)
      selectPersonaByScopeStmt

getPersonaScenesByScope ::
  (Store :> es) =>
  MemoryScope ->
  Eff es [PersonaSceneRow]
getPersonaScenesByScope scope =
  runTransaction $
    Tx.statement
      (scopeNamespaceText scope, scopeKindText scope, scopeRefText scope)
      selectScenesForPersonaStmt

mirrorPersonaToCurrentWorkspace :: PersonaRow -> IO FilePath
mirrorPersonaToCurrentWorkspace row = do
  workspace <- getCurrentDirectory
  mirrorPersonaToWorkspace workspace row

mirrorPersonaToWorkspace :: FilePath -> PersonaRow -> IO FilePath
mirrorPersonaToWorkspace workspace row = do
  let path = personaMirrorPath workspace row
  createDirectoryIfMissing True (workspace </> ".kioku" </> "persona")
  TextIO.writeFile path (row.bodyMd <> "\n")
  pure path

personaMirrorPath :: FilePath -> PersonaRow -> FilePath
personaMirrorPath workspace row =
  workspace </> ".kioku" </> "persona" </> Text.unpack (personaScopeSlug row <> ".md")

bestEffortMirrorPersona :: PersonaRow -> IO ()
bestEffortMirrorPersona row = do
  _ <- try (mirrorPersonaToCurrentWorkspace row) :: IO (Either IOException FilePath)
  pure ()

personaScopeSlug :: PersonaRow -> Text
personaScopeSlug row =
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

personaRowId :: MemoryScope -> Text
personaRowId scope =
  "kioku_persona:" <> renderScope scope

personaSourceHash :: [PersonaSceneRow] -> Text
personaSourceHash scenes =
  "v1:" <> Text.pack (show (Hash.hash (BL.toStrict (Aeson.encode (sceneSource <$> scenes))) :: Digest SHA256))

sceneSource :: PersonaSceneRow -> (Text, Text, UTCTime)
sceneSource scene =
  (scene.sceneId, scene.bodyMd, scene.updatedAt)

renderScenes :: [PersonaSceneRow] -> Text
renderScenes =
  Text.intercalate "\n\n" . fmap renderScene

renderScene :: PersonaSceneRow -> Text
renderScene scene =
  "# " <> scene.title <> "\n\n" <> scene.bodyMd

renderScope :: MemoryScope -> Text
renderScope scope =
  Text.intercalate "/" $
    scopeNamespaceText scope : catMaybes [scopeKindText scope, scopeRefText scope]

timerMarkerEventId :: TimerId -> EventId
timerMarkerEventId (TimerId uuid) = EventId uuid

l3PersonaTimerNamespace :: UUID
l3PersonaTimerNamespace =
  fromMaybe UUID.nil $
    UUID.fromString "6b696f6b-752d-7133-8000-706572736f6e"

personaRowDecoder :: D.Row PersonaRow
personaRowDecoder =
  PersonaRow
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> (fromIntegral @Int32 @Int <$> D.column (D.nonNullable D.int4))
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)
    <*> D.column (D.nonNullable D.timestamptz)

personaSceneRowDecoder :: D.Row PersonaSceneRow
personaSceneRowDecoder =
  PersonaSceneRow
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.timestamptz)

personaRowEncoder :: E.Params PersonaRow
personaRowEncoder =
  ((\row -> row.personaId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\row -> row.scopeRef) >$< E.param (E.nullable E.text))
    <> ((\row -> row.bodyMd) >$< E.param (E.nonNullable E.text))
    <> ((fromIntegral @Int @Int32 . \row -> row.sceneCount) >$< E.param (E.nonNullable E.int4))
    <> ((\row -> row.sourceHash) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.createdAt) >$< E.param (E.nonNullable E.timestamptz))
    <> ((\row -> row.updatedAt) >$< E.param (E.nonNullable E.timestamptz))

selectPersonaByScopeStmt :: Statement (Text, Maybe Text, Maybe Text) (Maybe PersonaRow)
selectPersonaByScopeStmt =
  preparable
    """
    SELECT persona_id, namespace, scope_kind, scope_ref, body_md, scene_count,
           source_hash, created_at, updated_at
    FROM kioku_personas
    WHERE namespace = $1
      AND ((scope_kind = $2 AND scope_ref = $3)
           OR ($2 IS NULL AND scope_kind IS NULL AND $3 IS NULL AND scope_ref IS NULL))
    """
    ( contrazip3
        (E.param (E.nonNullable E.text))
        (E.param (E.nullable E.text))
        (E.param (E.nullable E.text))
    )
    (D.rowMaybe personaRowDecoder)

selectScenesForPersonaStmt :: Statement (Text, Maybe Text, Maybe Text) [PersonaSceneRow]
selectScenesForPersonaStmt =
  preparable
    """
    SELECT scene_id, title, body_md, updated_at
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
    (D.rowList personaSceneRowDecoder)

upsertPersonaStmt :: Statement PersonaRow ()
upsertPersonaStmt =
  preparable
    """
    INSERT INTO kioku_personas
      (persona_id, namespace, scope_kind, scope_ref, body_md, scene_count,
       source_hash, created_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
    ON CONFLICT (persona_id) DO UPDATE SET
      body_md = EXCLUDED.body_md,
      scene_count = EXCLUDED.scene_count,
      source_hash = EXCLUDED.source_hash,
      updated_at = EXCLUDED.updated_at
    """
    personaRowEncoder
    D.noResult
