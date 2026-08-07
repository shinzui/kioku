-- | Database-level tests for the read-model schema itself: the constraints and indexes
-- the migrations are supposed to install. These go through a raw hasql connection rather
-- than the kiroku 'Store' effect, because the store's transaction error mapper folds a
-- unique violation on an application table into 'WrongExpectedVersion' (its 23505 branch
-- is written for the event tables) and so cannot tell us the SQLSTATE we care about.
module Kioku.SchemaSpec (tests) where

import Control.Exception (bracket)
import Data.Text (Text)
import Data.Text qualified as Text
import Hasql.Connection qualified as Connection
import Hasql.Connection.Settings qualified as Settings
import Hasql.Decoders qualified as D
import Hasql.Encoders qualified as E
import Hasql.Errors (ServerError (..), SessionError (..), StatementError (..))
import Hasql.Session qualified as Session
import Hasql.Statement (Statement, preparable)
import Kioku.Migrations.TestSupport (withKiokuMigratedDatabase)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit (assertBool, assertFailure, testCase, (@?=))

tests :: TestTree
tests =
  testGroup
    "Schema"
    [ testGroup
        "global scopes are unique, not merely NULL-distinct"
        [ testCase "two global scenes with the same key collide" (assertSqlState "23505" duplicateGlobalScenes),
          testCase "two global personas in one namespace collide" (assertSqlState "23505" duplicateGlobalPersonas)
        ],
      testGroup
        "the same scope in two memory spaces is two rows, not a collision"
        [ testCase "two spaces may hold the same global scene key" (assertAccepted crossSpaceGlobalScenes),
          testCase "two spaces may hold the same global persona" (assertAccepted crossSpaceGlobalPersonas)
        ],
      testGroup
        "a scope is global or an entity scope, never half of one"
        [ testCase "a memory with a kind and no ref is rejected" (assertSqlState "23514" (halfScopedMemory "'kind-without-ref'" "NULL")),
          testCase "a memory with a ref and no kind is rejected" (assertSqlState "23514" (halfScopedMemory "NULL" "'ref-without-kind'"))
        ],
      testGroup
        "every partitioned row names a memory space"
        [ testCase "a memory with no memory space is rejected" (assertSqlState "23502" unpartitionedMemory),
          testCase "a memory with an empty memory space is rejected" (assertSqlState "23514" emptySpaceMemory)
        ],
      testCase "the chain and session-list indexes exist and the redundant ones are gone" testIndexes
    ]

-- * Constraint cases

-- | Both rows carry distinct primary keys, so only the scope constraint can reject the
-- second one. Under the old @UNIQUE (namespace, scope_kind, scope_ref, scene_key)@ these
-- two rows coexisted happily: SQL considers NULLs distinct, so the constraint enforced
-- nothing at all for global scopes.
duplicateGlobalScenes :: Text
duplicateGlobalScenes =
  """
  INSERT INTO kiroku.kioku_scenes (memory_space_id, scene_id, namespace, scene_key, title, body_md, source_hash)
  VALUES ('space_a', 'scene-a', 'ns', 'default', 't', 'b', 'h'),
         ('space_a', 'scene-b', 'ns', 'default', 't', 'b', 'h')
  """

duplicateGlobalPersonas :: Text
duplicateGlobalPersonas =
  """
  INSERT INTO kiroku.kioku_personas (memory_space_id, persona_id, namespace, body_md, source_hash)
  VALUES ('space_a', 'persona-a', 'ns', 'b', 'h'),
         ('space_a', 'persona-b', 'ns', 'b', 'h')
  """

-- | The other half of the same constraint. Scene and persona ids are derived from the scope
-- alone, so two spaces using the same namespace produce the same id — which is exactly why the
-- primary key had to become composite. Both of these rows must be accepted.
crossSpaceGlobalScenes :: Text
crossSpaceGlobalScenes =
  """
  INSERT INTO kiroku.kioku_scenes (memory_space_id, scene_id, namespace, scene_key, title, body_md, source_hash)
  VALUES ('space_a', 'kioku_scene:ns:default', 'ns', 'default', 't', 'b', 'h'),
         ('space_b', 'kioku_scene:ns:default', 'ns', 'default', 't', 'b', 'h')
  """

crossSpaceGlobalPersonas :: Text
crossSpaceGlobalPersonas =
  """
  INSERT INTO kiroku.kioku_personas (memory_space_id, persona_id, namespace, body_md, source_hash)
  VALUES ('space_a', 'kioku_persona:ns', 'ns', 'b', 'h'),
         ('space_b', 'kioku_persona:ns', 'ns', 'b', 'h')
  """

-- | A row with exactly one of the two scope columns set. 'Kioku.Api.Scope.scopeFromColumns'
-- reads it back as a global scope, yet no exact-scope query matches it -- so the row is
-- invisible to both halves of the API. The CHECK makes it unwritable. Both arguments are
-- SQL literals, so a case can pass @NULL@ for the column it wants to leave unset.
halfScopedMemory :: Text -> Text -> Text
halfScopedMemory scopeKind scopeRef =
  "INSERT INTO kiroku.kioku_memories"
    <> " (memory_space_id, memory_id, agent_id, namespace, scope_kind, scope_ref, memory_type, content, created_at, updated_at)"
    <> " VALUES ('space_a', 'm-half', 'agent', 'ns', "
    <> scopeKind
    <> ", "
    <> scopeRef
    <> ", 'fact', 'content', now(), now())"

