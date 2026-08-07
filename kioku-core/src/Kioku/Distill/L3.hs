{-# LANGUAGE DataKinds #-}

module Kioku.Distill.L3
  ( L3Error (..),
    PersonaRow (..),
    fireL3PersonaTimer,
    getPersonaByScope,
    PersonaTimerPayload (..),
    l3PersonaProcessManagerName,
    l3PersonaTimerId,
    partitionedCorrelationId,
    mirrorPersonaToCurrentWorkspace,
    mirrorPersonaToWorkspace,
    personaMirrorPath,
    personaRowId,
    regeneratePersona,
    scheduleL3PersonaTimerTx,
  )
where

import Control.Exception (IOException, try)
import Crypto.Hash (Digest, SHA256)
import Crypto.Hash qualified as Hash
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (withObject, (.:))
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
import Kioku.Api.Access (MemoryContextProvider (..), MemorySpaceId, memoryContextSpace, memorySpaceIdText)
import Kioku.Api.Scope (MemoryScope, scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Distill.Persona (PersonaInput (..), PersonaOutput (..))
import Kioku.Distill.Runtime (DistillRuntime, distillWorkspaceRoot, runPersonaDistillation)
import Kioku.Distill.ScopeIdentity (scopeIdentity, scopeSlugFromColumns)
import Kioku.Distill.Timer.Outcome (FireOutcome (..), fireRetryDelay, timerMarkerEventId)
import Kioku.Partition (memorySpaceColumn, memorySpaceParam, parsePartitionSpace)
import Kioku.Prelude
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Transaction (runTransaction)
import Shikumi.Schema.Types (field, unField)
import System.Directory (createDirectoryIfMissing, doesFileExist, getCurrentDirectory, removeFile)
import System.FilePath ((</>))

data L3Error
  = L3SceneGenerationUnavailable
  | L3PersonaGenerationFailed !Text
  deriving stock (Generic, Show)

data PersonaRow = PersonaRow
  { memorySpaceId :: !MemorySpaceId,
    personaId :: !Text,
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

-- | What a scheduled persona regeneration needs to know.
--
-- @memorySpaceId@ is what keeps two spaces that happen to share a namespace and scope from
-- regenerating each other's persona. Timers scheduled before the field existed decode into
-- 'Kioku.Api.Access.legacyMemorySpaceId', the same rule stored events follow.
data PersonaTimerPayload = PersonaTimerPayload
  { memorySpaceId :: !MemorySpaceId,
    scope :: !MemoryScope
  }
  deriving stock (Generic, Eq, Show)
  deriving anyclass (ToJSON)

instance FromJSON PersonaTimerPayload where
  parseJSON =
    withObject "PersonaTimerPayload" \o ->
      PersonaTimerPayload <$> parsePartitionSpace o <*> o .: "scope"

l3PersonaProcessManagerName :: Text
l3PersonaProcessManagerName = "kioku-l3-persona"

personaDebounceSeconds :: NominalDiffTime
personaDebounceSeconds = 5

scheduleL3PersonaTimerTx :: MemorySpaceId -> MemoryScope -> UTCTime -> Tx.Transaction ()
scheduleL3PersonaTimerTx memorySpaceId scope now =
  scheduleTimerTx $
    TimerRequest
      { timerId = l3PersonaTimerId memorySpaceId scope fireAt,
        processManagerName = l3PersonaProcessManagerName,
        correlationId = partitionedCorrelationId memorySpaceId scope,
        fireAt,
        payload = Aeson.toJSON PersonaTimerPayload {memorySpaceId, scope}
      }
  where
    fireAt = addUTCTime personaDebounceSeconds now

-- | The timer id and correlation id both carry the memory space.
--
-- Unlike the L1 timers, which are keyed by a globally unique session id, these are keyed by a
-- scope — and two spaces are allowed to use the same one. Without the space in the id,
-- keiro's @scheduleTimerTx@ upsert would treat one space's regeneration as a re-arming of the
-- other's and only one payload would survive.
l3PersonaTimerId :: MemorySpaceId -> MemoryScope -> UTCTime -> TimerId
l3PersonaTimerId memorySpaceId scope fireAt =
  TimerId $
    UUIDv5.generateNamed
      l3PersonaTimerNamespace
      (BS.unpack (TE.encodeUtf8 raw))
  where
    raw =
      l3PersonaProcessManagerName
        <> ":"
        <> partitionedCorrelationId memorySpaceId scope
        <> ":"
        <> Text.pack (show fireAt)

-- | A scope identity qualified by its memory space. 'memorySpaceIdText' cannot contain @:@,
-- @\/@ or @%@ (see 'Kioku.Api.Access.mkMemorySpaceId') and 'scopeIdentity' escapes those same
-- characters, so joining the two with @:@ is injective.
partitionedCorrelationId :: MemorySpaceId -> MemoryScope -> Text
partitionedCorrelationId memorySpaceId scope =
  memorySpaceIdText memorySpaceId <> ":" <> scopeIdentity scope

regeneratePersona ::
  (IOE :> es, Store :> es) =>
  DistillRuntime ->
  MemorySpaceId ->
  MemoryScope ->
  Eff es (Either L3Error (Maybe PersonaRow))
regeneratePersona rt memorySpaceId scope = do
  scenes <- getPersonaScenesByScope memorySpaceId scope
  case scenes of
    -- Every scene in this scope is gone, so the persona distilled from them has
    -- no source left. Delete it and its mirror, symmetrically with the scene
    -- delete in "Kioku.Distill.L2", and without an LLM call: there is nothing
    -- to summarize. The persona is the top of the pyramid, so nothing chains on.
    [] -> do
      existing <- getPersonaByScope memorySpaceId scope
      case existing of
        Nothing -> pure (Right Nothing)
        Just row -> do
          runTransaction (Tx.statement (PersonaKey memorySpaceId row.personaId) deletePersonaStmt)
          liftIO (bestEffortRemovePersonaMirror rt row)
          pure (Right Nothing)
    _ -> do
      let sourceHash = personaSourceHash scenes
          personaId = personaRowId scope
      existing <- getPersonaByScope memorySpaceId scope
      case existing of
        Just row
          | row.sourceHash == sourceHash -> do
              liftIO (bestEffortMirrorPersona rt row)
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
                      { memorySpaceId,
                        personaId,
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
              liftIO (bestEffortMirrorPersona rt row)
              pure (Right (Just row))

-- | Fire one L3 persona timer.
--
-- Like the L1 handler, a background pass cannot arrive holding an authorization context: it
-- reads the memory space out of the payload and asks the provider for a decision about /that/
-- space. A refusal is a configuration fact, so it dead-letters rather than retrying forever.
fireL3PersonaTimer ::
  (IOE :> es, Store :> es) =>
  MemoryContextProvider (Eff es) ->
  DistillRuntime ->
  TimerRow ->
  Eff es FireOutcome
fireL3PersonaTimer contexts rt row
  | row.processManagerName /= l3PersonaProcessManagerName =
      pure FireNotMine
  | otherwise =
      case Aeson.fromJSON @PersonaTimerPayload row.payload of
        -- Unparseable now, unparseable on every retry: dead-letter rather than
        -- mark it fired and lose the persona silently.
        Aeson.Error err ->
          pure (FireFailedPermanently ("L3 persona timer payload is malformed: " <> Text.pack err))
        Aeson.Success payload -> do
          decision <- contexts.contextForSpace payload.memorySpaceId
          case decision of
            Left denial ->
              pure
                ( FireFailedPermanently
                    ("L3 persona timer is not authorized for its memory space: " <> Text.pack (show denial))
                )
            Right context -> do
              result <- regeneratePersona rt (memoryContextSpace context) payload.scope
              pure $
                case result of
                  Right _ -> FireCompleted (timerMarkerEventId row.timerId)
                  Left err -> FireRetryLater (fireRetryDelay row.attempts) (Text.pack (show err))

getPersonaByScope ::
  (Store :> es) =>
  MemorySpaceId ->
  MemoryScope ->
  Eff es (Maybe PersonaRow)
getPersonaByScope memorySpaceId scope =
  runTransaction $
    Tx.statement (scopeKey memorySpaceId scope) selectPersonaByScopeStmt

getPersonaScenesByScope ::
  (Store :> es) =>
  MemorySpaceId ->
  MemoryScope ->
  Eff es [PersonaSceneRow]
getPersonaScenesByScope memorySpaceId scope =
  runTransaction $
    Tx.statement (scopeKey memorySpaceId scope) selectScenesForPersonaStmt

-- | A scope lookup inside one memory space, as a record rather than a four-tuple so that the
-- partition cannot be transposed with the namespace it sits beside.
data PartitionedScope = PartitionedScope
  { memorySpaceId :: !MemorySpaceId,
    namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text)
  }

data PersonaKey = PersonaKey !MemorySpaceId !Text

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

bestEffortMirrorPersona :: DistillRuntime -> PersonaRow -> IO ()
bestEffortMirrorPersona rt row = do
  let write = do
        workspace <- distillWorkspaceRoot rt
        mirrorPersonaToWorkspace workspace row
  _ <- try write :: IO (Either IOException FilePath)
  pure ()

-- | Remove a persona's mirror file. Best-effort for the same reason writing it
-- is: the database row is the durable artifact and is already deleted.
bestEffortRemovePersonaMirror :: DistillRuntime -> PersonaRow -> IO ()
bestEffortRemovePersonaMirror rt row = do
  let remove = do
        workspace <- distillWorkspaceRoot rt
        let path = personaMirrorPath workspace row
        exists <- doesFileExist path
        when exists (removeFile path)
  _ <- try remove :: IO (Either IOException ())
  pure ()

personaScopeSlug :: PersonaRow -> Text
personaScopeSlug row =
  scopeSlugFromColumns row.namespace row.scopeKind row.scopeRef

-- | The persistent primary key of a persona row. Escaped, so two distinct scopes can never
-- derive the same id.
personaRowId :: MemoryScope -> Text
personaRowId scope =
  "kioku_persona:" <> scopeIdentity scope

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

-- | A human-readable scope label for the LLM prompt. Deliberately *not* escaped and
-- deliberately not used for identity: a collision here is cosmetic. Identity comes from
-- 'scopeIdentity'.
renderScope :: MemoryScope -> Text
renderScope scope =
  Text.intercalate "/" $
    scopeNamespaceText scope : catMaybes [scopeKindText scope, scopeRefText scope]

l3PersonaTimerNamespace :: UUID
l3PersonaTimerNamespace =
  fromMaybe UUID.nil $
    UUID.fromString "6b696f6b-752d-7133-8000-706572736f6e"

personaRowDecoder :: D.Row PersonaRow
personaRowDecoder =
  PersonaRow
    <$> memorySpaceColumn
    <*> D.column (D.nonNullable D.text)
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
  ((\row -> row.memorySpaceId) >$< memorySpaceParam)
    <> ((\row -> row.personaId) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\row -> row.scopeRef) >$< E.param (E.nullable E.text))
    <> ((\row -> row.bodyMd) >$< E.param (E.nonNullable E.text))
    <> ((fromIntegral @Int @Int32 . \row -> row.sceneCount) >$< E.param (E.nonNullable E.int4))
    <> ((\row -> row.sourceHash) >$< E.param (E.nonNullable E.text))
    <> ((\row -> row.createdAt) >$< E.param (E.nonNullable E.timestamptz))
    <> ((\row -> row.updatedAt) >$< E.param (E.nonNullable E.timestamptz))

selectPersonaByScopeStmt :: Statement PartitionedScope (Maybe PersonaRow)
selectPersonaByScopeStmt =
  preparable
    """
    SELECT memory_space_id, persona_id, namespace, scope_kind, scope_ref, body_md, scene_count,
           source_hash, created_at, updated_at
    FROM kioku_personas
    WHERE memory_space_id = $1
      AND namespace = $2
      AND ((scope_kind = $3 AND scope_ref = $4)
           OR ($3 IS NULL AND scope_kind IS NULL AND $4 IS NULL AND scope_ref IS NULL))
    """
    partitionedScopeEncoder
    (D.rowMaybe personaRowDecoder)

selectScenesForPersonaStmt :: Statement PartitionedScope [PersonaSceneRow]
selectScenesForPersonaStmt =
  preparable
    """
    SELECT scene_id, title, body_md, updated_at
    FROM kioku_scenes
    WHERE memory_space_id = $1
      AND namespace = $2
      AND ((scope_kind = $3 AND scope_ref = $4)
           OR ($3 IS NULL AND scope_kind IS NULL AND $4 IS NULL AND scope_ref IS NULL))
    ORDER BY scene_key ASC, updated_at DESC
    """
    partitionedScopeEncoder
    (D.rowList personaSceneRowDecoder)

-- | Delete by the row's own primary key, for the same reason 'deleteSceneStmt' does: the
-- scope-identity string format is not re-implemented here. That key is now composite, because
-- the persona id alone is derived from the scope and two spaces may share one.
deletePersonaStmt :: Statement PersonaKey ()
deletePersonaStmt =
  preparable
    "DELETE FROM kioku_personas WHERE memory_space_id = $1 AND persona_id = $2"
    ( ((\(PersonaKey space _) -> space) >$< memorySpaceParam)
        <> ((\(PersonaKey _ personaId) -> personaId) >$< E.param (E.nonNullable E.text))
    )
    D.noResult

upsertPersonaStmt :: Statement PersonaRow ()
upsertPersonaStmt =
  preparable
    """
    INSERT INTO kioku_personas
      (memory_space_id, persona_id, namespace, scope_kind, scope_ref, body_md, scene_count,
       source_hash, created_at, updated_at)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
    ON CONFLICT (memory_space_id, persona_id) DO UPDATE SET
      body_md = EXCLUDED.body_md,
      scene_count = EXCLUDED.scene_count,
      source_hash = EXCLUDED.source_hash,
      updated_at = EXCLUDED.updated_at
    """
    personaRowEncoder
    D.noResult
