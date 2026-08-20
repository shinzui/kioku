---
id: 38
slug: use-canonical-schema-and-recall-strategy-vocabularies
title: "Use canonical schema and recall-strategy vocabularies"
kind: exec-plan
created_at: 2026-08-20T13:57:31Z
intention: "intention_01m0fpyzp4e2kbnhyvcm00zd9t"
master_plan: "docs/masterplans/7-remediate-the-kioku-0-3-0-0-to-0-4-0-0-release-range-review.md"
---

# Use canonical schema and recall-strategy vocabularies

This ExecPlan is a living document. The sections Progress, Surprises & Discoveries,
Decision Log, and Outcomes & Retrospective must be kept up to date as work proceeds.
If durable project context changes, update or create ADRs in docs/adr/ in the same change.


## Purpose / Big Picture

Kioku should spell each shared concept once. After this change vector capability detection gets
the memories projection's schema and relation from `Kioku.Database.Schema`, and the CLI accepts
recall strategies through the same parser and enumeration as the API wire format. Moving or
adding a projection strategy can no longer leave a second hard-coded probe or CLI vocabulary
silently behind.

Users see unchanged successful commands, but invalid `--strategy` values now receive the API's
canonical error with every accepted spelling. Tests enumerate `allRecallStrategies`, so a future
strategy addition fails until the CLI accepts it automatically rather than until someone notices
the duplicate case expression.


## Progress

Use a checklist to summarize granular steps. Every stopping point must be documented here,
even if it requires splitting a partially completed task into two ("done" vs. "remaining").
This section must always reflect the actual current state of the work.

- [ ] Parameterize the vector capability catalog query with canonical schema/relation constants.
- [ ] Replace the CLI-only strategy case expression with `parseRecallStrategy`.
- [ ] Add database and parser regressions for the canonical vocabularies.
- [ ] Update changelogs, format, and run complete core and CLI suites.


## Surprises & Discoveries

Document unexpected behaviors, bugs, optimizations, or insights discovered during
implementation. Provide concise evidence.

(None yet.)


## Decision Log

Record every decision made while working on the plan.

- Decision: Pass `kiokuSchema` and `memoriesRelation` as catalog-query parameters rather than
  interpolating SQL literals.
  Rationale: the values are trusted constants either way, but parameters keep the probe's SQL
  static and make the statement type say exactly which physical identity it consumes.
  Date: 2026-08-20

- Decision: Adapt `parseRecallStrategy` directly to optparse-applicative with `first`.
  Rationale: `Kioku.Api.Recall` already owns accepted strings, their order, and the invalid-value
  message. A wrapper is needed only to convert `String`/`Text`, not to reinterpret the vocabulary.
  Date: 2026-08-20


## Outcomes & Retrospective

Summarize outcomes, gaps, and lessons learned at major milestones or at completion.
Compare the result against the original purpose. Before marking the plan complete,
distill durable project context from the Decision Log, Surprises & Discoveries, and
this section into docs/adr/. Keep task-local execution details here.

(To be filled during and after implementation.)


## Context and Orientation

`kioku-core/src/Kioku/Database/Schema.hs` is the physical-layout vocabulary. It defines
`kiokuSchema = "kioku"`, `memoriesRelation = "memories"`, and the qualified `memoriesTable` used by
ordinary read/write statements. `kioku-core/src/Kioku/Recall/Capability.hs` instead repeats the
schema and relation as string literals in five `information_schema.columns` probes and one
`pg_catalog` typmod probe. The checks are correct today but will drift if the projection moves.
The separate `to_regtype('vector')` check deliberately resolves a bare PostgreSQL type through the
connection search path; this plan must not qualify or otherwise change that behavior.

`kioku-api/src/Kioku/Api/Recall.hs` owns `RecallStrategy`, `allRecallStrategies`,
`recallStrategyText`, and `parseRecallStrategy`. The parser returns a complete error such as
`unknown recall strategy: fuzzy (expected keyword, embedding, hybrid)`. Despite importing the
type through `Kioku.Recall`, `kioku-cli/src/Kioku/Cli/Commands/Recall.hs` has a private
`parseStrategy` case expression with the same three successes and a different error. Its parser
tests live in `kioku-cli/test/Kioku/Cli/ParserSpec.hs`.

[Projections live in the Kioku schema](../adr/projections-live-in-the-kioku-schema.md) establishes
that projection SQL must name the dedicated schema explicitly and that the central schema module
owns those names. [The partition is a column, not a
schema](../adr/the-partition-is-a-column-not-a-schema.md) distinguishes this physical schema from
a memory-space identity. No ADR currently governs pure vocabulary deduplication, and this plan
does not make a new architectural decision, so no new ADR is required.


## Plan of Work

### Milestone 1 — Capability detection consumes the schema vocabulary

In `Kioku.Recall.Capability`, import `kiokuSchema` and `memoriesRelation`. Change the private
statement input from `()` to `(Text, Text)`, encode the pair as two non-null text parameters, and
replace every catalog comparison with `table_schema = $1` / `table_name = $2` (and
`n.nspname = $1` / `c.relname = $2`). Call it with `(kiokuSchema, memoriesRelation)` from
`detectVectorCapability`. Keep column names, `to_regtype('vector')`, result decoding, and
`classifyProbe` unchanged.

