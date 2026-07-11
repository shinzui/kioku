-- | Shared option readers and helpers for the kioku CLI.
module Kioku.Cli.Options
  ( boundedIntReader,
  )
where

import Options.Applicative

-- | An integer option reader that enforces an inclusive range at parse time.
--
-- @label@ names the value in the error message, e.g. @\"LIMIT\"@. Without this, @--limit -1@
-- travelled all the way to Postgres and came back as @LIMIT must not be negative@, and an
-- unbounded large value was a cost and latency footgun rather than a parse error.
boundedIntReader :: String -> Int -> Int -> ReadM Int
boundedIntReader label lo hi = do
  n <- auto
  if n >= lo && n <= hi
    then pure n
    else
      readerError
        (label <> " must be between " <> show lo <> " and " <> show hi <> " (got " <> show n <> ")")
