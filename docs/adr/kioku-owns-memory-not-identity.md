---
type: Architecture Decision Record
title: Kioku owns memory data, never identity or authorization
description: >-
  Kioku stores memory and carries an authorization decision made elsewhere; it holds no roster,
  credentials, memberships, or policy, and takes no dependency on any identity service.
timestamp: 2026-08-06T17:20:00Z
docId: ADR-1
status: accepted
date: 2026-08-06
---

# Kioku owns memory data, never identity or authorization

## Status

Accepted, 2026-08-06.

## Context

Kioku is a reusable agent-memory library. Before this decision it had no notion of who was
calling: commands and queries carried a `MemoryScope` plus a free-text `agentId`, and any process
that could open the database could read everything in it. That is workable for a trusted
in-process host and untenable behind a service boundary.

The obvious fix — give Kioku users, teams, roles, and an access-control list — is the wrong one
twice over. It would fork whatever roster and policy engine the deployment already has, and it
would put security-critical policy in a memory library where nobody is looking for it.

Three distinct questions have to be answered before a request may touch memory, and they are
genuinely distinct:

1. **Is this credential real, and does it carry a coarse claim for this kind of action?** That is
   authentication. Its answer is a verified subject plus static claims minted at login, and it
   says nothing about any particular memory space.
2. **Which principal is that subject?** That is a directory question. The subject identifier a
   credential carries is not a principal identifier, and the mapping between them — along with
   team membership and agent lifecycle — belongs to whoever runs the roster.
3. **May that principal perform this action on this memory space?** That is authorization, and
   in a relationship-based model it is a graph query, not a column.

Collapsing any pair of these produces a real vulnerability. Treating a coarse `kioku:read` claim
as sufficient grants every space in the deployment to anyone who can read one. Trusting a
caller-supplied principal identifier authorizes a string the caller made up.

## Decision

Kioku owns memory-space data and nothing else about identity. It does not store users, teams,
roles, memberships, credentials, sessions, or access-control policy, and it does not infer them.

Kioku's core accepts a `MemoryAccessContext` — the record that says a decision has already been
made — and never derives one itself. There are exactly two ways to obtain one:

- `assumeAuthorizedMemoryContext`, for a trusted in-process host that has no authentication
  boundary. It is named to be conspicuous in review.
- `authorizeMemoryAccess`, which runs the three gates above in order, refuses to skip any, and
  keeps their failures distinct.

The identity seams are two records of plain functions, `PrincipalDirectory` and
`PermissionChecker`. Kioku names no vendor and imposes no wire protocol.

**Kioku takes no build dependency on any identity service, and will not acquire one.**
`kioku-api/src/Kioku/Api/Access.hs` compiles against `base`, `containers`, `text`, and `aeson`.
Kioku's dependency set remains Baikai, the Keiro/Keiki/Kiroku/Shibuya cohort, Shikumi, and
ordinary Hackage libraries. When a portfolio adapter is written, it lives in a separate package
that depends on Kioku, not the reverse.

Principal identifiers cross the boundary as opaque rendered text. Kioku validates only what it
must to store and compare them safely — non-empty, no whitespace or control characters, and none
of the separators an object reference gives meaning to — and never parses the kind prefix. A
directory that grows an eighth principal kind requires no change in Kioku.

The object type and permission names Kioku asks about are supplied by the host as a
`MemoryAuthorizationBinding`. Kioku ships no default, and construction rejects a binding that
omits any of its five actions.

## Consequences

A host with no identity stack uses Kioku exactly as before, through one explicitly named
function. A host behind a service boundary wires its own stack into two function records. Neither
pays for the other.

Four refusals stay distinct all the way to the caller — missing coarse claim, unresolved
principal, denial, and conditional decision — and **none of them may be turned into a successful
read that happens to return no rows.** A caller cannot distinguish "you may not look here" from
"there is nothing here", and only one of those is worth acting on.

Agent lifecycle stays outside Kioku. A paused agent reaches Kioku as a subject that no longer
resolves, and fails closed there. Kioku cannot tell that apart from an unlinked or removed
credential, which is correct: distinguishing them would mean holding directory state.

The `MemoryAccessContext` constructor lives in `Kioku.Api.Access.Internal` and its fields are
exposed as read-only accessors, because exporting record fields would export record-update syntax
with them and let an authorized decision be widened without naming the constructor. The context
has no `FromJSON` instance for the same reason: a serializable decision can be stored and replayed
against a grant that has since been revoked.

The cost is that Kioku cannot answer "who may see this?" on its own, and an integrator must
supply a binding rather than getting a working default. That is deliberate: a plausible default
would claim a compatibility no test could demonstrate.

## Alternatives rejected

**Kioku owns an access-control list.** Rejected: it forks the deployment's existing roster and
policy engine, and puts security policy where no reviewer expects it.

**Nullable `team_id` / `user_id` / `agent_id` columns.** Rejected: teams, people, and agents are
principals, while spaces are objects with relationships. Fixed columns cannot express
team-of-team nesting or a grant derived from membership, and they bake one identity vocabulary
into the schema.

**Depend on a specific identity stack directly.** Rejected on principle, not on availability. A
memory library that drags one authentication service in behind it is unusable by anyone who
already has a different one.

## References

- `kioku-api/src/Kioku/Api/Access.hs`, `kioku-api/src/Kioku/Api/Access/Internal.hs`
- `kioku-core/test/Kioku/PortfolioAccessSpec.hs` — the conformance fixtures
- [Scopes & Integrations](../user/integrations.md) — a worked integration and the contract matrix
- [ADR-2](namespace-is-not-a-security-boundary.md), [ADR-3](legacy-data-lands-in-one-explicit-space.md)
