---
id: 13
slug: harden-schema-and-recall-with-indexes-constraints-and-scope-identity-fixes
title: "Harden schema and recall with indexes, constraints, and scope identity fixes"
kind: exec-plan
created_at: 2026-07-07T14:58:23Z
intention: "intention_01kwyhabypepdt1mwemmf0dvqa"
master_plan: "docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md"
---

# Harden schema and recall with indexes, constraints, and scope identity fixes

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.


## Purpose / Big Picture

kioku is an event-sourced agent memory and session library backed by Postgres. A 2026-07-07
review found that its read-model schema and its retrieval SQL are softer than they look: the
supersession-chain query does sequential scans on every recursion level because two columns it
recurses on have no index; the pgvector similarity query is written in a way that defeats the
HNSW index it was given (and even when the index is used, its default search width cannot fill
the candidate pool); two UNIQUE constraints silently enforce nothing for global-scope rows;
no table prevents a half-populated scope (kind set, ref missing) that is then misclassified;
two differently-scoped memories can collide onto the same scene/persona row because scope
identity strings are joined without escaping; a mis-set embedding-dimension environment
variable fails at runtime on every event instead of once at startup; and a one-shot
conditional migration leaves databases without pgvector permanently degraded — which, we
discovered, is the current state of this repository's own dev database.

After this plan, a user can: run `just migrate` on the dev database and watch it heal itself
into full pgvector capability; run `EXPLAIN` on the vector recall query and see the HNSW index
actually used; try to insert a second global-scope persona for the same namespace and get a
unique-violation instead of silent duplication; record memories under the scopes
`ScopeGlobal (Namespace "a/b/c")` and `ScopeEntity (Namespace "a") (ScopeKind "b") "c"` and
get two distinct scenes and personas instead of one corrupted row; start the worker with
`KIOKU_EMBEDDING_DIMENSIONS=512` against a 1536-dimension column and get one clear startup
error instead of a failure per event; and read, in `docs/user/recall.md` and in the haddocks,
exactly why recall treats a global scope as "search the whole namespace" while scoped reads
treat it as "rows with no entity scope".


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").

- [x] M1: mint the schema-hardening migration (indexes, NULLS NOT DISTINCT uniques, scope CHECKs, redundant-index drop) and touch `Migrations.hs` — `2026-07-11-17-35-11-kioku-schema-hardening.sql`
- [x] M1: add DB-level constraint and index tests (`kioku-core/test/Kioku/SchemaSpec.hs`) — 5 cases, all 5 fail without the migration and pass with it
- [x] M1: `cabal test all` green (93 passed, up from 88); `just migrate` applies cleanly on the dev DB and is a no-op on the second run
- [x] M2: add pgvector to the dev shell Postgres in `nix/haskell.nix` (pgvector 0.8.2; `pkgs.postgresql.dev` kept alongside for `libpq.pc`)
- [x] M2: mint the embedding-schema self-healing migration and touch `Migrations.hs` — `2026-07-11-17-45-43-kioku-embedding-schema-heal.sql`
- [x] M2: verify the dev DB heals — `embedding kiroku.vector(1536)` + `kioku_memories_embedding_hnsw` now exist after `just migrate`
- [x] M2: document the late-install remediation path in `docs/user/recall.md` (including the `public`-schema trap)
- [x] M3: fix the vector candidate ORDER BY — **and deliberately NOT add the `SET LOCAL hnsw.ef_search` over-fetch, which measurement showed is a recall regression** (see Decision Log supersession)
- [x] M3: export test seams (`selectFtsCandidates`, `selectVectorCandidates`, `vectorLiteral`) and add `RecallSqlSpec` DB tests — 6 cases; the vector round-trip is proven to genuinely run under pgvector and to skip loudly without it
- [x] M3: capture before/after `EXPLAIN` transcripts (below) — the real defect is narrower than the plan claimed
- [x] M4: extend the capability probe with dimension validation (`VectorDimensionMismatch`) — **and change the extension probe from `pg_extension` to `to_regtype('vector')`**, the search-path-aware question recall actually asks
- [x] M4: fail fast in the worker CLI on mismatch; add capability tests — verified live: `--backfill` exits 1 before touching an event, the continuous worker stays up and keeps firing timers
- [x] M5: add `Kioku.Distill.ScopeIdentity` (escaped identity, hash-suffixed slug) and rewire L2/L3 — `renderScope` survives only as the LLM prompt label, where collisions are cosmetic
- [x] M5: add `mkNamespace`/`mkScopeKind` validators in `kioku-api` and use them in the CLI scope parser
- [x] M5: mint the id-recompute migration for ambiguous scene/persona rows and touch `Migrations.hs` — `2026-07-11-18-18-36-kioku-scope-identity-recompute.sql`
- [x] M5: add scope-identity collision and legacy-id-stability tests — 5 cases; SQL and Haskell verified to derive byte-identical ids
- [x] M6: document global-scope semantics in `docs/user/recall.md` and haddocks on both query paths
- [x] Final: full `cabal build all && cabal test all` (106 passed, up from 88), `just migrate` clean and idempotent, retrospective written


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

- The repository's own dev database is already in the FINDING-7 degraded state. Probing it
  during plan research showed pgvector is not even installable and the embedding columns are
  absent, because `nix/haskell.nix` ships plain `pkgs.postgresql` without the pgvector
  extension package:

  ```text
  $ psql -d kioku -tAc "SELECT 1 FROM pg_available_extensions WHERE name='vector'"
  (no rows)
  $ psql -d kioku -tAc "SELECT column_name FROM information_schema.columns
                        WHERE table_schema='kiroku' AND table_name='kioku_memories'
                        AND column_name='embedding'"
  (no rows)
  ```

  This makes Milestone 2 (heal the schema) directly demonstrable on the dev DB, and it means
  no vector-path test currently runs against a real vector column anywhere.

- `hnsw.ef_search` defaults to 40, but `candidatePoolSize` in
  `kioku-core/src/Kioku/Recall.hs` is 50. Even if the HNSW index were used, an index scan
  could never return more than 40 candidates before filtering — the vector channel silently
  under-fills the RRF pool. The fix must raise `ef_search`, not just repair the ORDER BY.

- The dev Postgres is 17.10 (`psql --version`), so `UNIQUE NULLS NOT DISTINCT` (PostgreSQL
  15+) is available.

- `kioku-api`'s custom prelude genuinely uses the `lens` package
  (`import "lens" Control.Lens` in `kioku-api/src/Kioku/Prelude.hs`), but `generic-lens` and
  `uuid` are referenced nowhere in `kioku-api/src` — only a comment mentions generic-lens.
  Only those two dependencies are dead. (Their removal is owned by
  docs/plans/15-tighten-cli-and-api-surface-validation.md, which gates it on an
  implementation-time re-grep; recorded here as a discovery only.)

- The session chain CTE (`selectSessionChainStmt` in
  `kioku-core/src/Kioku/Session/ReadModel.hs`) recurses on
  `s.session_id = c.previous_session_id`, a primary-key lookup, so it is healthy. The
  seq-scan problem is specific to the *memory* supersession chain, whose recursive join has
  OR arms on the un-indexed `supersedes`/`superseded_by` columns.

Discovered during M1 implementation (2026-07-11):

- **The "Last touched" comment convention is load-bearing in a way its own wording hides,
  and this milestone tripped over it.** GHC's recompilation check is *content*-based, not
  mtime-based, so `touch`ing `Migrations.hs` — or `kioku-migrations.cabal`, which is what
  `just migrate` does — does **not** force Template Haskell to re-read `sql-migrations/`.
  Only an actual edit to the module's bytes does. Proving the M1 tests fail before the
  migration and pass after it required editing the comment *twice* (once to embed the
  directory without the new file, once to embed it with), and both intermediate `touch`
  runs silently reused a stale embed and reported a false failure. Evidence: with the
  migration file present on disk and `Migrations.hs` merely touched, `SchemaSpec` still
  reported `kioku_memories_supersedes_idx is missing`. `Data.FileEmbed.embedDir` registers
  the files it *found* as dependencies, so a newly added file is by construction not among
  them — the exact staleness hole
  docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md
  M3 exists to close. That plan should not assume `touch` is a workaround; it is not one.

- The constraint names the plan predicted from the DDL were exactly right
  (`kioku_scenes_namespace_scope_kind_scope_ref_scene_key_key`,
  `kioku_personas_namespace_scope_kind_scope_ref_key`), and both scene/persona upserts
  target the primary keys (`ON CONFLICT (scene_id)` / `(persona_id)`, `L2.hs:487` /
  `L3.hs:387`), so swapping the unique constraints disturbed neither.

- `pg_indexes.indexname` has PostgreSQL type `name` (OID 19), not `text` (OID 25), so a
  hasql `D.text` decoder on it fails with `UnexpectedColumnTypeStatementError 0 25 19`.
  `SchemaSpec` casts with `indexname::text`. Any sibling plan writing catalog queries
  through hasql needs the same cast.

- **`SchemaSpec` reads the SQLSTATE through a raw hasql connection, not through the kiroku
  `Store` effect, and it has to.** `Kiroku.Store.Error.mapTransactionUsageError` recognises
  23505 only on the event tables (`events_pkey`, `stream_events_pkey`); a unique violation
  on an *application* table falls through to `mapUsageError`, which reports it as
  `WrongExpectedVersion "<transaction>" AnyVersion (StreamVersion 0)` — the SQLSTATE is
  gone. A check violation (23514) does survive, as `UnexpectedServerError "23514" msg`.
  Any sibling plan asserting on constraint violations should connect raw rather than assert
  on `WrongExpectedVersion`.

