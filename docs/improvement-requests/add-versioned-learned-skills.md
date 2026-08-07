---
type: Improvement Request
title: Add versioned learned skills
description: >-
  Let Kioku derive, review, version, activate, and retire reusable skills from successful
  sessions without treating executable guidance as an ordinary memory atom.
timestamp: 2026-08-06T15:00:12Z
requestId: IR-3
status: proposed
origin: mori://shinzui/kioku
---

# Improvement Request: Add Versioned Learned Skills

## Status

Proposed. Design and implementation should begin only after the secure-evidence and
portfolio-isolation contracts are stable enough to supply trusted inputs, provenance, and access
context.

## Context

Kioku can distill facts, preferences, constraints, instructions, scenes, and personas, but it has
no first-class artifact for a reusable procedure learned from successful work. Encoding a skill as
`MemoryType = instruction` would lose version history, activation state, resource manifests,
evaluation evidence, and safe rollout. It would also let one extracted sentence become executable
guidance without review.

The recent review of `mori://TencentCloud/TencentDB-Agent-Memory` showed the value of immutable,
versioned learned Skills. That third-party project is not yet registered in Mori, so a more
specific artifact URI is pending. Kioku should adopt the capability while fitting its own
architecture: event-sourced artifacts, secure L0→L1 evidence selection, first-class provenance,
memory-space isolation, and portfolio principals.

## Requested Change

Add a separate versioned Skill aggregate and read model, preferably in an optional package rather
than expanding the core memory-type enum. A skill has a stable ID plus immutable versions with:

- memory space, canonical Meibo owner/author principals, name, summary, and lifecycle
  (`draft | active | retired`);
- procedure content and a typed resource manifest for referenced files, tools, or templates;
- source session/memory/evidence-decision IDs and model-call evidence IDs;
- evaluation results, success criteria, compatibility metadata, and creation/activation times;
- optimistic expected-version checks and exactly one active version per skill.

Provide an opt-in derivation pipeline from successful sessions. It must consume only evidence
accepted by `docs/plans/23-gate-untrusted-session-evidence-before-l1-distillation.md`, produce a
draft, and require an explicit trusted activation action. Failed, cancelled, untrusted-only, or
secret-bearing sessions cannot auto-activate a skill.

Skill lookup is partitioned by `MemorySpaceId` and authorized through the same Meibo/Shomei/En
contract as memory. Kioku stores principal references and artifact state; it does not create its
own users, teams, agents, memberships, or ACL rules. Export to provider-native skill layouts may
be added as adapters, but the durable Kioku representation remains provider-neutral.

## Acceptance

1. Skills are a separate aggregate/artifact family, not an overloaded memory atom.
2. Updating a skill appends an immutable version under optimistic concurrency; readers can pin a
   version or request the active one, and rollback activates an earlier immutable version.
3. Derivation from a successful fixture creates a draft with complete evidence/provenance links;
   an untrusted-instruction fixture creates no activatable skill.
4. Activation is an explicit attributable command and exactly one version is active.
5. Resources are content-addressed or integrity-checked, traversal-safe, and included in version
   identity.
6. Two memory spaces can use the same skill name/version without visibility or artifact collision.
7. Person, team, and agent ownership uses canonical Meibo principal IDs; En checks the owning
   memory-space object.
8. Real-PostgreSQL replay/concurrency tests and an end-to-end derive-review-activate-use test pass.

## Requested Deliverables

- ExecPlan/MasterPlan and ADRs for the Skill aggregate, activation model, and resource integrity.
- Public types, event codecs, projections, migrations, derivation/evaluation pipeline, and
  inspection APIs.
- Provider-neutral import/export plus at least one provider-native adapter fixture.
- Security, provenance, partition-isolation, concurrency, and end-to-end tests.
- User documentation and a tagged release.
