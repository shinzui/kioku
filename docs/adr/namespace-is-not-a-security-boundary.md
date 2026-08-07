---
type: Architecture Decision Record
title: Namespace organizes memory; memory space isolates it
description: >-
  Namespaces and scopes remain an organizing vocabulary with no security meaning; isolation
  between callers is carried only by an explicit MemorySpaceId.
timestamp: 2026-08-07T00:00:00Z
docId: ADR-2
status: accepted
date: 2026-08-06
---

# Namespace organizes memory; memory space isolates it

## Status

Accepted, 2026-08-06.

## Context

Kioku already has a two-level addressing vocabulary in `kioku-api/src/Kioku/Api/Scope.hs`. A
`Namespace` labels the host — `rei`, `mori`, `shikigami` — and a `MemoryScope` is either that
namespace alone or a namespace with an entity kind and reference, such as
`rei:intention:intention_01h9`. One database serves many hosts, kept apart by namespace.

Read quickly, that looks like tenancy: each host has its own namespace, and its data does not
collide with another host's. It is tempting to conclude that a caller confined to a namespace is
therefore isolated within it.

It is not, and the difference is not cosmetic. Nothing in the scope machinery authenticates
anyone. A namespace is a label a caller supplies; it is not a claim anyone verified. Worse, the
global scope deliberately means *no scope filter* for recall: `kioku recall --scope mori` returns
every active memory in the namespace, entity-scoped rows included. A vocabulary with a documented
"return everything" value cannot also be a containment boundary.

There is also a shape mismatch. A namespace is a host label, so it is fixed per deployment of that
host. Isolation between callers is not: two people using the same host must sometimes be
separated, and one team must sometimes reach several isolated collections. Those are different
cardinalities, and forcing both onto one identifier means one of them is wrong.

## Decision

Namespaces and scopes stay exactly what they are: an organizing vocabulary with no security
meaning. They keep hosts from colliding and they decide which memories accumulate together, feed
a persona, or share a scene identity. They decide nothing about who may read them.

Isolation is carried solely by `MemorySpaceId`. It is an independent identifier, not derived from
the namespace, not derived from the scope, and not derived from any principal. Every command,
query, worker task, and (from the read-model migration onward) every stored row belongs to exactly
one memory space.

The authorization object for a space is formed from the space identifier alone. The namespace and
scope contribute nothing to it, so the same namespace and the same scope in two different memory
spaces are two different questions to ask, and a decision about one can never be replayed as a
decision about the other.

A memory space identifier is opaque validated text rather than a Kioku-minted identifier, because
a host may create spaces in a system Kioku does not own.

## Consequences

Existing hosts change nothing about how they choose namespaces and scopes; the guidance in
[Scopes & Integrations](../user/integrations.md) still stands, and global-scope recall keeps its
namespace-wide meaning *within one space*.

An integrator asking "how do I keep customer A's memories away from customer B?" gets one answer —
a memory space — rather than a namespace convention that would have failed the first time someone
called recall with a global scope.

Recall must never span memory spaces, including under a global scope. That is a stronger
constraint than the current recall semantics, and it is why the explicit-recall-boundaries work
depends on this decision. [ADR-8](an-explicit-recall-target-replaces-the-overloaded-scope.md)
delivers it in the type: a recall call names its breadth with a `RecallTarget` and takes its
memory space from the authorizing context, so a target that widens to a whole namespace has no
way to name a second space.

The cost is a second axis to carry: every path now needs both a scope and a space. The
alternative was one axis that quietly meant two different things.

## Alternatives rejected

**Promote `Namespace` to the tenancy boundary.** Rejected: it is caller-supplied, unauthenticated,
fixed per host rather than per tenant, and its global form is defined to bypass filtering.

**Derive the memory space from the scope.** Rejected: it would make an authorization boundary a
function of an organizing label, so renaming a scope would move data across a security boundary.

## References

- `kioku-api/src/Kioku/Api/Scope.hs`, `kioku-api/src/Kioku/Api/Access.hs`
- `kioku-core/test/Kioku/PortfolioAccessSpec.hs` — "the same namespace and scope in two spaces
  are two different questions"
- [Scopes & Integrations](../user/integrations.md)
- [ADR-1](kioku-owns-memory-not-identity.md), [ADR-3](legacy-data-lands-in-one-explicit-space.md)
