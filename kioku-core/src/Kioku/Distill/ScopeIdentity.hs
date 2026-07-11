-- | Collision-free identity strings for a 'MemoryScope'.
--
-- Distillation derives persistent row ids, timer ids, and mirror filenames from a scope's
-- namespace, kind, and ref. Those three are unconstrained host-supplied text, and the old
-- derivation simply joined them with @\/@:
--
-- > ScopeGlobal (Namespace "a/b/c")                     -> "a/b/c"
-- > ScopeEntity (Namespace "a") (ScopeKind "b") "c"     -> "a/b/c"
--
-- Two different scopes, one identity — so both wrote to the same @kioku_scenes@ /
-- @kioku_personas@ row, and because the upserts do not update the scope columns on conflict,
-- the second scope's content landed on a row still attributed to the first. Cross-scope data
-- bleed, silently.
--
-- The fix is to percent-escape each component before joining, which makes the encoding
-- injective per component and so the join unambiguous. Escaping @%@ first is what keeps it
-- injective: without that, an input already containing @%2F@ would decode ambiguously.
--
-- Components containing none of @%@, @\/@ or @:@ — which is every well-formed scope in the
-- hosts and the docs (@rei:intention:intention_abc@, @mori:repo:web@, …) — encode to
-- themselves, so existing ids stay byte-identical and no mass migration is needed.
module Kioku.Distill.ScopeIdentity
  ( escapeScopeComponent,
    scopeIdentity,
    scopeIdentityFromColumns,
    scopeSlugFromColumns,
  )
where

import Crypto.Hash (Digest, SHA256)
import Crypto.Hash qualified as Hash
import Data.Maybe (catMaybes)
import Data.Text qualified as Text
import Data.Text.Encoding qualified as TE
import Kioku.Api.Scope (MemoryScope, scopeKindText, scopeNamespaceText, scopeRefText)
import Kioku.Prelude

-- | Percent-escape the three characters that would otherwise make the joined identity
-- ambiguous. @%@ must be escaped first, or the encoding is not injective.
escapeScopeComponent :: Text -> Text
escapeScopeComponent =
  Text.replace ":" "%3A"
    . Text.replace "/" "%2F"
    . Text.replace "%" "%25"

scopeIdentity :: MemoryScope -> Text
scopeIdentity scope =
  scopeIdentityFromColumns
    (scopeNamespaceText scope)
    (scopeKindText scope)
    (scopeRefText scope)

-- | The row-column flavour. Kind and ref are both present or both absent — the
-- @*_scope_pair_check@ constraints added by the schema-hardening migration guarantee it — but
-- a half-populated row is treated as global here, matching 'Kioku.Api.Scope.scopeFromColumns'.
scopeIdentityFromColumns :: Text -> Maybe Text -> Maybe Text -> Text
scopeIdentityFromColumns namespace scopeKind scopeRef =
  case (scopeKind, scopeRef) of
    (Just kind, Just ref) ->
      Text.intercalate "/" (escapeScopeComponent <$> [namespace, kind, ref])
    _ ->
      escapeScopeComponent namespace

-- | A workspace mirror filename: a human-readable prefix plus a hash of the true identity.
--
-- The readable part alone cannot be collision-free — the sanitiser maps every unsafe
-- character to @-@, so @Namespace "a-b"@ and @Namespace "a" / ScopeKind "b"@ both render
-- @a-b@ — and no "escape only when ambiguous" rule can detect that locally. The suffix is
-- what actually separates them; the prefix is only so a human can tell the files apart.
scopeSlugFromColumns :: Text -> Maybe Text -> Maybe Text -> Text
scopeSlugFromColumns namespace scopeKind scopeRef =
  sanitizeSlug readable <> "-" <> identityDigest
  where
    readable =
      Text.intercalate "-" (namespace : catMaybes [scopeKind, scopeRef])

    identityDigest =
      Text.take 10 . Text.pack . show $
        (Hash.hash (TE.encodeUtf8 (scopeIdentityFromColumns namespace scopeKind scopeRef)) :: Digest SHA256)

sanitizeSlug :: Text -> Text
sanitizeSlug =
  Text.map \ch ->
    if isSafeSlugChar ch then ch else '-'

isSafeSlugChar :: Char -> Bool
isSafeSlugChar ch =
  (ch >= 'a' && ch <= 'z')
    || (ch >= 'A' && ch <= 'Z')
    || (ch >= '0' && ch <= '9')
    || ch == '-'
    || ch == '_'
