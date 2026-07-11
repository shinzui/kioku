module Kioku.Api.Scope
  ( Namespace (..),
    ScopeKind (..),
    MemoryScope (..),
    mkNamespace,
    mkScopeKind,
    scopeNamespaceText,
    scopeKindText,
    scopeRefText,
    scopeFromColumns,
  )
where

import Data.Text qualified as Text
import Kioku.Prelude

-- | A host label: "rei", "mori", "shikigami", and similar namespaces.
newtype Namespace = Namespace Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The entity-kind tag: "intention", "habit", "repo", "group", "agent", etc.
newtype ScopeKind = ScopeKind Text
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

data MemoryScope
  = ScopeGlobal Namespace
  | ScopeEntity Namespace ScopeKind Text
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Validating constructors for the two label-like scope components.
--
-- Namespaces and kinds are vocabularies — @rei@, @mori@, @shikigami@; @intention@, @repo@,
-- @agent@ — and nothing legitimate contains @%@, @\/@ or @:@. Rejecting those at the edge is
-- cheap defence in depth on top of the escaping in
-- 'Kioku.Distill.ScopeIdentity.escapeScopeComponent', which is what actually guarantees
-- distinct scopes get distinct identities.
--
-- Refs are deliberately *not* validated: they are host-controlled free text and legitimately
-- contain @\/@ (repo-style refs such as @shinzui\/kikan@, arbitrary agent names). The raw
-- 'Namespace' and 'ScopeKind' constructors stay exported, because hosts construct them
-- directly.
mkNamespace :: Text -> Either Text Namespace
mkNamespace = fmap Namespace . validateScopeLabel "namespace"

mkScopeKind :: Text -> Either Text ScopeKind
mkScopeKind = fmap ScopeKind . validateScopeLabel "scope kind"

validateScopeLabel :: Text -> Text -> Either Text Text
validateScopeLabel label value
  | Text.null value = Left (label <> " must not be empty")
  | Just offending <- Text.find (`Text.elem` reservedScopeChars) value =
      Left (label <> " must not contain " <> Text.singleton offending <> ": " <> value)
  | otherwise = Right value

-- | The characters the scope-identity encoding gives meaning to.
reservedScopeChars :: Text
reservedScopeChars = "%/:"

scopeNamespaceText :: MemoryScope -> Text
scopeNamespaceText = \case
  ScopeGlobal (Namespace ns) -> ns
  ScopeEntity (Namespace ns) _ _ -> ns

scopeKindText :: MemoryScope -> Maybe Text
scopeKindText = \case
  ScopeGlobal _ -> Nothing
  ScopeEntity _ (ScopeKind k) _ -> Just k

scopeRefText :: MemoryScope -> Maybe Text
scopeRefText = \case
  ScopeGlobal _ -> Nothing
  ScopeEntity _ _ ref -> Just ref

scopeFromColumns :: Text -> Maybe Text -> Maybe Text -> MemoryScope
scopeFromColumns ns (Just k) (Just ref) = ScopeEntity (Namespace ns) (ScopeKind k) ref
scopeFromColumns ns _ _ = ScopeGlobal (Namespace ns)
