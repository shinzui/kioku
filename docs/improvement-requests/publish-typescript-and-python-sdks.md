---
type: Improvement Request
title: Publish TypeScript and Python SDKs
description: >-
  Publish supported TypeScript and Python clients generated from Kioku's versioned OpenAPI
  contract, with ergonomic typed wrappers, safe retry behavior, and conformance tests.
timestamp: 2026-08-06T15:00:12Z
requestId: IR-5
status: proposed
origin: mori://shinzui/kioku
---

# Improvement Request: Publish TypeScript and Python SDKs

## Status

Proposed. Implementation depends on IR-4's stable versioned HTTP/OpenAPI contract. Design can
start earlier to constrain naming, pagination, error, and authentication ergonomics.

## Context

Non-Haskell agents should not hand-assemble Kioku URLs or duplicate its scope and partition
semantics. A generated client alone is mechanically complete but often awkward; a fully
handwritten client drifts from the service. Kioku needs a reproducible generated protocol layer
plus a small reviewed ergonomic layer in each target language.

## Requested Change

Publish official TypeScript and Python SDKs from the checked-in IR-4 OpenAPI document. The
generated transport/types are not edited by hand. A thin handwritten layer provides idiomatic
clients, async operation, cursor iterators, explicit recall-target constructors, command
idempotency helpers, typed errors, timeouts/cancellation, and configurable retry/backoff only for
safe/idempotent operations.

Callers supply a Shomei bearer token through an injectable credential provider; optional En
decision tokens are forwarded only for their scoped request. SDKs do not resolve Meibo, infer
team membership, cache ACL decisions beyond their token lifetime, or provide an “all spaces”
shortcut. Logs and exceptions redact credentials and sensitive request bodies.

Version generated clients against the service major version and test every release against a
real Kioku service fixture. Add an OpenAPI breaking-change check so a service change cannot
silently publish incompatible clients.

## Acceptance

1. TypeScript and Python packages are generated reproducibly from the same committed OpenAPI
   document and contain no divergent handwritten wire models.
2. The exact global bucket, an exact entity scope, and namespace-wide recall are three distinct
   typed constructors — matching the three `kind` tags on the wire — and always require one
   memory-space context. No client may express a target by omitting a scope field.
3. Pagination iterators preserve cursors and bounds; they never fetch an unbounded collection.
4. Retry middleware retries only documented idempotent operations and carries idempotency keys
   across attempts.
5. 401, 403, 404, 409, 422, 429, and 5xx responses map to distinct typed errors with request IDs
   and retry metadata where applicable.
6. Credentials, decision tokens, raw prompts, and memory content are absent from default logs and
   exception rendering.
7. One real-service conformance suite runs the same behavioral cases through Haskell/direct HTTP,
   TypeScript, and Python clients.
8. Packages include semantic-versioning policy, migration notes, examples, and registry releases.

## Requested Deliverables

- SDK design ExecPlan and OpenAPI compatibility policy.
- Generated TypeScript and Python protocol clients plus ergonomic wrappers.
- Cross-language real-service conformance, auth/redaction, retry, pagination, and cancellation
  tests.
- Package registry publishing automation, examples, reference docs, and tagged releases.
