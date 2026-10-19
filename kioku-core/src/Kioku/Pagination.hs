-- | SQL-bounded core reads using the shared Relay keyset implementation.
-- Hosts exposing these cursors over an API bind their collection/filter context
-- around the public Relay cursor; this module never forks that codec.
module Kioku.Pagination (BoundedPageError (..), boundedPage, Connection, PageRequest (..)) where

import Hasql.Decoders qualified as D
import Hasql.DynamicStatements.Snippet qualified as S
import Hasql.Transaction qualified as Tx
import Relay.Pagination (Connection, CursorError, PageRequest (..), PageRequestError (..))
import Relay.Pagination.Hasql qualified as R

data BoundedPageError = InvalidPageSize !PageRequestError | InvalidPageCursor !CursorError
  deriving stock (Eq, Show)

boundedPage :: R.SortSpec row -> D.Row row -> S.Snippet -> PageRequest -> Tx.Transaction (Either BoundedPageError (Connection row))
boundedPage order decoder base request
  | request.pageSize < 0 = pure (Left (InvalidPageSize (NegativePageSize request.pageSize)))
  | request.pageSize > 100 = pure (Left (InvalidPageSize (PageSizeTooLarge request.pageSize 100)))
  | otherwise = case R.paginate order request base decoder of
      Left failure -> pure (Left (InvalidPageCursor failure))
      Right statement -> Right <$> Tx.statement () statement
