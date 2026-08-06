---
id: 24
slug: define-portfolio-identity-and-authorization-contracts-for-kioku
title: "Define portfolio identity and authorization contracts for Kioku"
kind: exec-plan
created_at: 2026-08-06T14:43:35Z
intention: "intention_01kzbref3keh3rsvwtgznjtsq7"
master_plan: "docs/masterplans/5-portfolio-compatible-memory-isolation-and-authorization.md"
---

# Define portfolio identity and authorization contracts for Kioku

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

After this change, Kioku has one reviewed contract for identity, isolation, and authorization
that matches the portfolio: Meibo principal IDs identify people, teams, agents, services, and
organizations; Shomei authenticates; En authorizes a concrete memory-space object. Kioku owns
the memory-space data but no roster, credentials, memberships, or ACL policy. The contract is
visible as public types, a permission mapping, conformance fixtures, and an ADR that later child
plans can implement without reopening the boundary.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [x] Verify released Meibo, Shomei, En, and Kikan-En APIs and versions through Mori, upstream
  tags, and authoritative registries. (2026-08-06 — none are released; see Surprises.)
- [x] Write the contract matrix into `docs/user/integrations.md`. (2026-08-06)
- [x] Define the memory-space object, principal-reference, actor/owner, and permission vocabulary.
  (2026-08-06 — `kioku-api/src/Kioku/Api/Access/Internal.hs`.)
- [x] Specify the Shomei → Meibo → En request flow and consistency-token handling.
  (2026-08-06 — `authorizeMemoryAccess` in `kioku-api/src/Kioku/Api/Access.hs`.)
- [x] Add public Kioku API types and pure wire-format tests without copying directory policy.
  (2026-08-06 — 57 cases in `kioku-api/test/Kioku/Api/AccessSpec.hs`, all passing.)
- [ ] Add cross-project conformance fixtures for person, team, agent, and service principals.
- [ ] Record the final boundary and legacy-space policy in local ADRs.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- Meibo's source already has one canonical `PrincipalId` renderer for `person_…`, `agent_…`,
  `team_…`, `role_…`, `service_…`, `connector_…`, and `org_…` TypeIDs. Its registered metadata
  is stale, so implementation must verify its actual released package state.
- Kikan-En currently accepts only agent subjects for action-oriented objects. Its IR-1 proposes
  the missing person/team/org and space vocabulary; Kioku cannot finalize permission names by
  guessing ahead of that owner.

- **None of the four dependencies is released** (verified 2026-08-06). Every package in Meibo,
  Shomei, and En sits at an in-tree `version: 0.1.0.0`, and `git tag` is empty in all three
  checkouts as well as in Kikan-En. Hackage returns `404` for `meibo-api`, `meibo-core`,
  `en-core`, `en-servant`, `en-client`, `shomei-core`, `shomei-servant`, and `kikan-en`; only
  `kioku-api` returns `200`. Mori's registry lists zero packages for `shinzui/meibo`, which is
  the stale metadata the MasterPlan predicted.

  ```text
  meibo-api -> 404   en-core     -> 404   shomei-servant -> 404
  meibo-core -> 404  en-servant  -> 404   kikan-en       -> 404
  kioku-api  -> 200
  ```

  The consequence is decisive rather than incidental: no `build-depends` entry on any of them can
  exist, so the Milestone 2 sentence "provide an adapter from released `meibo-api` only if that
  dependency is published and PVP compatible" resolves to *not published*, and Kioku takes the
  opaque-rendered-id branch.

- Kikan-En's live schema confirms the gap concretely. `Kikan.En.Schema` (project-relative
  `src/Kikan/En/Schema.hs`) declares seven object types — `agent`, `kawa_source`,
  `kizashi_recipient`, `danwa_thread`, `channel_egress`, `workspace`, `intention` — and every
  relation takes `Schema.subject "agent"`. There is no `space` object, no `person`/`team`/`org`
  subject, and no `can_view` family. `mori path` resolves IR-1 to the project-relative
  `docs/improvement-requests/add-user-facing-principal-vocabulary.md`, whose frontmatter reads
  `status: proposed`.

- Shomei's authenticated principal is **not** a Meibo principal. `Shomei.Servant.Auth.AuthUser`
  carries `authUserId :: UserId` — Shomei's own identifier — alongside roles, scopes, and
  permissions. Meibo's spec records the join separately as
  `CredentialLink { principal_id, shomei_sub, linked_at }` with a dedicated resolution endpoint
  (`GET /v1/principals/by-credential/{sub}`). This is direct evidence that the Meibo resolution
  step is a real hop and not a rename of the Shomei subject, which is why the plan's three-step
  order is not redundant.

