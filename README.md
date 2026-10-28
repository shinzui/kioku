# kioku

**kioku** is a reusable, event-sourced agent memory and session library written in Haskell. It
stores durable memories, records agent sessions and turns, supports hybrid recall over Postgres
full-text search plus embeddings, and distills raw session evidence into higher-level memory
artifacts.

## The Name

**kioku** is the romanized reading of the Japanese word **記憶**, meaning **memory**. The name is
literal: this repository provides the shared memory layer for agent systems. It is designed to
remember what agents learn, where that knowledge applies, and which session produced it.

## What It Provides

- **Durable memory**: event-sourced memory records for facts, preferences, constraints,
  patterns, and instructions.
- **Session tracking**: event-sourced agent sessions, conversation turns, delegation lineage,
  and durable awaiting/resume state.
- **Hybrid recall**: Postgres full-text search and `pgvector` semantic retrieval fused with
  Reciprocal Rank Fusion.
- **Distillation**: L0 session evidence becomes L1 memory atoms, L2 scenes, and L3 persona
  summaries.
- **Memory-space isolation**: every command and query names one memory space; namespaces and
  entity scopes organize memory inside it. Hosts supply authorization and write attribution.
- **Bounded inspection**: permission-checked session and memory pages, fixed-field metadata,
  separate tag pages, complete counts, and newest-active memory queries.
- **Host-owned AI**: explicit API, batch, or interactive capabilities for distillation, separate
  embedding capabilities, and foreground recovery of deferred interactive timers.

## Repository Layout

- `kioku-api/`: shared API types and identifiers.
- `kioku-core/`: memory, session, recall, and distillation runtime library.
- `kioku-cli/`: command-line interface for demos, recall, distillation, scenes, and workers.
- `kioku-migrations/`: manifest-ordered, checksummed pg-migrate component and test support.
- `kioku-migrate/`: standalone migration and read-model reconciliation executable.
- `docs/user/`: user and integration documentation.
- `docs/plans/`: ExecPlans for larger implementation work.

## Getting Started

Start with the user guide:

- [docs/user/README.md](docs/user/README.md)
- [docs/user/getting-started.md](docs/user/getting-started.md)
- [docs/user/concepts.md](docs/user/concepts.md)
- [CLI reference](docs/user/cli-reference.md) and [AI configuration](docs/user/configuration.md)
- [Library API](docs/user/library-api.md) and [bounded reads](docs/user/bounded-reads.md)
- [Upgrading to Kioku 0.12 / Keiro 0.22](docs/user/upgrading-to-keiro-0-22.md)

Common development commands:

```bash
cabal build all
TASTY_NUM_THREADS=4 cabal test all -j1
just migrate
DATABASE_URL="$PG_CONNECTION_STRING" cabal run kioku-migrate -- verify
```

Project dependencies resolve from Hackage; `cabal.project` does not replace released packages with
Git checkouts. All five Kioku packages are at **0.12.0.0**, using
[Keiro](mori://shinzui/keiro) 0.22, [Kiroku Store](mori://shinzui/kiroku/packages/kiroku-store)
0.12, [Shibuya Core](mori://shinzui/shibuya/packages/shibuya-core) 0.12 and its
[Kiroku adapter](mori://shinzui/shibuya/packages/shibuya-kiroku-adapter) 0.7, with pg-migrate 1.2.
The optional PGMQ integration is constrained to Keiro PGMQ 0.22, PGMQ 0.7 and its Shibuya adapter
0.18; Kioku's normal runtime does not build that integration.

The composed migration plan has **63 entries (Kiroku 16, Keiro 32, Kioku 15)**.
From a complete 0.11 database, only `kiroku/0016` applies; rebuild and restart all Store-linked
hosts together with workers stopped for migration. Follow the
[0.12 upgrade runbook](docs/user/upgrading-to-keiro-0-22.md) for backup rehearsal and verification.
Older installations also need their intervening index-build pauses, checkpoint checks, and
[bounded-read catalog adoption](docs/user/bounded-reads.md).

The development shell is provided by Nix:

```bash
nix develop
```

For a fresh local database, run `process-compose up`, then in another development shell:

```bash
cabal run kioku -- demo --yes-write-events
cabal run kioku -- recall "concise answers" --scope kioku_demo:demo:demo --strategy keyword
```

Storage and keyword recall need no AI credentials. To enable distillation or semantic recall,
select an explicit [AI configuration file](docs/user/configuration.md) with `--ai-config FILE`
or `KIOKU_AI_CONFIG`. Without one, AI is disabled.

## Status

kioku is experimental infrastructure for the kikan agent ecosystem. It is primarily a library
embedded by host applications, with a CLI for local operation and inspection.
