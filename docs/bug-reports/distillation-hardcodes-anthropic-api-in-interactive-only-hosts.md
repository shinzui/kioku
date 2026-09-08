---
type: Bug Report
title: Distillation hardcodes the Anthropic API in interactive-only hosts
description: >-
  Kioku's former default distillation runtime unconditionally selected the Anthropic API,
  bypassing the embedding host's interactive-only policy and repeatedly failing without an API key.
generated:
  by: process:codex
  at: "2026-09-08T14:25:26Z"
bugId: BUG-2
status: fixed
severity: unusable
origin: mori://shinzui/rei
affects: mori://shinzui/kioku/packages/kioku-core
affectedVersion: unknown
fixedVersion: unreleased
resolution: >-
  Fixed in source by explicit host-owned Baikai feature configuration, disabled defaults,
  checked interactive results, and durable deferred-work recovery through released Keiro
  0.16.0.0 APIs. Kioku and Rei regression evidence verifies background deferral and authorized
  foreground completion without implicit API or batch fallback. The reporting host source
  is updated; package release and deployed-worker adoption have not been performed.
environment: >-
  Global Rei launchd worker on macOS, observed 2026-09-07 PDT. The operator requires
  interactive execution only and intentionally supplies no ANTHROPIC_API_KEY.
observed: >-
  Rei's Kioku distillation timers invoke newDistillRuntime, which registers ClaudeApi
  and selects anthropic_claude_haiku_4_5. L1 extraction and L2 scene generation fail
  with ProviderFailure reporting that ANTHROPIC_API_KEY is not set, then retry repeatedly.
expected: >-
  Under the reporting operator's explicit interactive-only policy, embedded distillation
  must use the host-authorized interactive execution path and must not implicitly select
  an API transport or require API credentials. This expectation is an integration requirement,
  not a claim that Kioku's current documentation promises interactive distillation.
reproduction:
  - Run an embedding host with Kioku distillation timers enabled and an interactive-only execution policy; leave ANTHROPIC_API_KEY unset.
  - Use the default newDistillRuntime constructor, as Rei's timer dispatcher does.
  - Make an eligible L1 extraction or L2 scene timer due and allow the host worker to dispatch it.
  - Observe the missing ANTHROPIC_API_KEY ProviderFailure and repeated timer retries instead of interactive execution.
reviews:
  - kind: model
    reviewer: codex
    reviewed_at: "2026-09-08T14:25:26Z"
    document_timestamp: "2026-09-08T14:25:26Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: unspecified
    effort: unspecified
    context: >-
      Implementation-author review against Kioku commits 4da73b0 and 6862915,
      released Keiro 0.16 APIs and tags, actual core/CLI/migration logs, and the
      corrected 40-test Rei host run. Verified that fixedVersion is unreleased,
      the earlier malformed host fixture is not used as acceptance evidence,
      and no live deployment or production timer replay is claimed.

---

# Distillation hardcodes the Anthropic API in interactive-only hosts

## Evidence and cause

In [Runtime.hs](../../kioku-core/src/Kioku/Distill/Runtime.hs), `newDistillRuntime`
previously unconditionally called `ClaudeApi.register`, builds `defaultLLMConfig globalProviderRegistry`,
and selects `Models.anthropic_claude_haiku_4_5`. It accepts no host provider or transport policy.
The same runtime supplies extraction, consolidation, scene generation, and persona generation.

The consumer is `mori://shinzui/rei`, project-relative source
`rei-core/src/Rei/Infrastructure/ReiTimers.hs` (artifact-level source URI pending).
Its Kioku timer dispatch branch constructs this default runtime before firing the timer;
that path does not pass Rei's agent provider configuration through to Kioku.

The global worker's logs on 2026-09-07 included:

```text
L1ExtractionFailed "ProviderFailure \"env var ANTHROPIC_API_KEY is not set\""
L2SceneGenerationFailed "ProviderFailure \"env var ANTHROPIC_API_KEY is not set\""
```

The investigation counted 11,498 matching retry lines that day through approximately
15:40 PDT: 10,868 L1 extraction failures and 630 L2 scene-generation failures. Most retries
used a 900-second delay. These are retry counts, not distinct sessions or lost memories.
The live failures establish L1/L2 impact; consolidation/persona use the same constructor,
but their failure was not separately observed.

The deployed Kioku package version was not established, so `affectedVersion` is `unknown`.
The same hardcoded constructor was inspected in repository commit
`14a7543f508a7d8110296383aa0500ab9e3b6a5d`, whose kioku-core package declares 0.5.2.0.
This report does not claim that the deployed worker uses that exact revision.

## Requirement and documentation discrepancy

[Distillation](../user/distillation.md) and [Configuration](../user/configuration.md)
documented the Anthropic API requirement at the time of the report. That implementation followed the
guide of its time but violated the reporting host operator's explicit requirement: use only
interactive execution, never direct API execution. This was filed as the requested integration
bug with status `reported`; its missing policy boundary is now covered by Kioku and host regressions.
There is no evidence of a previously working interactive default.

Adding an API key is not an acceptable workaround: it enables the prohibited execution path.
Likewise, silently substituting a headless CLI call does not establish compliance with an
interactive-only policy. The implementation must make the supported interaction mode explicit.

## Required fix and acceptance evidence

- Let an embedding host supply its authorized distillation runtime/provider policy instead of
  unconditionally registering the API provider in the default host path.
- Wire the reporting host to the interactive execution path. If a background timer cannot run
  interactively, defer it for an authorized interactive session with an actionable status;
  do not fall back to an API or continually retry a permanent configuration mismatch.
- Apply the policy consistently to extraction, consolidation, scene, and persona programs.
- Add regression coverage showing that an interactive-only host with no API key never invokes
  the API provider, including when interactive execution is unavailable. Verify permitted
  interactive execution can complete distillation without API credentials.
- Update the user guides and host integration instructions to explain execution selection,
  required interactive-session availability, and deferred work.

Keep any separately supported API mode explicitly selected. Do not address this report by
provisioning ANTHROPIC_API_KEY. The unrelated action-projection/database errors found during
the same Rei health investigation are outside this report.


## Fix and acceptance (2026-09-08)

[Plan 41](../plans/41-configure-all-kioku-ai-features-through-baikai-and-honor-host-execution-policy.md)
records the implementation, dependency verification, and exact validation commands. Kioku
commits `4da73b0` and `6862915` replace the implicit model/provider with explicit feature
configuration and add authorized listing/resume of the original parked timer. All 235 core
tests in the full adoption run passed; all 20 timer tests passed after the final recovery
additions, alongside 58 CLI tests, 24 migration tests, and 125 API tests. Tests exercise a
real-runtime interactive result-file fixture, concurrent resume exclusion, unavailable and
denied preflights, cancellation cleanup, expired-claim recovery, and stale-token refusal.
The earlier real Claude terminal smoke produced a validated preference atom without API or
database credentials.

The reporting host `mori://shinzui/rei` passed all 40 selected durable-timer tests using
released Keiro 0.16 and a temporary local-Kioku validation overlay. Its corrected fixture
checks the actual deferred reason, authorized listing, and foreground completion of the
original valid scene timer once. The initial host test's malformed payload and dead-state-only
assertion were insufficient evidence; that fixture is replaced, not relied upon for closure.

`fixed` here means the source fix and required regression acceptance are complete. No new
Kioku package has been published, no live worker has been redeployed, and no production timer
has been replayed. The consumer's released-package index and deployment inputs need updating
when adopting the forthcoming Kioku release; this report makes no claim that the observed
launchd process is already repaired.
