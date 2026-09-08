---
type: Architecture Decision Record
title: Hosts own AI execution capabilities
description: Kioku requires explicit Baikai execution capabilities for each AI feature and parks unavailable interactive work without provider fallback.
timestamp: 2026-09-08T01:00:00Z
docId: ADR-12
status: accepted
date: 2026-09-08
---

# Hosts own AI execution capabilities

## Status

Accepted, 2026-09-08. Authorized deferred resume requires a forthcoming upstream timer API.

## Context

The old distillation constructor registered Anthropic globally and captured a fixed model in
four closures. Its writable model/config fields could disagree with those closures. Embeddings
were independently enabled by environment defaults. Neither behavior represented permission
from an embedding host to use a particular transport or credential.

## Decision

Every production AI entry point consumes a validated `AIRuntime`. Disabled is the default.
Distillation settings use Baikai models/options and interactive requests, with shared defaults
and closed feature overrides. Embedding settings remain separate Baikai embedding models.
Hosts grant API and batch registries separately, plus explicit interactive and embedding
capabilities. Validation snapshots only selected handlers into private registries; Kioku never
mutates the supplied registry. Nested programs cannot replace the selected model or options.

Interactive execution requires a host-supplied session launcher. A worker receives no launcher.
An installed executable, terminal, batch CLI subscription, or credential does not grant one.
A private request manifest and bounded, non-symlink regular result file carry an envelope with
fresh request identity, feature, and typed result. Exit success alone never counts as a result.
Shikumi checks the result against the same schema/domain rules as completion execution.

Memory authorization precedes execution availability. Unavailable interactive timers are
parked through Keiro's existing dead-letter operation with the stable reason prefix
`kioku:deferred:interactive-unavailable`. Polling cannot reclaim them. Authorized resume must
recheck space authorization and session ownership, then atomically claim the original timer by
its ID and expected deferred reason. Until Keiro exposes that operation and deferred listing,
Kioku does not offer unsafe generic replay or write to Keiro-owned tables.

## Consequences

Storage and keyword recall remain usable without AI. Hybrid recall visibly falls back to
keywords, candidate lookup can scan, and explicit embedding-only/backfill requests refuse
missing execution capabilities. Configured embedding uses must agree on model and endpoint;
stored model labels are checked before semantic execution. Model changes require explicit
re-embedding; configuration does not migrate data.

The zero-argument distillation constructor is removed. Controlled callbacks are available only
through the explicit test seam. Versioned configuration files share a parser across CLI and
embedding hosts. Provider defaults cannot be restored by credential presence.

## Alternatives rejected

A mode string checked after constructing the old runtime would leave global registration and
captured defaults intact. Treating batch CLI execution as interactive would spend a capability
the operator did not grant. Repeated retries for missing terminal ownership would waste claims
and hide work that requires a foreground session. Direct SQL replay in Kioku would split
ownership of Keiro's timer state machine.

## References

- [Plan 41](../plans/41-configure-all-kioku-ai-features-through-baikai-and-honor-host-execution-policy.md)
- [ADR-1](kioku-owns-memory-not-identity.md)
- [ADR-2](namespace-is-not-a-security-boundary.md)
- `mori://shinzui/baikai/packages/baikai`
- `mori://shinzui/keiro/packages/keiro`
