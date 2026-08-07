-- | What a recall call searches, said out loud.
--
-- Recall has always been able to do two quite different things, and until this module existed it
-- said both of them with the same value. A 'Kioku.Api.Scope.MemoryScope' of
-- @ScopeGlobal (Namespace "mori")@ handed to recall meant /every scope in the namespace/ — the
-- scope filter vanished and entity-scoped rows came back too — while the same value handed to
-- 'Kioku.Recall.getActiveByScope' meant /the global bucket only/. Both behaviours are wanted.
-- Neither is wrong. But one value naming both of them is a defect you cannot see at a call site,
-- and the difference is how many rows a caller gets and which ones.
--
-- 'RecallTarget' names the two meanings apart:
--
-- * @'ExactScope' scope@ searches exactly that scope. @'ExactScope' ('Kioku.Api.Scope.ScopeGlobal'
--   ns)@ is the global bucket of @ns@ and nothing else — a request that had no representation at
--   all before this type.
-- * @'NamespaceWide' ns@ searches every scope in @ns@.
--
-- __The target never selects a tenant.__ A memory space is the isolation boundary
-- ('Kioku.Api.Access.MemorySpaceId'), and it is supplied at execution by the
-- 'Kioku.Api.Access.MemoryAccessContext' that authorized the call — never by the target.
-- "Namespace-wide" therefore means every scope in one namespace /of one already authorized
-- space/. Widening what you search must never widen who you are.
--
-- Nothing here knows about SQL, PostgreSQL, or the effect stack; this module is the vocabulary,
-- and "Kioku.Recall" is where a target is executed.
module Kioku.Api.Recall
  ( -- * What a recall call targets
    RecallTarget (..),
    recallTargetNamespace,
    recallTargetExactScope,
    recallTargetIsNamespaceWide,

    -- * Migrating from the overloaded scope
    legacyRecallTarget,

    -- * How a recall call searches
    RecallStrategy (..),
    allRecallStrategies,
    recallStrategyText,
    parseRecallStrategy,

    -- * How many results it may return
    RecallLimit,
    mkRecallLimit,
    recallLimitInt,
    defaultRecallLimit,
    maxRecallLimit,

    -- * The request
    RecallQuery (..),
    mkRecallQuery,
  )
where

import Data.Aeson (Key, (.:), (.:?))
import Data.Aeson qualified as Aeson
import Data.Aeson.Types qualified as Aeson (Pair, Parser)
import Data.Text qualified as Text
import Kioku.Api.Scope
  ( MemoryScope (..),
    Namespace (..),
    ScopeKind (..),
    mkNamespace,
    mkScopeKind,
  )
import Kioku.Prelude

-- | The two things a recall call can search, kept apart by construction.
--
-- There is deliberately no third constructor and no \"unspecified\" case. A target that could be
-- absent would immediately grow a default, and the only sensible default for a search is the
-- widest one — which is how the overloaded scope became a hazard in the first place.
data RecallTarget
  = -- | Exactly this scope. For @'ScopeGlobal' ns@ that is the global bucket of @ns@: rows
    -- recorded with no entity scope. For @'ScopeEntity' ns kind ref@ it is that entity and no
    -- other.
    ExactScope !MemoryScope
  | -- | Every scope in this namespace: the global bucket and every entity scope under it. This
    -- is what a pre-'RecallTarget' recall did with a global scope.
    NamespaceWide !Namespace
  deriving stock (Eq, Show, Generic)

-- | The namespace a target searches. Every target names exactly one; a target that spanned
-- namespaces has never existed and is not being introduced here.
recallTargetNamespace :: RecallTarget -> Namespace
recallTargetNamespace = \case
  ExactScope (ScopeGlobal ns) -> ns
  ExactScope (ScopeEntity ns _ _) -> ns
  NamespaceWide ns -> ns

-- | The scope an exact target names, or 'Nothing' for a namespace-wide one.
recallTargetExactScope :: RecallTarget -> Maybe MemoryScope
recallTargetExactScope = \case
  ExactScope scope -> Just scope
  NamespaceWide _ -> Nothing

-- | Whether this target widens past a single scope. Worth a name of its own: this is the
-- predicate an audit log, a CLI confirmation, or a policy check actually wants to ask.
recallTargetIsNamespaceWide :: RecallTarget -> Bool
recallTargetIsNamespaceWide = \case
  ExactScope _ -> False
  NamespaceWide _ -> True

