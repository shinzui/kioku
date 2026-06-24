module Kioku.Api.Scope
  ( Namespace (..),
    ScopeKind (..),
    MemoryScope (..),
    scopeNamespaceText,
    scopeKindText,
    scopeRefText,
    scopeFromColumns,
  )
where

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
