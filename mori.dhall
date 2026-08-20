let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/e4899c15b6a7c36f5d6f2619c8a36ceabe58fc41/package.dhall
        sha256:f33943bf2a160e4dc2087e482a3e784d39e79ff58d5ec67c1f53bcee3389e323

let testDep =
      \(name : Text) ->
        Schema.Dependency.WithAugmentation
          { name
          , extraDocs = [] : List Schema.DocRef.Type
          , localPathOverride = None Text
          , kind = None Schema.DependencyKind
          , source = None Schema.DependencySource
          , scope = Some Schema.DependencyScope.Test
          , versionConstraint = None Text
          }

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
    , packages =
      [ Schema.Package::{
        , name = "kioku-api"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kioku-api"
        , description = Some "Reusable agent memory wire types"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson:aeson"
          , Schema.Dependency.ByName "ekmett/lens:lens"
          , Schema.Dependency.ByName "MMZK1526/mmzk-typeid:mmzk-typeid"
          , testDep "UnkindPartition/tasty:tasty"
          , testDep "UnkindPartition/tasty:tasty-hunit"
          ]
        }
      , Schema.Package::{
        , name = "kioku-core"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kioku-core"
        , description = Some "Reusable agent memory runtime"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson:aeson"
          , Schema.Dependency.ByName "shinzui/baikai:baikai"
          , Schema.Dependency.ByName "shinzui/baikai:baikai-claude"
          , Schema.Dependency.ByName "shinzui/baikai:baikai-effectful"
          , Schema.Dependency.ByName
              "nikita-volkov/contravariant-extras:contravariant-extras"
          , Schema.Dependency.ByName "kazu-yamamoto/crypton:crypton"
          , Schema.Dependency.ByName "effectful/effectful:effectful"
          , Schema.Dependency.ByName "effectful/effectful:effectful-core"
          , Schema.Dependency.ByName "ekmett/lens:lens"
          , Schema.Dependency.ByName "ekmett/lens:generic-lens"
          , Schema.Dependency.ByName "hasql/hasql:hasql"
          , Schema.Dependency.ByName "hasql/hasql:hasql-pool"
          , Schema.Dependency.ByName "hasql/hasql:hasql-transaction"
          , Schema.Dependency.ByName
              "iand675/hs-opentelemetry:hs-opentelemetry-api"
          , Schema.Dependency.ByName "shinzui/keiki:keiki"
          , Schema.Dependency.ByName "shinzui/keiro:keiro"
          , Schema.Dependency.ByName "shinzui/keiro:keiro-core"
          , Schema.Dependency.ByName "shinzui/kiroku:kiroku-store"
          , Schema.Dependency.ByName "shinzui/kiroku:shibuya-kiroku-adapter"
          , Schema.Dependency.ByName "MMZK1526/mmzk-typeid:mmzk-typeid"
          , Schema.Dependency.ByName "shinzui/shibuya:shibuya-core"
          , Schema.Dependency.ByName "shinzui/shikumi:shikumi"
          , Schema.Dependency.ByName "shinzui/shikumi:shikumi-trace"
          , Schema.Dependency.ByName "haskell-hvr/uuid:uuid"
          , testDep "UnkindPartition/tasty:tasty"
          , testDep "UnkindPartition/tasty:tasty-hunit"
          ]
        }
      , Schema.Package::{
        , name = "kioku-cli"
        , type = Schema.PackageType.Tool
        , language = Schema.Language.Haskell
        , path = Some "kioku-cli"
        , description = Some "kioku command-line interface"
        , dependencies =
          [ Schema.Dependency.ByName "effectful/effectful:effectful"
          , Schema.Dependency.ByName "shinzui/kiroku:kiroku-store"
          , Schema.Dependency.ByName
              "pcapriotti/optparse-applicative:optparse-applicative"
          , testDep "UnkindPartition/tasty:tasty"
          , testDep "UnkindPartition/tasty:tasty-hunit"
          ]
        }
      , Schema.Package::{
        , name = "kioku-migrations"
        , type = Schema.PackageType.Library
        , language = Schema.Language.Haskell
        , path = Some "kioku-migrations"
        , description = Some "Schema migrations for kioku"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson:aeson"
          , Schema.Dependency.ByName "shinzui/ephemeral-pg:ephemeral-pg"
          , Schema.Dependency.ByName "hasql/hasql:hasql"
          , Schema.Dependency.ByName "hasql/hasql:hasql-transaction"
          , Schema.Dependency.ByName "shinzui/keiro:keiro-migrations"
          , Schema.Dependency.ByName "shinzui/kiroku:kiroku-store-migrations"
          , Schema.Dependency.ByName "shinzui/pg-migrate:pg-migrate"
          , Schema.Dependency.ByName "shinzui/pg-migrate:pg-migrate-embed"
          , Schema.Dependency.ByName "shinzui/pg-migrate:pg-migrate-import-codd"
          , Schema.Dependency.ByName
              "shinzui/pg-migrate:pg-migrate-test-support"
          , testDep "UnkindPartition/tasty:tasty"
          , testDep "UnkindPartition/tasty:tasty-hunit"
          ]
        }
      , Schema.Package::{
        , name = "kioku-migrate"
        , type = Schema.PackageType.Tool
        , language = Schema.Language.Haskell
        , path = Some "kioku-migrate"
        , description = Some "The kioku schema migration entry point"
        , dependencies =
          [ Schema.Dependency.ByName "haskell/aeson:aeson"
          , Schema.Dependency.ByName "hasql/hasql:hasql"
          , Schema.Dependency.ByName "shinzui/kiroku:kiroku-store"
          , Schema.Dependency.ByName
              "pcapriotti/optparse-applicative:optparse-applicative"
          , Schema.Dependency.ByName "shinzui/pg-migrate:pg-migrate"
          , Schema.Dependency.ByName "shinzui/pg-migrate:pg-migrate-cli"
          , Schema.Dependency.ByName "shinzui/pg-migrate:pg-migrate-import-codd"
          ]
        }
      ]
    , dependencies =
      [ "MMZK1526/mmzk-typeid:mmzk-typeid"
      , "UnkindPartition/tasty:tasty"
      , "UnkindPartition/tasty:tasty-hunit"
      , "effectful/effectful:effectful"
      , "effectful/effectful:effectful-core"
      , "ekmett/lens:lens"
      , "ekmett/lens:generic-lens"
      , "haskell-hvr/uuid:uuid"
      , "haskell/aeson:aeson"
      , "hasql/hasql:hasql"
      , "hasql/hasql:hasql-pool"
      , "hasql/hasql:hasql-transaction"
      , "iand675/hs-opentelemetry:hs-opentelemetry-api"
      , "kazu-yamamoto/crypton:crypton"
      , "nikita-volkov/contravariant-extras:contravariant-extras"
      , "pcapriotti/optparse-applicative:optparse-applicative"
      , "shinzui/baikai:baikai"
      , "shinzui/baikai:baikai-claude"
      , "shinzui/baikai:baikai-effectful"
      , "shinzui/ephemeral-pg:ephemeral-pg"
      , "shinzui/keiki:keiki"
      , "shinzui/keiro:keiro"
      , "shinzui/keiro:keiro-core"
      , "shinzui/keiro:keiro-migrations"
      , "shinzui/kiroku:kiroku-store"
      , "shinzui/kiroku:kiroku-store-migrations"
      , "shinzui/kiroku:shibuya-kiroku-adapter"
      , "shinzui/pg-migrate:pg-migrate"
      , "shinzui/pg-migrate:pg-migrate-cli"
      , "shinzui/pg-migrate:pg-migrate-embed"
      , "shinzui/pg-migrate:pg-migrate-import-codd"
      , "shinzui/pg-migrate:pg-migrate-test-support"
      , "shinzui/shibuya:shibuya-core"
      , "shinzui/shikumi:shikumi"
      , "shinzui/shikumi:shikumi-trace"
      ]
    , dependencyRefs =
      [ Schema.MoriRef::{
        , namespace = "MMZK1526"
        , name = "mmzk-typeid"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "mmzk-typeid"
        }
      , Schema.MoriRef::{
        , namespace = "UnkindPartition"
        , name = "tasty"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "tasty"
        }
      , Schema.MoriRef::{
        , namespace = "UnkindPartition"
        , name = "tasty"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "tasty-hunit"
        }
      , Schema.MoriRef::{
        , namespace = "effectful"
        , name = "effectful"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "effectful"
        }
      , Schema.MoriRef::{
        , namespace = "effectful"
        , name = "effectful"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "effectful-core"
        }
      , Schema.MoriRef::{
        , namespace = "ekmett"
        , name = "lens"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "lens"
        }
      , Schema.MoriRef::{
        , namespace = "ekmett"
        , name = "lens"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "generic-lens"
        }
      , Schema.MoriRef::{
        , namespace = "haskell-hvr"
        , name = "uuid"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "uuid"
        }
      , Schema.MoriRef::{
        , namespace = "haskell"
        , name = "aeson"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "aeson"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql-pool"
        }
      , Schema.MoriRef::{
        , namespace = "hasql"
        , name = "hasql"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hasql-transaction"
        }
      , Schema.MoriRef::{
        , namespace = "iand675"
        , name = "hs-opentelemetry"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "hs-opentelemetry-api"
        }
      , Schema.MoriRef::{
        , namespace = "kazu-yamamoto"
        , name = "crypton"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "crypton"
        }
      , Schema.MoriRef::{
        , namespace = "nikita-volkov"
        , name = "contravariant-extras"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "contravariant-extras"
        }
      , Schema.MoriRef::{
        , namespace = "pcapriotti"
        , name = "optparse-applicative"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "optparse-applicative"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "baikai"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "baikai"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "baikai"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "baikai-claude"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "baikai"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "baikai-effectful"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "ephemeral-pg"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "ephemeral-pg"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiki"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiki"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiro"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiro"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiro"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiro-core"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "keiro"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "keiro-migrations"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kiroku"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "kiroku-store"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kiroku"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "kiroku-store-migrations"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "kiroku"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shibuya-kiroku-adapter"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate-cli"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate-embed"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate-import-codd"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "pg-migrate"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "pg-migrate-test-support"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shibuya"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shibuya-core"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shikumi"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shikumi"
        }
      , Schema.MoriRef::{
        , namespace = "shinzui"
        , name = "shikumi"
        , kind = Some Schema.MoriArtifactKind.Package
        , key = Some "shikumi-trace"
        }
      ]
    , okfBundles =
      [ Schema.OkfBundle::{
        , name = "improvement-requests"
        , path = "docs/improvement-requests"
        , profile = Some "docs/improvement-requests/profile.dhall"
        , okfVersion = "0.1"
        , description = Some "Kioku-owned improvement requests"
        }
      , Schema.OkfBundle::{
        , name = "bug-reports"
        , path = "docs/bug-reports"
        , profile = Some "docs/bug-reports/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "Defects in behavior Kioku already provides, one reproduction per report"
        }
      , Schema.OkfBundle::{
        , name = "reviews"
        , path = "docs/reviews"
        , profile = Some "docs/reviews/profile.dhall"
        , okfVersion = "0.2"
        , description = Some
            "Records of Kioku artifacts having been reviewed, one examination per record"
        }
      ]
    }
