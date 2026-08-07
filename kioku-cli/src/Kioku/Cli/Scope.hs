module Kioku.Cli.Scope
  ( parseScope,
    scopeGrammarError,
    parseNamespaceOnly,
    namespaceGrammarError,
  )
where

import Data.Text qualified as Text
import Kioku.Api.Scope (MemoryScope (..), Namespace, mkNamespace, mkScopeKind)

-- | @NAMESPACE@ or @NAMESPACE:KIND:REF@.
--
-- Only the first two colons split. Everything after the second colon is the ref, colons
-- included, so a URL or a @host:port@ pair is expressible: @ops:host:db.internal:5432@ has the
-- ref @db.internal:5432@. Splitting on /every/ colon (the old behavior) made those refs
-- unreachable from the CLI — they parsed as four segments and were rejected.
--
-- Namespace and kind still go through the validating constructors, so a @\/@ or @%@ that would
-- make the scope's derived identity ambiguous is rejected here rather than silently escaped
-- into a row id; a @:@ in either is now impossible by construction rather than by validation.
-- The ref is not validated beyond being non-empty: refs are host free text, and
-- 'Kioku.Distill.ScopeIdentity.escapeScopeComponent' escapes the colons they may now contain,
-- so a colon-bearing ref still gets a collision-free identity.
parseScope :: String -> Either String MemoryScope
parseScope raw =
  case Text.breakOn ":" (Text.pack raw) of
    (ns, afterNs)
      | Text.null afterNs -> ScopeGlobal <$> namespace ns
      | otherwise ->
          case Text.breakOn ":" (Text.drop 1 afterNs) of
            (kind, afterKind)
              | Text.null afterKind -> Left scopeGrammarError
              | ref <- Text.drop 1 afterKind ->
                  if Text.null ref
                    then Left "REF must not be empty"
                    else ScopeEntity <$> namespace ns <*> scopeKind kind <*> pure ref
  where
    namespace = first Text.unpack . mkNamespace
    scopeKind = first Text.unpack . mkScopeKind
    first f = either (Left . f) Right

scopeGrammarError :: String
scopeGrammarError =
  "expected NAMESPACE or NAMESPACE:KIND:REF (REF may contain ':'; NAMESPACE and KIND may not)"

-- | A bare @NAMESPACE@, with no scope attached.
--
-- Recall's @--global-bucket@ and @--namespace-wide@ take a namespace rather than a scope, because
-- the scope part is what the flag itself is saying. A colon is therefore rejected with its own
-- message rather than left to 'mkNamespace': someone typing @--namespace-wide mori:repo:web@ is
-- reaching for @--scope@, and saying so is more use than reporting a reserved character.
parseNamespaceOnly :: String -> Either String Namespace
parseNamespaceOnly raw
  | Text.isInfixOf ":" text = Left namespaceGrammarError
  | otherwise = either (Left . Text.unpack) Right (mkNamespace text)
  where
    text = Text.pack raw

namespaceGrammarError :: String
namespaceGrammarError =
  "expected a bare NAMESPACE with no scope attached; use --scope NAMESPACE:KIND:REF for one entity"
