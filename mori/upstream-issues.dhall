let UpstreamIssues =
      https://raw.githubusercontent.com/shinzui/mori-schema/b85081a0e935a976202fd7a1227f8b93e2cbeb23/extensions/upstream-issues/package.dhall
        sha256:50f8b061a1bd999aac83e3f0ed69cd5a829d2bcf101f556a733f52ed9671e064

in  UpstreamIssues.UpstreamIssuesCatalog::{
    , entries =
      [ UpstreamIssues.UpstreamIssue::{
        , key = "mmzk-typeid-kindid-ghc-9-12-4-profiling-coercionkind-panic"
        , dependency = "mmzk-typeid"
        , summary =
            "Compiling any module that uses a KindID-typed identifier with GHC 9.12.4 and -prof crashes the compiler: \"panic! (the 'impossible' happened) / coercionKind / ConsSymbolDef\". The defect is in GHC's coercion optimiser, but KindID's type-level prefix validation is the only thing in this dependency chain that emits ConsSymbol axioms, so in practice the panic tracks use of this package"
        , status = UpstreamIssues.IssueStatus.Workaround
        , revisitTrigger = Some
            "Drop the ghc-prof-options lines from kioku-core/kioku-core.cabal and kioku-cli/kioku-cli.cabal and delete this entry once a GHC release fixes the coercion optimiser; retest with `cabal build all --enable-profiling`, which reproduces the panic in one shot. Full mechanism and the trigger sites inside the dependency are written up once, upstream, at mori://MMZK1526/mmzk-typeid/upstream-issues/mmzk-typeid-kindid-ghc-9-12-4-profiling-coercionkind-panic -- keep the summary above in sync with that entry. Kioku-local shape: two packages are hit, and only one of them mentions mmzk-typeid. kioku-core fails at Kioku.Distill.L1, which imports Data.KindID.V7 directly (kioku-core/src/Kioku/Distill/L1.hs:23,605). kioku-cli fails at Kioku.Cli.Commands.DemoSession, which never names mmzk-typeid at all and inherits the ConsSymbol axioms transitively through kioku-core's KindID-typed identifiers -- so a future package that merely consumes kioku-core's API can start panicking under profiling with no local change, and the fix is to add the same line to that package's library stanza. The workaround is `ghc-prof-options: -fno-opt-coercion`, deliberately NOT `ghc-options`, so ordinary non-profiled builds keep the coercion optimiser; both were verified to build. Do not attempt to narrow it to a -fprof-auto tweak: `profiling-detail: none` and `profiling-detail: late-toplevel` were both tested here and both still panic, so cost-centre insertion is not the trigger and this is not GHC issue 26056 (https://gitlab.haskell.org/ghc/ghc/-/issues/26056). Unrelated but discovered in the same investigation and needed before any clean profiling build can even start: nix/haskell.nix must carry pkgs.openssl.dev, because libpq.pc declares `Requires.private: libssl libcrypto` and postgresql.dev does not propagate openssl; a plain `cabal build` hides that failure whenever postgresql-libpq-pkgconfig is already in the cabal store"
        , workaroundPath = Some "kioku-core/kioku-core.cabal"
        , upstreamUrl = Some "https://gitlab.haskell.org/ghc/ghc"
        , tags =
          [ "kindid"
          , "type-level-symbol"
          , "ghc-9.12.4"
          , "profiling"
          , "compiler-panic"
          , "coercion-optimiser"
          , "no-upstream-ticket"
          ]
        }
      ]
    }