-- | The target a pre-'RecallTarget' caller was asking for, given the 'MemoryScope' it passed.
--
-- @
-- 'ScopeGlobal' ns        -> 'NamespaceWide' ns
-- 'ScopeEntity' ns k r    -> 'ExactScope' ('ScopeEntity' ns k r)
-- @
--
-- Use this exactly once per call site, while migrating, to keep the results you have today. Then
-- decide: if you wanted the global bucket rather than the whole namespace, the answer is
-- @'ExactScope' ('ScopeGlobal' ns)@, which this function deliberately never produces.
--
-- Mapping the global scope to 'NamespaceWide' rather than to an exact global bucket is the whole
-- point. The opposite mapping would compile, run, and silently return a small fraction of the
-- rows the caller used to get.
legacyRecallTarget :: MemoryScope -> RecallTarget
legacyRecallTarget = \case
  ScopeGlobal ns -> NamespaceWide ns
  scope@ScopeEntity {} -> ExactScope scope

-- | Which retrieval channels a recall call runs.
--
-- This lived in @Kioku.Recall@ until targets became explicit. It belongs beside them: a request
-- is a target, a query, a strategy and a bound, and all four are pure vocabulary that a host,
-- an HTTP service, or an SDK has to be able to name without depending on the runtime.
data RecallStrategy
  = -- | Full-text search only. Needs no embedding endpoint.
    Keyword
  | -- | Vector similarity only. Needs the query embedded.
    Embedding
  | -- | Both channels, fused by reciprocal rank. The default and what you almost always want.
    Hybrid
  deriving stock (Generic, Eq, Show, Enum, Bounded)

-- | Every strategy, in the order they are documented.
allRecallStrategies :: [RecallStrategy]
allRecallStrategies = [minBound .. maxBound]

-- | The wire and command-line spelling of a strategy. These three strings appear in
-- @kioku recall --strategy@ and in every request body, so changing one is a breaking change.
recallStrategyText :: RecallStrategy -> Text
recallStrategyText = \case
  Keyword -> "keyword"
  Embedding -> "embedding"
  Hybrid -> "hybrid"

parseRecallStrategy :: Text -> Either Text RecallStrategy
parseRecallStrategy = \case
  "keyword" -> Right Keyword
  "embedding" -> Right Embedding
  "hybrid" -> Right Hybrid
  other ->
    Left
      ( "unknown recall strategy: "
          <> other
          <> " (expected "
          <> Text.intercalate ", " (recallStrategyText <$> allRecallStrategies)
          <> ")"
      )

-- | How many hits a recall call may return: at least one, at most 'maxRecallLimit'.
--
-- A validated newtype rather than a bare 'Int' because the two ends mean different things and
-- both were previously unenforced at the library boundary. Zero or negative is not \"no limit\",
-- it is a caller bug that silently returns nothing; and an unbounded upper end invites a request
-- for a million rows that the database would have to plan for. The command line has enforced
-- @1-100@ since it was written — this puts the same rule where library callers meet it.
newtype RecallLimit = RecallLimit Int
  deriving stock (Eq, Ord, Show, Generic)

-- | The largest number of hits a single recall call may ask for.
--
-- 100 matches the range @kioku recall --limit@ has always accepted, and it is also the most a
-- request can produce: each channel contributes at most 50 candidates, so a fused result set
-- holds at most 100 distinct memories. Asking for more has never returned more.
maxRecallLimit :: Int
maxRecallLimit = 100

-- | What @kioku recall@ uses when no limit is given.
defaultRecallLimit :: RecallLimit
defaultRecallLimit = RecallLimit 8

mkRecallLimit :: Int -> Either Text RecallLimit
mkRecallLimit value
  | value < 1 = Left ("recall limit must be at least 1: " <> Text.pack (show value))
  | value > maxRecallLimit =
      Left
        ( "recall limit must be at most "
            <> Text.pack (show maxRecallLimit)
            <> ": "
            <> Text.pack (show value)
        )
  | otherwise = Right (RecallLimit value)

recallLimitInt :: RecallLimit -> Int
recallLimitInt (RecallLimit value) = value

-- | Everything a recall call needs except the space it runs in.
--
-- The memory space is deliberately absent. It comes from the
-- 'Kioku.Api.Access.MemoryAccessContext' passed to 'Kioku.Recall.recall', because a request is
-- something a caller composes and a space is something an authorization decision granted. Keeping
-- them in separate values means no code path can widen a target and a tenancy in one edit.
--
-- Every field is already validated by its own type, so the record constructor is safe to export:
-- a 'RecallTarget' cannot be ambiguous and a 'RecallLimit' cannot be zero. 'mkRecallQuery' is a
-- convenience for callers holding a plain 'Int'.
--
-- The query text is /not/ validated. It is user input on its way to
-- @websearch_to_tsquery@, which is total by design and never raises, and rejecting empty or
-- punctuation-only text here would break callers that rely on today's \"no matches\" answer.
data RecallQuery = RecallQuery
  { target :: !RecallTarget,
    query :: !Text,
    strategy :: !RecallStrategy,
    maxResults :: !RecallLimit
  }
  deriving stock (Eq, Show, Generic)

