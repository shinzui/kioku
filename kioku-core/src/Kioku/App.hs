{-# LANGUAGE DataKinds #-}

module Kioku.App
  ( AppEffects,
    AppEnv (..),
    KeiroMetrics,
    runAppIO,
    withNoopAppEnv,
    noopTracer,
  )
where

import Effectful (Eff, IOE, runEff)
import Effectful.Error.Static (Error, runErrorNoCallStack)
import Keiro.Telemetry (KeiroMetrics)
import Kioku.Prelude
import Kioku.ReadModel (registerKiokuReadModels)
import Kiroku.Store.Connection (ConnectionSettings)
import Kiroku.Store.Effect (Store, runStoreResource)
import Kiroku.Store.Effect.Resource (KirokuStoreResource, withKirokuStore)
import Kiroku.Store.Error (StoreError)
import OpenTelemetry.Attributes qualified as Attr
import OpenTelemetry.Trace.Core qualified as OTel
import Shibuya.Telemetry.Effect (Tracer, Tracing, runTracing)

type AppEffects = '[Store, KirokuStoreResource, Error StoreError, Tracing, IOE]

data AppEnv = AppEnv
  { connectionSettings :: !ConnectionSettings,
    tracer :: !Tracer,
    metrics :: !(Maybe KeiroMetrics)
  }
  deriving stock (Generic)

runAppIO :: AppEnv -> Eff AppEffects a -> IO (Either StoreError a)
runAppIO env =
  runEff
    . runTracing (tracer env)
    . runErrorNoCallStack
    . withKirokuStore (connectionSettings env)
    . runStoreResource

withNoopAppEnv :: ConnectionSettings -> (AppEnv -> IO a) -> IO a
withNoopAppEnv connectionSettings continue = do
  tracer <- noopTracer
  let env = AppEnv {connectionSettings, tracer, metrics = Nothing}
  registration <- runAppIO env registerKiokuReadModels
  case registration of
    Left err -> fail ("Kioku read-model registration failed: " <> show err)
    Right () -> continue env

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
