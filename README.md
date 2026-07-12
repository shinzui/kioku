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
- **Host-agnostic scopes**: memories are partitioned by namespace and optional entity reference
  so hosts such as `rei`, `mori`, and `shikigami` can share one store without colliding.

## Repository Layout

- `kioku-api/`: shared API types and identifiers.
- `kioku-core/`: memory, session, recall, and distillation runtime library.
- `kioku-cli/`: command-line interface for demos, recall, distillation, scenes, and workers.
- `kioku-migrations/`: manifest-ordered, checksummed pg-migrate component and test support.
- `docs/user/`: user and integration documentation.
- `docs/plans/`: ExecPlans for larger implementation work.

## Getting Started

Start with the user guide:

- [docs/user/README.md](docs/user/README.md)
- [docs/user/getting-started.md](docs/user/getting-started.md)
- [docs/user/concepts.md](docs/user/concepts.md)

Common development commands:

```bash
cabal build all
cabal test all
just migrate
DATABASE_URL="$PG_CONNECTION_STRING" cabal run kioku-migrate -- verify
```

The development shell is provided by Nix:

```bash
nix develop
```

## Status

kioku is experimental infrastructure for the kikan agent ecosystem. It is primarily a library
embedded by host applications, with a CLI for local operation and inspection.
