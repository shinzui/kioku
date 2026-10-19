---
type: Improvement Request
title: Expose archive change receipts without inventing legacy principals
description: Provide a supported authoritative archive changed receipt for hosts whose existing legacy-space commands truthfully carry UnattributedPrincipal, without weakening context-first authorization or fabricating identity.
requestId: IR-7
status: proposed
origin: mori://shinzui/rei/plans/255-expose-agent-execution-sessions-memory-schedules-and-review-workflows
generated:
  by: openai/gpt-6.1-sol
  at: "2026-10-19T22:55:57Z"
timestamp: "2026-10-19T22:55:57Z"
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

---

# Expose archive change receipts without inventing legacy principals

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

This is a request for owner review, not authorization to implement or publish an
upstream change. It is separate from [IR-6](expose-fixed-memory-metadata-tag-pages-and-recency-queries.md),
which concerns read resources.
