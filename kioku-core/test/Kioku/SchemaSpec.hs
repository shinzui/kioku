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
        "a scope is global or an entity scope, never half of one"
        [ testCase "a memory with a kind and no ref is rejected" (assertSqlState "23514" (halfScopedMemory "'kind-without-ref'" "NULL")),
          testCase "a memory with a ref and no kind is rejected" (assertSqlState "23514" (halfScopedMemory "NULL" "'ref-without-kind'"))
        ],
      testCase "the chain and session-list indexes exist and the redundant turns index is gone" testIndexes
    ]

-- * Constraint cases

-- | Both rows carry distinct primary keys, so only the scope constraint can reject the
-- second one. Under the old @UNIQUE (namespace, scope_kind, scope_ref, scene_key)@ these
-- two rows coexisted happily: SQL considers NULLs distinct, so the constraint enforced
-- nothing at all for global scopes.
duplicateGlobalScenes :: Text
duplicateGlobalScenes =
  """
  INSERT INTO kiroku.kioku_scenes (scene_id, namespace, scene_key, title, body_md, source_hash)
  VALUES ('scene-a', 'ns', 'default', 't', 'b', 'h'),
         ('scene-b', 'ns', 'default', 't', 'b', 'h')
  """

duplicateGlobalPersonas :: Text
duplicateGlobalPersonas =
  """
  INSERT INTO kiroku.kioku_personas (persona_id, namespace, body_md, source_hash)
  VALUES ('persona-a', 'ns', 'b', 'h'),
         ('persona-b', 'ns', 'b', 'h')
  """

-- | A row with exactly one of the two scope columns set. 'Kioku.Api.Scope.scopeFromColumns'
-- reads it back as a global scope, yet no exact-scope query matches it -- so the row is
-- invisible to both halves of the API. The CHECK makes it unwritable. Both arguments are
-- SQL literals, so a case can pass @NULL@ for the column it wants to leave unset.
halfScopedMemory :: Text -> Text -> Text
halfScopedMemory scopeKind scopeRef =
  "INSERT INTO kiroku.kioku_memories"
    <> " (memory_id, agent_id, namespace, scope_kind, scope_ref, memory_type, content, created_at, updated_at)"
    <> " VALUES ('m-half', 'agent', 'ns', "
    <> scopeKind
    <> ", "
    <> scopeRef
    <> ", 'fact', 'content', now(), now())"

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
            "kioku_sessions_namespace_started_idx",
            "kioku_sessions_namespace_focus_idx"
          ]
        assertBool
          "kioku_turns_session_idx still exists; it duplicates the index implied by UNIQUE (session_id, turn_index)"
          ("kioku_turns_session_idx" `notElem` indexes)

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
