{-# LANGUAGE DataKinds #-}

module Kioku.App
  ( AppEffects,
    AppEnv (..),
    KeiroMetrics,
    runAppIO,
    noopTracer,
  )
where

import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Keiro.Telemetry (KeiroMetrics)
import Kioku.Prelude
import Kiroku.Store.Connection (KirokuStore)
import Kiroku.Store.Effect (Store, runStorePool)
import Kiroku.Store.Error (StoreError)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Trace.Core qualified as OTel
import Shibuya.Telemetry.Effect (Tracer, Tracing, runTracing)

type AppEffects = '[Store, Error StoreError, Tracing, IOE]

data AppEnv = AppEnv
  { store :: !KirokuStore,
    tracer :: !Tracer,
    metrics :: !(Maybe KeiroMetrics)
  }
  deriving stock (Generic)

runAppIO :: AppEnv -> Eff AppEffects a -> IO (Either StoreError a)
runAppIO env =
  runEff
    . runTracing (tracer env)
    . runErrorNoCallStack
    . runStorePool (store env)

noopTracer :: IO Tracer
noopTracer = do
  provider <- OTel.createTracerProvider [] OTel.emptyTracerProviderOptions
  pure (OTel.makeTracer provider instrumentationLib OTel.tracerOptions)
  where
    instrumentationLib =
      OTel.InstrumentationLibrary
        { OTel.libraryName = "kioku-noop",
          OTel.libraryVersion = "",
          OTel.librarySchemaUrl = "",
          OTel.libraryAttributes = Attr.emptyAttributes
        }