- The full suite hit one flaky failure under load —
  `Failed to start ephemeral PostgreSQL: TimeoutError (ConnectionTimeout {durationSeconds = 60})`
  in `TimerWorkerSpec` — and passed on rerun (93/93). M1 added five more database-backed
  cases to a suite tasty runs concurrently with `-N`; the ephemeral-pg cluster count is now
  high enough to occasionally lose a 60-second startup race. Not a regression, but the
  remaining milestones add more DB tests and should expect it.

- The `just new-migration` recipe's own usage string said `just new-migration name=<slug>`,
  which `just` rejects (it parses `name=...` as the positional value and fails the
  `[a-z0-9-]` check). The working form is `just new-migration <slug>`; the usage string is
  corrected in this milestone's commit.

Discovered during M2 implementation (2026-07-11):

- **`pkgs.postgresql.withPackages` has a single `out` output and therefore silently drops
  the `dev` output**, which is what carries `lib/pkgconfig/libpq.pc`. Swapping
  `pkgs.postgresql` for the wrapper — the exact one-line change this plan specified — makes
  `cabal` fail to resolve *any* build plan:
  `rejecting: postgresql-libpq-pkgconfig-0.11 (conflict: pkg-config package libpq>=14.12,
  not found in the pkg-config database)`. The fix is to keep `pkgs.postgresql.dev` in
  `baseDevPackages` alongside the wrapper. This is a trap for any project doing the same
  swap, and it fails at dependency resolution, far from its cause.

- **The `public`-schema abort EP-3 predicted is real, and the root cause is deeper than the
  migration.** Reproduced on the dev DB: with pgvector in `public` and
  `search_path = kiroku, pg_catalog`, `CREATE EXTENSION IF NOT EXISTS vector` is a no-op,
  the `pg_extension` probe reports available, `to_regtype('vector')` is NULL, and
  `ALTER TABLE ... ADD COLUMN embedding vector(1536)` dies with
  `42704: type "vector" does not exist`. The heal migration schema-qualifies the type and
  the operator class with the extension's *actual* schema, so the DDL now succeeds under
  either layout.

  But the deeper problem is a **runtime** one that no migration can fix: the application
  connects with `search_path = kiroku, pg_catalog` (`Kiroku.Store.Connection` defaults
  `schema = "kiroku"`, `extraSearchPath = []`), and recall casts with a bare `$1::vector`.
  If pgvector lives anywhere but `kiroku`, that cast cannot resolve — so a database can have
  perfectly healthy embedding columns and an HNSW index and *still* fail every vector query.
  The migration raises a `WARNING` naming the schema and the two remedies (move the
  extension, or add the schema to `extraSearchPath`); `docs/user/recall.md` documents both.
  **This changes M4's design:** capability detection currently probes `pg_extension`, which
  answers "does the extension exist *somewhere*" — the wrong question. It must ask
  "can *this connection* name the type", i.e. `to_regtype('vector') IS NOT NULL`, so an
  unreachable extension degrades to keyword recall instead of erroring on every query.

- The fresh install lands in `kiroku` (verified: `CREATE EXTENSION IF NOT EXISTS vector`
  under the migration's search_path puts it there, and `to_regtype('vector')` then
  resolves), so the dev DB and every ephemeral test cluster get the good layout.

- `atttypmod` on the healed column is exactly `1536` and `format_type` renders
  `kiroku.vector(1536)` — M4's dimension-probe assumption verified on real data.

- **EP-3's inherited landmine is disarmed.** `DistillSpec`'s `testRecallCandidateWindow`
  asserted `capability @?= VectorExtensionUnavailable`, hard-coding the *absence* of
  pgvector, which stops being true the moment the dev shell gains it. It now *injects*
  `VectorExtensionUnavailable` instead of probing the cluster: the case is about the
  candidate finder reaching a duplicate the priority-scan window hides, and nothing about
  vectors. Pinning the keyword plan is what makes `dummyEmbeddingModel` safe — by
  construction now, rather than by luck of the environment.

- The dev shell's pgvector is **0.8.2**, so `hnsw.iterative_scan` *is* available. The plan's
  decision not to adopt it (to avoid pinning a minimum pgvector version) still stands, but
  the option is live in this environment rather than hypothetical.

- **Tests only see pgvector inside the new dev shell.** `ephemeral-pg` takes `initdb`/
  `postgres` from `PATH`, so a shell entered before this change still spins up clusters
  without the extension. The suite is green either way (93/93 in both), which is the
  designed degradation — but any vector-path assertion must be run under
  `nix develop --command cabal test all`, or it will silently skip.

Discovered during M3 implementation (2026-07-11) — **the milestone's central premise was
wrong, and the prescribed fix was half harmful:**

- **The `created_at DESC` tiebreak does not defeat the HNSW index on PostgreSQL 17.** The
  plan asserted a seq-scan-plus-sort; the real plan, on 2000 embedded rows, is:

  ```text
  ### BEFORE — the shipped query: ORDER BY distance, created_at DESC
  Limit
    ->  Incremental Sort
          Sort Key: ((embedding <=> '[VEC]'::vector)), created_at DESC
          Presorted Key: ((embedding <=> '[VEC]'::vector))
          ->  Index Scan using kioku_memories_embedding_hnsw on kioku_memories
                Order By: (embedding <=> '[VEC]'::vector)
                Filter: ((status = 'active') AND (namespace = 'explain_ns'))
  ```

  PostgreSQL 13+ supplies the second key with an `Incremental Sort` on top of the index's
  presorted leading key. The fix still lands the intended plan —

  ```text
  ### AFTER — ORDER BY distance only
  Limit
    ->  Index Scan using kioku_memories_embedding_hnsw on kioku_memories
          Order By: (embedding <=> '[VEC]'::vector)
          Filter: ((status = 'active') AND (namespace = 'explain_ns'))
  ```

  — and it is still worth making, because index use with the second key is *contingent* on
  incremental sort. With `SET enable_incremental_sort = off` (i.e. PostgreSQL < 13, or a
  planner that declines it) the BEFORE query collapses to precisely the disaster the plan
  described, `Limit → Sort → Seq Scan`, while the AFTER query keeps its `Index Scan`. So the
  change converts a conditional index scan into an unconditional one. That is the honest
  scope of this fix: robustness, not a rescue.

- **`SET LOCAL hnsw.ef_search = 200` is a recall regression and was not shipped.** Two
  measurements killed it.

  Its premise — "`ef_search` defaults to 40, below the 50-row pool, so the vector channel can
  never fill it" — is false: pgvector searches with `ef = max(ef_search, LIMIT)`, and the
  pool filled to exactly 50 at the default in every probe.

  Worse, raising it changes the *plan*, not just the scan width. Seeded with 2000 rows in the
  target namespace plus 2000 decoys in another namespace sitting almost exactly on the query
  vector (the filtered-ANN worst case, since the scope filter is applied *after* the index
  scan):

  ```text
  ### DEFAULT ef_search
  Limit (actual rows=50)                         <- correct
    ->  Sort (top-N heapsort)
          ->  Bitmap Heap Scan on kioku_memories (actual rows=2000)
                ->  Bitmap Index Scan on kioku_memories_scope_idx

  ### ef_search = 200
  Limit (actual rows=0)                          <- the vector channel returns NOTHING
    ->  Index Scan using kioku_memories_embedding_hnsw (actual rows=0)
          Rows Removed by Filter: 1648
  ```

  The default keeps an *exact* plan; the bump lures the planner onto an ANN scan that burns
  its whole budget on rows the namespace filter then discards. Shipping this would have
  silently emptied the vector channel precisely when the corpus is large and the scope is
  selective. `hnsw.iterative_scan = relaxed_order` — the remedy the plan named as a future
  option — **also returned 0 rows** on the same probe, so it is not a drop-in either. The
  hazard is documented at `candidatePoolSize` and left to a follow-up with its own
  investigation.

  **Cross-plan lesson, and it rhymes with EP-4's:** this plan's Decision Log reasoned about
  a query planner from first principles and got both the failure mode and the remedy wrong.
  Neither error would have survived one `EXPLAIN ANALYZE` on seeded data. Any remaining plan
  that prescribes a *performance* change should measure the plan before and after on real
  rows, not reason about pathkeys.

- **A partial index needs its predicate restated in the query.** `ORDER BY embedding <=> …
  LIMIT 50` with no `embedding IS NOT NULL` gets a seq scan; the index is
  `WHERE embedding IS NOT NULL`, so the planner must be able to prove the query implies it.
  Recall's statement already carries that predicate, but it is load-bearing, not decoration.

- **Rows inserted in an open transaction do not get an HNSW index scan**, even with
  `enable_seqscan = off` and a fresh `ANALYZE`. Every EXPLAIN in this milestone therefore ran
  against committed data. Anyone reproducing this in a `BEGIN … ROLLBACK` block will see a
  seq scan and draw the wrong conclusion — as this milestone's first three attempts did.

- **M2's pgvector gave several existing tests their first real run.** In the pgvector shell
  the suite reports no skips at all; without it, `EmbeddingWorkerSpec` prints
  `[skipped: provider failure]`, `[skipped: successful embedding]` and
  `[skipped: dimension mismatch]`. Those cases have been passing vacuously. `RecallSqlSpec`'s
  vector round-trip follows the same house convention and says so out loud rather than
  skipping silently — verified in both directions by temporarily converting the skip into a
  failure: it fires in the old shell and does not in the new one.


## Decision Log

Record every decision made while working on the plan.

- Decision: Enforce global-scope uniqueness with `UNIQUE NULLS NOT DISTINCT`, not a coalesced
  expression index.
  Rationale: NULLS NOT DISTINCT keeps a real table constraint (usable by future
  `ON CONFLICT` targets and visible in `\d`), whereas a `COALESCE(...)` expression index
  hides the rule and cannot be targeted by name. It requires PostgreSQL 15+; the dev shell
  pins nixpkgs' default `pkgs.postgresql`, currently 17.10 (verified with `psql --version`),
  and PostgreSQL 15 is recorded as the project's minimum supported server from this plan on.
  Date: 2026-07-07

