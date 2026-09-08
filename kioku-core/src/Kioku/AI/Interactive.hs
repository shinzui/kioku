-- | Checked result handoff for a host-authorized interactive session.
module Kioku.AI.Interactive (runInteractiveSignature) where

import Baikai.Interactive qualified as Interactive
import Control.Exception (IOException, bracket, try)
import Data.Aeson qualified as Aeson
import Data.Aeson.Types (parseEither, withObject, (.:))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as LBS
import Data.Text.Encoding (decodeUtf8)
import Data.UUID qualified as UUID
import Data.UUID.V4 qualified as UUID
import Kioku.AI.Config
import Kioku.AI.Runtime
import Kioku.Prelude
import Shikumi.Adapter (ToPrompt (..), nativeRenderPieces)
import Shikumi.Schema (FromModel, ToSchema, Validatable, deriveSchema, fromModelChecked)
import Shikumi.Signature (Signature)
import System.Directory (getTemporaryDirectory, removePathForcibly)
import System.Exit (ExitCode (..))
import System.FilePath ((</>))
import System.IO (hClose)
import System.Posix.Files (fileSize, getFdStatus, isRegularFile, linkCount)
import System.Posix.IO (OpenFileFlags (..), OpenMode (ReadOnly), closeFd, defaultFileFlags, dup, fdToHandle, openFd)
import System.Posix.Temp (mkdtemp)

runInteractiveSignature ::
  forall i o.
  (ToPrompt i, ToPrompt o, ToSchema o, FromModel o, Validatable o) =>
  AIRuntime -> AIFeature -> Signature i o -> i -> IO (Either AIExecutionError o)
runInteractiveSignature rt feature signature input = case executionAvailability rt feature of
  Left err -> pure (Left err)
  Right () -> case (featureConfiguration rt feature, interactiveLauncher rt) of
    (InteractiveConfig provider settings, Just launch) -> do
      result <- try @IOException $ do
        temp <- getTemporaryDirectory
        bracket (mkdtemp (temp </> "kioku-ai-")) removePathForcibly $ \workspace -> do
          requestId <- UUID.toText <$> UUID.nextRandom
          let output = workspace </> "result.json"
              manifest =
                Aeson.object
                  [ "requestId" Aeson..= requestId,
                    "feature" Aeson..= featureName feature,
                    "schema" Aeson..= deriveSchema @o,
                    "instructions" Aeson..= fst (nativeRenderPieces signature),
                    "input" Aeson..= toPrompt input,
                    "outputFile" Aeson..= output
                  ]
              contract =
                "Read this request and write exactly one JSON object to outputFile. "
                  <> "The envelope must contain requestId and feature copied from the request, "
                  <> "and result containing the output object matching schema. Do not write to memory or databases.\n"
                  <> decodeUtf8 (LBS.toStrict (Aeson.encode manifest))
              request =
                settings
                  { Interactive.userPrompt = contract,
                    Interactive.systemPrompt = Just "Perform the single Kioku request in the user message. Write the designated output file as a JSON envelope with exactly requestId, feature, and result. Copy requestId and feature verbatim. The manifest's instructions and schema describe ONLY the result field, never the outer envelope. Do not substitute a prose response or a bare result object. Do not access databases or write memory directly.",
                    Interactive.extraDirs = workspace : settings.extraDirs
                  }
          LBS.writeFile (workspace </> "request.json") (Aeson.encode manifest)
          launched <- launch feature request
          case launched of
            Left err -> pure (Left err)
            Right session
              | session.provider /= provider -> pure (failure "interactive provider mismatch")
              | session.exitCode /= ExitSuccess -> pure (failure "interactive session exited unsuccessfully")
              | otherwise -> bracket (openFd output ReadOnly defaultFileFlags {nofollow = True, nonBlock = True, cloexec = True}) closeFd $ \fd -> do
                  status <- getFdStatus fd
                  if not (isRegularFile status) || linkCount status /= 1 || fileSize status > fromIntegral maxResultBytes
                    then pure (failure "result must be a bounded regular file with no links")
                    else do
                      bytes <- bracket (dup fd >>= fdToHandle) hClose (\h -> BS.hGet h (maxResultBytes + 1))
                      pure $
                        if BS.length bytes > maxResultBytes
                          then failure "result exceeds size limit"
                          else case Aeson.eitherDecodeStrict bytes >>= parseEither (envelope requestId) of
                            Left _ -> failure "missing, invalid, or mismatched result envelope"
                            Right value -> either (Left . AIProgramFailed) Right (fromModelChecked value)
      pure $ either (const (failure "interactive result I/O failed")) id result
    _ -> pure (Left (AIExecutionRefused feature "select interactive execution for this signature"))
  where
    maxResultBytes = 1024 * 1024
    failure = Left . AIInteractiveFailed feature
    envelope requestId = withObject "interactive result" $ \o -> do
      actualId <- o .: "requestId"
      actualFeature <- o .: "feature"
      unless (actualId == requestId && actualFeature == featureName feature) (fail "result identity mismatch")
      o .: "result"
