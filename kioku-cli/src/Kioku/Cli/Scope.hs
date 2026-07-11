module Kioku.Cli.Scope
  ( parseScope,
  )
where

import Data.Text qualified as Text
import Kioku.Api.Scope (MemoryScope (..), mkNamespace, mkScopeKind)

-- | @NAMESPACE@ or @NAMESPACE:KIND:REF@.
--
-- The namespace and kind go through the validating constructors, so a @\/@ or @%@ that would
-- make the scope's derived identity ambiguous is rejected here rather than silently escaped
-- into a row id. The @:@-split already excludes @:@ from all three fields.
--
-- The ref is not validated beyond being non-empty: refs are host free text and legitimately
-- contain @\/@.
parseScope :: String -> Either String MemoryScope
parseScope raw =
  case Text.splitOn ":" (Text.pack raw) of
    [ns] ->
      ScopeGlobal <$> namespace ns
    [ns, kind, ref]
      | Text.null ref -> Left "REF must not be empty"
      | otherwise -> ScopeEntity <$> namespace ns <*> scopeKind kind <*> pure ref
    _ ->
      Left "expected NAMESPACE or NAMESPACE:KIND:REF"
  where
    namespace = first Text.unpack . mkNamespace
    scopeKind = first Text.unpack . mkScopeKind
    first f = either (Left . f) Right