- Decision: Do not change recall's global-scope behavior; document it. Global scope in
  *recall* means "search every active row in the namespace"; global scope in *scoped reads*
  (`getActiveByScope`, scene/persona lookups) means "exactly the rows with no entity scope".
  We name these "namespace-wide recall" and "exact-scope reads".
  Rationale: MasterPlan decision (docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md);
  the broad semantics is recorded as intentional in
  docs/plans/2-kioku-hybrid-retrieval-pgvector-fts-rrf.md and hosts (rei, mori, shikigami)
  may depend on it. The defect is the lack of documentation, not the behavior.
  Date: 2026-07-07

- Decision: Fix the vector query by removing `created_at DESC` from its ORDER BY entirely
  (no Haskell-side tiebreak) and raising the HNSW search width with
  `SET LOCAL hnsw.ef_search = 200` inside the candidate-selection transaction.
  Rationale: the secondary sort key breaks pathkey matching, forcing a full sort over a seq
  scan. The statement does not return the distance, so Haskell cannot re-tiebreak equal
  distances; exact distance ties are vanishingly rare with 1536-dimension floats and RRF
  fusion is robust to tie order. `ef_search = 200` (4x the 50-row pool) is the standard
  mitigation for the filtered-ANN caveat: the index yields up to 200 nearest tuples, the
  namespace/scope/status filters then thin them, and the LIMIT can still be met. pgvector
  0.8's `hnsw.iterative_scan = relaxed_order` would remove the truncation entirely but pins a
  minimum pgvector version and changes result order guarantees; it is documented as a future
  option, not adopted.
  Date: 2026-07-07
  **SUPERSEDED 2026-07-11 during M3, in its second half only — both stated premises were
  measured and both are false.** See the evidence in Surprises & Discoveries (M3). In short:
  (1) pgvector already searches with `ef = max(ef_search, LIMIT)`, so the 40 default does
  *not* prevent the 50-row pool from filling — it filled to 50 in every measurement; and
  (2) raising it is not a neutral over-fetch, it changes the *plan*: with 2000 target rows
  and 2000 nearer decoys in another namespace, `SET hnsw.ef_search = 200` moved the planner
  off an exact plan returning 50 correct rows onto an HNSW scan that spent its budget on
  rows the namespace filter then discarded — 1648 removed, **zero returned**. Shipping it
  would have silently emptied the vector channel exactly when the corpus is large and the
  scope is selective, which is when recall matters most.

- Decision (supersedes the `ef_search` half of the above): remove `created_at DESC`; do
  **not** set `hnsw.ef_search`. Document the filtered-ANN starvation hazard where
  `candidatePoolSize` is defined, and leave `hnsw.iterative_scan` to a follow-up.
  Rationale: the ORDER BY fix survives scrutiny, though for a narrower reason than the plan
  gave — the index is *not* defeated on PostgreSQL 17, which bolts an `Incremental Sort` onto
  the index scan to supply the second key. It *is* defeated wherever incremental sort is
  unavailable (PostgreSQL < 13) or not chosen, where the plan collapses to `Seq Scan` + full
  `Sort` exactly as the plan predicted. Removing the second key makes index use unconditional
  instead of contingent, costs nothing (the statement does not return distances, so no caller
  could tiebreak on them), and measured neutral-to-better in every plan shape tried. The
  starvation hazard is real but *pre-existing* and not something the ORDER BY fix introduces;
  `hnsw.iterative_scan = relaxed_order` is the intended remedy but is not a drop-in — it also
  returned zero rows on the same probe — so it needs its own investigation rather than a
  hopeful `SET`.
  Date: 2026-07-11

