{-# LANGUAGE DataKinds #-}

module Kioku.DistillSpec
  ( tests,
  )
where

import Baikai (Response, _Response, _TextContent)
import Baikai.Content (AssistantContent (..))
import Baikai.Embedding (EmbeddingModel)
import Data.Aeson qualified as Aeson
import Data.ByteString.Lazy qualified as BL
import Data.Foldable (traverse_)
import Data.Functor.Contravariant ((>$<))
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Int (Int64)
import Data.Set qualified as Set
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Data.Text.IO qualified as TextIO
import Data.Time (addUTCTime, diffUTCTime)
import Data.Vector qualified as Vector
import Effectful (Eff, IOE, runEff, (:>))
import Effectful.Dispatch.Dynamic (interpret)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Effectful.Prim (runPrim)
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Statement (Statement, preparable)
import Hasql.Transaction qualified as Tx
import Keiro.Stream qualified as Stream
import Keiro.Timer (countDueTimers)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..), scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Api.Types (Confidence (..), MemoryType (..))
import Kioku.App (AppEnv (..), noopTracer, runAppIO)
import Kioku.Distill.Consolidate (ConsolidateInput (..), ConsolidationAction (..), ConsolidationDecision (..), ExistingMemory (..), consolidateProgram)
import Kioku.Distill.Extract (ExtractOutput (..), ExtractedAtom (..), extractProgram)
import Kioku.Distill.L1 (L1Error (..), L1Outcome (..), L1RunMode (..), L1Summary (..), distillSessionL1, recallCandidates, scopedScanCandidates)
import Kioku.Distill.L2 (SceneRow (..), getScenesByScope, regenerateScene, sceneMirrorPath)
import Kioku.Distill.L3 (PersonaRow (..), getPersonaByScope, personaMirrorPath, regeneratePersona)
import Kioku.Distill.Persona (personaProgram)
import Kioku.Distill.Runtime (DistillRuntime (..), newDistillRuntime)
import Kioku.Distill.Scene (SceneInput (..), sceneProgram)
import Kioku.Distill.Timer (idleFlushSeconds, l1ExtractProcessManagerName)
import Kioku.Distill.Timer.Worker (runKiokuTimerWorkerOnce)
import Kioku.Id (MemoryId, SessionId, genMemoryId, genSessionId, idText, parseIdLenient)
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain
  ( ArchiveMemoryData (..),
    RecordMemoryData (..),
    SupersedeMemoryData (..),
    UpdateMemoryConfidenceData (..),
    UpdateMemoryTagsData (..),
  )
