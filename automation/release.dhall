-- Turn an observed release tag into the one immutable Project release fact
-- mori keeps for shinzui/kioku.
--
-- The same shape shinzui/baikai, shinzui/shikumi and shinzui/keiro use. Kioku
-- sits at the end of the baikai -> shikumi -> kioku cohort cascade and is the
-- only hop that publishes nothing about itself; a release fact is what lets a
-- future consumer -- or `mori registry releases shinzui/kioku --with-dependents`
-- -- see that a version admitting the new cohort exists.
--
-- Registered as its own named automation (`--name release`) rather than folded
-- into the repo's root mori.automation.dhall, which carries the
-- `upgrade-baikai-cohort` reaction. The two want opposite execution policies
-- and a single automation must agree on every scalar: this one shells out per
-- observed tag and wants `queued = True`, while a cohort bump takes up to three
-- hours and must not hold a recording behind it.
--
-- Pinned to mori-schema 7904371, the commit that adds `RefSelector.refRegexes`.
-- This is the commit the current mori binary embeds (`mori schema pin`), so the
-- import resolves without touching the network. The repo's root
-- mori.automation.dhall still pins the older 026ae74; the two files are
-- separate automations and need not agree.
let Schema =
      https://raw.githubusercontent.com/shinzui/mori-schema/7904371c3ee1f592b427167e213cb1baa835de2c/package.dhall
        sha256:4b3730d985a19575278e3f155d98d5a60992e5f51b4f9223d390ef13e513e3c4

in  Schema.Automation::{
    , events =
      [ Schema.EventSelector.RefSelector Schema.RefSelector::{
        , name = "kioku-release-tag"
        ,
          -- Kioku cuts ONE tag per release -- `v0.5.2.0` covers all five
          -- packages, which share a version -- so unlike baikai and shikumi
          -- there is no umbrella tag to pick out of a set of siblings. A
          -- whole-input POSIX extended regex is still preferred over the
          -- `refPatterns = [ "v*" ]` glob it could have been: globs understand
          -- `*` and `**` and nothing else, so `v*` would also fire on a future
          -- `vendor-...` or `v2-experiment` tag and record a version that is
          -- not one. `[.]` for the literal dot: a Dhall double-quoted string
          -- would otherwise need the backslash doubled.
          refRegexes = [ "v[0-9]+([.][0-9]+)*" ]
        , kinds = [ "tag" ]
        }
      ]
    , reactions =
      [ Schema.Reaction::{
        , name = "record-kioku-release"
        , on = [ "kioku-release-tag" ]
        , actions =
          [ Schema.ReactionAction.RunCommand Schema.RunCommandAction::{
            , command = "./scripts/record-release.sh"
            , args = [ "{{ref.name}}" ]
            ,
              -- Not the 600-second default, which would hold the FIFO group for
              -- ten minutes on a hung database -- but not 60 seconds either.
              -- Every RunCommand is executed as `nix develop --command`, and
              -- that entry, not the single `mori registry release record`
              -- against a local Postgres, dominates: 60s timed out reactions in
              -- shinzui/keiro and shinzui/baikai while the nix eval cache was
              -- cold and contended, which is how a release fact there went
              -- unrecorded.
              timeout = Some +300
            }
          ]
        }
      ]
    ,
      -- A release cut triggers this once, so there is nothing to serialize in
      -- the ordinary case. It is kept for the replay case:
      -- `mori automate reset-checkpoint --to-root` re-observes every `v*` tag in
      -- the repo's history at once, and serializing keeps those invocations from
      -- racing each other into the same Project stream. Re-recording a version
      -- is already safe -- the first committed release time and source win -- so
      -- this is about avoiding contention, not correctness.
      queued = True
    , execution = Schema.ExecutionPolicy::{ allowLocal = True }
    }
