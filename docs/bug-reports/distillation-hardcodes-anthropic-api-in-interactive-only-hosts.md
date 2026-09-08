---
type: Bug Report
title: Distillation hardcodes the Anthropic API in interactive-only hosts
description: >-
  Kioku's default distillation runtime unconditionally selects the Anthropic API,
  bypassing the embedding host's interactive-only policy and repeatedly failing without an API key.
generated:
  by: process:codex
  at: "2026-09-08T00:11:53Z"
bugId: BUG-2
status: reported
severity: unusable
origin: mori://shinzui/rei
affects: mori://shinzui/kioku/packages/kioku-core
affectedVersion: unknown
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
---

# Distillation hardcodes the Anthropic API in interactive-only hosts

## Evidence and cause

In [Runtime.hs](../../kioku-core/src/Kioku/Distill/Runtime.hs), `newDistillRuntime`
unconditionally calls `ClaudeApi.register`, builds `defaultLLMConfig globalProviderRegistry`,
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
currently document the Anthropic API requirement. The implementation therefore follows its
current guide, but violates the reporting host operator's explicit requirement: use only
interactive execution, never direct API execution. This is filed as the requested integration
bug with status `reported`; it has not been reproduced independently in Kioku's test suite.
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
