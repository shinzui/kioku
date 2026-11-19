---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Add an authenticated HTTP service](add-an-authenticated-http-service.md) - Ship an optional versioned HTTP service over Kioku's library API with Shomei authentication, Meibo principal resolution, En object authorization, bounded operations, and OpenAPI.
- [Add indexed session and bounded memory read models](add-indexed-session-and-bounded-memory-read-models.md) - Provide subject-reference session lookup plus SQL-bounded recall and retention-candidate queries so long-lived consumers do not scan unbounded Kioku histories in application memory.
- [Add versioned learned skills](add-versioned-learned-skills.md) - Let Kioku derive, review, version, activate, and retire reusable skills from successful sessions without treating executable guidance as an ordinary memory atom.
- [Expose archive change receipts without inventing legacy principals](expose-archive-change-receipts-without-inventing-legacy-principals.md) - Provide a supported authoritative archive changed receipt for hosts whose existing legacy-space commands truthfully carry UnattributedPrincipal, without weakening context-first authorization or fabricating identity.
- [Expose fixed Memory metadata, tag pages and recency queries](expose-fixed-memory-metadata-tag-pages-and-recency-queries.md) - Provide permission-checked fixed Memory metadata, separately paged tags, newest-active lookup and scope-kind filtering so Rei can expose bounded resources without private Kioku SQL or collection preloading.
- [Filter ranked recall by tag and memory type](filter-ranked-recall-by-tag-and-memory-type.md) - Let a recall query restrict its candidates to memories carrying given tags or memory types before ranking, so a caller asking for the best matches within a subset gets a full result page instead of filtering an unrestricted page after the fact.
- [Let a host record memories without scheduling scene distillation](let-a-host-record-memories-without-scheduling-scene-distillation.md) - Give a host that only stores and recalls memories a supported way to turn off scene-timer scheduling for a memory space, so its writes do not accumulate timers that nothing fires or that spend model calls on scenes nobody reads.
- [Publish TypeScript and Python SDKs](publish-typescript-and-python-sdks.md) - Publish supported TypeScript and Python clients generated from Kioku's versioned OpenAPI contract, with ergonomic typed wrappers, safe retry behavior, and conformance tests.
- [Release Kioku for Keiki 0.4 and Keiro 0.4](release-kioku-for-keiki-0-4-and-keiro-0-4.md) - Publish a coherent Kioku release whose bounds, migrations, and runtime APIs support the released Keiki 0.4 and Keiro 0.4 families without downstream allow-newer overrides.
