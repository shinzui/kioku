---
title: "Host-owned AI execution with an explicit, versioned capability grant"
type: Capability
description: "Refuse to generate anything until a host grants a validated AIRuntime naming its own transports, models, and credentials — disabled by default, with API, batch, interactive, and embedding as separate permissions and no implicit provider or fallback anywhere."
generated:
  by: claude-code/opus-5
  at: "2026-09-08T20:08:43Z"
capabilityId: CAP-17
provider: mori://shinzui/kioku
status: shipped
stability: experimental
since: unreleased
packages:
  - kioku-core
interface:
  - Kioku.AI.Runtime
  - Kioku.AI.Config
  - Kioku.AI.File
  - Kioku.AI.Interactive
evidence:
  - kind: test
    resource: kioku-core/test/Kioku/AIRuntimeSpec.hs
    proves: "Versioned configuration rejects unknown modes and features, overrides cannot grant API authority, transport aliases cannot disguise batch as API, disabled construction makes no calls, host registries stay isolated, interactive background ownership is deferred without a call, and an invalid result file never succeeds."
  - kind: test
    resource: kioku-cli/test/Kioku/Cli/RecallEndToEndSpec.hs
    proves: "An explicit AI file overrides the environment and credentials alone do not enable AI."
  - kind: example
    resource: docs/examples/ai-api.json
    proves: "A complete version-1 API configuration: permissions, distillation defaults, per-feature replacements, and named credential environment variables."
  - kind: example
    resource: docs/examples/ai-interactive.json
    proves: "A version-1 interactive configuration whose empty embeddings object leaves embeddings disabled."
  - kind: guide
    resource: docs/adr/host-owned-ai-execution.md
    proves: "Why the zero-argument distillation constructor was removed, and the rule that memory authorization precedes execution availability."
  - kind: guide
    resource: docs/user/configuration.md
    proves: "Every field of the AI configuration file, which commands need which capability, and what each unavailable capability degrades to."
---

# Host-owned AI execution with an explicit, versioned capability grant

Kioku generates nothing on its own authority. Every production AI entry point consumes a
validated `AIRuntime`, and `disabledAIConfig` — which enables nothing — is the default.
The runtime that replaced it is built by the host from a versioned configuration file that
names transports, models, endpoints, and the environment variables its credentials come
from. There is no implicit provider, no implicit model, and no fallback between them.

The permissions are separate because the risks are: `api` selects a Baikai HTTP transport,
`batch` selects a batch transport, `interactive` launches a genuine terminal session, and
embedding capability is independent of all three. Per-feature replacements for extraction,
consolidation, scene, and persona must each be authorized by the same permissions — an
override cannot grant authority the top-level permissions withheld, and a transport alias
cannot disguise batch as API.

Construction **validates without reading credentials** and snapshots the selected handlers
into private registries, so Kioku never mutates a host's registry and a nested program
cannot replace the selected model or options.

Interactive execution needs a host-supplied session launcher. An installed executable, a
TTY, a batch CLI subscription, or a credential grants none. The launch carries a private
request manifest and a bounded, non-symlink regular result file whose envelope must show a
fresh request identity, the feature, and a typed result — **a successful process exit with
no valid matching result is a failed generation** — and that result is checked against the
same Shikumi schema and domain rules as completion output.

Only foreground work can own an interactive session. `loadAIRuntime` takes a foreground
flag that background hosts must pass as `False`, and background interactive work is parked
rather than downgraded: see
[deferred interactive recovery (CAP-18)](deferred-interactive-recovery.md).

**Execution permission is not memory permission.** Authorization to read or write memory is
a separate decision, made first, through
[the access context (CAP-4)](memory-space-isolation.md).

## Shape

```json
{
  "version": 1,
  "permissions": ["interactive"],
  "distillation": {"mode": "interactive", "provider": "claude", "model": "claude-haiku-4-5", "workingDir": "."},
  "features": {},
  "embeddings": {}
}
```

```haskell
runtime <- loadAIRuntime foreground explicitPath   -- falls back to KIOKU_AI_CONFIG, then disabled
let distill = newDistillRuntime runtime workspaceRoot
```

## Limits

- This is **unreleased**: it exists on the default branch only. The 0.5.2.0 line still
  registers its provider from environment defaults.
- `runDistillProgram` requires an `AIFeature`. Interactive execution of an arbitrary
  program is refused, because it has no typed signature handoff; only the four built-in
  signatures support one.
- With generation disabled, storage and keyword recall keep working, hybrid
  [recall (CAP-5)](hybrid-recall-with-explicit-targets.md) visibly falls back to keyword,
  and explicit embedding-only or backfill requests refuse rather than degrade.
- Configured embedding uses must agree on model and endpoint. Stored model labels are
  checked before semantic execution, and a model change requires explicit re-embedding —
  configuration migrates no data.
- Controlled callbacks are available only through the explicit test seam
  (`testDistillRuntime`, `withTestRunners`), never by mutating a live runtime.
