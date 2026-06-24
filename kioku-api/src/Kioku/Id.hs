{-# LANGUAGE UndecidableInstances #-}

module Kioku.Id
  ( MemoryId,
    SessionId,
    genMemoryId,
    genSessionId,
    idText,
    parseId,
    parseIdAnyPrefix,
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

parseIdAnyPrefix ::
  forall prefix.
  (ToPrefix prefix, ValidPrefix (PrefixSymbol prefix)) =>
  Text ->
  Either Text (KindID prefix)
parseIdAnyPrefix t =
  case TypeID.parseText t of
    Left err -> Left (Text.pack (show err))
    Right tid -> Right (KindID.decorateKindID (TypeID.getUUID tid))