- Decision: Scope-identity strings become collision-free by percent-escaping each component
  (`%` -> `%25`, `/` -> `%2F`, `:` -> `%3A`) before joining, instead of rejecting `/` in
  refs or switching row ids to UUIDv5.
  Rationale: refs are host-controlled free text and legitimately contain `/` (repo-style refs
  such as `shinzui/kikan`; shikigami uses arbitrary agent names as refs —
  `agentScope` in shikigami's `Shikigami/Memory/Scope.hs`), so rejection would break hosts.
  Percent-escaping is injective per component, so distinct scopes can never render the same
  identity. Crucially, components containing none of `%/:`, which is every well-formed scope
  observed in hosts and docs (`rei:intention:intention_abc`, `mori:repo:web`, ...), produce
  byte-identical ids to the current derivation — existing scene/persona rows stay valid with
  no mass migration. UUIDv5 ids would orphan every existing row.
  Date: 2026-07-07

- Decision: Migration strategy for persisted deterministic ids: one idempotent migration
  recomputes `scene_id`/`persona_id` only for rows whose namespace/kind/ref contain `%`,
  `/`, or `:` (the ambiguous encodings). Rows that had already collided keep the scope stored
  in their columns — i.e. they remain attributed to the first writer — and the second scope's
  scene/persona simply regenerates under its now-distinct id on the next distillation timer.
  Rationale: unambiguous ids are byte-stable (previous decision), so most databases have
  nothing to rewrite. For genuinely collided rows the row's scope columns are the only truth
  available; the second scope's content is regenerable from its memories, so regeneration —
  not forensic splitting — is the correct recovery.
  Date: 2026-07-07

- Decision: Mirror-file slugs gain a 10-hex-character SHA-256 suffix of the escaped scope
  identity for *all* scopes (e.g. `rei-intention-intention_abc-3f2a9c81d0.md`), accepting
  that every existing mirror filename changes once.
  Rationale: the sanitizer maps every unsafe character to `-`, so `ns "a-b"` and
  `ns "a", kind "b"` collide and no "only when ambiguous" rule can detect collisions locally.
  Mirror files are best-effort regenerated caches under `.kioku/` in a workspace, not
  identity-bearing records; a one-time rename is acceptable and stale old-name files are
  harmless leftovers (docs/plans/10-propagate-memory-forget-operations-to-scenes-personas-and-workspace-mirrors.md
  owns deletion machinery and will compute paths through these same functions).
  Date: 2026-07-07

- Decision: `Namespace` and `ScopeKind` get validating smart constructors
  (`mkNamespace`, `mkScopeKind`: non-empty, none of `%`, `/`, `:`) in
  `kioku-api/src/Kioku/Api/Scope.hs`, used by the CLI scope parser; the raw newtype
  constructors remain exported. Refs stay unconstrained.
  Rationale: namespaces and kinds are label vocabularies ("rei", "mori", "shikigami";
  "intention", "repo", "agent") and nothing legitimate needs those characters, so validation
  there is cheap defense-in-depth on top of escaping. Hiding the constructors would break
  compiling hosts (shikigami constructs `Namespace "shikigami"` directly). The broader
  CLI/API validation sweep belongs to
  docs/plans/15-tighten-cli-and-api-surface-validation.md, which can adopt these
  constructors.
  Date: 2026-07-07

- Decision: `detectVectorCapability` changes signature to take the configured embedding
  dimensions (`Int`) and gains a `VectorDimensionMismatch !Int !Int` variant (configured,
  actual). On mismatch: `kioku worker --backfill` exits non-zero with a one-line explanation;
  the continuous worker prints the same error and runs the timer loop only (no embedding
  host); recall degrades to keyword exactly like the other unavailable states.
  Rationale: a dimension mismatch is a configuration error that would otherwise fail on
  every single event. Killing the whole continuous worker would also stop distillation
  timers, which are unrelated to embeddings, so the worker stays up but is loud. The
  signature change is internal; the three call sites are all in `kioku-cli`.
  Date: 2026-07-07

- Decision: Add pgvector to the dev shell Postgres
  (`pkgs.postgresql` -> `(pkgs.postgresql.withPackages (ps: [ ps.pgvector ]))` in
  `nix/haskell.nix`), and write vector-dependent tests to probe `pg_available_extensions`
  and skip vector-only assertions when the extension is absent.
  Rationale: without this, the healing migration (M2) has nothing to heal against in dev,
  the EXPLAIN verification (M3) is impossible, and no test can ever touch a real vector
  column (ephemeral-pg uses the same `postgres` binaries from PATH). Skipping keeps the
  suite green in environments without pgvector, which remains a supported degradation.
  Date: 2026-07-07

- Decision: The self-healing embedding migration re-runs the same guarded DO block as the
  original 2026-06-24-01-00-00 migration. Databases where pgvector arrives *after* this
  migration has been recorded are healed by a documented psql remediation (same DO block,
  run manually) added to `docs/user/recall.md`, not by yet another migration.
  Rationale: codd records each migration once; we cannot re-run recorded migrations, and
  minting an endless series of "retry" migrations does not converge. One catch-up migration
  fixes every database that migrates after gaining the extension (including our dev DB);
  the documented manual path covers stragglers and is byte-identical SQL, so it cannot
  drift from the migration.
  Date: 2026-07-07

- Decision: This plan owns all schema indexes (including dropping the redundant
  `kioku_turns_session_idx`), but it does NOT add a `kioku_sessions.previous_session_id`
  index.
  Rationale: MasterPlan integration constraint concentrates index DDL here to avoid two
  plans minting conflicting index migrations. The `previous_session_id` index was originally
  planned for
  docs/plans/12-enforce-aggregate-invariants-for-lineage-resume-correlation-and-idempotent-commands.md,
  but that plan's research showed `getChain`'s recursive join resolves through the
  `kioku_sessions` primary key (`s.session_id = c.previous_session_id` probes the PK), and
  its lineage validation is pure command-time checking with no query on
  `previous_session_id` — the index would be pure write amplification, the same defect this
  plan removes in `kioku_turns_session_idx`. Add it later only if a real reverse-chain query
  appears.
  Date: 2026-07-07


## Outcomes & Retrospective

All six milestones landed (commits `830a1d4`, `312769a`, `3a3f1e5`, `939cf8f`, `cdbd1f0`,
plus this one). The suite went from 88 to 106 tests, and — for the first time — the
vector-dependent ones actually execute rather than skipping vacuously.

Measured against the Purpose section's promises, one by one:

- *"run `just migrate` and watch the dev database heal itself into full pgvector
  capability"* — done, and it is the outcome I am most confident in because the degraded
  state was real, not hypothetical: `kioku_memories.embedding` went from absent to
  `kiroku.vector(1536)` with an HNSW index, and `kioku worker --backfill` now embeds
  (3 memories on its first real run).
- *"try to insert a second global-scope persona and get a unique violation"* — done
  (23505 on `kioku_personas_scope_unique`), along with the half-populated-scope CHECK
  (23514). Both are asserted by `SchemaSpec`, which fails against the pre-migration schema.
- *"record memories under `ScopeGlobal (Namespace "a/b/c")` and
  `ScopeEntity (Namespace "a") (ScopeKind "b") "c"` and get two distinct scenes and
  personas"* — done, and the migration's SQL derivation was cross-checked against the
  Haskell one on a real row: both produce `kioku_scene:a%2Fb%2Fc:default`.
- *"start the worker with `KIOKU_EMBEDDING_DIMENSIONS=512` against a 1536-dimension column
  and get one clear startup error"* — done, verified live in both directions: `--backfill`
  exits 1 before touching an event; the continuous worker prints the mismatch and keeps
  firing distillation timers.
- *"read exactly why recall treats a global scope as 'search the whole namespace'"* — done
  in `docs/user/recall.md` and in haddocks on all four query paths.
- *"run `EXPLAIN` and see the HNSW index actually used"* — **done, but the finding is not
  what the plan expected, and this is the milestone's real story.** See below.

**What went wrong, and what it should teach the remaining plans.** M3's premise was wrong
in both halves, and neither error would have survived a single `EXPLAIN ANALYZE` on seeded
rows:

1. The plan said the `created_at DESC` tiebreak *defeats* the HNSW index, forcing a seq
   scan. On PostgreSQL 17 it does not — the planner supplies the second key with an
   `Incremental Sort` over the index scan. The fix is still right, but its value is
   robustness (index use becomes unconditional rather than contingent on incremental sort,
   which does not exist before PostgreSQL 13), not rescue. Claiming otherwise in the commit
   message would have been a lie.
2. The plan prescribed `SET LOCAL hnsw.ef_search = 200`. **Shipping that would have been a
   recall regression**, and it was not shipped. Its premise (the 40 default cannot fill a
   50-row pool) is false — pgvector searches with `ef = max(ef_search, LIMIT)` — and the
   change is not a neutral over-fetch: on seeded data it moved the planner off an exact
   plan returning 50 correct rows onto an ANN scan that spent its budget on rows the scope
   filter discarded, returning **zero**. A plan that reasons about a query planner from
   first principles should be treated as a hypothesis, not an instruction.

The gap this leaves: **filtered-ANN starvation is real, reproducible, and still unfixed.**
It predates this work — the ORDER BY change neither causes nor cures it — and pgvector 0.8's
`hnsw.iterative_scan` is *not* the drop-in remedy the plan assumed (`relaxed_order` returned
zero rows on the same probe). It is documented at `candidatePoolSize` with the repro, and it
deserves its own plan rather than a hopeful `SET`.

Two smaller gaps worth naming rather than burying:

- The suite's ephemeral-Postgres clusters now lose a 60-second startup race often enough to
  matter: four full-suite runs during this plan failed on
  `TimeoutError (ConnectionTimeout {durationSeconds = 60})` and passed on rerun (a failing
  run takes ~65s, a healthy one ~15s). M1 added 5 database-backed cases and M3/M4 added 7
  more, to a suite tasty already runs concurrently with `-N`. This is contention, not a
  regression, but it makes "green" cost a rerun. Capping tasty's thread count would likely
  fix it; that was left alone deliberately, since throttling concurrency can also mask real
  races.
- `nix/haskell.nix` is marked seihou-managed, and M2 edited it anyway. There was no
  alternative: `extraDevPackages` is appended *after* `baseDevPackages`, so a
  pgvector-enabled postgres added there would lose the PATH race to the plain one. If seihou
  regenerates the file, the pgvector line and the `pkgs.postgresql.dev` line beside it must
  be reapplied together, or the dev shell silently loses either pgvector or `libpq.pc`.


## Context and Orientation

kioku is a Haskell workspace with four packages: `kioku-api` (wire types: scopes, ids,
prelude), `kioku-core` (domain logic, read models, recall, distillation), `kioku-cli` (the
`kioku` executable), and `kioku-migrations` (SQL migrations embedded into the binary at
compile time). Events are stored by the `kiroku` event-store library; *read models* —
ordinary Postgres tables that projections keep up to date — live in the `kiroku` schema of
the application database. Migrations are applied by codd (a migration tool that orders `.sql`
files by their timestamped filenames and records each as applied exactly once); the files
live in `kioku-migrations/sql-migrations/` and are embedded via Template Haskell in
`kioku-migrations/src/Kioku/Migrations.hs`. Because Template Haskell only re-reads the
directory when that module recompiles, the file carries a "Last touched" comment that must be
edited whenever a migration file is added (until
docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md
lands its staleness guard, this comment-touch is mandatory). New migrations are scaffolded
with `just new-migration name=<slug>`, which mints a fresh UTC timestamp filename; `just
migrate` applies everything to the dev database. Tests spin up throwaway Postgres clusters
via the `ephemeral-pg` library and apply all migrations through
`Kioku.Migrations.TestSupport.withKiokuMigratedDatabase`
(`kioku-migrations/test-support/Kioku/Migrations/TestSupport.hs`); the tasty suite is
`kioku-test` in `kioku-core/kioku-core.cabal`, run by `cabal test all`.

A *memory scope* (`kioku-api/src/Kioku/Api/Scope.hs`) is either `ScopeGlobal Namespace`
(namespace-wide, stored as `scope_kind = NULL, scope_ref = NULL`) or
`ScopeEntity Namespace ScopeKind Text` (anchored to an entity, both columns set). Five
tables carry the `(namespace, scope_kind, scope_ref)` triple: `kioku_memories`,
`kioku_sessions` (created in
`kioku-migrations/sql-migrations/2026-06-24-00-00-00-kioku-base.sql`), and `kioku_scenes`,
`kioku_personas`, `kioku_consolidation_decisions`
(`2026-06-24-02-00-00-kioku-distillation.sql`). `scopeFromColumns` (Scope.hs:45-47) treats
anything that is not (Just, Just) as global — so a half-populated row (kind set, ref NULL) is
misclassified as global on read yet matches no exact-scope query.

Recall (`kioku-core/src/Kioku/Recall.hs`) runs up to two candidate queries — full-text
(`selectFtsCandidatesStmt`, :365-381) and vector (`selectVectorCandidatesStmt`, :383-399) —
then fuses them with reciprocal-rank fusion. Both use the scope predicate
`(($3 IS NULL AND $4 IS NULL) OR (scope_kind = $3 AND scope_ref = $4))`: for a global scope
the parameters are NULL, the first disjunct is always true, and the query searches the whole
namespace. The exact-scope read-model queries (`kioku-core/src/Kioku/Memory/ReadModel.hs`
:363, and the scene/persona lookups in `Kioku/Distill/L2.hs` and `L3.hs`) instead require
NULL columns for a global scope. This asymmetry is intentional
(docs/plans/2-kioku-hybrid-retrieval-pgvector-fts-rrf.md, "The scope predicate" note around
line 714) but documented nowhere user-facing.

The vector column is `embedding vector(1536)` with a partial HNSW index
`kioku_memories_embedding_hnsw ... WHERE embedding IS NOT NULL`
(`2026-06-24-01-00-00-kioku-memory-embeddings.sql`), created only if
`CREATE EXTENSION vector` succeeds inside a one-shot DO block — if it fails, codd still
records the migration as applied and the schema is permanently degraded. The configured
dimension count comes from `KIOKU_EMBEDDING_DIMENSIONS`
(`kioku-core/src/Kioku/Memory/Embedding.hs:44`, default 1536) and is never checked against
the column. Capability detection (`kioku-core/src/Kioku/Recall/Capability.hs`) probes only
extension and column *existence*. The embedding worker
(`kioku-core/src/Kioku/Memory/Embedding/Worker.hs:249-259`) upserts
`embedding = $2::vector` per event, which is where a mismatch would explode.

Distillation derives deterministic row identities from scopes:
`sceneRowId scope = "kioku_scene:" <> renderScope scope <> ":" <> sceneKey`
(`kioku-core/src/Kioku/Distill/L2.hs:275-277`),
`personaRowId scope = "kioku_persona:" <> renderScope scope` (`L3.hs:243-245`), where
`renderScope` joins namespace/kind/ref with `/` and no escaping (L2.hs:302-305,
L3.hs:263-266). Timer ids are UUIDv5 over strings containing `renderScope` (L2.hs:122-134,
L3.hs:103-115), and workspace mirror files are named by a `-`-joined sanitized slug
(L2.hs:256-273, L3.hs:224-241). Because the components are unconstrained Text,
`ScopeGlobal (Namespace "a/b/c")` and `ScopeEntity (Namespace "a") (ScopeKind "b") "c"` both
render `a/b/c` — the same persona id — and the upserts (`upsertSceneStmt` L2.hs:391-407,
`upsertPersonaStmt` L3.hs:345-360) do not update scope columns on conflict, so the second
scope's body lands on a row still attributed to the first (cross-scope data bleed), and
colliding slugs make one scope's mirror file overwrite another's.

The dev environment (`nix/haskell.nix`) provides Postgres 17.10 via `pkgs.postgresql`
*without* the pgvector extension package, and `process-compose.yaml` starts it with
`pg_ctl`. Consequently the dev database is currently in the degraded no-vector state.


## Plan of Work

The work is six milestones. Each mints at most one migration file (fresh timestamp via
`just new-migration`), keeps every function signature that sibling plans consume stable, and
is independently verifiable with `cabal test all` plus the psql checks listed under
Validation. All Haskell file paths below are repository-relative.


### Milestone 1: Schema-hardening migration — chain and session indexes, NULLS NOT DISTINCT uniqueness, scope-pairing CHECKs

Scope: one new migration file plus a new DB test module. At the end, the memory
supersession chain and the session list queries have real indexes, duplicate global-scope
scenes/personas are impossible, half-populated scope pairs are impossible, the redundant
turns index is gone, and the lineage index requested by
docs/plans/12-enforce-aggregate-invariants-for-lineage-resume-correlation-and-idempotent-commands.md
exists.

Run `just new-migration name=kioku-schema-hardening` from the repository root. It creates
`kioku-migrations/sql-migrations/<UTC-timestamp>-kioku-schema-hardening.sql` with the
`-- codd: in-txn` header and `SET search_path TO kiroku, pg_catalog;`. Fill it with, in
order:

First, data repair so the constraints can be added on non-empty databases (all idempotent,
no-ops on fresh DBs). Normalize half-populated scope pairs to fully NULL — this matches what
`scopeFromColumns` already reports for such rows at read time, so observable behavior does
not change:

```sql
UPDATE kioku_memories SET scope_kind = NULL, scope_ref = NULL
 WHERE (scope_kind IS NULL) <> (scope_ref IS NULL);
UPDATE kioku_sessions SET scope_kind = NULL, scope_ref = NULL
 WHERE (scope_kind IS NULL) <> (scope_ref IS NULL);
UPDATE kioku_scenes SET scope_kind = NULL, scope_ref = NULL
 WHERE (scope_kind IS NULL) <> (scope_ref IS NULL);
UPDATE kioku_personas SET scope_kind = NULL, scope_ref = NULL
 WHERE (scope_kind IS NULL) <> (scope_ref IS NULL);
UPDATE kioku_consolidation_decisions SET scope_kind = NULL, scope_ref = NULL
 WHERE (scope_kind IS NULL) <> (scope_ref IS NULL);
```

Then dedupe scenes and personas treating NULLs as equal, keeping the newest row per logical
scope (only NULL-scoped duplicates can exist — the old constraints already blocked non-NULL
ones):

```sql
DELETE FROM kioku_scenes doomed
 USING kioku_scenes keeper
 WHERE doomed.namespace = keeper.namespace
   AND doomed.scope_kind IS NOT DISTINCT FROM keeper.scope_kind
   AND doomed.scope_ref  IS NOT DISTINCT FROM keeper.scope_ref
   AND doomed.scene_key = keeper.scene_key
   AND (doomed.updated_at, doomed.scene_id) < (keeper.updated_at, keeper.scene_id);

DELETE FROM kioku_personas doomed
 USING kioku_personas keeper
 WHERE doomed.namespace = keeper.namespace
   AND doomed.scope_kind IS NOT DISTINCT FROM keeper.scope_kind
   AND doomed.scope_ref  IS NOT DISTINCT FROM keeper.scope_ref
   AND (doomed.updated_at, doomed.persona_id) < (keeper.updated_at, keeper.persona_id);
```

Then swap the NULL-blind unique constraints for NULLS NOT DISTINCT ones (PostgreSQL 15+;
the inline `UNIQUE (...)` table constraints in the distillation migration got the default
names shown here — verify with `\d kiroku.kioku_scenes` if in doubt):

```sql
ALTER TABLE kioku_scenes
  DROP CONSTRAINT IF EXISTS kioku_scenes_namespace_scope_kind_scope_ref_scene_key_key;
ALTER TABLE kioku_scenes
  ADD CONSTRAINT kioku_scenes_scope_scene_key_unique
  UNIQUE NULLS NOT DISTINCT (namespace, scope_kind, scope_ref, scene_key);

ALTER TABLE kioku_personas
  DROP CONSTRAINT IF EXISTS kioku_personas_namespace_scope_kind_scope_ref_key;
ALTER TABLE kioku_personas
  ADD CONSTRAINT kioku_personas_scope_unique
  UNIQUE NULLS NOT DISTINCT (namespace, scope_kind, scope_ref);
```

(To keep re-application safe despite `ADD CONSTRAINT` lacking `IF NOT EXISTS`, precede each
`ADD` with `DROP CONSTRAINT IF EXISTS <new name>` as well.)

Then the scope-pairing CHECK on all five tables (same drop-then-add idempotence pattern;
one shown, repeat for `kioku_sessions`, `kioku_scenes`, `kioku_personas`,
`kioku_consolidation_decisions`):

```sql
ALTER TABLE kioku_memories DROP CONSTRAINT IF EXISTS kioku_memories_scope_pair_check;
ALTER TABLE kioku_memories ADD CONSTRAINT kioku_memories_scope_pair_check
  CHECK ((scope_kind IS NULL) = (scope_ref IS NULL));
```

Finally the indexes:

```sql
CREATE INDEX IF NOT EXISTS kioku_memories_supersedes_idx
  ON kioku_memories (supersedes) WHERE supersedes IS NOT NULL;
CREATE INDEX IF NOT EXISTS kioku_memories_superseded_by_idx
  ON kioku_memories (superseded_by) WHERE superseded_by IS NOT NULL;
CREATE INDEX IF NOT EXISTS kioku_sessions_namespace_started_idx
  ON kioku_sessions (namespace, started_at DESC);
CREATE INDEX IF NOT EXISTS kioku_sessions_namespace_focus_idx
  ON kioku_sessions (namespace, focus, started_at DESC);
DROP INDEX IF EXISTS kioku_turns_session_idx;
```

The first two serve the recursive supersession CTE
(`selectSupersessionChainStmt`, `kioku-core/src/Kioku/Memory/ReadModel.hs:432-452`), whose
join arms `m.supersedes = c.memory_id OR m.superseded_by = c.memory_id` currently force a
seq scan per recursion level (the other two arms hit the primary key). The
`(namespace, started_at DESC)` index serves `selectSessionsByNamespaceStmt` and
`selectSessionsByStartedRangeStmt`; `(namespace, focus, started_at DESC)` serves
`selectSessionsByFocusStmt` (all in `kioku-core/src/Kioku/Session/ReadModel.hs:349-423`,
which today sort entire namespaces). `kioku_turns_session_idx` duplicates the index implied
by `UNIQUE (session_id, turn_index)` (base migration :68 vs :71). No
`previous_session_id` index is added: the session chain CTE joins through the primary key,
and docs/plans/12-enforce-aggregate-invariants-for-lineage-resume-correlation-and-idempotent-commands.md
validates lineage with pure command-time checks that never query that column (see Decision
Log).

Edit `kioku-migrations/src/Kioku/Migrations.hs` and update the comment above
`embeddedKiokuFiles` (line 57-59) to `Last touched: <today> schema hardening migration.` so
Template Haskell re-embeds the directory.

Add `kioku-core/test/Kioku/SchemaSpec.hs` (register in `kioku-core/kioku-core.cabal`
`other-modules` and in `kioku-core/test/Main.hs`), following the
`withKiokuMigratedDatabase`-plus-`withStore` pattern of
`kioku-core/test/Kioku/SessionLineageSpec.hs`. Using raw hasql sessions against `connStr`,
assert: inserting two `kioku_scenes` rows with the same namespace, NULL kind/ref, and same
`scene_key` raises SQLSTATE 23505 (unique violation); same for two NULL-scoped
`kioku_personas` rows in one namespace; inserting a `kioku_memories` row with
`scope_kind = 'x', scope_ref = NULL` raises 23514 (check violation); and
`SELECT indexname FROM pg_indexes WHERE schemaname='kiroku'` contains the five new index
names and no longer contains `kioku_turns_session_idx`.

Acceptance: `cabal test all` green (new tests fail against the pre-migration schema — you
can prove this by running them before adding the migration file); `just migrate` applies the
migration to the dev DB without error and re-running `just migrate` is a no-op.


### Milestone 2: pgvector in the dev shell and a self-healing embedding-schema migration

Scope: a one-line nix change plus one new migration. At the end, the dev database — which is
currently degraded (no pgvector, no embedding columns) — heals itself on `just migrate`, and
any database that gains the pgvector extension before its next migration run heals likewise.

In `nix/haskell.nix`, in `baseDevPackages`, replace `pkgs.postgresql` with
`(pkgs.postgresql.withPackages (ps: [ ps.pgvector ]))`. Re-enter the dev shell and restart
Postgres (`pg_ctl stop -D $PGDATA` then restart via process-compose or
`pg_ctl start -w -l $PGLOG -o "--unix_socket_directories='$PGHOST'" -o "-c listen_addresses=''"`)
so the server binaries with the vector extension are running. The data directory is
unchanged (same major version), so no re-init is needed. Verify:
`psql -d kioku -tAc "SELECT 1 FROM pg_available_extensions WHERE name='vector'"` now
returns `1`. This also gives `ephemeral-pg` test clusters pgvector, since they use the
`postgres` binaries on PATH.

Run `just new-migration name=kioku-embedding-schema-heal` and fill it with the *same*
guarded DO block as `2026-06-24-01-00-00-kioku-memory-embeddings.sql` (attempt
`CREATE EXTENSION IF NOT EXISTS vector` inside a caught exception block, probe
`pg_extension`, and if available run the four `ALTER TABLE kioku_memories ADD COLUMN IF NOT
EXISTS ...` statements and the two `CREATE INDEX IF NOT EXISTS` statements — copy the block
verbatim, updating only the header comment to explain it is a catch-up: the original
migration is one-shot, codd records it applied even when the extension was missing, and
this migration re-attempts the DDL so a later `just migrate` heals a degraded schema). All
statements are `IF NOT EXISTS`, so it is a no-op on healthy databases and still-degraded
ones. Touch the "Last touched" comment in `kioku-migrations/src/Kioku/Migrations.hs` again.

Add a short "Healing a degraded schema" note to the Degradation section of
`docs/user/recall.md`: if pgvector is installed *after* all migrations have run, re-run the
DO block manually (`psql -d kioku -f kioku-migrations/sql-migrations/<timestamp>-kioku-embedding-schema-heal.sql`)
— it is idempotent — or simply apply it on the next `just migrate` in environments that have
not yet run this migration.

Acceptance: on the dev DB, before this milestone
`SELECT column_name FROM information_schema.columns WHERE table_schema='kiroku' AND
table_name='kioku_memories' AND column_name='embedding'` returns nothing; after
`just migrate` it returns `embedding`, and
`SELECT indexname FROM pg_indexes WHERE indexname='kioku_memories_embedding_hnsw'` returns
the index. `kioku worker --backfill` no longer reports missing columns (it will report 0
backfilled without an embedding endpoint, which is fine).


### Milestone 3: Vector recall query fix — index-compatible ORDER BY, ef_search over-fetch, EXPLAIN proof, and recall SQL tests

Scope: `kioku-core/src/Kioku/Recall.hs` plus a new DB test module. At the end, the vector
candidate query is served by the HNSW index (proven with EXPLAIN), the index scan is wide
enough to fill the 50-row pool despite post-scan filters, and the recall candidate SQL has
DB-level tests for scope, status, and query-parsing behavior.

In `selectVectorCandidatesStmt` (Recall.hs:383-399), change the ORDER BY from
`ORDER BY embedding <=> $1::vector, created_at DESC` to
`ORDER BY embedding <=> $1::vector`. The trailing `created_at DESC` adds a second pathkey
the HNSW index cannot produce, so the planner falls back to a full scan plus sort; pgvector
ANN indexes are only used when the ORDER BY is exactly the single distance expression. Do
not touch the FTS statement (GIN indexes provide no ordering; its ORDER BY is fine).

In `selectVectorCandidates` (Recall.hs:205-214), widen the HNSW search before the statement
runs, inside the same transaction:

```haskell
selectVectorCandidates req queryVector =
  runTransaction do
    Tx.sql "SET LOCAL hnsw.ef_search = 200"
    Tx.statement (vectorCandidateQuery req queryVector) selectVectorCandidatesStmt
```

Add a named constant `hnswEfSearch :: Int32` (value 200) next to `candidatePoolSize` with a
comment explaining both problems it addresses: (1) `hnsw.ef_search` defaults to 40, below
the 50-row pool, so even an unfiltered index scan cannot fill the pool; (2) the
namespace/scope/status predicates are applied *after* the index scan (the standard pgvector
filtered-ANN caveat), so the scan must over-fetch — 200 gives 4x headroom. Note in the same
comment that pgvector >= 0.8 offers `SET LOCAL hnsw.iterative_scan = relaxed_order` to
eliminate the truncation entirely; we do not adopt it yet to avoid pinning the pgvector
version (record this in the Decision Log — already done).

`SET LOCAL` scopes the setting to the enclosing transaction, so no other query is affected.
If `Tx.sql` is unavailable in the pinned `hasql-transaction`, use a parameterless
`Statement () ()` with `preparable ... E.noParams D.noResult`; do not interpolate the value.

For testability, add `selectFtsCandidates`, `selectVectorCandidates`, and `vectorLiteral`
to the export list of `Kioku.Recall` with a haddock noting they are exported for DB-level
tests. Add `kioku-core/test/Kioku/RecallSqlSpec.hs` (register in the cabal file and
`test/Main.hs`), using `withKiokuMigratedDatabase` and seeding `kiroku.kioku_memories` with
raw hasql INSERTs (simplest and closest to the SQL under test). Cover:

- Scope predicate: seed one global-scope memory and one entity-scoped memory in namespace
  `ns1`, plus one memory in `ns2`. A keyword recall (run `Kioku.Recall.recall` with a dummy
  `EmbeddingModel`, capability `VectorExtensionUnavailable`, strategy `Keyword` — this path
  never calls the embedding endpoint) with `ScopeGlobal (Namespace "ns1")` returns *both*
  ns1 rows (namespace-wide semantics); with the entity scope it returns only the entity row;
  ns2 never appears.
- Status filter: an `archived` row matching the query is never returned.
- Query parsing: `websearch_to_tsquery` must not error on an empty query or an
  operator-laden one (`"\"unbalanced OR AND"`); recall returns `[]` or matches, but never
  throws.
- Vector round-trip (skip unless `SELECT 1 FROM pg_extension WHERE extname='vector'`
  succeeds after `CREATE EXTENSION IF NOT EXISTS vector`): insert a row with
  `embedding = $1::vector` using `vectorLiteral (Vector.fromList [...1536 values...])`,
  read back `embedding::text`, and assert `selectVectorCandidates` with a nearby query
  vector returns the row first. This exercises the `vectorLiteral` text encoding through a
  real `::vector` cast.

Acceptance: tests green; the EXPLAIN transcript in Concrete Steps shows
`Index Scan using kioku_memories_embedding_hnsw` after the change and a seq-scan-plus-sort
before it.


### Milestone 4: Embedding dimension validation in capability detection

Scope: `kioku-core/src/Kioku/Recall/Capability.hs`, its three call sites in `kioku-cli`,
and tests. At the end, a `KIOKU_EMBEDDING_DIMENSIONS` value that disagrees with the actual
`vector(N)` column produces one clear startup error instead of a runtime failure per event.

Extend `CapabilityProbe` with `embeddingTypmod :: !(Maybe Int32)` and add to the probe SQL a
scalar subquery reading the column's type modifier (for pgvector, `atttypmod` *is* the
declared dimension count, or -1 if the column was declared without one):

