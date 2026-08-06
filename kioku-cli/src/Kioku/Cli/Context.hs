-- | The memory space and principal the CLI acts as.
--
-- Kioku's core will not write anything without a 'MemoryAccessContext' — a record saying that
-- somebody already decided this caller may do this here. The CLI is a trusted in-process host
-- with no authentication boundary of its own, so it builds one through the deliberately
-- conspicuous 'assumeAuthorizedMemoryContext' rather than by consulting anything.
--
-- Two environment variables decide what it claims:
--
-- * @KIOKU_MEMORY_SPACE@ — which memory space the command reads and writes. It defaults to
--   'legacyMemorySpaceId' (@kioku_legacy@), which is where every row written before memory
--   spaces existed lives, so an unchanged CLI keeps operating on exactly the data it did before.
-- * @KIOKU_ACTOR@ — the principal writes are attributed to. It defaults to @kioku_cli@: the CLI
--   is genuinely the thing acting, and naming it plainly is better than borrowing an identity
--   from a directory the CLI does not talk to.
--
-- Both are validated, and a malformed value is a startup error rather than a silent fallback —
-- a typo in a memory space name must not quietly send writes somewhere else.
module Kioku.Cli.Context
  ( cliMemoryContext,
    cliMemoryActor,
    cliMemorySpace,
    cliContextProvider,
  )
where

import Data.Text (Text)
import Data.Text qualified as Text
import Kioku.Api.Access
  ( MemoryAccessContext,
    MemoryActor (..),
    MemoryContextProvider,
    MemorySpaceId,
    assumeAuthorizedContextProvider,
    assumeAuthorizedMemoryContext,
    legacyMemorySpaceId,
    mkMemorySpaceId,
    mkPrincipalRef,
  )
import System.Environment (lookupEnv)

-- | The context every CLI write runs under.
cliMemoryContext :: IO MemoryAccessContext
cliMemoryContext = assumeAuthorizedMemoryContext <$> cliMemorySpace <*> cliMemoryActor

-- | The provider a CLI-hosted background worker uses.
--
-- Unlike 'cliMemoryContext' this is not pinned to one space: a worker claims timers for whatever
-- space they were scheduled in, and refusing to serve them would strand the work. What the CLI
-- is asserting by using this is that a process holding its database credentials may act in any
-- space in that database — which is already true of anything with the connection string.
cliContextProvider :: (Applicative m) => IO (MemoryContextProvider m)
cliContextProvider = assumeAuthorizedContextProvider <$> cliMemoryActor

cliMemorySpace :: IO MemorySpaceId
cliMemorySpace =
  resolveEnv "KIOKU_MEMORY_SPACE" legacyMemorySpaceId mkMemorySpaceId

cliMemoryActor :: IO MemoryActor
cliMemoryActor =
  MemoryActor <$> resolveEnv "KIOKU_ACTOR" defaultActor mkPrincipalRef
  where
    defaultActor = either (error . Text.unpack) id (mkPrincipalRef "kioku_cli")

resolveEnv :: String -> a -> (Text -> Either Text a) -> IO a
resolveEnv name fallback parse = do
  raw <- lookupEnv name
  case raw of
    Nothing -> pure fallback
    Just value ->
      case parse (Text.pack value) of
        Right parsed -> pure parsed
        Left err -> ioError (userError (name <> ": " <> Text.unpack err))
