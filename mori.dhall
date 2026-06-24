let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/026ae74331e5c516542af1dd96f041c658ed4621/package.dhall
        sha256:18258ef583580a897f4af3e7c86db0342afb42fb40efc535b217ba1089230141

in  Schema.Project::{
    , project = Schema.ProjectIdentity::{
      , name = "kioku"
      , namespace = "shinzui"
      , type = Schema.PackageType.Library
      , language = Schema.Language.Haskell
      , lifecycle = Schema.Lifecycle.Experimental
      , description = Some "Reusable agent memory and session library"
      , domains = [ "AgentMemory", "EventSourcing" ]
      , owners = [ "shinzui" ]
      }
    , repos = [ Schema.Repo::{ name = "kioku", github = Some "shinzui/kioku" } ]
    , dependencies =
      [ "shinzui/kiroku"
      , "shinzui/keiro"
      , "shinzui/keiki"
      , "shinzui/shibuya"
      , "shinzui/pgmq-hs"
      ]
    }
