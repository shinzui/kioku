{ repoName = "kioku"
, repoDescription = Some "Reusable agent memory and session library for Haskell"
, modules =
  [] : List
       { name : Text
       , version : Optional Text
       , path : Text
       , description : Optional Text
       , tags : List Text
       }
, recipes =
  [] : List
       { name : Text
       , version : Optional Text
       , path : Text
       , description : Optional Text
       , tags : List Text
       }
, blueprints =
  [ { name = "kioku-upgrade"
    , version = Some "0.7.1"
    , path = "blueprints/kioku-upgrade"
    , description = Some
        "Ordered upgrade guidance for Kioku consumers, including the Keiro 0.24 and Kiroku Store 0.13 cohort and database cutover runbook"
    , tags =
      [ "haskell", "postgresql", "event-sourcing", "agent-memory", "kioku", "migration" ]
    }
  ]
, prompts =
  [] : List
       { name : Text
       , version : Optional Text
       , path : Text
       , description : Optional Text
       , tags : List Text
       }
}