- En already gives Kioku everything it needs for freshness, and the shape is worth copying
  faithfully. `En.Revision` defines `Consistency = MinimizeLatency | AtLeastAsFresh
  ConsistencyToken | AtExactSnapshot ConsistencyToken | FullyConsistent`, and every check returns
  `CheckOutcome { decision, checkedAt :: ConsistencyToken }` — including `checkMany`, which
  returns one token for the whole batch because the batch was decided at one revision. En's
  three-valued `CheckDecision = Allowed | Denied | Conditional [CaveatObligation]` means a
  fail-closed consumer has to treat `Conditional` as a distinct outcome, not as an allow;
  `En.Servant.Authorize.requirePermission` does exactly that.


## Decision Log

Record every decision made while working on the plan.

- Decision: `MemorySpaceId` is a Kioku-owned object identifier, not a Meibo principal ID.
  Rationale: A team or person can own or access many spaces, and access is a relationship in En.
  Date: 2026-08-06

- Decision: Actor and owner identities use Meibo's canonical rendered principal IDs without
  copying profiles or memberships into Kioku.
  Rationale: This preserves joins and audit identity while keeping Meibo authoritative.
  Date: 2026-08-06

- Decision: The authorization order is Shomei coarse gate, Meibo subject resolution, then En
  object check.
  Rationale: Authentication, directory, and object authorization are separate portfolio seams;
  any one of them is insufficient by itself.
  Date: 2026-08-06

- Decision: Kioku takes no `build-depends` entry on `meibo-api`, `shomei-servant`, `en-core`,
  `en-servant`, or `kikan-en`, and adds no source-repository pin for them.
  Rationale: All four are unreleased (in-tree `0.1.0.0`, no git tags, `404` on Hackage). The plan
  forbids vendoring source or loosening bounds around an unreleased feature, and a Git pin would
  make Kioku's own Hackage releases unbuildable. Kioku accepts the rendered principal id as
  opaque text instead; an adapter can be added without changing core once the packages ship.
  Date: 2026-08-06

- Decision: Kioku stays independently usable, and independence is a standing constraint rather
  than a consequence of the previous decision. Kioku's dependency set remains Baikai, the
  Keiro/Keiki/Kiroku/Shibuya cohort, Shikumi, and ordinary Hackage libraries; the identity seams
  are records of plain functions named for their role (`PrincipalDirectory`, `PermissionChecker`),
  not for any vendor, and `Kioku.Api.Access` compiles against `base`, `containers`, `text`, and
  `aeson` only. When the portfolio packages ship, the mapping lives in a separate adapter package.
  Rationale: A memory library that pulls a specific authentication service in behind it is
  unusable by anyone who already has a different one. Verified 2026-08-06: no `.cabal` file or
  `cabal.project` in this repository names any portfolio package.
  Date: 2026-08-06 (user directive during implementation)

- Decision: `MemoryAccessContext` exports read-only accessors (`memoryContextSpace`,
  `memoryContextActor`, `memoryContextPermissions`, `memoryContextDecisionToken`) rather than its
  record fields.
  Rationale: Exporting fields exports record-update syntax with them, and
  `context { grantedPermissions = everything }` widens an authorized decision without ever naming
  the constructor — the exact hole that keeping the constructor internal is supposed to close.
  Date: 2026-08-06

- Decision: The context records `grantedPermissions :: Set MemoryPermission`, extending the
  three-field sketch in Interfaces and Dependencies.
  Rationale: A context is a decision, and a decision is about specific actions. Without the set,
  a context minted by checking `read` would silently authorize `forget`. `authorizeMemoryAccess`
  checks every requested permission for the same reason.
  Date: 2026-08-06

- Decision: Kioku ships no default `MemoryAuthorizationBinding`, and construction rejects any
  binding that omits an action.
  Rationale: The object type, permission names, and coarse scopes belong to schemas Kioku does
  not own — and the memory-space object does not exist in the current Kikan-En schema at all.
  Shipping plausible names would claim a compatibility no test can demonstrate. Requiring the
  host to supply all five makes the dependency visible at the call site and keeps
  `memoryPermissionBinding` total, so a rarely-exercised path cannot discover a hole in
  production.
  Date: 2026-08-06

- Decision: `MemoryAccessContext` gets no `ToJSON`/`FromJSON` instance, though every leaf
  identifier does.
  Rationale: A serializable authorized decision can be written down, stored, and replayed against
  a grant that has since been revoked. EP-2 persists the space, actor, and owner — the facts —
  not the decision.
  Date: 2026-08-06


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

No implementation has started. The plan ends when downstream plans have an executable,
versioned conformance contract rather than only architecture prose.


## Context and Orientation

`kioku-api/src/Kioku/Api/Scope.hs` defines `Namespace` and `MemoryScope`; current commands and
queries use scope plus free-text `agentId`, but no outer tenant or authorization object exists.
Namespaces organize memory inside a deployment and must not become a security boundary.

The authoritative portfolio seams are:

