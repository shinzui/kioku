{-# LANGUAGE UndecidableInstances #-}

module Kioku.Id
  ( MemoryId,
    SessionId,
    genMemoryId,
    genSessionId,
    idText,
    parseId,
    parseIdLenient,
  )
where

import Data.KindID.Class (ToPrefix (..), ValidPrefix)
import Data.KindID.V7 (KindID)
import Data.KindID.V7 qualified as KindID
import Data.Text qualified as Text
import Data.TypeID.V7 qualified as TypeID
import Kioku.Prelude

type MemoryId = KindID "kioku_memory"

type SessionId = KindID "kioku_session"

genMemoryId :: (MonadIO m) => m MemoryId
genMemoryId = KindID.genKindID @"kioku_memory"

genSessionId :: (MonadIO m) => m SessionId
genSessionId = KindID.genKindID @"kioku_session"

idText :: (ToPrefix prefix, ValidPrefix (PrefixSymbol prefix)) => KindID prefix -> Text
idText = Text.pack . KindID.toString

parseId ::
  forall prefix.
  (ToPrefix prefix, ValidPrefix (PrefixSymbol prefix)) =>
  Text ->
  Either Text (KindID prefix)
parseId t =
  case KindID.parseString @prefix (Text.unpack t) of
    Left err -> Left (Text.pack (show err))
    Right kid -> Right kid

-- | Lenient TypeID parsing: accepts /any/ prefix (or none), discards it, and rebrands the
-- UUID into the target 'KindID' type.
--
-- This is deliberate in exactly three places, all of which trust the UUID but cannot trust the
-- prefix: decoding legacy Rei event streams (whose ids carry @agent_memory_*@ \/
-- @agent_session_*@ prefixes), parsing memory ids echoed back by an LLM during distillation,
-- and parsing timer correlation ids.
--
-- Never use it to parse operator input. It will happily accept a @kioku_memory@ id where a
-- 'SessionId' is expected and hand back a session id pointing at a session that does not
-- exist. Use the strict 'parseId', which rejects a wrong prefix and names both prefixes in the
-- error.
parseIdLenient ::
  forall prefix.
  (ToPrefix prefix, ValidPrefix (PrefixSymbol prefix)) =>
  Text ->
  Either Text (KindID prefix)
parseIdLenient t =
  case TypeID.parseText t of
    Left err -> Left (Text.pack (show err))
    Right tid -> Right (KindID.decorateKindID (TypeID.getUUID tid))
