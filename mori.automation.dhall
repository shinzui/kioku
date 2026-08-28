let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/026ae74331e5c516542af1dd96f041c658ed4621/package.dhall
        sha256:18258ef583580a897f4af3e7c86db0342afb42fb40efc535b217ba1089230141

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.SignalSelector Schema.SignalSelector::{
        , name = "baikai-released"
        , signalTypes = [ "BaikaiReleased" ]
        , sourceProjects = [ "shinzui/baikai" ]
        }
      , Schema.EventSelector.SignalSelector Schema.SignalSelector::{
        , name = "shikumi-released"
        ,
          -- The second leg of the baikai -> shikumi -> kioku cascade, and the
          -- one that closes it. `scripts/baikai-cohort.sh` already lists
          -- shikumi and shikumi-trace as cohort members, because only their
          -- newest patches carry bounds admitting a new baikai -- so the
          -- upgrade this repo runs has always been waiting on shikumi, while
          -- nothing woke it when shikumi moved.
          --
          -- That gap is observable: on 2026-08-28 baikai 0.6.0.0 woke this
          -- reaction, the solver found no install plan because shikumi still
          -- pinned baikai-effectful <0.4, and the run backed out cleanly. It
          -- was then never re-triggered, because a skip is terminal until the
          -- next signal. With this leg, shikumi's own release is that signal.
          signalTypes = [ "ShikumiReleased" ]
        , sourceProjects = [ "shinzui/shikumi" ]
        }
      ]
    , reactions =
      [ Schema.Reaction::{
        , name = "upgrade-baikai-cohort"
        , on = [ "baikai-released", "shikumi-released" ]
        , actions =
          [ Schema.ReactionAction.RunCommand Schema.RunCommandAction::{
            , command = "just"
            , args = [ "upgrade-baikai" ]
            ,
              -- A cold cohort bump rebuilds baikai, shikumi, and their
              -- dependencies before Kioku's own four suites even start.
              timeout = Some +10800
            ,
              -- No env, and deliberately no {{meta.*}} templates. Mori's
              -- `buildContext` covers ChangesetObserved, RefObserved, and
              -- WorkflowSignalReceived; a signal-triggered reaction like this
              -- one is triggered by SignalDeliverySucceeded, which falls through
              -- to the empty context, so a {{meta.tag}} here would reach the
              -- command as the literal seven characters rather than a tag. The
              -- sibling keiro-syntax automation does exactly that and has failed
              -- on every run since it was written. Nothing is lost: the signal is
              -- only a wake-up, and the script re-derives what to do from
              -- Hackage, which is the only source that can answer it correctly
              -- twelve hours after the tag anyway.
              env = [] : List { mapKey : Text, mapValue : Text }
            }
          ]
        , schedule = Some Schema.Schedule::{
          ,
            -- A baikai release and the shikumi/shikumi-trace patches that widen
            -- their bounds to admit it are separate uploads by the same person.
            -- Observed practice is same-day -- baikai 0.5.0.0 and shikumi 0.3.0.2
            -- are both dated 2026-08-05 -- so wait the working day out rather
            -- than waking into a cohort that cannot yet be solved.
            --
            -- The wait is now a convenience rather than the only safety net. A
            -- run that still finds no install plan backs out cleanly, and the
            -- shikumi-released leg re-arms this reaction when the rest of the
            -- cohort actually publishes; before that leg existed, a skip here
            -- was terminal until the next baikai release.
            after = Some "PT12H"
          ,
            -- One baikai release pushes a tag per package, so this reaction is
            -- triggered several times within seconds. Debounce them into the
            -- single run that the last tag schedules.
            coalesceKey = Some "baikai-cohort-bump"
          , idempotencyCheck = Some Schema.IdempotencyCheck::{
            , command = "./scripts/baikai-bump-needed.sh"
            ,
              -- Asked twelve hours after the tag, not at trigger time: by then
              -- the cohort may be complete, already bumped by hand, or the tree
              -- may be mid-work. Non-zero means skip, and skipping is the
              -- ordinary outcome rather than a fault.
              skipOnExit = Schema.SkipOnExit.NonZero
            , timeout = Some +120
            }
          }
        }
      ]
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