```sql
(SELECT a.atttypmod
   FROM pg_attribute a
   JOIN pg_class c ON c.oid = a.attrelid
   JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'kiroku' AND c.relname = 'kioku_memories'
    AND a.attname = 'embedding' AND NOT a.attisdropped) AS embedding_typmod
```

(Verify the claim once on a healed dev DB: `SELECT atttypmod, format_type(atttypid, atttypmod)
FROM pg_attribute WHERE ...` must show `1536` and `vector(1536)`.)

Change the signature to `detectVectorCapability :: (Store :> es) => Int -> Eff es
VectorCapability` where the argument is the configured dimensions
(`EmbeddingConfig.dimensions`). Add a constructor `VectorDimensionMismatch !Int !Int`
(configured, actual) to `VectorCapability`. In `classifyProbe`, after the existing
missing-column checks: if the embedding column exists and its typmod is a positive number
different from the configured dimensions, return the mismatch. Treat typmod -1 or a missing
probe row as no constraint (available).

Update `planRecallExecution` in `kioku-core/src/Kioku/Recall.hs` to map
`VectorDimensionMismatch {}` to `keywordExecutionPlan`. Update the three CLI call sites to
pass `config.dimensions` from `resolveEmbeddingConfig`:
`kioku-cli/src/Kioku/Cli/Commands/Recall.hs:76`, `Distill.hs:76`, and `Worker.hs:50`. In
`Worker.hs` `runContinuousWorker`, handle the new case by printing
`"embedding dimension mismatch: KIOKU_EMBEDDING_DIMENSIONS=<c> but kiroku.kioku_memories.embedding is vector(<a>); fix the env var or migrate the column; running kioku timer worker only."`
and running the timer loop only; in `runBackfill`, make the mismatch exit non-zero via
`ioError (userError ...)` with the same message before any event is touched.

