---
type: Improvement Request
title: Add an authenticated HTTP service
description: >-
  Ship an optional versioned HTTP service over Kioku's library API with Shomei authentication,
  Meibo principal resolution, En object authorization, bounded operations, and OpenAPI.
timestamp: 2026-08-06T15:00:12Z
requestId: IR-4
status: proposed
origin: mori://shinzui/kioku
---

# Improvement Request: Add an Authenticated HTTP Service

## Status

Proposed. It depends on partitioned memory spaces and explicit recall targets. The service may be
planned in parallel, but it must not ship an unpartitioned endpoint or private identity/ACL model.

## Context

Kioku is currently a Haskell library/CLI. A stable network boundary is needed for non-Haskell
agents and the SDK work requested in IR-5, but exposing current calls directly would preserve the
ambiguous recall scope and free-text identity assumptions. The portfolio already owns the trust
stack: `mori://shinzui/shomei/packages/shomei-servant` authenticates and applies coarse scopes,
`mori://shinzui/meibo/docs/initial-spec` resolves the canonical principal, and
`mori://shinzui/en/packages/en-servant` authorizes concrete objects.

## Requested Change

Add optional Servant packages and a thin server executable over the public Kioku library. Expose
versioned `/v1` routes for health/readiness, memories, sessions/turns, explicit-target recall,
distillation jobs/status, provenance/model-call evidence inspection, and future artifact families
through separately versioned route groups.

Every protected request must follow one flow: verify Shomei credentials and coarse scope, resolve
the Shomei subject to a cached Meibo principal, check the requested memory-space/action through
En (or verify an in-scope short-lived En decision token), then construct `MemoryAccessContext`.
Authentication failure, missing principal, authorization denial, stale decision, not-found, and
empty successful result remain distinct. The service owns no user/team/agent/membership/ACL table.

Generate and check in a versioned OpenAPI document from the same route/types source. Use tagged
`RecallTarget` variants, cursor pagination, bounded page/query/body limits, idempotency keys for
retryable commands, structured errors with request IDs, cancellation/timeouts, rate limiting,
health/readiness, metrics, and OpenTelemetry. Namespace-wide recall is explicit and never crosses
one authorized memory space.

## Acceptance

1. All protected routes reject unauthenticated requests before Kioku access and distinguish 401
   from 403 and 404 without leaking object existence.
2. Person, team-derived, and agent access fixtures resolve through Meibo and En; the service has no
   parallel roster, membership, or ACL schema.
3. Every query/command carries one memory space and actor principal; cross-space ID substitution is
   denied and produces no database or filesystem mutation.
4. Recall OpenAPI uses the shipped tagged target union — a required `kind` discriminator with one
   tag per data-visible meaning (`exact_global`, `exact_entity`, `namespace_wide`), never a
   nullable `scope_kind`/`scope_ref` pair whose absence carries the meaning — and all list routes
   are cursor-paginated and server-bounded. See
   `docs/adr/an-explicit-recall-target-replaces-the-overloaded-scope.md` and `docs/user/recall.md`.
5. Idempotent command retries produce one logical result; unsafe retries are not automatic.
6. Readiness checks database/migrations and required auth dependencies without exposing secrets.
7. Generated OpenAPI is reproducible, diff-checked in CI, and drives a real-service conformance
   suite covering auth, errors, limits, retries, and shutdown.
8. Core Kioku packages remain usable without Servant, Shomei, Meibo, or En dependencies.

## Requested Deliverables

- MasterPlan/ExecPlans and ADRs for package boundaries, auth flow, error model, and versioning.
- Optional API/server packages, configuration, migration preflight, and production executable.
- Generated OpenAPI, real-service conformance harness, security/limit tests, and observability.
- Deployment and operator documentation plus a tagged release.
