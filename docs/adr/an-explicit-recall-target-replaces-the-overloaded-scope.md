---
type: Architecture Decision Record
title: An explicit recall target replaces the overloaded scope
description: >-
  Recall takes a RecallTarget naming exactly one of three meanings, the pre-target request
  survives one release as a deprecated wrapper, and the memory space comes from the authorizing
  context rather than the target.
timestamp: 2026-08-07T12:00:00Z
docId: ADR-8
status: accepted
date: 2026-08-07
---

# An explicit recall target replaces the overloaded scope

## Status

Accepted, 2026-08-07.

## Context

`kioku-api/src/Kioku/Api/Scope.hs` defines a `MemoryScope` as either a namespace alone
(`ScopeGlobal`) or a namespace with an entity kind and reference (`ScopeEntity`). Until this
decision, recall took that value directly, and `ScopeGlobal ns` meant two different things
depending on which function received it.

Handed to `recall`, it meant *no scope filter*: the candidate SQL spells the scope predicate
`(($4 IS NULL AND $5 IS NULL) OR (scope_kind = $4 AND scope_ref = $5))`, both parameters are NULL
for a global scope, the first disjunct is always true, and every active row in the namespace comes
back — entity-scoped rows included. Handed to `getActiveByScope`, `getGlobal`, or a scene or
persona lookup, the same value meant *the global bucket*: only rows recorded with no entity scope.

Both behaviours are wanted. Search wants the largest plausible candidate surface; a read asking
for "the global memories of `mori`" is asking for a specific set of rows. The defect was never
that the two behaviours existed — it was that one value named both, so a call site could not say
which it meant and a reviewer could not see which it got. The difference is how many rows come
back and which ones, and it was documented in prose rather than expressed in the type.

There was also a meaning with no representation at all: *the exact global bucket, ranked*. No
`RecallRequest` could ask for it, because the only value that named the global bucket was
interpreted as the whole namespace.

The remediation work in
`docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md` deliberately
documented the asymmetry rather than changing it, because changing the meaning of an existing
constructor in place would have silently narrowed every existing caller's results.

## Decision

Recall takes a `RecallTarget`, which names exactly one of three things: the exact global bucket
(`ExactScope (ScopeGlobal ns)`), one exact entity scope (`ExactScope (ScopeEntity ns k r)`), or
every scope in a namespace (`NamespaceWide ns`). It lives in `kioku-api/src/Kioku/Api/Recall.hs`
alongside `RecallQuery`, `RecallStrategy` and a `RecallLimit` validated to 1–100, so a host, an
HTTP service, or an SDK can name a request without depending on the runtime package.

The wire format carries a required discriminator with one tag per meaning — `exact_global`,
`exact_entity`, `namespace_wide` — rather than one tag per Haskell constructor. Two tags would
have separated the exact global bucket from an exact entity only by whether `scope_kind` was
present, which is the null-means-something representation this decision removes from SQL,
reintroduced on the wire. Decoding refuses an unknown tag and refuses a variant carrying a field
it has no meaning for.

**The memory space is not part of the target.** It comes from the `MemoryAccessContext` passed to
`recall`, and nothing in the request can change it. Widening a target is a retrieval choice inside
one already authorized partition; it must never be able to select whose memories are searched.
This is why `recall` takes a whole context where the other reads take a bare `MemorySpaceId` — it
is the only read that can be asked to widen. It does not re-check a permission, for the reason
recorded in `Kioku.Memory`: a context exists only for permissions `authorizeMemoryAccess` already
checked against that space.

**The pre-target API survives as a deprecated wrapper.** `RecallRequest` and `legacyRecall` map a
legacy scope through `legacyRecallTarget` — `ScopeGlobal ns` to `NamespaceWide ns`, an entity
scope to `ExactScope` — and return exactly the rows they return today. The mapping is toward the
*wider* target on purpose: the opposite mapping compiles, runs, and returns a fraction of the rows
the caller had yesterday. The pure `legacyRecallTarget` is deliberately **not** deprecated,
because it is the tool a migrating caller must use; the compile-time warning lives on
`legacyRecall`, which every unmigrated caller goes through.