Tests: pure classification cases in `kioku-core/test/Kioku/RecallSpec.hs` (mismatch maps to
keyword plan), and in `RecallSqlSpec` a DB case (skipped without pgvector):
`detectVectorCapability 512` against the migrated schema returns
`VectorDimensionMismatch 512 1536`, while `detectVectorCapability 1536` returns
`VectorAvailable`.

Acceptance: `KIOKU_EMBEDDING_DIMENSIONS=512 cabal run kioku -- worker --backfill` exits
non-zero with the message above on a healed dev DB; with 1536 it behaves as before.


### Milestone 5: Collision-free scope identity derivation with an id-recompute migration

Scope: a new shared module, edits in `Kioku/Distill/L2.hs` and `L3.hs`, validators in
`kioku-api`, one migration, and collision tests. At the end, distinct scopes can never
derive the same scene/persona row id, timer id, or mirror slug; well-formed existing rows
keep their exact ids; ambiguous existing rows are re-keyed by migration. Function names and
signatures consumed elsewhere (`sceneRowId`, `personaRowId`, `sceneMirrorPath`,
`personaMirrorPath`, `l2SceneTimerId`, `l3PersonaTimerId`, and the slug functions —
docs/plans/10-propagate-memory-forget-operations-to-scenes-personas-and-workspace-mirrors.md
computes deletion targets through them) do not change; only their internals do.

Create `kioku-core/src/Kioku/Distill/ScopeIdentity.hs` (add to `exposed-modules`):

```haskell
module Kioku.Distill.ScopeIdentity
  ( escapeScopeComponent,
    scopeIdentity,
    scopeIdentityFromColumns,
    scopeSlugFromColumns,
  )
where
```

