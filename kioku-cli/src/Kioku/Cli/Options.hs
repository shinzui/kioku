-- | Shared option readers and helpers for the kioku CLI.
module Kioku.Cli.Options
  ( boundedIntReader,
    yesWriteEventsFlag,
    redactConnectionString,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
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

-- | Required opt-in for a command that appends permanent events.
--
-- 'flag'' with no default, so omitting it is a parse error (@Missing: --yes-write-events@) and
-- the requirement is visible in @--help@. Deliberately not an environment variable: an
-- exported @KIOKU_ALLOW_DEMO=1@ is sticky state that outlives the moment of consent, which is
-- exactly how accidents happen in a long-lived shell.
yesWriteEventsFlag :: Parser ()
yesWriteEventsFlag =
  flag'
    ()
    ( long "yes-write-events"
        <> help
          "Required confirmation: this command appends PERMANENT events (kioku has no delete) to the database at PG_CONNECTION_STRING"
    )

-- | Best-effort password redaction for printing a libpq connection string.
--
-- Handles the keyword form (@password=...@) and the URI form (@user:pass\@host@). Best-effort
-- is the honest description: it exists so the preflight can show the operator which database
-- they are about to write to without echoing a secret into a terminal or a CI log.
redactConnectionString :: Text -> Text
redactConnectionString conn =
  case Text.stripPrefix "postgres://" conn of
    Just rest -> "postgres://" <> redactUserInfo rest
    Nothing ->
      case Text.stripPrefix "postgresql://" conn of
        Just rest -> "postgresql://" <> redactUserInfo rest
        Nothing -> Text.unwords (map redactPair (Text.words conn))
  where
    redactPair kv
      | "password=" `Text.isPrefixOf` kv = "password=REDACTED"
      | otherwise = kv

    redactUserInfo rest =
      case Text.breakOn "@" rest of
        (_, "") -> rest
        (userinfo, hostPart) ->
          case Text.breakOn ":" userinfo of
            (_, "") -> userinfo <> hostPart
            (user, _) -> user <> ":REDACTED" <> hostPart
