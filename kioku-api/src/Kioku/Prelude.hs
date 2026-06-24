{-# LANGUAGE PackageImports #-}

-- | The project-wide prelude. Do not re-export Data.Generics.Labels here:
-- generic-lens #label syntax collides with the keiki builder DSL.
module Kioku.Prelude
  ( module X,
    module Control.Lens,
    eventAesonOptions,
  )
where

import "aeson" Data.Aeson as X
  ( FromJSON,
    Options (..),
    SumEncoding (..),
    ToJSON,
    camelTo2,
    defaultOptions,
    fromJSON,
    genericParseJSON,
    genericToEncoding,
    genericToJSON,
    parseJSON,
    toEncoding,
    toJSON,
  )
import "base" Control.Applicative as X ((<|>))
import "base" Control.Monad as X (forM, forM_, guard, unless, void, when)
import "base" Control.Monad.IO.Class as X (MonadIO, liftIO)
import "base" Data.List.NonEmpty as X (NonEmpty (..))
import "base" Data.Maybe as X (fromMaybe, isJust, isNothing, mapMaybe)
import "base" Data.Proxy as X (Proxy (..))
import "base" GHC.Generics as X (Generic)
import "lens" Control.Lens
import "text" Data.Text as X (Text)
import "time" Data.Time as X (UTCTime, getCurrentTime)

-- | Standard event and command JSON options. Encodes sums as
-- {"type": "snake_case_tag", "data": {...}}.
eventAesonOptions :: Options
eventAesonOptions =
  defaultOptions
    { sumEncoding = TaggedObject "type" "data",
      constructorTagModifier = camelTo2 '_',
      tagSingleConstructors = True
    }
