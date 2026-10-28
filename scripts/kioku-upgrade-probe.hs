{-# LANGUAGE GHC2024 #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

-- Developer instrumentation. Compile this same source in each isolated project:
-- cabal exec -- ghc -XGHC2024 scripts/kioku-upgrade-probe.hs -o PROBE
-- See docs/user/upgrading-to-keiro-0-22.md for the explicit scratch identity gate.
import Control.Concurrent (threadDelay)
import Control.Monad (forM, forM_, unless, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson qualified as J
import Data.Aeson.Key qualified as Key
import Data.Aeson.KeyMap qualified as KM
import Data.ByteString qualified
import Data.ByteString.Lazy qualified as LBS
import Data.IORef
import Data.List (sort)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.Encoding qualified
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Data.Vector qualified as V
import Effectful (Eff)
import Effectful.Exception qualified
import Keiro.Projection.Catalog (mkRebuildGroupId)
import Keiro.ReadModel.Rebuild qualified as R
import Keiro.ReplayAudit qualified as A
import Keiro.Timer qualified as Timer
import Kioku.Api.Access
import Kioku.Api.Scope
import Kioku.Api.Types
import Kioku.App
import Kioku.Distill.L1 (scopedScanCandidates)
import Kioku.Distill.L2 (l2SceneProcessManagerName)
import Kioku.Distill.Runtime (testDistillRuntime)
import Kioku.Distill.Timer.Worker (runKiokuTimerWorkerOnce)
import Kioku.Id
import Kioku.Memory qualified as Memory
import Kioku.Memory.Domain
import Kioku.Memory.Embedding (EmbeddingConfig (..), toEmbeddingModel)
import Kioku.Memory.Embedding.Worker
import Kioku.Memory.EventStream (validateMemoryEventStream)
import Kioku.ProjectionCatalog (kiokuProjectionCatalog)
import Kioku.Recall.Capability
import Kioku.Session qualified as Session
import Kioku.Session.Domain
import Kioku.Session.EventStream (validateSessionEventStream)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Kiroku.Store.Effect.Resource (getKirokuStore)
import Kiroku.Store.Transaction (runTransaction)
import Kiroku.Store.Types (CategoryName (..), EventType (..), GlobalPosition (..))
import Shibuya.Adapter.Kiroku
  ( EventTypeFilter (..),
    KirokuAdapterConfig (..),
    SubscriptionName (..),
    SubscriptionTarget (..),
    defaultKirokuAdapterConfig,
    guardKirokuHandler,
    kirokuAdapter,
  )
import Shibuya.App qualified as App
import Shibuya.Core.AckHandle (AckHandle (..))
import Shibuya.Core.Ingested qualified as Ingested
import Shibuya.Policy
import System.Directory
import System.Environment
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.Process
import System.Timeout (timeout)

main :: IO ()
main = do
  args <- getArgs
  (mode, url, out) <- case args of
    [m, u, o] | m `elem` ["read", "write", "replay", "rebuild", "delivery"] -> pure (m, T.pack u, o)
    _ -> fail "usage: kioku-upgrade-probe read|write|replay|rebuild|delivery DATABASE_URL NEW_REPORT_DIRECTORY"
  exists <- doesDirectoryExist out
  when exists $ listDirectory out >>= \xs -> unless (null xs) (fail "report directory must be empty")
  createDirectoryIfMissing True out
  identity <- sqlJson url identitySql
  save out "identity.json" identity
  when (mode `elem` ["write", "rebuild", "delivery"]) $ do
    allowed <- lookupEnv "KIOKU_UPGRADE_DISPOSABLE"
    unless (allowed == Just "1") (fail "mutations require KIOKU_UPGRADE_DISPOSABLE=1")
    identityPath <- getEnv "KIOKU_UPGRADE_IDENTITY"
    currentReport <- canonicalizePath out
    recordedPath <- canonicalizePath identityPath
    when (recordedPath == currentReport </> "identity.json") (fail "scratch identity must predate this report")
    recorded <- LBS.readFile identityPath >>= decode
    unless (recorded == identity) (fail "database identity differs from the separately recorded scratch identity")
  tracer <- noopTracer
  let app = AppEnv (defaultConnectionSettings url) tracer Nothing
  case mode of
    "read" -> readProbe app url out
    "write" -> writeProbe app url out
    "replay" -> replayProbe app url out
    "rebuild" -> rebuildProbe app url out
    "delivery" -> deliveryProbe app url out
    _ -> fail "unreachable mode"
  putStrLn (mode <> " passed; reports: " <> out)

identitySql :: Text
identitySql = "SELECT jsonb_build_object('database',current_database(),'oid',(SELECT oid FROM pg_database WHERE datname=current_database()),'user',current_user,'server',coalesce(inet_server_addr()::text,current_setting('unix_socket_directories')),'port',current_setting('port'),'major',current_setting('server_version_num')::int/10000)"

save :: (J.ToJSON a) => FilePath -> FilePath -> a -> IO ()
save dir name = LBS.writeFile (dir </> name) . J.encode

decode :: LBS.ByteString -> IO J.Value
decode = either fail pure . J.eitherDecode

right :: (Show e) => Either e a -> IO a
right = either (fail . show) pure

run :: AppEnv -> Eff AppEffects a -> IO a
run env action = runAppIO env action >>= right

-- All SQL reads use an explicit read-only transaction. Passwords are never printed.
psql :: Text -> Text -> IO Text
psql url input = do
  (code, output, err) <- readProcessWithExitCode "psql" [T.unpack url, "-XAtq", "-v", "ON_ERROR_STOP=1"] (T.unpack input)
  unless (code == ExitSuccess) (fail ("psql failed: " <> err))
  pure (T.strip (T.pack output))

sqlJson :: Text -> Text -> IO J.Value
sqlJson url query = do
  result <- psql url ("BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY;\n" <> query <> ";\nCOMMIT;")
  decode (LBS.fromStrict (encodeText result))

encodeText :: Text -> Data.ByteString.ByteString
encodeText = Data.Text.Encoding.encodeUtf8

literal :: Text -> Text
literal value = "'" <> T.replace "'" "''" value <> "'"

ident :: Text -> Text
ident value = "\"" <> T.replace "\"" "\"\"" value <> "\""

-- Full ordered rows retain primary keys; JSON text ordering also covers tables
-- without primary keys, duplicate rows, and every nullable column.
rows :: Text -> Text -> Text -> IO J.Value
rows url table predicate =
  sqlJson
    url
    ("SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY to_jsonb(t)::text),'[]'::jsonb) FROM " <> table <> " t " <> predicate)

tables :: Text -> IO [Text]
tables url = do
  result <- sqlJson url "SELECT coalesce(jsonb_agg(format('%I.%I',n.nspname,c.relname) ORDER BY n.nspname,c.relname),'[]') FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname IN ('kioku','kiroku','keiro','pgmigrate') AND c.relkind IN ('r','p') AND NOT c.relispartition"
  right (J.fromJSON result `asEither` ())
  where
    asEither (J.Success x) _ = Right x
    asEither (J.Error e) _ = Left e

snapshot :: Text -> (Text -> Bool) -> IO J.Value
snapshot url select = do
  names <- filter select <$> tables url
  pairs <- forM names $ \name -> do
    value <- rows url name ""
    pure (Key.fromText name, value)
  pure (J.Object (KM.fromList pairs))

readProbe :: AppEnv -> Text -> FilePath -> IO ()
readProbe app url out = do
  allRows <- snapshot url (const True)
  save out "protected.json" allRows
  ledger <- snapshot url (T.isPrefixOf "pgmigrate.")
  save out "ledger.json" ledger
  (code, dump, err) <- readProcessWithExitCode "pg_dump" ["--schema-only", "--no-owner", "--no-privileges", "--dbname=" <> T.unpack url] ""
  unless (code == ExitSuccess) (fail err)
  writeFile (out </> "schema.sql") dump
  definitions <- sqlJson url "SELECT jsonb_build_object('constraints',(SELECT jsonb_object_agg(n.nspname||'.'||c.relname||'.'||con.conname,pg_get_constraintdef(con.oid) ORDER BY con.conname) FROM pg_constraint con JOIN pg_class c ON c.oid=con.conrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='kiroku' AND c.relname='subscriptions'),'comment',obj_description('kiroku'::regnamespace,'pg_namespace'))"
  save out "subscription-schema.json" definitions
  public <- publicReads app url
  save out "read.json" public
  cliEvidence url out

-- Exercise actual partition-checked public reads for every projected resource.
publicReads :: AppEnv -> Text -> IO J.Value
publicReads app url = do
  memories <- rows url "kioku.memories" ""
  sessions <- rows url "kioku.sessions" ""
  memoryResults <- forM (array memories) $ \v -> do
    space <- right (mkMemorySpaceId (field "memory_space_id" v))
    mid <- right (parseId (field "memory_id" v))
    result <- run app (Memory.getMetadataWithContext (context space) mid) >>= right
    pure (J.object ["id" J..= idText mid, "result" J..= show result])
  sessionResults <- forM (array sessions) $ \v -> do
    space <- right (mkMemorySpaceId (field "memory_space_id" v))
    sid <- right (parseId (field "session_id" v))
    result <- run app (Session.getById space sid) >>= right
    turns <- run app (Session.getTurns space sid) >>= right
    pure (J.object ["id" J..= idText sid, "result" J..= show result, "turns" J..= show turns])
  pure (J.object ["memories" J..= memoryResults, "sessions" J..= sessionResults])

array :: J.Value -> [J.Value]
array (J.Array xs) = V.toList xs
array _ = error "expected array"

field :: Text -> J.Value -> Text
field name (J.Object fields) = case KM.lookup (Key.fromText name) fields of
  Just (J.String t) -> t
  _ -> error ("missing text field " <> T.unpack name)
field _ _ = error "expected object"

actor :: MemoryActor
actor = MemoryActor (either (error . T.unpack) id (mkPrincipalRef "kioku-upgrade-probe"))

context :: MemorySpaceId -> MemoryAccessContext
context space = assumeAuthorizedMemoryContext space actor

fixtureSpace :: MemorySpaceId
fixtureSpace = either (error . T.unpack) id (mkMemorySpaceId "kioku_upgrade_probe")

fixtureTime :: UTCTime
fixtureTime = read "2026-10-28 00:00:00 UTC"

fixtureScope :: MemoryScope
fixtureScope = ScopeGlobal (Namespace "kioku_upgrade_probe")

fixtureMemory :: Text -> Text -> IO RecordMemoryData
fixtureMemory = fixtureMemoryAt fixtureTime

fixtureMemoryAt :: UTCTime -> Text -> Text -> IO RecordMemoryData
fixtureMemoryAt at suffix content = do
  mid <- right (parseId ("kioku_memory_01kvxa7d2cezhs874g3n8dfg" <> suffix))
  pure (RecordMemoryData mid fixtureSpace (memoryContextRecordedActor (context fixtureSpace)) Nothing "kioku-upgrade-probe" Nothing fixtureScope MemoryPreference content 5 HighConfidence Set.empty Nothing at)

writeProbe :: AppEnv -> Text -> FilePath -> IO ()
writeProbe app url out = do
  -- Fail before touching an existing fixture; replaying this mode requires a fresh twin.
  collision <- rows url "kioku.memories" ("WHERE memory_space_id=" <> literal (memorySpaceIdText fixtureSpace))
  unless (null (array collision)) (fail "fixture space already populated; restore a fresh twin")
  command <- fixtureMemory "mg" "upgrade command parity"
  sid <- right (parseId "kioku_session_01kvxa7d2cezhs874g3n8dfgmg")
  let ctx = context fixtureSpace
      who = memoryContextRecordedActor ctx
      start = StartSessionData sid fixtureSpace who Nothing "kioku-upgrade-probe" "upgrade parity" fixtureScope Nothing Nothing Nothing 0 fixtureTime
  outcomes <- run app $ do
    a <- Memory.recordWithContext ctx command
    b <- Memory.recordWithContext ctx command
    c <- Session.startWithContext ctx start
    d <- Session.recordTurnWithContext ctx (RecordTurnData sid fixtureSpace who "upgrade-probe-turn" 0 "user" "probe input" Nothing Nothing Nothing fixtureTime)
    e <- Session.awaitInputWithContext ctx (AwaitInputData sid fixtureSpace who "probe wait" (Just "probe-key") Nothing fixtureTime)
    f <- Session.resumeWithContext ctx (ResumeSessionData sid fixtureSpace who (Just "probe-key") False "probe resume" fixtureTime)
    g <- Memory.archiveWithContext ctx (ArchiveMemoryData command.memoryId fixtureSpace who fixtureTime)
    let other = either (error . T.unpack) id (mkMemorySpaceId "kioku_upgrade_other")
    h <- Memory.archiveWithContext (context other) (ArchiveMemoryData command.memoryId other (memoryContextRecordedActor (context other)) fixtureTime)
    liftIO $ do
      mapM_ (void . right) [a, b, g]
      mapM_ (void . right) [c, d, e, f]
      case h of Left _ -> pure (); Right _ -> fail "cross-space archive was accepted"
    pure [show a, show b, show c, show d, show e, show f, show g, show h]
  payloads <- sqlJson url ("SELECT coalesce(jsonb_agg(jsonb_build_object('type',e.event_type,'data',e.data,'metadata',e.metadata) ORDER BY se.stream_version,s.stream_name),'[]') FROM kiroku.events e JOIN kiroku.stream_events se USING(event_id) JOIN kiroku.streams s USING(stream_id) WHERE s.stream_name IN (" <> literal ("kioku_memory-" <> idText command.memoryId) <> "," <> literal ("kioku_session-" <> idText sid) <> ")")
  projected <- snapshot url (T.isPrefixOf "kioku.")
  timers <- rows url "keiro.keiro_timers" ""
  save out "commands.json" (J.object ["outcomes" J..= outcomes, "events" J..= payloads, "rows" J..= normalizeTargets projected, "timers" J..= normalize timers])
  cliEvidence url out

-- Only explicitly documented volatile projection/lease clocks are removed.
-- Event payload clocks, principal, tags, content and ordering remain exact.
normalize :: J.Value -> J.Value
normalize (J.Object obj) = J.Object (KM.map normalize (foldr KM.delete obj ["created_at", "updated_at", "lease_token", "claimed_at", "lease_expires_at"]))
normalize (J.Array xs) = J.Array (fmap normalize xs)
normalize value = value

cliEvidence :: Text -> FilePath -> IO ()
cliEvidence url out = do
  bin <- getEnv "KIOKU_UPGRADE_CLI"
  inherited <- getEnvironment
  let vars =
        filter (\(key, _) -> key `notElem` ["PG_CONNECTION_STRING", "DATABASE_URL", "KIOKU_MEMORY_SPACE", "KIOKU_AI_CONFIG"]) inherited
          <> [("PG_CONNECTION_STRING", T.unpack url), ("KIOKU_MEMORY_SPACE", T.unpack (memorySpaceIdText fixtureSpace)), ("KIOKU_AI_CONFIG", out </> "disabled-ai.json")]
  writeFile (out </> "disabled-ai.json") "{\"version\":1}"
  before <- snapshot url (T.isPrefixOf "keiro.")
  results <- forM [["--help"], ["recall", "upgrade", "--strategy", "keyword", "--global-bucket", "kioku_upgrade_probe"]] $ \args -> do
    (code, stdout, stderr) <- readCreateProcessWithExitCode (proc bin args) {env = Just vars} ""
    unless (code == ExitSuccess) (fail ("retained CLI failed: " <> stderr))
    pure (J.object ["args" J..= args, "stdout" J..= stdout])
  after <- snapshot url (T.isPrefixOf "keiro.")
  save out "cli.json" results
  save out "cli-metadata-phase.json" (J.object ["before" J..= before, "after" J..= after])

replayProbe :: AppEnv -> Text -> FilePath -> IO ()
replayProbe app url out = do
  memory <- right validateMemoryEventStream
  session <- right validateSessionEventStream
  inventory <- sqlJson url "SELECT coalesce(jsonb_agg(stream_name ORDER BY stream_name),'[]') FROM kiroku.streams WHERE split_part(stream_name,'-',1) IN ('kioku_memory','kioku_session')"
  before <- snapshot url (const True)
  reports <-
    run
      app
      ( A.auditTargets
          A.AuditFull
          A.defaultAuditBudget
          [ A.SomeAuditTarget (A.AuditTarget memory "kioku_memory" (A.streamInCategory "kioku_memory")),
            A.SomeAuditTarget (A.AuditTarget session "kioku_session" (A.streamInCategory "kioku_session"))
          ]
      )
  save out "replay.json" (J.object ["inventory" J..= inventory, "reports" J..= map show reports, "stateDigest" J..= J.Null, "exclusions" J..= ("Only the two native categories are audited; framework and foreign categories are excluded." :: Text)])
  unless (sum (map (.streamsSelected) reports) == length (array inventory)) (fail "native replay denominator mismatch")
  forM_ reports $ \r -> unless (r.failures == 0 && r.divergences == 0 && null r.rejectedStreams && r.streamsSkipped == 0 && length r.results == r.streamsSelected) (fail (show r))
  after <- snapshot url (const True)
  unless (before == after) (fail "read-only replay changed protected data")
  putStrLn ("native streams audited: " <> show (length (array inventory)))

-- Catalog rebuilding changes its own lifecycle metadata. All authoritative data,
-- timers, subscriptions, ledger and non-target Kioku tables must stay identical.
rebuildProtected :: Text -> Bool
rebuildProtected table =
  table
    `notElem` [ "kioku.memories",
                "kioku.sessions",
                "kioku.turns",
                "keiro.keiro_projection_rebuild_groups",
                "keiro.keiro_projection_rebuild_runs",
                "keiro.keiro_projection_rebuild_sources",
                "keiro.keiro_projection_rebuild_adapters",
                "keiro.keiro_projection_rebuild_verifications"
              ]

normalizeRegistry :: J.Value -> J.Value
normalizeRegistry (J.Object obj) =
  J.Object
    ( KM.mapWithKey
        ( \key value ->
            if key /= "keiro.keiro_read_models"
              then value
              else case value of
                J.Array xs ->
                  J.Array
                    ( fmap
                        ( \row -> case row of
                            J.Object r -> J.Object (foldr KM.delete r ["last_built_at", "updated_at"])
                            _ -> row
                        )
                        xs
                    )
                _ -> value
        )
        obj
    )
normalizeRegistry value = value

rebuildProbe :: AppEnv -> Text -> FilePath -> IO ()
rebuildProbe app url out = do
  before <- snapshot url rebuildProtected
  targets <- snapshot url (`elem` ["kioku.memories", "kioku.sessions", "kioku.turns"])
  save out "before.json" targets
  reports <- forM ["kioku-memory", "kioku-session"] $ \group -> do
    unique <- T.pack . UUID.toString <$> UUID.nextRandom
    rid <- right (R.mkRebuildRunId (group <> "-" <> unique))
    gid <- right (mkRebuildGroupId group)
    let request = R.RebuildRequest rid "kioku-upgrade-probe" "disposable restored-history rehearsal" (GlobalPosition 0)
    report <- run app (R.startCatalogRebuild kiokuProjectionCatalog gid (R.defaultRebuildOptions request)) >>= right
    unless (report.runStatus == R.RebuildRunPromoted) (fail ("rebuild incomplete: " <> show report))
    pure (show report)
  rebuilt <- snapshot url (`elem` ["kioku.memories", "kioku.sessions", "kioku.turns"])
  save out "replayed.json" rebuilt
  unless (semanticTargets targets == semanticTargets rebuilt) (fail "event-derived projection rows diverged")
  -- Restore enrichment only where the immutable identity, partition and content agree.
  let original = case targets of J.Object obj -> maybe (error "missing memories") id (KM.lookup "kioku.memories" obj); _ -> error "invalid targets"
      jsonText = Data.Text.Encoding.decodeUtf8 (LBS.toStrict (J.encode original))
      input = "jsonb_populate_recordset(NULL::kioku.memories," <> literal jsonText <> "::jsonb)"
  void $ psql url ("BEGIN; UPDATE kioku.memories m SET embedding=o.embedding,embedding_model=o.embedding_model,dimensions=o.dimensions,content_hash=o.content_hash FROM " <> input <> " o WHERE m.memory_id=o.memory_id AND m.memory_space_id=o.memory_space_id AND m.content=o.content; COMMIT;")
  enriched <- snapshot url (`elem` ["kioku.memories", "kioku.sessions", "kioku.turns"])
  unless (normalizeTargets targets == normalizeTargets enriched) (fail "enrichment/full-row preservation failed")
  after <- snapshot url rebuildProtected
  unless (normalizeRegistry before == normalizeRegistry after) (fail "rebuild changed protected non-target rows")
  save out "after.json" enriched
  save out "rebuild.json" (J.object ["runs" J..= reports, "protectedBefore" J..= before, "protectedAfter" J..= after])

normalizeTargets :: J.Value -> J.Value
normalizeTargets (J.Object obj) = J.Object (KM.mapWithKey (\key value -> if key == "kioku.sessions" then normalize value else value) obj)
normalizeTargets value = value

semanticTargets :: J.Value -> J.Value
semanticTargets (J.Object obj) = J.Object (KM.mapWithKey semantic obj)
  where
    semantic "kioku.memories" (J.Array xs) = J.Array (fmap removeEnrichment xs)
    semantic "kioku.sessions" xs = normalize xs
    semantic _ xs = xs
    removeEnrichment (J.Object row) = J.Object (foldr KM.delete row ["embedding", "embedding_model", "dimensions", "content_hash"])
    removeEnrichment v = v
semanticTargets v = v

deliveryProbe :: AppEnv -> Text -> FilePath -> IO ()
deliveryProbe app url out = do
  cap <- run app (detectVectorCapability 1536)
  unless (cap == VectorAvailable) (fail ("delivery requires pgvector: " <> show cap))
  -- Refuse historical due work so the timer seam cannot execute real host effects.
  due <- sqlJson url "SELECT count(*) FROM keiro.keiro_timers WHERE status='scheduled' AND fire_at <= now()"
  unless (due == J.Number 0) (fail "delivery timer lane requires no pre-existing due timers; use a separate clone")
  -- This isolated adapter uses the production handler, filter, policy and defaults.
  -- It never opens or rebinds the production embedding subscription.
  unique <- T.pack . UUID.toString <$> UUID.nextRandom
  let subscription = "kioku-upgrade-probe-" <> unique
      conf =
        (defaultKirokuAdapterConfig (SubscriptionName subscription) (Category (CategoryName "kioku_memory")))
          { eventTypeFilter = OnlyEventTypes (Set.singleton (EventType "MemoryRecorded"))
          }
  calls <- newIORef ([] :: [Text])
  let provider content = do
        unless (content `elem` ["upgrade delivery first", "upgrade delivery second"]) (fail "provider received unrelated content")
        modifyIORef' calls (content :)
        pure (Right (V.replicate 1536 0.1))
      worker = EmbeddingWorkerEnv (toEmbeddingModel (EmbeddingConfig "http://embedding.invalid" "text-embedding-3-small" 1536 "unused")) 1536 provider
      contexts = assumeAuthorizedContextProvider actor
  -- Do not feed historical rows to the deterministic provider. Start the dedicated
  -- checkpoint at the captured head without altering any existing subscription.
  headPosition <- sqlJson url "SELECT coalesce(max(stream_version),0) FROM kiroku.stream_events WHERE stream_id=0"
  void $ psql url ("INSERT INTO kiroku.subscriptions(subscription_name,last_seen,consumer_group_member,consumer_group_size,target_kind,target_category) VALUES (" <> literal subscription <> "," <> Data.Text.Encoding.decodeUtf8 (LBS.toStrict (J.encode headPosition)) <> ",0,1,'category','kioku_memory')")
  forM_ [("mh", "upgrade delivery first"), ("mj", "upgrade delivery second")] $ \(suffix, content) -> do
    now <- getCurrentTime
    command <- fixtureMemoryAt now suffix content
    run app (Memory.recordWithContext (context fixtureSpace) command) >>= right
    outcome <- timeout 30000000 $ run app $ do
      store <- getKirokuStore
      adapter <- kirokuAdapter store conf
      let handler msg = embeddingHandler contexts cap worker (Ingested.mkIngested msg.envelope (AckHandle (\_ -> pure ())))
          processor = App.QueueProcessor adapter (guardKirokuHandler handler) StrictInOrder Serial
      handle <- App.runApp App.defaultAppConfig [(App.ProcessorId subscription, processor)] >>= liftIO . right
      finallyEff
        (liftIO (awaitEffect url subscription (idText command.memoryId)))
        ( do
            drained <- App.stopAppGracefully (App.ShutdownConfig 2 4) handle
            liftIO (unless drained (fail "forced adapter shutdown"))
            App.waitApp handle
        )
    unless (outcome == Just ()) (fail "delivery timed out")
  delivered <- readIORef calls
  unless (sort delivered == sort ["upgrade delivery first", "upgrade delivery second"]) (fail "provider effects not exactly two")
  timerUuid <- UUID.nextRandom
  rt <- testDistillRuntime
  now <- getCurrentTime
  run app $ do
    runTransaction (Timer.scheduleTimerTx (Timer.TimerRequest (Timer.TimerId timerUuid) l2SceneProcessManagerName "upgrade-probe-empty" (addUTCTime (-1) now) (J.object ["scope" J..= ScopeGlobal (Namespace "kioku_upgrade_timer_empty"), "memorySpaceId" J..= fixtureSpace])))
    void (runKiokuTimerWorkerOnce Nothing contexts rt (scopedScanCandidates 5) now)
  timer <- rows url "keiro.keiro_timers" ("WHERE timer_id=" <> literal (UUID.toText timerUuid))
  unless (map (field "status") (array timer) == ["fired"]) (fail "due timer did not fire")
  checkpoint <- rows url "kiroku.subscriptions" ("WHERE subscription_name=" <> literal subscription)
  save out "delivery.json" (J.object ["providerCalls" J..= reverse delivered, "checkpoint" J..= checkpoint, "timer" J..= timer])

awaitEffect :: Text -> Text -> Text -> IO ()
awaitEffect url subscription mid = do
  state <- sqlJson url ("SELECT to_jsonb(EXISTS(SELECT 1 FROM kioku.memories WHERE memory_id=" <> literal mid <> " AND embedding IS NOT NULL) AND (SELECT last_seen FROM kiroku.subscriptions WHERE subscription_name=" <> literal subscription <> ") >= (SELECT max(se.stream_version) FROM kiroku.stream_events se JOIN kiroku.events e USING(event_id) WHERE se.stream_id=0 AND e.data->'data'->>'memoryId'=" <> literal mid <> "))")
  unless (state == J.Bool True) (threadDelay 20000 >> awaitEffect url subscription mid)

finallyEff :: Eff AppEffects a -> Eff AppEffects b -> Eff AppEffects a
finallyEff = Effectful.Exception.finally
