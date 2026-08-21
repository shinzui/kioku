-- | @kioku recall@: the one command that can be asked to widen what it searches.
--
-- Every other command takes a @--scope@ that means exactly one scope. Recall used to take the
-- same flag and mean two different things by it: @--scope mori:repo:web@ matched that entity
-- exactly, while @--scope mori@ dropped the scope filter and searched the whole namespace — the
-- opposite of what @kioku scenes --scope mori@ does with the same text. That was the command-line
-- half of the overload "Kioku.Api.Recall" removed from the library.
--
-- Each target now has exactly one spelling, and none of them is a bare namespace:
--
-- > kioku recall QUERY --scope NAMESPACE:KIND:REF   -- ExactScope (ScopeEntity …)
-- > kioku recall QUERY --global-bucket NAMESPACE    -- ExactScope (ScopeGlobal …)
-- > kioku recall QUERY --namespace-wide NAMESPACE   -- NamespaceWide …
--
-- @--scope NAMESPACE@ is a parse error naming the other two. It would have been tidier to let it
-- mean the global bucket, matching @kioku scenes@ — but that silently narrows every existing
-- @kioku recall --scope mori@ to a fraction of its rows, with no compiler to warn and a zero exit
-- status, which is the direction @docs\/adr\/an-explicit-recall-target-replaces-the-overloaded-scope.md@
-- records as the unsafe one.
--
-- The strategy spelling, enumeration, and invalid-value diagnostic are owned by
-- "Kioku.Api.Recall"; this module only adapts that vocabulary to optparse-applicative.
module Kioku.Cli.Commands.Recall
  ( RecallOptions (..),
    recallOptionsParser,
    recallTargetParser,
    describeTarget,
    bareNamespaceScopeError,
    runRecall,
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.Api.Access (memoryContextSpace, memorySpaceIdText)
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Kioku.Api.Types (MemoryRecord (..))
import Kioku.App (runAppIO, withNoopAppEnv)
import Kioku.Cli.Context (cliMemoryContext)
import Kioku.Cli.Options (boundedIntReader)
import Kioku.Cli.Scope (parseNamespaceOnly, parseScope)
import Kioku.Memory.Embedding (EmbeddingConfig (..), resolveEmbeddingConfig, toEmbeddingModel)
import Kioku.Recall
  ( RecallHit (..),
    RecallStrategy (..),
    RecallTarget (..),
    allRecallStrategies,
    mkRecallQuery,
    parseRecallStrategy,
    recall,
    recallStrategyText,
  )
import Kioku.Recall.Capability (detectVectorCapability)
import Kiroku.Store.Connection (defaultConnectionSettings)
import Options.Applicative
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

data RecallOptions = RecallOptions
  { query :: !Text,
    target :: !RecallTarget,
    strategy :: !RecallStrategy,
    limit :: !Int,
    showScores :: !Bool
  }
  deriving stock (Eq, Show)

recallOptionsParser :: Parser RecallOptions
recallOptionsParser =
  RecallOptions
    <$> (Text.pack <$> argument str (metavar "QUERY"))
    <*> recallTargetParser
    <*> option
      (eitherReader (first Text.unpack . parseRecallStrategy . Text.pack))
      ( long "strategy"
          <> metavar strategyMetavar
          <> value Hybrid
          <> help "Recall strategy"
      )
    <*> option
      (boundedIntReader "LIMIT" 1 100)
      ( long "limit"
          <> metavar "N"
          <> value 8
          <> help "Maximum hits to return (1-100)"
      )
    <*> switch
      ( long "show-scores"
          <> help "Print fused scores and component ranks"
      )

-- | Exactly one of the three target flags, and never two.
--
-- The mutual exclusion is the same construction @kioku worker@ uses for its one-shot modes:
-- alternatives consume the flag they name, so a second target flag is left over and optparse
-- reports it by name. Omitting all three is @Missing:@ with the three forms listed, which is the
-- help text an operator wants at that moment anyway.
recallTargetParser :: Parser RecallTarget
recallTargetParser =
  exactEntity <|> globalBucket <|> namespaceWide
  where
    exactEntity =
      ExactScope
        <$> option
          (eitherReader parseExactEntityScope)
          ( long "scope"
              <> metavar "NAMESPACE:KIND:REF"
              <> help "Search exactly this entity scope; REF may contain ':'"
          )

    globalBucket =
      ExactScope . ScopeGlobal
        <$> option
          (eitherReader parseNamespaceOnly)
          ( long "global-bucket"
              <> metavar "NAMESPACE"
              <> help "Search only the rows recorded in NAMESPACE with no entity scope"
          )

    namespaceWide =
      NamespaceWide
        <$> option
          (eitherReader parseNamespaceOnly)
          ( long "namespace-wide"
              <> metavar "NAMESPACE"
              <> help "Search every scope in NAMESPACE: the global bucket and every entity under it"
          )

-- | @--scope@ accepts the shared @NAMESPACE:KIND:REF@ grammar and then refuses the one result
-- that would be ambiguous.
--
-- Reusing 'parseScope' rather than writing a second grammar is deliberate: the rules about which
-- colons split, and which characters a namespace may hold, must not drift between @kioku recall@
-- and @kioku scenes@.
parseExactEntityScope :: String -> Either String MemoryScope
parseExactEntityScope raw = do
  scope <- parseScope raw
  case scope of
    ScopeGlobal (Namespace ns) -> Left (bareNamespaceScopeError (Text.unpack ns))
    entity -> Right entity

-- | What an operator sees when they type the spelling that used to work.
--
-- It names both replacements and says which one reproduces the old behavior, because the whole
-- reason this is an error rather than a silent re-reading is that the two answers differ in how
-- many rows come back.
bareNamespaceScopeError :: String -> String
bareNamespaceScopeError ns =
  unlines
    [ "a bare namespace is ambiguous for recall, so --scope will not accept one.",
      "  --global-bucket " <> ns <> "   rows in " <> ns <> " recorded with no entity scope",
      "  --namespace-wide " <> ns <> "  every scope in " <> ns <> " (what --scope " <> ns <> " returned before)"
    ]
    <> "--scope takes a full NAMESPACE:KIND:REF entity scope."

-- | The target and space a run actually searched, for the operator rather than for a script.
describeTarget :: RecallTarget -> String
describeTarget = \case
  ExactScope (ScopeGlobal (Namespace ns)) ->
    "the global bucket of " <> Text.unpack ns
  ExactScope (ScopeEntity (Namespace ns) (ScopeKind kind) ref) ->
    "scope " <> Text.unpack ns <> ":" <> Text.unpack kind <> ":" <> Text.unpack ref
  NamespaceWide (Namespace ns) ->
    "every scope in " <> Text.unpack ns

runRecall :: RecallOptions -> IO ()
runRecall opts = do
  connStr <- requireEnv "PG_CONNECTION_STRING"
  config <- resolveEmbeddingConfig
  context <- cliMemoryContext
  request <-
    case mkRecallQuery opts.target opts.query opts.strategy opts.limit of
      Left err -> ioError (userError ("kioku recall: " <> Text.unpack err))
      Right request -> pure request
  -- On stderr, not stdout: a script piping hits must see exactly the lines it saw before, while
  -- an operator at a terminal should never have to infer from a result count whether they
  -- searched one scope or a whole namespace.
  hPutStrLn
    stderr
    ( "kioku recall: searching "
        <> describeTarget opts.target
        <> ", in memory space "
        <> Text.unpack (memorySpaceIdText (memoryContextSpace context))
    )
  withNoopAppEnv (defaultConnectionSettings (Text.pack connStr)) \env -> do
    let model = toEmbeddingModel config
    result <- runAppIO env do
      capability <- detectVectorCapability config.dimensions
      recall model capability context request
    case result of
      Left storeErr -> ioError (userError ("kioku recall store error: " <> show storeErr))
      Right (Left recallErr) -> ioError (userError ("kioku recall error: " <> show recallErr))
      Right (Right []) -> putStrLn "(no matches)"
      Right (Right hits) -> mapM_ (printHit opts.showScores) (zip [(1 :: Int) ..] hits)

strategyMetavar :: String
strategyMetavar =
  Text.unpack (Text.intercalate "|" (recallStrategyText <$> allRecallStrategies))

printHit :: Bool -> (Int, RecallHit) -> IO ()
printHit showScores (index, hit)
  | showScores =
      putStrLn $
        show index
          <> ". score="
          <> printf "%.4f" hit.score
          <> " fts="
          <> rankText hit.ftsRank
          <> " vec="
          <> rankText hit.vecRank
          <> " "
          <> Text.unpack hit.memory.memoryType
          <> " "
          <> show (Text.unpack hit.memory.content)
  | otherwise =
      putStrLn $
        show index
          <> ". "
          <> Text.unpack hit.memory.memoryType
          <> " "
          <> show (Text.unpack hit.memory.content)

rankText :: Maybe Int -> String
rankText Nothing = "-"
rankText (Just rank) = show rank

requireEnv :: String -> IO String
requireEnv name = do
  found <- lookupEnv name
  case found of
    Just envValue -> pure envValue
    Nothing -> ioError (userError (name <> " is not set"))
