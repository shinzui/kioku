---
okf_version: "0.2"
---

# Files

- [profile.dhall](profile.dhall)

# Improvement Request

- [Add an authenticated HTTP service](add-an-authenticated-http-service.md) - Ship an optional versioned HTTP service over Kioku's library API with Shomei authentication, Meibo principal resolution, En object authorization, bounded operations, and OpenAPI.
- [Add indexed session and bounded memory read models](add-indexed-session-and-bounded-memory-read-models.md) - Provide subject-reference session lookup plus SQL-bounded recall and retention-candidate queries so long-lived consumers do not scan unbounded Kioku histories in application memory.
- [Add versioned learned skills](add-versioned-learned-skills.md) - Let Kioku derive, review, version, activate, and retire reusable skills from successful sessions without treating executable guidance as an ordinary memory atom.
- [Publish TypeScript and Python SDKs](publish-typescript-and-python-sdks.md) - Publish supported TypeScript and Python clients generated from Kioku's versioned OpenAPI contract, with ergonomic typed wrappers, safe retry behavior, and conformance tests.
- [Release Kioku for Keiki 0.4 and Keiro 0.4](release-kioku-for-keiki-0-4-and-keiro-0-4.md) - Publish a coherent Kioku release whose bounds, migrations, and runtime APIs support the released Keiki 0.4 and Keiro 0.4 families without downstream allow-newer overrides.