-- | No space at all. A NULL would have to be interpreted by every query, and the only two
-- available interpretations -- invisible, or visible everywhere -- are both wrong.
unpartitionedMemory :: Text
unpartitionedMemory =
  """
  INSERT INTO kiroku.kioku_memories
    (memory_id, agent_id, namespace, memory_type, content, created_at, updated_at)
  VALUES ('m-unpartitioned', 'agent', 'ns', 'fact', 'content', now(), now())
  """

-- | The empty string is not a space either. Allowing it would give "no space" a second
-- spelling, and one that satisfies NOT NULL.
emptySpaceMemory :: Text
emptySpaceMemory =
  """
  INSERT INTO kiroku.kioku_memories
    (memory_space_id, memory_id, agent_id, namespace, memory_type, content, created_at, updated_at)
  VALUES ('', 'm-empty-space', 'agent', 'ns', 'fact', 'content', now(), now())
  """

assertSqlState :: Text -> Text -> IO ()
assertSqlState expected sql =
  withMigratedConnection \conn -> do
    result <- Connection.use conn (Session.script sql)
    case result of
      Right () ->
        assertFailure
          ("expected SQLSTATE " <> Text.unpack expected <> ", but the statement succeeded: " <> Text.unpack sql)
      Left err ->
        case sqlState err of
          Just actual -> actual @?= expected
          Nothing -> assertFailure ("expected SQLSTATE " <> Text.unpack expected <> ", got: " <> show err)

assertAccepted :: Text -> IO ()
assertAccepted sql =
  withMigratedConnection \conn -> do
    result <- Connection.use conn (Session.script sql)
    case result of
      Right () -> pure ()
      Left err -> assertFailure ("expected the statement to be accepted, got: " <> show err)

sqlState :: SessionError -> Maybe Text
sqlState = \case
  ScriptSessionError _ (ServerError code _ _ _ _) -> Just code
  StatementSessionError _ _ _ _ _ (ServerStatementError (ServerError code _ _ _ _)) -> Just code
  _ -> Nothing

-- * Index case

testIndexes :: IO ()
testIndexes =
  withMigratedConnection \conn -> do
    result <- Connection.use conn (Session.statement () selectKiokuIndexes)
    case result of
      Left err -> assertFailure ("listing indexes failed: " <> show err)
      Right indexes -> do
        mapM_
          (\name -> assertBool (Text.unpack name <> " is missing") (name `elem` indexes))
          [ "kioku_memories_supersedes_idx",
            "kioku_memories_superseded_by_idx",
            -- Every index whose leading columns were a namespace or a scope is rebuilt with
            -- the memory space in front of them, because every such query now carries a space
            -- predicate and the space is the most selective column available.
            "kioku_memories_space_scope_idx",
            "kioku_memories_space_type_idx",
            "kioku_memories_space_namespace_idx",
            "kioku_sessions_space_scope_idx",
            "kioku_sessions_space_namespace_started_idx",
            "kioku_sessions_space_namespace_focus_idx",
            "kioku_sessions_space_awaiting_corr_idx",
            "kioku_consolidation_space_scope_idx"
          ]
        mapM_
          (\(name, why) -> assertBool (Text.unpack name <> " still exists; " <> why) (name `notElem` indexes))
          [ ("kioku_turns_session_idx", "it duplicates the index implied by UNIQUE (session_id, turn_index)"),
            ("kioku_scenes_scope_idx", "it duplicates the prefix of kioku_scenes_scope_scene_key_unique"),
            ("kioku_memories_scope_idx", "it was replaced by the partition-leading kioku_memories_space_scope_idx"),
            ("kioku_memories_type_idx", "it was replaced by the partition-leading kioku_memories_space_type_idx"),
            ("kioku_sessions_scope_idx", "it was replaced by the partition-leading kioku_sessions_space_scope_idx"),
            ("kioku_sessions_namespace_started_idx", "it was replaced by its partition-leading rebuild"),
            ("kioku_sessions_namespace_focus_idx", "it was replaced by its partition-leading rebuild"),
            ("kioku_sessions_awaiting_corr_idx", "it was replaced by its partition-leading rebuild"),
            ("kioku_consolidation_scope_idx", "it was replaced by its partition-leading rebuild")
          ]

-- | @pg_indexes.indexname@ is a @name@, not a @text@; the cast is what lets hasql decode it.
selectKiokuIndexes :: Statement () [Text]
selectKiokuIndexes =
  preparable
    "SELECT indexname::text FROM pg_indexes WHERE schemaname = 'kiroku'"
    E.noParams
    (D.rowList (D.column (D.nonNullable D.text)))

-- * Harness

withMigratedConnection :: (Connection.Connection -> IO a) -> IO a
withMigratedConnection use =
  withKiokuMigratedDatabase \connStr ->
    bracket (acquire connStr) Connection.release use
  where
    acquire connStr =
      Connection.acquire (Settings.connectionString connStr)
        >>= either (\err -> assertFailure ("could not connect: " <> show err)) pure