- `mori://shinzui/meibo/docs/initial-spec` for canonical principals and credential linkage.
- `mori://shinzui/shomei/packages/shomei-servant` for authenticated claims and coarse
  role/scope guards.
- `mori://shinzui/en/packages/en-core` and `mori://shinzui/en/packages/en-servant` for object
  checks, lookup, caveats, and consistency modes.
- `mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-1` for the proposed portfolio
  principal and space vocabulary.

No relevant local ADR exists. This plan creates the first local ADRs because the boundary is
durable architecture, not task-local implementation detail.


## Plan of Work

### Milestone 1: verify dependency contracts

Use Mori to locate each dependency, then compare local source with upstream release tags and
the authoritative registry before selecting bounds. Read the actual claims, principal ID,
check/lookup, and consistency-token types. Confirm whether Kikan-En IR-1 has shipped. If it has
not, record a hard external dependency; Kioku may still define its neutral `MemorySpaceId`, but
must not guess a private En object/relationship schema or claim portfolio ACL compatibility.

Write a contract matrix in `docs/user/integrations.md`: the value received, its owner, how
Kioku uses it, and what Kioku must never infer.

### Milestone 2: define Kioku's neutral context types

Add `kioku-api/src/Kioku/Api/Access.hs`. Define opaque `MemorySpaceId` and `PrincipalRef` wire
types, `MemoryActor`, `MemoryOwner`, `MemoryPermission`, and `MemoryAccessContext`. The principal
wire form is exactly Meibo's canonical `principalIdText`; Kioku does not define a principal-kind
enum. Provide an adapter from released `meibo-api` only if that dependency is published and PVP
compatible; otherwise accept the opaque rendered ID at the boundary and validate it in the
portfolio adapter, not by copying Meibo's parser.

Keep the constructor that represents an authorized decision internal to the future service
adapter. Embedded hosts get an explicitly named `assumeAuthorizedMemoryContext` escape hatch so
trusted in-process use is possible and visible in code review.

### Milestone 3: pin the authorization mapping and conformance

Once the owner schema exists, map Kioku actions to En permissions, expected to cover read,
record, distill, forget, and administer/share. Define how exact object refs are formed and how
`AtLeastAsFresh` is forwarded after membership or grant writes. Add fixtures for direct person,
team membership, agent ownership, denied cross-space access, paused agent handling at the host
boundary, and a stale-decision retry.

Create ADRs under `docs/adr/` for the trust-triad boundary and legacy default-space policy.


## Concrete Steps

Run from the Kioku repository root:

```bash
mori registry show shinzui/meibo --full
mori registry show shinzui/shomei --full
mori registry show shinzui/en --full
mori registry show shinzui/kikan-en --full
mori path mori://shinzui/kikan-en/okf/improvement-requests/concepts/IR-1
nix develop -c cabal test kioku-api
```

Then run the conformance test introduced by this plan:

```bash
nix develop -c cabal test kioku-core --test-options='-p "Portfolio access contract"'
```

Expected cases include allowed direct access, allowed team-derived access, denied cross-space
access, and a forwarded freshness token.


## Validation and Acceptance

Acceptance requires:

- Person, team, and agent fixtures use real Meibo-form rendered IDs; Kioku defines no competing
  `UserId`, `TeamId`, `AgentKind`, membership, or lifecycle vocabulary.
- One authenticated Shomei subject resolves to a Meibo principal before any En check.
- The same namespace/scope in two memory spaces yields different En object refs and one cannot
  authorize the other.
- Coarse Shomei scope failure and En denial are distinct errors; neither is converted to an
  empty successful recall response.
- A conformance test demonstrates `AtLeastAsFresh` forwarding.
- Local ADRs state ownership, the legacy-space rule, and why namespace is not tenancy.


## Idempotence and Recovery

This plan is additive: it introduces types, fixtures, docs, and ADRs before domain/schema
migration. If a dependency has not released the required API, leave the relevant progress item
unchecked and record the exact missing contract. Do not vendor source or loosen bounds around an
unreleased feature. Re-running conformance is read-only outside its ephemeral test database.


## Interfaces and Dependencies

The public types should be equivalent to:

```haskell
newtype MemorySpaceId = MemorySpaceId Text
newtype PrincipalRef = PrincipalRef Text

data MemoryPermission
  = MemoryRead
  | MemoryRecord
  | MemoryDistill
  | MemoryForget
  | MemoryAdmin

data MemoryAccessContext = MemoryAccessContext
  { memorySpaceId :: MemorySpaceId
  , actorPrincipal :: PrincipalRef
  , decisionToken :: Maybe Text
  }
```

Exact field names may change during API review. The dependency direction must not: Kioku core
accepts a validated context; Shomei, Meibo, and En adapters produce it. The future HTTP service
IR owns the live Servant wiring.
