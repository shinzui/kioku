---
type: Improvement Request
title: Expose archive change receipts without inventing legacy principals
description: Provide a supported authoritative archive changed receipt for hosts whose existing legacy-space commands truthfully carry UnattributedPrincipal, without weakening context-first authorization or fabricating identity.
requestId: IR-7
status: completed
completedAt: "2026-10-20T00:34:38Z"
resolution: >-
  Published Kioku v0.11.0.0 from release commit 1375927d81eda88e3411758c62251f5117916b1f with all five
  Hackage packages, four library documentation archives and the combined migration guidance.
  The immutable tag and GitHub release are at https://github.com/shinzui/kioku/releases/tag/v0.11.0.0.
  Downloaded sources match the upload digests and expose the supported public APIs.
  All 496 tests and build, Nix, package and source-distribution checks pass.
  Consumer adoption remains downstream work.
origin: mori://shinzui/rei/plans/255-expose-agent-execution-sessions-memory-schedules-and-review-workflows
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-20T00:34:38Z"
timestamp: "2026-10-20T00:34:38Z"
verified:
  - by: openai/gpt-6-astra
    at: "2026-10-19T23:37:23Z"
reviews:
  - kind: model
    reviewer: "codex (author self-review)"
    reviewed_at: "2026-10-19T22:58:18Z"
    document_timestamp: "2026-10-19T22:55:57Z"
    scope: technical-accuracy
    outcome: approved
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: >-
      Checked the request against published Kioku 0.10.0.0 source and tags,
      current published Store versions and the selected cohort where relevant.
      This author self-review approves request accuracy only; it does not
      approve implementation, dependency adoption or publication.
  - kind: model
    reviewer: "codex (Kioku source validation and scope clarification)"
    reviewed_at: "2026-10-19T23:37:23Z"
    document_timestamp: "2026-10-19T23:37:23Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-6-astra
    effort: unspecified
    context: >-
      Confirmed the facade gap, shared append receipt, legacy consumer mapping,
      typed errors and tests against the working tree; verified the 0.10.0.0
      baseline against Hackage and the upstream tag. ADRs 1, 3, 4, 5 and 14
      support receipt parity only as an explicitly deprecated legacy bridge,
      not a permanent historical-marker context. ExecPlan 50 records this scope,
      acceptance tests and publication prerequisite. Implementation remains pending.
  - kind: model
    reviewer: "codex (release verification and status self-review)"
    reviewed_at: "2026-10-20T00:34:38Z"
    document_timestamp: "2026-10-20T00:34:38Z"
    scope: content-and-metadata
    outcome: approved
    provider: openai
    model: gpt-6.1-sol
    effort: unspecified
    context: >-
      Verified the combined 0.11.0.0 tag and GitHub release, all five published
      source archives against upload SHA-256 digests, and all four library documentation
      pages. Published core source and Haddock expose both plans' APIs and the
      legacy bridge's deprecation/shared-worker contract. All 496 regression tests,
      build, Nix and package checks passed. This self-review records completion;
      it does not claim downstream consumer adoption.

---

# Expose archive change receipts without inventing legacy principals

## Status and implementation plan

Accepted on 2026-10-19 as a temporary compatibility extension after validating
the request against Kioku's source, its consumer adapter and architectural
decisions. Implementation is tracked by
[ExecPlan 50](../plans/50-expose-legacy-archive-change-receipts-without-inventing-principals.md),
linked to intention `intention_01m5b89rmzey4vy07z7ypf4az4`.
Implementation and the seven new public-facade PostgreSQL tests are locally verified:
first/repeat receipts, synchronized legacy and mixed races, exact unattributed payloads,
foreign active/archived IDs, context gates, missing and terminal errors, and compatibility
attribution/ID parity. All 496 regression tests, the build, Nix checks and five package checks pass;
ExecPlan 50 records the evidence.
Publication is complete in the combined 0.11.0.0 release, satisfying criterion 5.
All acceptance criteria are complete; consumer adoption remains downstream work.

The owner-side design exposes `Kioku.Memory.archiveLegacyChanged` over the
existing legacy-space guard and authoritative archive worker. It preserves the
supplied attribution and errors, and is deprecated from introduction with removal
coupled to `archive`. Support requires a documented, tested and published
migration bridge; it does not establish a permanent API for new unattributed writes.

[ADR-5](../adr/historical-attribution-is-marked-never-invented.md) explicitly
rejects historical-marker actors in new authorization contexts and acknowledges
the temporary exception in the existing deprecated wrappers. ADRs 1 and 5 now
clarify that exception for receipt parity while retaining the permanent
context-first contract. A host with no directory may vouch for a real stable
principal under [ADR-1](../adr/kioku-owns-memory-not-identity.md); inventing one
solely to obtain a receipt is not an attribution-preserving migration. Hosts
retain responsibility for authorization at their own boundary.