**The removal window.** The deprecated pair survives for at least one released version. It is
deleted only in a later PVP-breaking release, and only when both conditions hold: every dependent
Mori reports for `shinzui/kioku` compiles against `RecallTarget`, and no in-repository caller
constructs a `RecallRequest`. Completing the migration work does not by itself authorize deletion.

## Consequences

A call site now says which of the three sets of rows it means, and a reviewer can see it without
knowing which function is being called. The exact global bucket became expressible for the first
time.

It was expressible before it was executable. For one release `ExactScope (ScopeGlobal ns)`
type-checked, round-tripped on the wire, and was refused at execution with
`RecallExactGlobalUnsupported`, because the shared scope predicate had no parameter assignment for
it — the only rows it could reach through the statements of the day were the namespace-wide ones.
Refusing was the honest intermediate state; answering the wrong question quietly is the defect
being removed.

**That state is over.** [ADR-9](each-recall-target-gets-its-own-statement.md) gives each target its
own SQL scope clause, so all three execute, `RecallExactGlobalUnsupported` is gone, and
`resolveRecall` is total. `RecallError` retains only `RecallSpaceMismatch`, which nothing but
`legacyRecall` can produce.

`Kioku.Distill.L1.FindMergeCandidates` receives the pass's `MemoryAccessContext` rather than its
`MemorySpaceId`, because a finder that runs recall must be handed the decision that authorized the
pass. Its error channel became `L1Error` so that a recall refusal surfaces as
`L1RecallRefused` — flattening it into an empty candidate list would tell the consolidator there
is nothing to merge into, which is the "a denial became an empty result" mistake
`Kioku.Api.Access` exists to prevent.

The command line is unchanged for now: `--scope mori` still searches the whole namespace, through
`legacyRecallTarget`. Giving operators explicit exact and namespace-wide grammar is
`docs/plans/30-migrate-recall-consumers-to-explicit-targets.md`, and until then there is no way to
ask the CLI for the exact global bucket.

The cost is a second vocabulary beside `MemoryScope`, and a conversion between them at every
boundary that still speaks the old one. The alternative was a single vocabulary that meant two
different things depending on the reader.

## Alternatives rejected

**Reinterpret `ScopeGlobal` in place so recall means the global bucket.** Rejected: it is a
data-visibility change with no compiler signal. Every existing caller would keep compiling and
start receiving a fraction of the rows.

**Keep one `MemoryScope` and add a boolean `namespaceWide` field.** Rejected: a boolean beside a
scope is exactly as easy to get wrong as a scope alone, it has no meaningful default, and on the
wire it is another optional field whose absence carries meaning.

**Put the memory space in `RecallTarget` or `RecallQuery`.** Rejected: a request is something a
caller composes and a space is something an authorization decision granted. Keeping them in
separate values means no single edit can widen a target and a tenancy at once.

**Delete the legacy request now.** Rejected: `mori://shinzui/shikigami` is a known dependent, and
a breaking change with no deprecation period gives it no compile-time warning and no migration
window.

## References

- `kioku-api/src/Kioku/Api/Recall.hs`, `kioku-core/src/Kioku/Recall.hs`
- `kioku-api/test/Kioku/Api/RecallSpec.hs` — the three targets are three values, and three objects
- `kioku-core/test/Kioku/RecallCompatSpec.hs` — the legacy request returns what the explicit
  target returns, against a real database
- [Recall & Hybrid Retrieval](../user/recall.md), [Library API](../user/library-api.md)
- [ADR-2](namespace-is-not-a-security-boundary.md) — recall must never span memory spaces,
  including under a global scope; this decision is how that constraint reaches the type
- [ADR-6](the-partition-is-a-column-not-a-schema.md) — the partition predicate the target
  predicate sits beside
