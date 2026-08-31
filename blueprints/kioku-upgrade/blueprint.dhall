let S =
      https://raw.githubusercontent.com/shinzui/seihou-schema/49ff1e5b353b171b1b52946f478623ee4423ea93/package.dhall
        sha256:cadacb688dd31ec39feb7f2fe599973a1ad58ef8fcc8ed1100bf3da22a1222cb

in  S.Blueprint::{
    , name = "kioku-upgrade"
    , version = Some "0.1.0"
    , description = Some
        "Upgrade guidance for projects consuming Kioku, the agent memory runtime. One edge per released version window that needs judgement work, with the Keiro cohort edge entailed so a project that depends only on Kioku still crosses it exactly once."
    , prompt = ./prompt.md as Text
    , versionProbe = Some
        "jq -r '.\"install-plan\"[] | select(.\"pkg-name\"|startswith(\"kioku-\")) | .\"pkg-version\"' dist-newstyle/cache/plan.json 2>/dev/null | sort -u | tail -1 | grep ."
    , allowedTools = Some [ "Bash(cabal *)", "Bash(just *)", "Bash(rg *)" ]
    , files =
      [ S.Blueprint.BlueprintFile::{
        , src = "kioku-cohort-versions.md"
        , description = Some
            "Which upstream cohort each Kioku release pairs with, how to read what this project actually resolved, the composed migration plan's shape per release, and which ledger fixups a release requires."
        }
      ]
    , migrations =
      [ S.BlueprintMigration::{
        , from = "0.4.1.0"
        , to = "0.5.0.0"
        , prompt = ./migrations/0-4-1-0-to-0-5-0-0.md as Text
        , entails =
          [ S.EntailedEdge::{
            , blueprint = "keiro-upgrade"
            , from = "0.13.0.0"
            , to = "0.14.0.0"
            }
          ]
        }
      , S.BlueprintMigration::{
        , from = "0.5.1.0"
        , to = "0.5.2.0"
        , prompt = ./migrations/0-5-1-0-to-0-5-2-0.md as Text
        , entails =
          [ S.EntailedEdge::{
            , blueprint = "keiro-upgrade"
            , from = "0.14.0.0"
            , to = "0.15.0.0"
            }
          ]
        }
      ]
    , tags =
      [ "haskell"
      , "postgresql"
      , "event-sourcing"
      , "agent-memory"
      , "kioku"
      , "keiro"
      , "migration"
      ]
    }