`escapeScopeComponent` percent-escapes, in this order, `%` -> `%25`, then `/` -> `%2F`,
then `:` -> `%3A` (escaping `%` first makes the encoding injective).
`scopeIdentity :: MemoryScope -> Text` renders
`escape ns` for global scopes and `escape ns <> "/" <> escape kind <> "/" <> escape ref`
for entity scopes; `scopeIdentityFromColumns :: Text -> Maybe Text -> Maybe Text -> Text`
is the row-column variant (kind and ref are both present or both absent — guaranteed by
M1's CHECK). `scopeSlugFromColumns` builds the mirror slug: sanitize the `-`-joined
components exactly as today's `sanitizeSlug`/`isSafeSlugChar` do (move those helpers here),
then append `"-" <> Text.take 10 (sha256 hex of scopeIdentityFromColumns ...)` using
`Crypto.Hash` as L2/L3 already do. The hash suffix is what makes the slug collision-free;
the readable prefix is for humans.

Rewire `L2.hs`: `sceneRowId scope = "kioku_scene:" <> scopeIdentity scope <> ":" <>
escapeScopeComponent defaultSceneKey` (escaping the key future-proofs the format; today's
key `default` is unchanged by it); `l2SceneTimerId` and the timer `correlationId` use
`scopeIdentity` instead of `renderScope`; `sceneScopeSlug row = scopeSlugFromColumns
row.namespace row.scopeKind row.scopeRef`. Keep `renderScope` only as the human-readable
`scopeLabel` fed to the LLM prompts (collisions there are cosmetic); delete the local
`sanitizeSlug`/`isSafeSlugChar` copies. Mirror the same changes in `L3.hs`
(`personaRowId`, `l3PersonaTimerId`, correlation, `personaScopeSlug`). Note: pending timers
scheduled under old ids still fire normally; the debounce window may double-fire once
across the deploy boundary, which is harmless because regeneration is source-hash guarded.

In `kioku-api/src/Kioku/Api/Scope.hs`, add `mkNamespace :: Text -> Either Text Namespace`
and `mkScopeKind :: Text -> Either Text ScopeKind` (reject empty input and any of `%`,
`/`, `:`, with an error message naming the offending character); export them alongside the
existing constructors. Use them in `kioku-cli/src/Kioku/Cli/Scope.hs` `parseScope` so CLI
input gets validated (the `:`-split already excludes `:`; this adds `/` and `%`). Refs stay
unconstrained.

Run `just new-migration name=kioku-scope-identity-recompute` (its timestamp lands after
M1's and M2's files). The migration recomputes ids only for rows whose components contain
`%`, `/`, or `:` — all other ids are byte-identical under the new derivation:

```sql
UPDATE kioku_scenes SET scene_id =
  'kioku_scene:'
  || replace(replace(replace(namespace, '%', '%25'), '/', '%2F'), ':', '%3A')
  || COALESCE('/' || replace(replace(replace(scope_kind, '%', '%25'), '/', '%2F'), ':', '%3A')
       || '/' || replace(replace(replace(scope_ref, '%', '%25'), '/', '%2F'), ':', '%3A'), '')
  || ':' || replace(replace(replace(scene_key, '%', '%25'), '/', '%2F'), ':', '%3A')
 WHERE namespace ~ '[%/:]' OR scope_kind ~ '[%/:]' OR scope_ref ~ '[%/:]' OR scene_key ~ '[%/:]';
```

and the analogous `UPDATE kioku_personas SET persona_id = 'kioku_persona:' || ...` (no
scene-key part). The `COALESCE` collapses the kind/ref segment for global rows (M1
guarantees kind and ref are NULL together). Re-running recomputes the same value, so the
migration is idempotent, and it is a no-op on databases with well-formed scopes. A row that
had absorbed a second scope's content keeps the id derived from its *stored* scope columns
(the first writer); the second scope's scene/persona regenerates under its own id on the
next distillation run. Touch the "Last touched" comment in
`kioku-migrations/src/Kioku/Migrations.hs`.

Tests: in a new `kioku-core/test/Kioku/ScopeIdentitySpec.hs` (pure, no DB): the plan's
canonical collision — global `a/b/c` versus entity `a`/`b`/`c` — yields distinct
`sceneRowId`, `personaRowId`, timer ids, and slugs; a legacy-stability case asserts
`sceneRowId (ScopeEntity (Namespace "rei") (ScopeKind "intention") "intention_abc")`
still equals the exact string `"kioku_scene:rei/intention/intention_abc:default"`;
`escapeScopeComponent` is injective on a small adversarial set (`"a/b"`, `"a%2Fb"`, `"a:b"`).
In `SchemaSpec` or a DB case: after inserting a scene row with a `/`-bearing namespace and
old-style id, applying migrations recomputes it (covered implicitly since tests migrate from
scratch; a direct UPDATE-then-assert against the migration SQL text is acceptable instead).

Acceptance: `cabal test all` green; recording memories under the two colliding scopes on a
dev DB (see Validation) produces two scene rows and two persona rows with distinct ids and
two distinct mirror files.


### Milestone 6: Global-scope semantics documentation and haddocks

Scope: docs and metadata only. At the end, the recall/read-model asymmetry has a name and
is documented at every surface, and `kioku-api` declares only dependencies it uses.

In `docs/user/recall.md`, add a section "Global scope: namespace-wide recall vs exact-scope
reads" stating precisely: *recall* with `ScopeGlobal ns` searches every active memory in the
namespace (entity-scoped rows included) — global scope means "no scope filter" for search;
*scoped reads* (`getActiveByScope`, `getGlobal`, scene/persona lookups) with `ScopeGlobal
ns` return only rows recorded with no entity scope — global scope means "the global bucket"
for reads. Note this is intentional (search wants maximum candidate surface; reads want
exact buckets) and that `getActiveInNamespace` is the read-side namespace-wide equivalent.
Also update the step-3 candidate-selection bullet in the same file, which currently
describes the vector ORDER BY as "cosine distance then recency" — after M3 it is cosine
distance only.

Add haddocks stating the same on both query paths: `recall`/`RecallRequest.scope` and the
candidate statements in `kioku-core/src/Kioku/Recall.hs`, and `getActiveByScope` in the same
file plus the scope predicate statements in `kioku-core/src/Kioku/Memory/ReadModel.hs`
(around `selectActiveByScopeStmt`, :358). Each haddock should carry the one-line form:
"recall searches namespace-wide for global scope; scoped reads are exact-scope."

The dead `generic-lens`/`uuid` build-depends in `kioku-api/kioku-api.cabal` are NOT removed
here: that cleanup is owned by docs/plans/15-tighten-cli-and-api-surface-validation.md
(which gates it on an implementation-time re-grep, since this plan's `mkNamespace`/
`mkScopeKind` work could conceivably introduce a use). This plan only records the discovery.

Acceptance: the docs render the new section; haddock text present at all four sites.


## Concrete Steps

All commands run from the repository root `/Users/shinzui/Keikaku/bokuno/kioku`, inside the
nix dev shell (Postgres env vars `PGHOST`, `PGDATABASE=kioku` are set by the shell hook;
the dev server must be running, e.g. via `process-compose up` or `pg_ctl start`).

Scaffold each migration when its milestone starts (mints the timestamp at creation time):

```bash
just new-migration name=kioku-schema-hardening        # M1
just new-migration name=kioku-embedding-schema-heal   # M2
just new-migration name=kioku-scope-identity-recompute # M5
```

After editing each migration, update the "Last touched" comment in
`kioku-migrations/src/Kioku/Migrations.hs`, then build and test:

```bash
cabal build all
cabal test all
```

Expected test output ends with (module list grows as milestones add specs):

```text
All 6 tests passed (…)
Test suite kioku-test: PASS
```

Apply to the dev database and confirm idempotence:

```bash
just migrate
just migrate   # second run: codd reports nothing new to apply
```

M1 verification (dev DB):

```bash
psql -tAc "SELECT indexname FROM pg_indexes WHERE schemaname='kiroku' AND tablename='kioku_memories' ORDER BY 1"
# expect kioku_memories_supersedes_idx and kioku_memories_superseded_by_idx in the list
psql -c "INSERT INTO kiroku.kioku_memories (memory_id, agent_id, namespace, scope_kind, memory_type, content, created_at, updated_at)
         VALUES ('m_bad', 'a', 'ns', 'kind-without-ref', 't', 'c', now(), now())"
```

Expected failure:

```text
ERROR:  new row for relation "kioku_memories" violates check constraint "kioku_memories_scope_pair_check"
```

M2 verification (dev DB, after the nix change and Postgres restart):

```bash
psql -tAc "SELECT 1 FROM pg_available_extensions WHERE name='vector'"   # 1
just migrate
psql -tAc "SELECT column_name FROM information_schema.columns
           WHERE table_schema='kiroku' AND table_name='kioku_memories' AND column_name='embedding'"  # embedding
psql -tAc "SELECT indexname FROM pg_indexes WHERE indexname='kioku_memories_embedding_hnsw'"          # present
```

M3 EXPLAIN verification (dev DB with the healed schema; seed at least one embedded row
first, or accept a trivially empty result — the plan shape is what matters). Build a
1536-dimension literal into a psql variable, then EXPLAIN the exact statement shape recall
uses:

```bash
psql <<'SQL'
SELECT format('[%s]', string_agg('0.1', ',')) AS vec FROM generate_series(1, 1536) \gset
SET hnsw.ef_search = 200;
EXPLAIN (COSTS OFF)
SELECT memory_id FROM kiroku.kioku_memories
WHERE status = 'active' AND namespace = 'rei'
  AND ((NULL IS NULL AND NULL IS NULL) OR (scope_kind = NULL AND scope_ref = NULL))
  AND embedding IS NOT NULL
ORDER BY embedding <=> :'vec'::vector
LIMIT 50;
SQL
```

Expected plan (after the fix — the index scan line is the acceptance signal):

```text
Limit
  ->  Index Scan using kioku_memories_embedding_hnsw on kioku_memories
        Order By: (embedding <=> '[0.1,…]'::vector)
        Filter: ((status = 'active'::text) AND (namespace = 'rei'::text))
```

For contrast, appending `, created_at DESC` to the ORDER BY (the pre-fix shape) yields:

```text
Limit
  ->  Sort
        Sort Key: ((embedding <=> '[0.1,…]'::vector)), created_at DESC
        ->  Seq Scan on kioku_memories
```

Capture both transcripts into this plan's Surprises & Discoveries section when observed.

M4 verification (healed dev DB):

```bash
psql -tAc "SELECT atttypmod FROM pg_attribute a
           JOIN pg_class c ON c.oid = a.attrelid
           JOIN pg_namespace n ON n.oid = c.relnamespace
           WHERE n.nspname='kiroku' AND c.relname='kioku_memories' AND a.attname='embedding'"  # 1536
KIOKU_EMBEDDING_DIMENSIONS=512 cabal run kioku -- worker --backfill; echo "exit=$?"
```

Expected: non-zero exit and a message naming both 512 and 1536.

M5 verification (dev DB; requires an embedding endpoint or `--strategy keyword` paths —
scene generation needs the distill runtime, so the DB-level proof via tests is primary;
the pure-Haskell proof is `cabal test all` running `ScopeIdentitySpec`). Direct check that
identities differ:

```bash
cabal repl kioku-core --repl-no-load  # or ghci via cabal repl, then:
# > import Kioku.Distill.ScopeIdentity
# > import Kioku.Api.Scope
# > scopeIdentity (ScopeGlobal (Namespace "a/b/c"))
# "a%2Fb%2Fc"
# > scopeIdentity (ScopeEntity (Namespace "a") (ScopeKind "b") "c")
# "a/b/c"
```

M6 verification:

```bash
grep -n "namespace-wide" docs/user/recall.md kioku-core/src/Kioku/Recall.hs kioku-core/src/Kioku/Memory/ReadModel.hs
```


## Validation and Acceptance

The change is accepted when all of the following hold, each observable by a novice:

1. `cabal build all && cabal test all` passes from a clean checkout inside the dev shell.
   The suite now includes `SchemaSpec`, `RecallSqlSpec`, and `ScopeIdentitySpec` groups in
   the `kioku-test` output.
2. On the dev database, `just migrate` runs cleanly twice in a row; after it, the
   constraint-violation psql probes in Concrete Steps return the exact SQLSTATE errors
   shown, `kioku_turns_session_idx` is gone, and the four new indexes exist.
3. The previously degraded dev database has real embedding columns and the HNSW index
   (M2 transcript), and the EXPLAIN transcript shows
   `Index Scan using kioku_memories_embedding_hnsw` for the recall-shaped vector query
   with plain distance ORDER BY, versus seq-scan-plus-sort with the old ORDER BY.
4. `KIOKU_EMBEDDING_DIMENSIONS=512 cabal run kioku -- worker --backfill` fails fast with a
   message naming 512 and 1536; with the correct value the worker behaves as before.
5. In ghci, the two colliding scopes (`a/b/c` global vs `a`/`b`/`c` entity) produce
   different `scopeIdentity` values, and `ScopeIdentitySpec` asserts distinct row ids,
   timer ids, and slugs, plus byte-stability of the legacy id for a well-formed scope.
6. `docs/user/recall.md` contains the named semantics ("recall searches namespace-wide for
   global scope; scoped reads are exact-scope"), the healing note, and the corrected
   ORDER BY description; the same one-liner appears in haddocks on both query paths.

Tests that must fail before their milestone's change and pass after (novice sanity check):
`SchemaSpec`'s unique/check assertions (fail without the M1 migration), `RecallSqlSpec`'s
vector round-trip (fails without M2/M3 on a pgvector-enabled cluster), the capability
mismatch case (fails without M4), and `ScopeIdentitySpec`'s collision case (fails without
M5 — both scopes currently render `a/b/c`).


## Idempotence and Recovery

Every migration in this plan is written to be re-runnable: data repairs are guarded
`UPDATE ... WHERE` / `DELETE ... USING` statements that match nothing on the second pass,
constraints use drop-then-add pairs, and all `CREATE INDEX`/`ADD COLUMN` statements use
`IF NOT EXISTS`. codd applies each file once, but content-idempotence means a
half-applied-then-retried in-txn migration (codd rolls back on failure) or a manual re-run
against a snapshot cannot drift the schema. `just migrate` may be run repeatedly.

The M1 dedupe deletes older duplicate scene/persona rows. These are regenerable caches of
memories (scenes and personas are re-distilled from `kioku_memories` on the next timer), so
no unrecoverable data is lost; on databases you care about, take a backup first
(`pg_dump -n kiroku kioku > backup.sql`). The same is true of the M5 id recompute: if it
mis-keys a row, deleting the row entirely and letting distillation regenerate it is a safe
recovery.

The nix change (M2) is additive; if the new dev shell misbehaves, reverting the line and
restarting Postgres restores the previous (degraded but functional) state — but only if the
healing migration has not yet added `vector`-typed columns to the data directory. Once
columns of type `vector` exist, the server must keep a pgvector-capable binary (do not
revert the nix line or drop the extension after healing); if you must go back, drop the
embedding columns and index first.

Code changes are ordinary git-tracked edits; each milestone compiles and tests
independently, so `git revert` of a milestone's commit is always a clean rollback. Commit
at every milestone boundary with a conventional-commit message (e.g.
`feat(schema): add supersession and session list indexes with scope constraints`).


## Interfaces and Dependencies

Libraries and services: PostgreSQL >= 15 (NULLS NOT DISTINCT; dev pins nixpkgs
`pkgs.postgresql`, currently 17.10, gaining the `pgvector` extension package in M2); codd
(embedded migrations, ordered by filename timestamp); hasql / hasql-transaction (all SQL
statements; `Tx.sql`/`Tx.statement` inside `Kiroku.Store.Transaction.runTransaction`);
`ephemeral-pg` via `kioku-migrations:test-support` for DB tests; `Crypto.Hash` (SHA-256
slug suffix); tasty/tasty-hunit.

Signatures that must exist at the end (full module paths):

- `Kioku.Distill.ScopeIdentity.escapeScopeComponent :: Text -> Text`,
  `scopeIdentity :: MemoryScope -> Text`,
  `scopeIdentityFromColumns :: Text -> Maybe Text -> Maybe Text -> Text`,
  `scopeSlugFromColumns :: Text -> Maybe Text -> Maybe Text -> Text` (new module in
  kioku-core).
- Unchanged public shapes in `Kioku.Distill.L2` / `Kioku.Distill.L3`: `sceneRowId ::
  MemoryScope -> Text` (module-internal today), `personaRowId :: MemoryScope -> Text`,
  `sceneMirrorPath :: FilePath -> SceneRow -> FilePath`, `personaMirrorPath :: FilePath ->
  PersonaRow -> FilePath`, `l2SceneTimerId :: MemoryScope -> Text -> TimerId`,
  `l3PersonaTimerId :: MemoryScope -> UTCTime -> TimerId` — internals change, signatures do
  not, because docs/plans/10-propagate-memory-forget-operations-to-scenes-personas-and-workspace-mirrors.md
  blanks/deletes scene and persona rows and mirror files by calling exactly these functions.
- `Kioku.Api.Scope.mkNamespace :: Text -> Either Text Namespace` and
  `mkScopeKind :: Text -> Either Text ScopeKind`; the raw `Namespace`/`ScopeKind`
  constructors remain exported (host compatibility: shikigami, rei, mori construct them
  directly). docs/plans/15-tighten-cli-and-api-surface-validation.md may adopt these in its
  CLI/API sweep.
- `Kioku.Recall.Capability.detectVectorCapability :: (Store :> es) => Int -> Eff es
  VectorCapability` with `VectorCapability` gaining `VectorDimensionMismatch !Int !Int`.
  Callers: `kioku-cli/src/Kioku/Cli/Commands/{Recall,Distill,Worker}.hs`.
- `Kioku.Recall` additionally exports `selectFtsCandidates`, `selectVectorCandidates`, and
  `vectorLiteral` as documented test seams.

Cross-plan constraints (reference by path only): this plan owns schema indexes;
docs/plans/12-enforce-aggregate-invariants-for-lineage-resume-correlation-and-idempotent-commands.md
confirmed it needs no `previous_session_id` index (see Decision Log), and the dead
kioku-api dependency removal is owned by
docs/plans/15-tighten-cli-and-api-surface-validation.md.
Every migration added here mints a fresh UTC timestamp via `just new-migration` and touches
the "Last touched" comment in `kioku-migrations/src/Kioku/Migrations.hs`; that convention is
mandatory until
docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md
lands its embed-staleness guard. The global-scope semantics decision is owned by the
MasterPlan (docs/masterplans/2-kioku-review-remediation-correctness-resilience-and-hygiene.md):
recall behavior does not change; documentation does.


## Revision Notes

- 2026-07-07: Cross-plan reconciliation after all seven child plans were authored. Removed
  the `kioku_sessions.previous_session_id` index from the M1 migration (the plan-12 research
  showed `getChain` joins through the primary key and lineage validation is pure — the index
  would be write amplification), and reassigned the `generic-lens`/`uuid` removal from M6 to
  docs/plans/15-tighten-cli-and-api-surface-validation.md, which had independently claimed
  it with an implementation-time re-grep gate. Progress, Decision Log, Concrete Steps,
  Validation, and Interfaces sections updated accordingly.
