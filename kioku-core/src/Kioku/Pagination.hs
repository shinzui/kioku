-- | SQL-bounded core reads using the shared Relay keyset implementation.
-- Hosts exposing these cursors over an API bind their collection/filter context
-- around the public Relay cursor; this module never forks that codec.
--
-- Unlike the older space-first reads, every bounded read checks that its context grants
-- 'MemoryRead' before any SQL runs. A context minted only to record or forget cannot be spent
-- on listing or counting the space.
module Kioku.Pagination
  ( BoundedPageError (..),
    BoundedReadError (..),
    boundedPage,
    maxBoundedPageSize,
    gatedRead,
    gatedPage,
    contextSpaceSnippet,
    recallTargetSnippet,
    Connection,
    PageRequest (..),
  )
where

import Data.Bifunctor (first)
import Data.Text (Text)
import Hasql.Decoders qualified as D
import Hasql.DynamicStatements.Snippet qualified as S
import Hasql.Transaction qualified as Tx
import Keiro.ReadModel (ReadModelError)
import Kioku.Api.Access (MemoryAccessContext, MemoryPermission (MemoryRead), memoryContextAllows, memoryContextSpace, memorySpaceIdText)
import Kioku.Api.Recall (RecallTarget (..))
import Kioku.Api.Scope (MemoryScope (..), Namespace (..), ScopeKind (..))
import Relay.Pagination (Connection, CursorError, PageRequest (..), PageRequestError (..))
import Relay.Pagination.Hasql qualified as R

data BoundedPageError = InvalidPageSize !PageRequestError | InvalidPageCursor !CursorError
  deriving stock (Eq, Show)

-- | Every way a bounded read can fail, flattened so callers match one type.
data BoundedReadError
  = -- | the context authorized other actions, but not reading
    BoundedReadNotPermitted !MemoryPermission
  | BoundedReadFailed !ReadModelError
  | BoundedReadInvalidPage !BoundedPageError
  deriving stock (Eq, Show)

-- | The largest page any bounded read returns. A zero-size page is valid Relay and returns
-- only page info.
maxBoundedPageSize :: Int
maxBoundedPageSize = 100

boundedPage :: R.SortSpec row -> D.Row row -> S.Snippet -> PageRequest -> Tx.Transaction (Either BoundedPageError (Connection row))
boundedPage order decoder base request
  | request.pageSize < 0 = pure (Left (InvalidPageSize (NegativePageSize request.pageSize)))
  | request.pageSize > maxBoundedPageSize = pure (Left (InvalidPageSize (PageSizeTooLarge request.pageSize maxBoundedPageSize)))
  | otherwise = case R.paginate order request base decoder of
      Left failure -> pure (Left (InvalidPageCursor failure))
      Right statement -> Right <$> Tx.statement () statement

-- | Run a scalar read only if the context grants 'MemoryRead'.
gatedRead :: (Applicative f) => MemoryAccessContext -> f (Either ReadModelError a) -> f (Either BoundedReadError a)
gatedRead context run
  | not (memoryContextAllows MemoryRead context) = pure (Left (BoundedReadNotPermitted MemoryRead))
  | otherwise = first BoundedReadFailed <$> run

-- | Run a page read only if the context grants 'MemoryRead'.
gatedPage :: (Applicative f) => MemoryAccessContext -> f (Either ReadModelError (Either BoundedPageError a)) -> f (Either BoundedReadError a)
gatedPage context run = (>>= first BoundedReadInvalidPage) <$> gatedRead context run

-- | The context's memory space as a typed parameter.
contextSpaceSnippet :: MemoryAccessContext -> S.Snippet
contextSpaceSnippet = S.param . memorySpaceIdText . memoryContextSpace

-- | The namespace/scope predicate shared by the session and memory collections. The global
-- bucket is matched with @IS NULL@; an entity scope always names both its kind and ref.
recallTargetSnippet :: RecallTarget -> S.Snippet
recallTargetSnippet = \case
  NamespaceWide (Namespace ns) -> namespace ns
  ExactScope (ScopeGlobal (Namespace ns)) -> namespace ns <> " AND scope_kind IS NULL AND scope_ref IS NULL"
  ExactScope (ScopeEntity (Namespace ns) (ScopeKind kind) ref) -> namespace ns <> " AND scope_kind=" <> S.param kind <> " AND scope_ref=" <> S.param ref
  where
    namespace :: Text -> S.Snippet
    namespace ns = " AND namespace=" <> S.param ns
