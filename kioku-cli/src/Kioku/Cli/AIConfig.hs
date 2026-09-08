-- | CLI assembly delegates to the same versioned file boundary as embedded hosts.
module Kioku.Cli.AIConfig (aiConfigOption, loadAIRuntime, parseAIConfig) where

import Kioku.AI.File (loadAIRuntime, parseAIConfig)
import Options.Applicative qualified as Opt

aiConfigOption :: Opt.Parser (Maybe FilePath)
aiConfigOption = Opt.optional (Opt.strOption (Opt.long "ai-config" <> Opt.metavar "FILE" <> Opt.help "Explicit AI configuration (otherwise KIOKU_AI_CONFIG; absent means disabled)"))