import Kioku.Memory.Embedding (EmbeddingConfig (..), toEmbeddingModel)
import Kioku.Memory.EventStream (memoryStream)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Kioku.Prelude
import Kioku.Recall.Capability (VectorCapability (..))
import Kioku.Session qualified as Session
import Kioku.Session.Domain (CompleteSessionData (..), RecordTurnData (..), StartSessionData (..))
import Kiroku.Store.Connection (defaultConnectionSettings, withStore)
import Kiroku.Store.Effect (Store)
import Kiroku.Store.Error (StoreError)
import Kiroku.Store.Read (readStreamForward)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (EventType (..), RecordedEvent (..), StreamVersion (..))
import Shikumi.Effect.Time (runTime)
import Shikumi.Error (ShikumiError (..))
import Shikumi.LLM (LLM (..))
import Shikumi.Program (Program, runProgram)
import Shikumi.Schema (Validatable (..))
import Shikumi.Schema.Types (field, unField)
import Shikumi.Trace (runTrace, tracedLLM)
import Shikumi.Trace.Replay (runLLMReplay)
import Shikumi.Trace.Store (replayIndex)
import System.Directory (doesFileExist)
import System.IO.Temp (withSystemTempDirectory)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (Assertion, assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Distillation pyramid"
    [ testCase "replay distills duplicate turns into merged atom scene and persona" testReplayDistillation,
      testCase "re-running distillSessionL1 creates no new memories or audit rows" testRerunIdempotent,
      testCase "consolidation failure stores nothing and fails the pass" testConsolidationFailure,
      testCase "merge with a missing target drops it and stays convergent" testMergeMissingTarget,
      testCase "watermark skips re-extraction until a new turn arrives" testWatermarkSkip,
      testCase "a session accumulates one idle timer however many turns" testIdleTimerCollapse,
      testCase "recall candidates find a duplicate outside the scan window" testRecallCandidateWindow,
      forgetPropagationTests,
      confidencePropagationTests,
      validationTests
    ]

-- | Forgetting a memory must reach every derived artifact: the scene row, the
-- persona row, and the plaintext mirror files a host agent actually reads.
forgetPropagationTests :: TestTree
forgetPropagationTests =
  testGroup
    "Forget propagation"
    [ testCase "forget operations schedule scene timers" testForgetSchedulesSceneTimers,
      testCase "an emptied scope deletes its scene, persona, and mirrors" testEmptyScopeDeletesArtifacts,
      testCase "the timer worker propagates an archive to every artifact" testWorkerPropagatesArchive,
      testCase "supersede and merge propagate like archive" testWorkerPropagatesSupersedeAndMerge
    ]

-- | A memory's confidence is part of what its scope's scene is built from: it is
-- hashed into the scene's source hash ('atomSource') and written into the LLM's
-- prompt ('renderAtom'). Changing it must therefore refresh the scene, exactly as
-- forgetting does — otherwise an agent that downgrades a belief to @low@ goes on
-- reading a scene that asserts it at @high@.
confidencePropagationTests :: TestTree
confidencePropagationTests =
  testGroup
    "Confidence propagation"
    [ testCase "two confidence changes schedule two distinct scene timers" testConfidenceSchedulesDistinctSceneTimers,
      testCase "a tag change schedules nothing, because tags are not in the scene" testTagsUpdateSchedulesNoSceneTimer,
      testCase "a confidence change refreshes the scene, the persona, and the mirrors" testWorkerPropagatesConfidence
    ]

-- | The case that guards the trap. A naive fix gives the confidence timer a fixed
-- source id of @\<memoryId\>:confidence@, which derives the same UUIDv5 timer id
-- every time — and keiro's scheduling upsert only re-arms a conflicting timer
-- @WHERE status = 'scheduled'@, so the second change would update zero rows and be
-- silently dropped. That fix would refresh the scene on the first change and never
-- again: it would look fixed, and be worse than the bug. The delta-count below is
-- the only thing standing between that mistake and production, so it asserts the
-- count rises on *both* changes, not just the first.
--
-- The walk is genuinely @high -> medium -> low@ on purpose: 'Memory.updateConfidence'
-- refuses to emit an event when the confidence is unchanged, so re-applying the same
-- value would schedule nothing and pass this test for the wrong reason.
--
-- No session is written, so every timer counted here is an L2 scene timer.
testConfidenceSchedulesDistinctSceneTimers :: Assertion
testConfidenceSchedulesDistinctSceneTimers = withDistillEnv \env -> do
  now <- getCurrentTime
  memoryId <- genMemoryId
  let scope = forgetScope "intention_confidence_timers"
      -- Timers are debounced 5 seconds past their event time; an hour out makes
      -- every one of them due.
      horizon = addUTCTime 3600 now
  result <-
    runAppIO env do
      recordForgetFixture memoryId scope "Content for the confidence timer test" now
      afterRecord <- countDueTimers horizon

      lowered <-
        Memory.updateConfidence
          UpdateMemoryConfidenceData {memoryId, confidence = MediumConfidence, updatedAt = now}
      void (liftIO (expectRight "Memory.updateConfidence to medium" lowered))
      afterFirst <- countDueTimers horizon

      loweredAgain <-
        Memory.updateConfidence
          UpdateMemoryConfidenceData {memoryId, confidence = LowConfidence, updatedAt = now}
      void (liftIO (expectRight "Memory.updateConfidence to low" loweredAgain))
      afterSecond <- countDueTimers horizon
      pure (afterRecord, afterFirst, afterSecond)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (afterRecord, afterFirst, afterSecond) -> do
      afterRecord @?= 1
      afterFirst @?= 2
      afterSecond @?= 3

-- | Tags are in neither 'atomSource' (the scene's source hash) nor 'renderAtom'
-- (the LLM prompt), so a tag change cannot alter the scene. Scheduling a
-- regeneration for one would spend an LLM call to rewrite a byte-identical row.
-- This case pins that reasoning so a future reader does not "complete" the
-- confidence fix by adding an arm for 'MemoryTagsUpdated' too.
testTagsUpdateSchedulesNoSceneTimer :: Assertion
testTagsUpdateSchedulesNoSceneTimer = withDistillEnv \env -> do
  now <- getCurrentTime
  memoryId <- genMemoryId
  let scope = forgetScope "intention_tags_timers"
      horizon = addUTCTime 3600 now
  result <-
    runAppIO env do
      recordForgetFixture memoryId scope "Content for the tags timer test" now
      afterRecord <- countDueTimers horizon

      -- A genuinely different tag set: 'Memory.updateTags' short-circuits on an
      -- unchanged one, which would make this pass for the wrong reason.
      retagResult <-
        Memory.updateTags
          UpdateMemoryTagsData {memoryId, tags = Set.fromList ["retagged"], updatedAt = now}
      void (liftIO (expectRight "Memory.updateTags" retagResult))
      afterRetag <- countDueTimers horizon
      pure (afterRecord, afterRetag)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (afterRecord, afterRetag) -> do
      afterRecord @?= 1
      afterRetag @?= 1

-- | The whole pipeline, with nothing called by hand: lowering a memory's confidence
-- schedules a timer through the inline projection, the worker claims and fires it
-- exactly as @kioku worker@ does, and the scene row, the persona row, and the
-- plaintext mirror a host agent actually reads all follow.
testWorkerPropagatesConfidence :: Assertion
testWorkerPropagatesConfidence = withDistillWorkspaceEnv \env workspace -> do
  calls <- newDistillCalls
  runtime <- echoingRuntime calls <$> replayRuntimeIn workspace
  memoryId <- genMemoryId
  now <- getCurrentTime
  let scope = forgetScope "intention_confidence_worker"
  result <-
    runAppIO env do
      -- 'recordForgetFixture' records at 'HighConfidence'.
      recordForgetFixture memoryId scope confidenceContent now
      void (drainTimers runtime)
      builtScene <- getScenesByScope scope >>= liftIO . expectOneScene "the initial distillation"
      builtPersona <-
        getPersonaByScope scope >>= liftIO . expectJust "a persona after the initial distillation"
      personaRunsBefore <- liftIO (readIORef calls.personaCalls)

      lowered <-
        Memory.updateConfidence
          UpdateMemoryConfidenceData {memoryId, confidence = LowConfidence, updatedAt = now}
      void (liftIO (expectRight "Memory.updateConfidence" lowered))
      void (drainTimers runtime)

      refreshedScene <-
        getScenesByScope scope >>= liftIO . expectOneScene "after lowering the confidence"
      refreshedPersona <-
        getPersonaByScope scope >>= liftIO . expectJust "a persona after lowering the confidence"
      personaRunsAfter <- liftIO (readIORef calls.personaCalls)
      mirror <- liftIO (TextIO.readFile (sceneMirrorPath workspace refreshedScene))

      -- Timer firing is at-least-once, so another pass must change nothing.
      refired <- drainTimers runtime
      pure
        ( builtScene,
          refreshedScene,
          builtPersona,
          refreshedPersona,
          personaRunsBefore,
          personaRunsAfter,
          mirror,
          refired
        )
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (builtScene, refreshedScene, builtPersona, refreshedPersona, personaRunsBefore, personaRunsAfter, mirror, refired) -> do
      -- The crisp, LLM-independent proof that the scene was genuinely rebuilt: the
      -- source hash is computed over 'atomSource', which contains the confidence.
      assertBool
        ("the scene kept its stale source hash: " <> Text.unpack refreshedScene.sourceHash)
        (refreshedScene.sourceHash /= builtScene.sourceHash)

      -- The prompt the scene distiller actually saw. 'renderAtom' formats each
      -- memory as "- <id> (<type>, <confidence>): <content>".
      atoms <- latestSceneAtoms calls
      assertBool
        ("the scene LLM still saw the old confidence: " <> Text.unpack atoms)
        (not (highNeedle `Text.isInfixOf` atoms))
      assertBool
        ("the scene LLM never saw the new confidence: " <> Text.unpack atoms)
        (lowNeedle `Text.isInfixOf` atoms)

      -- ...and, the point of the whole plan, the plaintext file on disk.
      assertBool
        ("the scene mirror still asserts the old confidence: " <> Text.unpack mirror)
        (not (highNeedle `Text.isInfixOf` mirror))
      assertBool
        ("the scene mirror never learned the new confidence: " <> Text.unpack mirror)
        (lowNeedle `Text.isInfixOf` mirror)

      -- The persona cascades off the scene write. Persona bodies are built from
      -- scene titles and bodies, so they inherit the confidence transitively; the
      -- observable here is the fact of regeneration, not persona text saying "low".
      assertBool
        "the persona was not regenerated after the scene changed"
        (personaRunsAfter > personaRunsBefore)
      assertBool
        "the persona row was not rewritten after the scene changed"
        (refreshedPersona.updatedAt >= builtPersona.updatedAt)

      refired @?= 0

confidenceContent :: Text
confidenceContent = "The user prefers tabs over spaces."

-- | 'renderAtom' renders "- <id> (<type>, <confidence>): <content>", and
-- 'recordForgetFixture' records a 'MemoryPreference'. Matching the parenthesised
-- pair rather than a bare "high"/"low" keeps the assertion from colliding with
-- any occurrence of those words in the memory's content.
highNeedle :: Text
highNeedle = "(preference, high)"

lowNeedle :: Text
lowNeedle = "(preference, low)"

alphaContent :: Text
alphaContent = "The alpha secret is that the launch slipped to March."

alphaNeedle :: Text
alphaNeedle = "alpha secret"

betaContent :: Text
betaContent = "The beta fact is that the docs live in ops/README.md."

betaNeedle :: Text
betaNeedle = "beta fact"

oldAddressContent :: Text
oldAddressContent = "The user is at 12 Elm Street."

oldAddressNeedle :: Text
oldAddressNeedle = "12 Elm Street"

newAddressContent :: Text
newAddressContent = "The user is at 9 Oak Lane."

newAddressNeedle :: Text
newAddressNeedle = "9 Oak Lane"

loserContent :: Text
loserContent = "The user mentioned gamma trivia once."

loserNeedle :: Text
loserNeedle = "gamma trivia"

winnerContent :: Text
winnerContent = "The user relies on delta truth daily."

-- | The privacy-shaped case. Forgetting the last memory in a scope must take the
-- scene and persona with it — row and plaintext mirror alike — and must not pay
-- an LLM to summarize what is no longer there.
testEmptyScopeDeletesArtifacts :: Assertion
testEmptyScopeDeletesArtifacts = withDistillWorkspaceEnv \env workspace -> do
  calls <- newDistillCalls
  runtime <- countingRuntime calls <$> replayRuntimeIn workspace
  alphaId <- genMemoryId
  betaId <- genMemoryId
  now <- getCurrentTime
  let scope = forgetScope "intention_forget_empty"
  result <-
    runAppIO env do
      recordForgetFixture alphaId scope alphaContent now
      recordForgetFixture betaId scope betaContent now

      firstScene <- regenerateScene runtime scope
      sceneRow <- liftIO (expectJustRow "the first regeneration writes a scene" firstScene)
      firstPersona <- regeneratePersona runtime scope
      personaRow <- liftIO (expectJustRow "the first regeneration writes a persona" firstPersona)

      -- Both mirrors have to be observed here, while they still exist: the whole
      -- point of what follows is that they stop existing.
      let scenePath = sceneMirrorPath workspace sceneRow
          personaPath = personaMirrorPath workspace personaRow
      mirrorsWritten <-
        liftIO ((&&) <$> doesFileExist scenePath <*> doesFileExist personaPath)

      -- Forget one of the two: the scene must rebuild from the survivor alone.
      archivedAlpha <- Memory.archive ArchiveMemoryData {memoryId = alphaId, archivedAt = now}
      void (liftIO (expectRight "Memory.archive alpha" archivedAlpha))
      afterOne <- regenerateScene runtime scope
      survivorScene <- liftIO (expectJustRow "the scene survives one forget" afterOne)

      -- Forget the last one: nothing may be left to regenerate from.
      archivedBeta <- Memory.archive ArchiveMemoryData {memoryId = betaId, archivedAt = now}
      void (liftIO (expectRight "Memory.archive beta" archivedBeta))
      emptyScene <- regenerateScene runtime scope
      emptyPersona <- regeneratePersona runtime scope

      scenes <- getScenesByScope scope
      persona <- getPersonaByScope scope
      pure (mirrorsWritten, scenePath, personaPath, survivorScene, emptyScene, emptyPersona, scenes, persona)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (mirrorsWritten, scenePath, personaPath, survivorScene, emptyScene, emptyPersona, scenes, persona) -> do
      assertBool "the scene and persona mirrors were written to begin with" mirrorsWritten

      -- The forgotten memory is gone from what the scene is built from.
      atoms <- latestSceneAtoms calls
      assertBool
        ("forgotten content reached the scene LLM: " <> Text.unpack atoms)
        (not (alphaNeedle `Text.isInfixOf` atoms))
      survivorScene.atomIds @?= [idText betaId]

      -- The emptied scope keeps no artifact anywhere.
      case emptyScene of
        Right Nothing -> pure ()
        other -> assertFailure ("expected no scene for an emptied scope, got " <> show other)
      case emptyPersona of
        Right Nothing -> pure ()
        other -> assertFailure ("expected no persona for an emptied scope, got " <> show other)
      scenes @?= []
      persona @?= Nothing
      doesFileExist scenePath
        >>= \exists -> assertBool "the scene mirror was removed" (not exists)
      doesFileExist personaPath
        >>= \exists -> assertBool "the persona mirror was removed" (not exists)

      -- Neither empty regeneration paid for an LLM call: two scene runs (the
      -- initial build and the rebuild from the survivor) and one persona run.
      readIORef calls.sceneCalls >>= \runs -> runs @?= 2
      readIORef calls.personaCalls >>= \runs -> runs @?= 1

-- | Archive, supersede, and merge each leave behind exactly one scene timer,
-- just as recording does. No session is written, so every timer counted here is
-- an L2 scene timer.
testForgetSchedulesSceneTimers :: Assertion
testForgetSchedulesSceneTimers = withDistillEnv \env -> do
  now <- getCurrentTime
  archivedId <- genMemoryId
  supersededId <- genMemoryId
  supersederId <- genMemoryId
  loserId <- genMemoryId
  winnerId <- genMemoryId
  let scope = forgetScope "intention_forget_timers"
      -- Timers are debounced 5 seconds past their event time; an hour out makes
      -- every one of them due.
      horizon = addUTCTime 3600 now
  result <-
    runAppIO env do
      traverse_
        (\mid -> recordForgetFixture mid scope ("Content for " <> idText mid) now)
        [archivedId, supersededId, supersederId, loserId, winnerId]
      afterRecords <- countDueTimers horizon

      archived <- Memory.archive ArchiveMemoryData {memoryId = archivedId, archivedAt = now}
      void (liftIO (expectRight "Memory.archive" archived))
      afterArchive <- countDueTimers horizon

      superseded <-
        Memory.supersede
          SupersedeMemoryData
            { memoryId = supersededId,
              supersededBy = supersederId,
              supersededAt = now
            }
      void (liftIO (expectRight "Memory.supersede" superseded))
      afterSupersede <- countDueTimers horizon

      merged <- Memory.merge loserId winnerId
      void (liftIO (expectRight "Memory.merge" merged))
      afterMerge <- countDueTimers horizon
      pure (afterRecords, afterArchive, afterSupersede, afterMerge)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (afterRecords, afterArchive, afterSupersede, afterMerge) -> do
      afterRecords @?= 5
      afterArchive @?= 6
      afterSupersede @?= 7
      afterMerge @?= 8

-- | The whole pipeline, with nothing called by hand: a forget command schedules a
-- timer through the inline projection, the worker claims and fires it exactly as
-- @kioku worker@ does, and the scene, persona, and both plaintext mirrors follow.
testWorkerPropagatesArchive :: Assertion
testWorkerPropagatesArchive = withDistillWorkspaceEnv \env workspace -> do
  calls <- newDistillCalls
  runtime <- echoingRuntime calls <$> replayRuntimeIn workspace
  alphaId <- genMemoryId
  betaId <- genMemoryId
  now <- getCurrentTime
  let scope = forgetScope "intention_forget_worker"
  result <-
    runAppIO env do
      recordForgetFixture alphaId scope alphaContent now
      recordForgetFixture betaId scope betaContent now
      void (drainTimers runtime)

      builtScene <- getScenesByScope scope >>= liftIO . expectOneScene "the initial distillation"
      builtPersona <-
        getPersonaByScope scope >>= liftIO . expectJust "a persona after the initial distillation"
      let scenePath = sceneMirrorPath workspace builtScene
          personaPath = personaMirrorPath workspace builtPersona
      builtMirrors <- liftIO ((&&) <$> doesFileExist scenePath <*> doesFileExist personaPath)

      -- Forget alpha. The worker has to rebuild the scene from the survivor.
      archivedAlpha <- Memory.archive ArchiveMemoryData {memoryId = alphaId, archivedAt = now}
      void (liftIO (expectRight "Memory.archive alpha" archivedAlpha))
      void (drainTimers runtime)
      survivorScene <- getScenesByScope scope >>= liftIO . expectOneScene "after forgetting alpha"
      survivorMirror <- liftIO (TextIO.readFile scenePath)

      -- Forget beta, the last one. Every artifact has to go with it.
      archivedBeta <- Memory.archive ArchiveMemoryData {memoryId = betaId, archivedAt = now}
      void (liftIO (expectRight "Memory.archive beta" archivedBeta))
      void (drainTimers runtime)
      emptyScenes <- getScenesByScope scope
      emptyPersona <- getPersonaByScope scope
      survivingMirrors <- liftIO ((||) <$> doesFileExist scenePath <*> doesFileExist personaPath)

      -- Timer firing is at-least-once, so another pass must change nothing.
      refired <- drainTimers runtime
      pure
        ( builtMirrors,
          survivorScene,
          survivorMirror,
          emptyScenes,
          emptyPersona,
          survivingMirrors,
          refired
        )
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (builtMirrors, survivorScene, survivorMirror, emptyScenes, emptyPersona, survivingMirrors, refired) -> do
      assertBool "the worker wrote both mirrors to begin with" builtMirrors

      -- The forgotten memory is gone from the scene's inputs and its metadata...
      atoms <- latestSceneAtoms calls
      assertBool
        ("forgotten content reached the scene LLM: " <> Text.unpack atoms)
        (not (alphaNeedle `Text.isInfixOf` atoms))
      survivorScene.atomIds @?= [idText betaId]

      -- ...and, the point of the whole plan, from the plaintext file on disk.
      assertBool
        ("the forgotten text is still in the scene mirror: " <> Text.unpack survivorMirror)
        (not (alphaNeedle `Text.isInfixOf` survivorMirror))
      assertBool
        ("the surviving memory vanished from the scene mirror: " <> Text.unpack survivorMirror)
        (betaNeedle `Text.isInfixOf` survivorMirror)

      -- Forgetting the last memory empties the scope entirely.
      emptyScenes @?= []
      emptyPersona @?= Nothing
      assertBool "a mirror file survived an emptied scope" (not survivingMirrors)

      refired @?= 0

-- | Archive is not a special case: superseding and merging retire a memory the
-- same way, and must reach the scene the same way.
testWorkerPropagatesSupersedeAndMerge :: Assertion
testWorkerPropagatesSupersedeAndMerge = withDistillWorkspaceEnv \env workspace -> do
  supersedeCalls <- newDistillCalls
  mergeCalls <- newDistillCalls
  supersedeRuntime <- echoingRuntime supersedeCalls <$> replayRuntimeIn workspace
  mergeRuntime <- echoingRuntime mergeCalls <$> replayRuntimeIn workspace
  oldId <- genMemoryId
  newId <- genMemoryId
  loserId <- genMemoryId
  winnerId <- genMemoryId
  now <- getCurrentTime
  let supersedeScope = forgetScope "intention_forget_supersede"
      mergeScope = forgetScope "intention_forget_merge"
  result <-
    runAppIO env do
      -- Supersession, in its own scope. Drain between the two scopes so each
      -- runtime only ever sees its own timers.
      recordForgetFixture oldId supersedeScope oldAddressContent now
      recordForgetFixture newId supersedeScope newAddressContent now
      void (drainTimers supersedeRuntime)
      superseded <-
        Memory.supersede
          SupersedeMemoryData {memoryId = oldId, supersededBy = newId, supersededAt = now}
      void (liftIO (expectRight "Memory.supersede" superseded))
      void (drainTimers supersedeRuntime)
      supersedeScene <-
        getScenesByScope supersedeScope >>= liftIO . expectOneScene "after superseding"

      -- Merge, in a second scope.
      recordForgetFixture loserId mergeScope loserContent now
      recordForgetFixture winnerId mergeScope winnerContent now
      void (drainTimers mergeRuntime)
      merged <- Memory.merge loserId winnerId
      void (liftIO (expectRight "Memory.merge" merged))
      void (drainTimers mergeRuntime)
      mergeScene <- getScenesByScope mergeScope >>= liftIO . expectOneScene "after merging"

      pure (supersedeScene, mergeScene)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (supersedeScene, mergeScene) -> do
      supersedeAtoms <- latestSceneAtoms supersedeCalls
      assertBool
        ("superseded content reached the scene LLM: " <> Text.unpack supersedeAtoms)
        (not (oldAddressNeedle `Text.isInfixOf` supersedeAtoms))
      assertBool
        ("the superseding content is missing from the scene: " <> Text.unpack supersedeAtoms)
        (newAddressNeedle `Text.isInfixOf` supersedeAtoms)
      supersedeScene.atomIds @?= [idText newId]

      mergeAtoms <- latestSceneAtoms mergeCalls
      assertBool
        ("merged-away content reached the scene LLM: " <> Text.unpack mergeAtoms)
        (not (loserNeedle `Text.isInfixOf` mergeAtoms))
      mergeScene.atomIds @?= [idText winnerId]

-- | Fire due timers until none are claimable, looking an hour ahead so both the
-- 5-second scene debounce and the persona timer chained off a scene write are
-- due. Bounded on purpose: a timer that rescheduled itself would otherwise spin
-- here forever, and a hung test is worse than a failed one.
drainTimers ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  DistillRuntime ->
  Eff es Int
drainTimers rt = go (50 :: Int) 0
  where
    go fuel fired
      | fuel <= 0 = liftIO (assertFailure "the timer drain did not converge within 50 fires")
      | otherwise = do
          realNow <- liftIO getCurrentTime
          claimed <-
            runKiokuTimerWorkerOnce
              Nothing
              rt
              (scopedScanCandidates 5)
              (addUTCTime 3600 realNow)
          case claimed of
            Nothing -> pure fired
            Just _ -> go (fuel - 1) (fired + 1)

expectOneScene :: String -> [SceneRow] -> IO SceneRow
expectOneScene label = \case
  [row] -> pure row
  other -> assertFailure (label <> ": expected exactly one scene, got " <> show (length other))

expectJust :: String -> Maybe a -> IO a
expectJust label =
  maybe (assertFailure (label <> ": expected a value, got none")) pure

forgetScope :: Text -> MemoryScope
forgetScope =
  ScopeEntity (Namespace "rei") (ScopeKind "intention")

recordForgetFixture ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  MemoryId ->
  MemoryScope ->
  Text ->
  UTCTime ->
  Eff es ()
recordForgetFixture memoryId scope content now = do
  recorded <-
    Memory.record
      RecordMemoryData
        { memoryId,
          agentId = "test-agent",
          sessionId = Nothing,
          scope,
          memoryType = MemoryPreference,
          content,
          priority = 50,
          confidence = HighConfidence,
          tags = Set.fromList ["forget-test"],
          supersedes = Nothing,
          recordedAt = now
        }
  void (liftIO (expectRight "Memory.record" recorded))

-- | Pure tests over the 'Validatable' instances; no database, no LLM.
validationTests :: TestTree
validationTests =
  testGroup
    "extract and consolidate outputs are clamped and rejected"
    [ testCase "priority is clamped into [0, 100]" do
        validatedAtom (atomWith "preference" "Keep it short." (-1000000) "high")
          >>= \atom -> unField atom.priority @?= 0
        validatedAtom (atomWith "preference" "Keep it short." 250 "high")
          >>= \atom -> unField atom.priority @?= 100,
      testCase "atomType and confidence are lowercased" do
        atom <- validatedAtom (atomWith "  Preference " "Keep it short." 50 "HIGH")
        unField atom.atomType @?= "preference"
        unField atom.confidence @?= "high",
      testCase "an unknown atomType is rejected" $
        assertValidationFailure "atomType" (ExtractOutput [atomWith "vibe" "Keep it short." 50 "high"]),
      testCase "an unknown confidence is rejected" $
        assertValidationFailure "confidence" (ExtractOutput [atomWith "fact" "Keep it short." 50 "certain"]),
      testCase "blank atom content is rejected" $
        assertValidationFailure "atom content" (ExtractOutput [atomWith "fact" "   " 50 "high"]),
      testCase "StoreAtom and SkipAtom drop stray targets" do
        stored <- expectValid (decisionWith StoreAtom ["kioku_memory_01hxxx"])
        stored.targetMemoryIds @?= []
        skipped <- expectValid (decisionWith SkipAtom ["garbage"])
        skipped.targetMemoryIds @?= [],
      testCase "MergeAtom and UpdateAtom require at least one target" do
        assertValidationFailure "MergeAtom requires" (decisionWith MergeAtom [])
        assertValidationFailure "UpdateAtom requires" (decisionWith UpdateAtom []),
      testCase "an unparseable target id is rejected" $
        assertValidationFailure "unparseable id" (decisionWith MergeAtom ["not-a-typeid"]),
      testCase "a parseable target id is accepted unchanged" do
        target <- idText <$> genMemoryId
        decision <- expectValid (decisionWith MergeAtom [target])
        decision.targetMemoryIds @?= [target]
    ]

atomWith :: Text -> Text -> Int -> Text -> ExtractedAtom
atomWith atomType content priority confidence =
  ExtractedAtom
    { atomType = field atomType,
      content = field content,
      priority = field priority,
      confidence = field confidence
    }

decisionWith :: ConsolidationAction -> [Text] -> ConsolidationDecision
decisionWith action targetMemoryIds =
  ConsolidationDecision
    { action,
      targetMemoryIds,
      resultContent = Nothing,
      rationale = field "because"
    }

validatedAtom :: ExtractedAtom -> IO ExtractedAtom
validatedAtom atom = do
  output <- expectValid (ExtractOutput [atom])
  case output.atoms of
    [validated] -> pure validated
    other -> assertFailure ("expected exactly one atom, got " <> show (length other))

expectValid :: (Validatable a) => a -> IO a
expectValid value =
  case validate value of
    Left err -> assertFailure ("expected a valid value, got: " <> Text.unpack err)
    Right ok -> pure ok

assertValidationFailure :: (Validatable a, Show a) => Text -> a -> Assertion
assertValidationFailure needle value =
  case validate value of
    Right ok -> assertFailure ("expected a validation failure, got: " <> show ok)
    Left err ->
      assertBool
        ("validation message should mention " <> show needle <> ", got: " <> Text.unpack err)
        (needle `Text.isInfixOf` err)

data MemoryStatus = MemoryStatus
  { memoryId :: !Text,
    content :: !Text,
    status :: !Text
  }
  deriving stock (Generic, Eq, Show)

data ScopeParams = ScopeParams
  { namespace :: !Text,
    scopeKind :: !(Maybe Text),
    scopeRef :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data AuditRowView = AuditRowView
  { decision :: !Text,
    targetIds :: !Text,
    resultMemoryId :: !(Maybe Text)
  }
  deriving stock (Generic, Eq, Show)

data TimerKindRow = TimerKindRow
  { kind :: !Text,
    timerCount :: !Int64,
    maxFireAt :: !UTCTime
  }
  deriving stock (Generic, Eq, Show)

data TimerQuery = TimerQuery
  { processManagerName :: !Text,
    correlationId :: !Text
  }
  deriving stock (Generic, Eq, Show)

data DistillResult = DistillResult
  { summary :: !L1Summary,
    memories :: ![MemoryStatus],
    scenes :: ![SceneRow],
    persona :: !(Maybe PersonaRow),
    mergeAuditCount :: !Int64,
    loserEvents :: ![RecordedEvent]
  }
  deriving stock (Generic, Show)

testReplayDistillation :: Assertion
testReplayDistillation = withDistillWorkspaceEnv \env workspace -> do
  runtime <- replayRuntimeIn workspace
  sid <- genSessionId
  now <- getCurrentTime
  let scope = fixtureScope
  result <-
    runAppIO env do
      writeFixtureSession sid scope now
      distillResult <- distillSessionL1 RespectWatermark runtime (scopedScanCandidates 5) sid
      summary <- liftIO (expectDistilled "distillSessionL1" distillResult)
      sceneResult <- regenerateScene runtime scope
      _scene <- liftIO (expectRight "regenerateScene" sceneResult)
      personaResult <- regeneratePersona runtime scope
      _persona <- liftIO (expectRight "regeneratePersona" personaResult)
      memories <- loadMemoryStatuses scope
      mergeAuditCount <- loadMergeAuditCount scope
      scenes <- getScenesByScope scope
      persona <- getPersonaByScope scope
      loserEvents <- loadLoserEvents memories
      pure DistillResult {summary, memories, scenes, persona, mergeAuditCount, loserEvents}
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right distill -> assertDistillResult distill

-- | Run an action against a freshly migrated ephemeral database. Deliberately
-- does not change the working directory: tasty runs test cases concurrently and
-- the process-wide cwd would race. ephemeral-pg keeps its cluster under the XDG
-- cache directory, so no chdir is needed.
withDistillEnv :: (AppEnv -> IO a) -> IO a
withDistillEnv action =
  withKiokuMigratedDatabase \connStr ->
    withStore (defaultConnectionSettings connStr) \st -> do
      tracer <- noopTracer
      action AppEnv {store = st, tracer, metrics = Nothing}

fixtureScope :: MemoryScope
fixtureScope =
  ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_distill_test"

-- | A second pass over an unchanged session must converge: the deterministic
-- atom ids mean every write is a no-op and the deterministic audit key means
-- @ON CONFLICT DO NOTHING@ suppresses duplicate audit rows.
testRerunIdempotent :: Assertion
testRerunIdempotent = withDistillEnv \env -> do
  runtime <- replayRuntime
  sid <- genSessionId
  now <- getCurrentTime
  result <-
    runAppIO env do
      writeFixtureSession sid fixtureScope now
      first <- distillSessionL1 RespectWatermark runtime (scopedScanCandidates 5) sid
      summary1 <- liftIO (expectDistilled "first pass" first)
      memories1 <- loadMemoryStatuses fixtureScope
      audits1 <- loadAuditCount fixtureScope
      second <- distillSessionL1 IgnoreWatermark runtime (scopedScanCandidates 5) sid
      summary2 <- liftIO (expectDistilled "second pass" second)
      memories2 <- loadMemoryStatuses fixtureScope
      audits2 <- loadAuditCount fixtureScope
      pure (summary1, memories1, audits1, summary2, memories2, audits2)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (summary1, memories1, audits1, summary2, memories2, audits2) -> do
      summary1.stored @?= 1
      summary1.merged @?= 1
      length memories1 @?= 2
      audits1 @?= 2
      summary2.extracted @?= 2
      summary2.stored @?= 0
      summary2.merged @?= 0
      summary2.skipped @?= 2
      memories2 @?= memories1
      audits2 @?= audits1
      length [() | row <- memories2, row.status == "active"] @?= 1

-- | A consolidation LLM failure is a failed pass, not a silent store.
testConsolidationFailure :: Assertion
testConsolidationFailure = withDistillEnv \env -> do
  base <- replayRuntime
  let runtime = base {runConsolidate = \_ -> pure (Left (ValidationFailure "boom"))}
  sid <- genSessionId
  now <- getCurrentTime
  result <-
    runAppIO env do
      writeFixtureSession sid fixtureScope now
      distilled <- distillSessionL1 RespectWatermark runtime (scopedScanCandidates 5) sid
      memories <- loadMemoryStatuses fixtureScope
      audits <- loadAuditCount fixtureScope
      pure (distilled, memories, audits)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (distilled, memories, audits) -> do
      case distilled of
        Left (L1ConsolidationFailed _) -> pure ()
        other -> assertFailure ("expected L1ConsolidationFailed, got " <> show other)
      memories @?= []
      audits @?= 0

-- | A hallucinated-but-parseable merge target is dropped before the winner is
-- recorded, the audit records only the surviving target, and a re-run converges.
testMergeMissingTarget :: Assertion
testMergeMissingTarget = withDistillEnv \env -> do
  base <- replayRuntime
  existingId <- genMemoryId
  ghostId <- genMemoryId
  let mergeResponse = mergeTargetsResponse [idText existingId, idText ghostId]
      runtime =
        base
          { runExtract = replayProgram singleAtomExtractResponse extractProgram,
            runConsolidate = replayProgram mergeResponse consolidateProgram
          }
  sid <- genSessionId
  now <- getCurrentTime
  result <-
    runAppIO env do
      writeFixtureSession sid fixtureScope now
      seedMemory existingId sid fixtureScope "The user likes concise answers." now
      first <- distillSessionL1 RespectWatermark runtime (scopedScanCandidates 5) sid
      summary1 <- liftIO (expectDistilled "first pass" first)
      memories1 <- loadMemoryStatuses fixtureScope
      audits1 <- loadAuditRows fixtureScope
      second <- distillSessionL1 IgnoreWatermark runtime (scopedScanCandidates 5) sid
      void (liftIO (expectDistilled "second pass" second))
      memories2 <- loadMemoryStatuses fixtureScope
      audits2 <- loadAuditRows fixtureScope
      pure (summary1, memories1, audits1, memories2, audits2)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (summary1, memories1, audits1, memories2, audits2) -> do
      summary1.extracted @?= 1
      summary1.merged @?= 1
      assertBool "seeded memory is merged away" $
        any (\row -> row.memoryId == idText existingId && row.status == "merged") memories1
      length [() | row <- memories1, row.status == "active"] @?= 1
      case audits1 of
        [audit] -> do
          audit.decision @?= "merge"
          audit.targetIds @?= encodeJsonText [idText existingId]
        other -> assertFailure ("expected exactly one audit row, got " <> show (length other))
      memories2 @?= memories1
      audits2 @?= audits1

-- | The watermark makes a re-fire with no new turns a pure database read. The
-- proof is an extractor that fails if it is ever called: the pass succeeds
-- anyway, so the LLM was not reached. Recording one more turn re-enables it.
testWatermarkSkip :: Assertion
testWatermarkSkip = withDistillEnv \env -> do
  working <- replayRuntime
  let exploding =
        working {runExtract = \_ -> pure (Left (ValidationFailure "extractor must not run"))}
  sid <- genSessionId
  now <- getCurrentTime
  result <-
    runAppIO env do
      writeRunningFixtureSession sid fixtureScope now
      first <- distillSessionL1 RespectWatermark working (scopedScanCandidates 5) sid
      void (liftIO (expectDistilled "first pass" first))
      skipped <- distillSessionL1 RespectWatermark exploding (scopedScanCandidates 5) sid
      recordFixtureTurn sid now 4 "Never deploy on a Friday."
      afterNewTurn <- distillSessionL1 RespectWatermark exploding (scopedScanCandidates 5) sid
      pure (skipped, afterNewTurn)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (skipped, afterNewTurn) -> do
      case skipped of
        Right L1SkippedUpToDate -> pure ()
        other -> assertFailure ("expected L1SkippedUpToDate, got " <> show other)
      case afterNewTurn of
        Left (L1ExtractionFailed _) -> pure ()
        other -> assertFailure ("expected L1ExtractionFailed after a new turn, got " <> show other)

-- | However many turns a session records, it holds exactly one idle timer,
-- re-armed forward to the latest turn. Ramp timers fire only on ramp turns
-- (1, 2, 4, 8, 16, ...), and completion adds one final timer.
testIdleTimerCollapse :: Assertion
testIdleTimerCollapse = withDistillEnv \env -> do
  sid <- genSessionId
  now <- getCurrentTime
  result <-
    runAppIO env do
      writeFixtureSession sid fixtureScope now
      loadTimerKinds sid
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right kinds -> do
      let lookupKind k = [row | row <- kinds, row.kind == k]
      case lookupKind "idle" of
        [idle] -> do
          idle.timerCount @?= 1
          let lastTurnAt = turnRecordedAt now (length fixtureTurns)
              expected = addUTCTime idleFlushSeconds lastTurnAt
          assertBool
            ( "idle timer should be re-armed to the last turn's recordedAt + 30min; expected "
                <> show expected
                <> " but found "
                <> show idle.maxFireAt
            )
            (abs (diffUTCTime idle.maxFireAt expected) < 0.001)
        other -> assertFailure ("expected exactly one idle timer row, got " <> show other)
      case lookupKind "ramp" of
        [ramp] -> ramp.timerCount @?= 2
        other -> assertFailure ("expected one ramp kind grouping, got " <> show other)
      case lookupKind "final" of
        [final] -> final.timerCount @?= 1
        other -> assertFailure ("expected one final timer row, got " <> show other)

-- | The scan finder returns the first @limit@ rows of a @priority ASC@ scan, so
-- a duplicate that sits behind enough low-priority filler is invisible to the
-- consolidator and gets stored again. Relevance-ranked recall finds it.
--
-- Both halves run in one database against separate scopes, so the contrast is
-- the only difference between them.
testRecallCandidateWindow :: Assertion
testRecallCandidateWindow = withDistillEnv \env -> do
  base <- replayRuntime
  recallSid <- genSessionId
  scanSid <- genSessionId
  recallDuplicateId <- genMemoryId
  scanDuplicateId <- genMemoryId
  now <- getCurrentTime
  let recallScope = ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_recall_window"
      scanScope = ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_scan_window"
      -- Merge only when the consolidator was actually shown the duplicate.
      runtimeFor duplicateId =
        base
          { runExtract = replayProgram singleAtomExtractResponse extractProgram,
            runConsolidate = \input ->
              if any (\existing -> unField existing.memoryId == idText duplicateId) input.existing
                then replayProgram (mergeTargetsResponse [idText duplicateId]) consolidateProgram input
                else replayProgram storeAtomResponse consolidateProgram input
          }
  -- Inject the capability rather than probing the cluster. This case is about the candidate
  -- finder -- that recall reaches a duplicate the priority scan window hides -- and nothing
  -- about vectors. Pinning it to the keyword plan is what makes dummyEmbeddingModel safe: it
  -- guarantees no embedding endpoint is ever called, instead of relying on the test cluster
  -- happening to lack pgvector, which it no longer does.
  let capability = VectorExtensionUnavailable
  result <-
    runAppIO env do
      writeRunningFixtureSession recallSid recallScope now
      seedCandidateWindow recallSid recallScope now recallDuplicateId
      recallOutcome <-
        distillSessionL1
          RespectWatermark
          (runtimeFor recallDuplicateId)
          (recallCandidates dummyEmbeddingModel capability 8)
          recallSid
      recallSummary <- liftIO (expectDistilled "recall pass" recallOutcome)
      recallMemories <- loadMemoryStatuses recallScope

      writeRunningFixtureSession scanSid scanScope now
      seedCandidateWindow scanSid scanScope now scanDuplicateId
      scanOutcome <-
        distillSessionL1
          RespectWatermark
          (runtimeFor scanDuplicateId)
          (scopedScanCandidates 5)
          scanSid
      scanSummary <- liftIO (expectDistilled "scan pass" scanOutcome)
      scanMemories <- loadMemoryStatuses scanScope
      pure (recallSummary, recallMemories, scanSummary, scanMemories)
  case result of
    Left storeErr -> assertFailure ("store error: " <> show storeErr)
    Right (recallSummary, recallMemories, scanSummary, scanMemories) -> do
      recallSummary.merged @?= 1
      recallSummary.stored @?= 0
      assertBool "recall found the duplicate behind the scan window and merged it" $
        any
          (\row -> row.memoryId == idText recallDuplicateId && row.status == "merged")
          recallMemories

      -- The defect being fixed, pinned in place: the scan never sees the duplicate.
      scanSummary.stored @?= 1
      scanSummary.merged @?= 0
      assertBool "the scan window hid the duplicate, so it stayed active" $
        any
          (\row -> row.memoryId == idText scanDuplicateId && row.status == "active")
          scanMemories

-- | Six low-priority fillers ahead of the duplicate in a @priority ASC@ scan,
-- with content that shares no stem with the extracted atom so full-text search
-- passes over them.
seedCandidateWindow ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  MemoryScope ->
  UTCTime ->
  MemoryId ->
  Eff es ()
seedCandidateWindow sid scope now duplicateId = do
  traverse_
    ( \(n :: Int) -> do
        fillerId <- genMemoryId
        seedMemoryWith
          fillerId
          sid
          scope
          ("Filler note " <> Text.pack (show n) <> ": the deployment pipeline runs on Nix flakes.")
          10
          now
    )
    [1 .. 6]
  seedMemoryWith duplicateId sid scope "The user prefers concise answers." 90 now

dummyEmbeddingModel :: EmbeddingModel
dummyEmbeddingModel =
  toEmbeddingModel
    EmbeddingConfig
      { baseUrl = "http://embedding.invalid",
        model = "test-embedding",
        dimensions = 8,
        apiKey = ""
      }

seedMemory ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  MemoryId ->
  SessionId ->
  MemoryScope ->
  Text ->
  UTCTime ->
  Eff es ()
seedMemory memoryId sid scope content =
  seedMemoryWith memoryId sid scope content 50

seedMemoryWith ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  MemoryId ->
  SessionId ->
  MemoryScope ->
  Text ->
  Int ->
  UTCTime ->
  Eff es ()
seedMemoryWith memoryId sid scope content priority now = do
  recorded <-
    Memory.record
      RecordMemoryData
        { memoryId,
          agentId = "test-agent",
          sessionId = Just sid,
          scope,
          memoryType = MemoryPreference,
          content,
          priority,
          confidence = HighConfidence,
          tags = Set.fromList ["seed"],
          supersedes = Nothing,
          recordedAt = now
        }
  void (liftIO (expectRight "Memory.record" recorded))

-- | Turn @n@ is recorded one minute after turn @n-1@, so the single debounced
-- idle timer's @fire_at@ is observably re-armed forward by each turn.
turnRecordedAt :: UTCTime -> Int -> UTCTime
turnRecordedAt now turnIndex =
  addUTCTime (60 * fromIntegral (turnIndex - 1)) now

fixtureTurns :: [(Int, Text)]
fixtureTurns =
  [ (1, "I like short answers."),
    (2, "Please keep replies brief."),
    (3, "The deploy script is in ops/deploy.sh.")
  ]

-- | Start a session and record 'fixtureTurns', leaving it @Running@ so further
-- turns can be recorded. The aggregate only accepts @RecordTurn@ from @Running@.
writeRunningFixtureSession ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  MemoryScope ->
  UTCTime ->
  Eff es ()
writeRunningFixtureSession sid scope now = do
  startResult <-
    Session.start
      StartSessionData
        { sessionId = sid,
          agentId = "test-agent",
          focus = "style preference capture",
          scope,
          subjectRef = Just "intention_distill_test",
          previousSessionId = Nothing,
          parentSessionId = Nothing,
          delegationDepth = 0,
          startedAt = now
        }
  void (liftIO (expectRight "Session.start" startResult))
  traverse_ (uncurry (recordFixtureTurn sid now)) fixtureTurns

recordFixtureTurn ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  UTCTime ->
  Int ->
  Text ->
  Eff es ()
recordFixtureTurn sid now turnIndex content = do
  turnResult <-
    Session.recordTurn
      RecordTurnData
        { sessionId = sid,
          turnId = idText sid <> "-turn-" <> Text.pack (show turnIndex),
          turnIndex,
          role = "user",
          content,
          toolSummary = Nothing,
          promptTokens = Nothing,
          outputTokens = Nothing,
          recordedAt = turnRecordedAt now turnIndex
        }
  void (liftIO (expectRight "Session.recordTurn" turnResult))

writeFixtureSession ::
  (IOE :> es, Store :> es, Error StoreError :> es) =>
  SessionId ->
  MemoryScope ->
  UTCTime ->
  Eff es ()
writeFixtureSession sid scope now = do
  writeRunningFixtureSession sid scope now
  completeResult <-
    Session.complete
      CompleteSessionData
        { sessionId = sid,
          completedAt = turnRecordedAt now (length fixtureTurns),
          modelUsed = Just "test-model",
          summary = Just "Captured style preferences."
        }
  void (liftIO (expectRight "Session.complete" completeResult))

replayRuntime :: IO DistillRuntime
replayRuntime = do
  rt <- newDistillRuntime
  pure
    rt
      { runExtract = replayProgram extractResponse extractProgram,
        runConsolidate = \input -> replayProgram (consolidateResponse input) consolidateProgram input,
        runScene = replayProgram sceneResponse sceneProgram,
        runPersona = replayProgram personaResponse personaProgram
      }

-- | A replay runtime whose plaintext mirrors go to a private directory rather
-- than the process's working directory. Any test that asserts on mirror files —
-- or merely regenerates a scene, which writes one as a side effect — must use
-- this: tasty runs cases concurrently, so a process-wide @chdir@ would race.
replayRuntimeIn :: FilePath -> IO DistillRuntime
replayRuntimeIn workspace = do
  rt <- replayRuntime
  pure rt {workspaceRoot = Just workspace}

-- | An 'AppEnv' plus the private workspace its mirrors are written into.
withDistillWorkspaceEnv :: (AppEnv -> FilePath -> IO a) -> IO a
withDistillWorkspaceEnv action =
  withSystemTempDirectory "kioku-distill" \workspace ->
    withDistillEnv \env -> action env workspace

-- | Counters and captures over the two distillation runners the forget paths
-- must not invoke, plus the atom text each scene distillation was actually shown.
data DistillCalls = DistillCalls
  { sceneCalls :: !(IORef Int),
    personaCalls :: !(IORef Int),
    sceneAtoms :: !(IORef [Text])
  }

newDistillCalls :: IO DistillCalls
newDistillCalls =
  DistillCalls <$> newIORef 0 <*> newIORef 0 <*> newIORef []

countingRuntime :: DistillCalls -> DistillRuntime -> DistillRuntime
countingRuntime calls rt =
  rt
    { runScene = \input -> do
        modifyIORef' calls.sceneCalls (+ 1)
        modifyIORef' calls.sceneAtoms (<> [unField input.atoms])
        rt.runScene input,
      runPersona = \input -> do
        modifyIORef' calls.personaCalls (+ 1)
        rt.runPersona input
    }

-- | 'countingRuntime', but the scene body echoes the atoms it was built from, so
-- the mirror file's bytes on disk are a direct function of which memories
-- survive. That is what lets the end-to-end tests assert "the forgotten text is
-- gone from the file a host agent would read" against real content, rather than
-- settling for the row metadata.
echoingRuntime :: DistillCalls -> DistillRuntime -> DistillRuntime
echoingRuntime calls rt =
  (countingRuntime calls rt)
    { runScene = \input -> do
        modifyIORef' calls.sceneCalls (+ 1)
        modifyIORef' calls.sceneAtoms (<> [unField input.atoms])
        replayProgram (echoSceneResponse (unField input.atoms)) sceneProgram input
    }

-- | Newlines are flattened because the response format is line-oriented: the
-- atoms are a bulleted list, and each bullet would otherwise look like a field.
echoSceneResponse :: Text -> Text
echoSceneResponse atoms =
  Text.unlines
    [ "[[ ## title ## ]]",
      "Response style",
      "[[ ## bodyMd ## ]]",
      Text.replace "\n" " | " atoms,
      "[[ ## completed ## ]]"
    ]

-- | The atom text handed to the most recent scene distillation.
latestSceneAtoms :: DistillCalls -> IO Text
latestSceneAtoms calls = do
  captured <- readIORef calls.sceneAtoms
  case reverse captured of
    latest : _ -> pure latest
    [] -> assertFailure "the scene distiller was never called"

replayProgram :: Text -> Program i o -> i -> IO (Either ShikumiError o)
replayProgram response prog input = do
  (live, tree) <-
    runEff
      . runPrim
      . runTime
      . runTrace
      . runFixedLLM (mkResponse response)
      . tracedLLM
      . runErrorNoCallStack @ShikumiError
      $ runProgram prog input
  case live of
    Left err -> pure (Left err)
    Right _ -> case replayIndex tree of
      Left err -> assertFailure (Text.unpack err)
      Right idx ->
        runEff
          . runLLMReplay idx
          . runErrorNoCallStack @ShikumiError
          $ runProgram prog input

runFixedLLM :: Response -> Eff (LLM : es) a -> Eff es a
runFixedLLM resp = interpret \_ -> \case
  Complete {} -> pure resp
  Stream {} -> pure []

mkResponse :: Text -> Response
mkResponse responseText =
  _Response
    & #message
    . #content
    .~ Vector.singleton (AssistantText (_TextContent & #text .~ responseText))

extractResponse :: Text
extractResponse =
  """
  [[ ## atoms ## ]]
  [
    {"atomType":"preference","content":"The user prefers concise answers.","priority":50,"confidence":"high"},
    {"atomType":"preference","content":"The user wants replies kept brief.","priority":50,"confidence":"high"}
  ]
  [[ ## completed ## ]]
  """

storeAtomResponse :: Text
storeAtomResponse =
  """
  [[ ## action ## ]]
  StoreAtom
  [[ ## targetMemoryIds ## ]]
  []
  [[ ## resultContent ## ]]
  The user prefers concise answers.
  [[ ## rationale ## ]]
  The preference is durable and not yet represented.
  [[ ## completed ## ]]
  """

consolidateResponse :: ConsolidateInput -> Text
consolidateResponse input =
  case input.existing of
    [] -> storeAtomResponse
    ExistingMemory {memoryId = targetId} : _ ->
      Text.unlines
        [ "[[ ## action ## ]]",
          "MergeAtom",
          "[[ ## targetMemoryIds ## ]]",
          encodeJsonText ([unField targetId] :: [Text]),
          "[[ ## resultContent ## ]]",
          "The user prefers concise answers.",
          "[[ ## rationale ## ]]",
          "The candidate restates the existing concise-answer preference.",
          "[[ ## completed ## ]]"
        ]

singleAtomExtractResponse :: Text
singleAtomExtractResponse =
  """
  [[ ## atoms ## ]]
  [
    {"atomType":"preference","content":"The user prefers concise answers.","priority":50,"confidence":"high"}
  ]
  [[ ## completed ## ]]
  """

mergeTargetsResponse :: [Text] -> Text
mergeTargetsResponse targets =
  Text.unlines
    [ "[[ ## action ## ]]",
      "MergeAtom",
      "[[ ## targetMemoryIds ## ]]",
      encodeJsonText targets,
      "[[ ## resultContent ## ]]",
      "The user prefers concise answers.",
      "[[ ## rationale ## ]]",
      "The candidate restates the existing concise-answer preference.",
      "[[ ## completed ## ]]"
    ]

sceneResponse :: Text
sceneResponse =
  """
  [[ ## title ## ]]
  Response style
  [[ ## bodyMd ## ]]
  - The user prefers concise answers.
  [[ ## completed ## ]]
  """

personaResponse :: Text
personaResponse =
  """
  [[ ## bodyMd ## ]]
  # Persona

  The user values concise answers in this scope.
  [[ ## completed ## ]]
  """

loadMemoryStatuses ::
  (Store :> es) =>
  MemoryScope ->
  Eff es [MemoryStatus]
loadMemoryStatuses scope =
  runTransaction $
    Tx.statement (scopeParams scope) selectMemoryStatusesStmt

loadMergeAuditCount ::
  (Store :> es) =>
  MemoryScope ->
  Eff es Int64
loadMergeAuditCount scope =
  runTransaction $
    Tx.statement (scopeParams scope) selectMergeAuditCountStmt

loadAuditCount ::
  (Store :> es) =>
  MemoryScope ->
  Eff es Int64
loadAuditCount scope =
  runTransaction $
    Tx.statement (scopeParams scope) selectAuditCountStmt

loadAuditRows ::
  (Store :> es) =>
  MemoryScope ->
  Eff es [AuditRowView]
loadAuditRows scope =
  runTransaction $
    Tx.statement (scopeParams scope) selectAuditRowsStmt

-- | keiro's timer table is unqualified at the pinned version: it lives in the
-- @kiroku@ schema, which the connection's search_path already resolves.
loadTimerKinds ::
  (Store :> es) =>
  SessionId ->
  Eff es [TimerKindRow]
loadTimerKinds sid =
  runTransaction $
    Tx.statement
      TimerQuery
        { processManagerName = l1ExtractProcessManagerName,
          correlationId = idText sid
        }
      selectTimerKindsStmt

selectTimerKindsStmt :: Statement TimerQuery [TimerKindRow]
selectTimerKindsStmt =
  preparable
    """
    SELECT payload->>'kind', count(*), max(fire_at)
    FROM keiro.keiro_timers
    WHERE process_manager_name = $1
      AND correlation_id = $2
    GROUP BY payload->>'kind'
    ORDER BY payload->>'kind'
    """
    timerQueryEncoder
    (D.rowList timerKindRowDecoder)

timerQueryEncoder :: E.Params TimerQuery
timerQueryEncoder =
  ((\q -> q.processManagerName) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.correlationId) >$< E.param (E.nonNullable E.text))

timerKindRowDecoder :: D.Row TimerKindRow
timerKindRowDecoder =
  TimerKindRow
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.int8)
    <*> D.column (D.nonNullable D.timestamptz)

loadLoserEvents ::
  (Store :> es) =>
  [MemoryStatus] ->
  Eff es [RecordedEvent]
loadLoserEvents memories =
  case [mid | MemoryStatus {memoryId = mid, status = "merged"} <- memories] of
    loser : _ ->
      case (parseIdLenient loser :: Either Text MemoryId) of
        Left _ -> pure []
        Right loserId ->
          Vector.toList <$> readStreamForward (Stream.streamName (memoryStream loserId)) (StreamVersion 0) 100
    [] -> pure []

scopeParams :: MemoryScope -> ScopeParams
scopeParams scope =
  ScopeParams
    { namespace = scopeNamespaceText scope,
      scopeKind = scopeKindText scope,
      scopeRef = scopeRefText scope
    }

selectMemoryStatusesStmt :: Statement ScopeParams [MemoryStatus]
selectMemoryStatusesStmt =
  preparable
    """
    SELECT memory_id, content, status
    FROM kioku_memories
    WHERE namespace = $1
      AND ((scope_kind = $2 AND scope_ref = $3)
           OR ($2 IS NULL AND scope_kind IS NULL AND $3 IS NULL AND scope_ref IS NULL))
    ORDER BY created_at ASC
    """
    scopeParamsEncoder
    (D.rowList memoryStatusDecoder)

selectAuditCountStmt :: Statement ScopeParams Int64
selectAuditCountStmt =
  preparable
    """
    SELECT count(*)
    FROM kioku_consolidation_decisions
    WHERE namespace = $1
      AND ((scope_kind = $2 AND scope_ref = $3)
           OR ($2 IS NULL AND scope_kind IS NULL AND $3 IS NULL AND scope_ref IS NULL))
    """
    scopeParamsEncoder
    (D.singleRow (D.column (D.nonNullable D.int8)))

selectAuditRowsStmt :: Statement ScopeParams [AuditRowView]
selectAuditRowsStmt =
  preparable
    """
    SELECT decision, target_ids::text, result_memory_id
    FROM kioku_consolidation_decisions
    WHERE namespace = $1
      AND ((scope_kind = $2 AND scope_ref = $3)
           OR ($2 IS NULL AND scope_kind IS NULL AND $3 IS NULL AND scope_ref IS NULL))
    ORDER BY decided_at ASC
    """
    scopeParamsEncoder
    (D.rowList auditRowViewDecoder)

auditRowViewDecoder :: D.Row AuditRowView
auditRowViewDecoder =
  AuditRowView
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nullable D.text)

selectMergeAuditCountStmt :: Statement ScopeParams Int64
selectMergeAuditCountStmt =
  preparable
    """
    SELECT count(*)
    FROM kioku_consolidation_decisions
    WHERE namespace = $1
      AND ((scope_kind = $2 AND scope_ref = $3)
           OR ($2 IS NULL AND scope_kind IS NULL AND $3 IS NULL AND scope_ref IS NULL))
      AND decision = 'merge'
    """
    scopeParamsEncoder
    (D.singleRow (D.column (D.nonNullable D.int8)))

scopeParamsEncoder :: E.Params ScopeParams
scopeParamsEncoder =
  ((\q -> q.namespace) >$< E.param (E.nonNullable E.text))
    <> ((\q -> q.scopeKind) >$< E.param (E.nullable E.text))
    <> ((\q -> q.scopeRef) >$< E.param (E.nullable E.text))

memoryStatusDecoder :: D.Row MemoryStatus
memoryStatusDecoder =
  MemoryStatus
    <$> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)
    <*> D.column (D.nonNullable D.text)

assertDistillResult :: DistillResult -> Assertion
assertDistillResult result = do
  result.summary.extracted @?= 2
  result.summary.stored @?= 1
  result.summary.merged @?= 1
  length [() | row <- result.memories, row.status == "active"] @?= 1
  length [() | row <- result.memories, row.status == "merged"] @?= 1
  assertBool "active memory keeps the concise-answer preference" $
    any (\row -> row.status == "active" && "concise answers" `Text.isInfixOf` row.content) result.memories
  result.mergeAuditCount @?= 1
  assertBool "loser stream contains MemoryMerged" $
    any (\event -> event.eventType == EventType "MemoryMerged") result.loserEvents
  length result.scenes @?= 1
  assertBool "scene body is non-empty" $
    any (not . Text.null . (.bodyMd)) result.scenes
  case result.persona of
    Nothing -> assertFailure "expected persona row"
    Just persona -> assertBool "persona body is non-empty" (not (Text.null persona.bodyMd))

expectRight :: (Show e) => String -> Either e a -> IO a
expectRight label = \case
  Left err -> assertFailure (label <> " failed: " <> show err)
  Right value -> pure value

-- | Unwrap a regeneration that was expected to produce an artifact, not to find
-- the scope empty.
expectJustRow :: (Show e) => String -> Either e (Maybe a) -> IO a
expectJustRow label outcome =
  expectRight label outcome >>= \case
    Just row -> pure row
    Nothing -> assertFailure (label <> ": expected a row, got none")

-- | Unwrap a pass that was expected to actually run, not skip on the watermark.
expectDistilled :: String -> Either L1Error L1Outcome -> IO L1Summary
expectDistilled label outcome = do
  distilled <- expectRight label outcome
  case distilled of
    L1Distilled summary -> pure summary
    L1SkippedUpToDate -> assertFailure (label <> " unexpectedly skipped on the watermark")

encodeJsonText :: (ToJSON a) => a -> Text
encodeJsonText =
  TE.decodeUtf8 . BL.toStrict . Aeson.encode
