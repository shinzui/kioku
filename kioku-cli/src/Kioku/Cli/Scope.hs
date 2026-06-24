module Kioku.Cli.Scope
  ( parseScope,
  )
where

import Data.Text qualified as Text
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))

parseScope :: String -> Either String MemoryScope
parseScope raw =
  case Text.splitOn ":" (Text.pack raw) of
    [ns]
      | not (Text.null ns) -> Right (ScopeGlobal (Namespace ns))
    [ns, kind, ref]
      | not (Text.null ns) && not (Text.null kind) && not (Text.null ref) ->
          Right (ScopeEntity (Namespace ns) (ScopeKind kind) ref)
    _ ->
      Left "expected NAMESPACE or NAMESPACE:KIND:REF"