## Verified baseline and consumer

Rei must return whether an archive command appended a fact, including truthful
no-op receipts for repeats and concurrent requests. The consumer is
`mori://shinzui/rei/plans/255-expose-agent-execution-sessions-memory-schedules-and-review-workflows`
under
`mori://shinzui/rei/masterplans/29-close-rei-cli-and-http-api-gaps-on-the-haskell-jitsurei-contract`.

Checked against the published `kioku-core` 0.10.0.0 archive and tag
`v0.10.0.0`, commit `5f4afc872b09d615d1bb8c78369d6912161c550f`,
on 2026-10-19:

- `archiveWithContextChanged` already returns the owner's authoritative
  `(MemoryId, Bool)` receipt and enforces context permission, space and actor.
- The deprecated `archive` compatibility facade admits only the legacy memory
  space and returns `MemoryId`, discarding that changed flag.
- Rei's existing `ArchiveAgentMemoryData` adapter truthfully supplies
  `UnattributedPrincipal`. Its bearer metadata may also lack an issued
  principal. Creating a made-up `MemoryActor` to satisfy the context-first
  facade would change attribution without an identity authority.

The existing consumers are in `mori://shinzui/rei`, project-relative
`rei-core/src/Rei/Modules/Agent/Memory/KiokuAdapter.hs` and
`rei-core/src/Rei/Modules/Agent/Memory/StoreHandler.hs`
(source-artifact URIs pending).

## Requested behavior

Provide a supported route from the existing legacy attribution contract to the
authoritative archive changed receipt, or document an owner-supported migration
that preserves unknown attribution. Kioku owns the API choice; this request does
not require extending the deprecated compatibility layer indefinitely.

Keep context-first permission, space and actor checks intact. Any legacy-space
entry must retain its existing partition guard and must not grant access to
arbitrary spaces. An issued principal must come from the host's actual identity
boundary, never a substituted process label or invented human/agent identity.

Compute `changed` at the existing command/event-append owner. Rei must not infer
it from before/after reads, timestamps, private event-store queries or a second
archive implementation. Preserve existing not-found, conflicting terminal-state
and idempotent-repeat behavior.

## Acceptance

1. Real public-facade tests cover a first archive, a repeat and concurrent
   attempts. Exactly one appending command reports `changed = True`.
2. Existing unattributed writes remain unattributed; no invented principal is
   retained in a canonical event or its payload.
3. Foreign-space legacy requests are refused. Context-first requests continue
   to enforce permission, space and actor matching.
4. Missing and incompatible terminal Memories retain the owner's typed
   outcomes; changed receipts do not turn refusals into successful no-ops.
5. Document and publish the supported API/migration before Rei adoption.
   An unpublished local wrapper is not an accepted dependency.

Owner validation and implementation planning are now recorded in ExecPlan 50.
The user authorized the combined release; the published API and migration guidance
now complete acceptance. This remains separate from
[IR-6](expose-fixed-memory-metadata-tag-pages-and-recency-queries.md), which
concerns read resources; the plans coordinate releases if shipped together.

## Completion evidence

Published on 2026-10-20 UTC: [Kioku v0.11.0.0](https://github.com/shinzui/kioku/releases/tag/v0.11.0.0), release commit `1375927d81eda88e3411758c62251f5117916b1f`, annotated tag object `5b5f4d3ae99d623e760c96375303a6a732beb5f1`. All five packages are published: [kioku-api](https://hackage.haskell.org/package/kioku-api-0.11.0.0), [kioku-migrations](https://hackage.haskell.org/package/kioku-migrations-0.11.0.0), [kioku-core](https://hackage.haskell.org/package/kioku-core-0.11.0.0), [kioku-cli](https://hackage.haskell.org/package/kioku-cli-0.11.0.0), [kioku-migrate](https://hackage.haskell.org/package/kioku-migrate-0.11.0.0). All four library documentation archives are published and their module pages are reachable; `kioku-migrate` has no library documentation.

Downloaded all five Hackage source archives and matched their SHA-256 digests to the verified upload artifacts. The published core archive has SHA-256 `0f63e1fdbf59511631ab52e849b1b2209a8da5945f4779bdc18135a680c337ac`; its facade exports all four fixed Memory inspection operations and `archiveLegacyChanged`, including the deprecation/Haddock contract and the unchanged guarded `archiveInChanged` call. Published Haddock exposes these APIs too. The source archives match the tagged package files, and the migrations archive includes all fifteen SQL files and the manifest. The release notes and 0.10.0.0-to-0.11.0.0 upgrade edge cover both plans. Consumer adoption remains downstream work and can now use the published API.