Extend `kioku-core/test/Kioku/RecallSqlSpec.hs` around the existing dimension-detection case. On a
fully migrated database, prove the probe sees the canonical memories table and still reports the
real vector width. Keep the statement private; the final source scan is the structural acceptance
check that the capability module contains no literal catalog predicate for `'kioku'` or
`'memories'`.

### Milestone 2 — The CLI consumes the API strategy vocabulary

In `Kioku.Cli.Commands.Recall`, import `Data.Bifunctor.first` and import
`allRecallStrategies`, `parseRecallStrategy`, and `recallStrategyText` through `Kioku.Recall`.
Replace `eitherReader parseStrategy` with:

```haskell
eitherReader (first Text.unpack . parseRecallStrategy . Text.pack)
```

Delete the local `parseStrategy`. Derive the strategy metavar or help's accepted spelling list
from `allRecallStrategies` and `recallStrategyText` as well; keeping a literal
`keyword|embedding|hybrid` in help would leave the same drift in a less obvious place.

Add `strategyTests` to `Kioku.Cli.ParserSpec`. For every member of `allRecallStrategies`, render it
with `recallStrategyText`, pass it to the real `recallOptionsParser`, and assert the parsed field
matches. Assert omission still defaults to `Hybrid`. For an invalid value, compare or contain the
exact message returned by `parseRecallStrategy`; do not freeze a second hand-written list in the
test.

### Milestone 3 — Validate behavior and document ownership

Update the module comments to point at the owning schema and API modules. Add fixed notes to
`kioku-core/CHANGELOG.md` and `kioku-cli/CHANGELOG.md`, format, and run both full suites. No user
guide change is needed because accepted values and successful behavior remain unchanged.


## Concrete Steps

Run from `/Users/shinzui/Keikaku/bokuno/kioku`.

Locate every duplicate before editing:

```bash
rg -n "table_schema = 'kioku'|table_name = 'memories'|parseStrategy|keyword\|embedding\|hybrid" \
  kioku-core/src kioku-core/test kioku-cli/src kioku-cli/test
rg -n 'kiokuSchema|memoriesRelation|parseRecallStrategy|allRecallStrategies' \
  kioku-api/src kioku-core/src kioku-cli/src
```

Format and run focused tests:

```bash
nix fmt
cabal test kioku-core:kioku-test --test-options='-p "capability detection"'
cabal test kioku-cli:kioku-cli-test --test-options='-p strategy'
```

Then run complete affected packages and verify the duplicate definitions are gone:

```bash
cabal build kioku-core kioku-cli
cabal test kioku-core:kioku-test
cabal test kioku-cli:kioku-cli-test
rg -n "table_schema = 'kioku'|table_name = 'memories'|parseStrategy|keyword\|embedding\|hybrid" \
  kioku-core/src/Kioku/Recall/Capability.hs kioku-cli/src/Kioku/Cli/Commands/Recall.hs
git diff --check
```

The final `rg` is expected to print nothing. The invalid parser test should include
`unknown recall strategy` followed by the API-rendered expected list.


## Validation and Acceptance

Against the migrated canonical schema, `detectVectorCapability` still distinguishes missing
vector support, missing columns, dimension mismatch, and availability exactly as before. Its
catalog relation identity comes solely from `Kioku.Database.Schema`; the bare `vector` type probe
retains its search-path semantics.

For every strategy in `allRecallStrategies`, `kioku recall QUERY --namespace-wide ns --strategy
VALUE` parses to that constructor when `VALUE = recallStrategyText strategy`. With no flag it
parses `Hybrid`. An unknown value returns `parseRecallStrategy`'s exact diagnostic and complete
accepted list. There is no CLI-local case expression or literal metavar list.

The core and CLI builds and full tests pass. No database migration, wire spelling, command exit
status, default, or public recall type changes.


## Idempotence and Recovery

These are pure source refactors with no durable data mutation. Formatting and tests are safe to
repeat. If capability behavior changes unexpectedly, restore the old statement shape while
keeping the canonical constants as its inputs and compare the rendered SQL parameters; do not
work around a failure by reintroducing literals. If CLI parsing changes, compare the adapter's
`Either String` directly with `parseRecallStrategy` before touching the shared parser.


## Interfaces and Dependencies

Use existing `text`, `hasql`, and `optparse-applicative` dependencies. `Data.Bifunctor.first` is
from `base`; no dependency bounds change.

The API vocabulary remains:

```haskell
allRecallStrategies :: [RecallStrategy]
recallStrategyText :: RecallStrategy -> Text
parseRecallStrategy :: Text -> Either Text RecallStrategy
```

The private capability statement becomes equivalent to:

```haskell
detectVectorCapabilityStmt :: Statement (Text, Text) CapabilityProbe
```

Public `detectVectorCapability :: Store :> es => Int -> Eff es VectorCapability` and all CLI
option/result types remain unchanged. No test seam or schema identity is added to the public API.