mkRecallQuery :: RecallTarget -> Text -> RecallStrategy -> Int -> Either Text RecallQuery
mkRecallQuery target query strategy limit = do
  maxResults <- mkRecallLimit limit
  Right RecallQuery {target, query, strategy, maxResults}

-- * Wire format

-- $
-- The encoding is hand-written rather than derived, and the discriminator is required. Three
-- meanings, three tags, no field whose /absence/ changes what the request means:
--
-- @
-- {"kind":"exact_global","namespace":"mori"}
-- {"kind":"exact_entity","namespace":"mori","scope_kind":"repo","scope_ref":"shinzui\/kikan"}
-- {"kind":"namespace_wide","namespace":"mori"}
-- @
--
-- A derived encoding would have spelled the two Haskell constructors instead, leaving the
-- exact-global and exact-entity cases separated only by whether @scope_kind@ was present — which
-- is the null-means-something representation this whole change exists to remove, moved from SQL
-- onto the wire.
--
-- Decoding is strict in both directions: an unknown @kind@ is an error, and a variant carrying a
-- field it has no meaning for ('exact_global' with a @scope_kind@, say) is an error too, rather
-- than a value with a silently ignored field.

instance ToJSON RecallTarget where
  toJSON = \case
    ExactScope (ScopeGlobal (Namespace ns)) ->
      Aeson.object [pair "kind" exactGlobalTag, pair "namespace" ns]
    ExactScope (ScopeEntity (Namespace ns) (ScopeKind kind) ref) ->
      Aeson.object
        [ pair "kind" exactEntityTag,
          pair "namespace" ns,
          pair "scope_kind" kind,
          pair "scope_ref" ref
        ]
    NamespaceWide (Namespace ns) ->
      Aeson.object [pair "kind" namespaceWideTag, pair "namespace" ns]

instance FromJSON RecallTarget where
  parseJSON = Aeson.withObject "RecallTarget" \o -> do
    kind <- o .: "kind"
    namespace <- parseValidated mkNamespace =<< o .: "namespace"
    scopeKind <- o .:? "scope_kind"
    scopeRef <- o .:? "scope_ref"
    case (kind :: Text, scopeKind, scopeRef) of
      (k, Nothing, Nothing)
        | k == exactGlobalTag -> pure (ExactScope (ScopeGlobal namespace))
        | k == namespaceWideTag -> pure (NamespaceWide namespace)
      (k, Just kindText, Just ref)
        | k == exactEntityTag -> do
            entityKind <- parseValidated mkScopeKind kindText
            pure (ExactScope (ScopeEntity namespace entityKind ref))
      (k, _, _)
        | k `elem` [exactGlobalTag, exactEntityTag, namespaceWideTag] ->
            fail
              ( "recall target "
                  <> show k
                  <> " must carry "
                  <> ( if k == exactEntityTag
                         then "both scope_kind and scope_ref"
                         else "neither scope_kind nor scope_ref"
                     )
              )
        | otherwise ->
            fail
              ( "unknown recall target kind: "
                  <> show k
                  <> " (expected exact_global, exact_entity or namespace_wide)"
              )

instance ToJSON RecallStrategy where
  toJSON = toJSON . recallStrategyText

instance FromJSON RecallStrategy where
  parseJSON = Aeson.withText "RecallStrategy" (parseValidated parseRecallStrategy)

instance ToJSON RecallLimit where
  toJSON = toJSON . recallLimitInt

-- | Decoding enforces the same bounds as 'mkRecallLimit'. A newtype validated only on the path
-- the host controls is validated only where nobody attacks it.
instance FromJSON RecallLimit where
  parseJSON value = parseValidated mkRecallLimit =<< parseJSON value

instance ToJSON RecallQuery where
  toJSON request =
    Aeson.object
      [ pair "target" request.target,
        pair "query" request.query,
        pair "strategy" request.strategy,
        pair "max_results" request.maxResults
      ]

instance FromJSON RecallQuery where
  parseJSON = Aeson.withObject "RecallQuery" \o ->
    RecallQuery
      <$> o .: "target"
      <*> o .: "query"
      <*> o .: "strategy"
      <*> o .: "max_results"

exactGlobalTag, exactEntityTag, namespaceWideTag :: Text
exactGlobalTag = "exact_global"
exactEntityTag = "exact_entity"
namespaceWideTag = "namespace_wide"

-- | Run one of this project's @Either Text@ validating constructors inside a parser, so a wire
-- value is held to exactly the rule a directly constructed one is.
parseValidated :: (a -> Either Text b) -> a -> Aeson.Parser b
parseValidated validate = either (fail . Text.unpack) pure . validate

-- | 'Kioku.Prelude' re-exports @Control.Lens@, which owns @(.=)@, so aeson's stays out of scope
-- and object fields are built through this instead.
pair :: (ToJSON v) => Key -> v -> Aeson.Pair
pair key value = (key, toJSON value)
