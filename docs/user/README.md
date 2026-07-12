# kioku (記憶) — User Guide

**kioku** ("memory") is a reusable, event-sourced **agent memory** and **agent session**
library for the kikan ecosystem. It gives any agent platform one shared engine for:

- **Durable memory** — facts, patterns, preferences, constraints, and instructions an agent
  learns, stored as an event-sourced aggregate (the kiroku event stream is the source of truth).
- **Sessions** — event-sourced agent runs with turn capture, delegation lineage, and
  park-and-resume state for external input.
- **Hybrid recall** — Postgres full-text search fused with `pgvector` semantic similarity via
  Reciprocal Rank Fusion (RRF), tuned by recency, priority, and confidence.
- **A distillation pyramid** — raw evidence (L0) is distilled by LLM programs into memory
  **atoms** (L1), human-readable **scenes** (L2), and a per-scope **persona** (L3).

kioku is **host-agnostic**: memories are organized by a generic `MemoryScope`
(`namespace` + optional `kind` + `ref`) so that different platforms — **rei** (personal
coaching), **mori** (multi-repo agent execution), and **shikigami** (autonomous system agents)
— can share one memory database without colliding.

> kioku is a Haskell library plus a `kioku` CLI. It is a building block embedded by host
> applications, not a standalone product. This guide covers both using the CLI and embedding
> the library.

## Documentation map

Start here, in order:

1. **[Getting Started](getting-started.md)** — prerequisites, database setup, environment, and
   your first memory in under five minutes.
2. **[Concepts](concepts.md)** — the mental model: memories, scopes, sessions, recall, and the
   distillation pyramid. Read this before the rest.
3. **[CLI Reference](cli-reference.md)** — every `kioku` subcommand, its flags, and examples.
4. **[Recall & Hybrid Retrieval](recall.md)** — how matches are found, fused, and ranked.
5. **[The Distillation Pyramid](distillation.md)** — L0 → L1 → L2 → L3, consolidation, timers,
   and workspace mirroring.
6. **[Configuration](configuration.md)** — every environment variable and its default.
7. **[Library API](library-api.md)** — embedding kioku in a Haskell host application.
8. **[Scopes & Integrations](integrations.md)** — namespace conventions for rei, mori,
   shikigami, and your own host.
9. **[Troubleshooting & FAQ](troubleshooting.md)** — common errors and how to resolve them.
10. **[Upgrading from Codd](upgrading-to-pg-migrate.md)** — the backup-first, zero-replay
    cutover for existing data-bearing databases.

## At a glance

```text
        ┌──────────────────────────────────────────────┐
        │                  kioku CLI                    │
        │  demo · recall · distill · scenes · persona   │
        │  demo-session · worker                        │
        └──────────────────────────────────────────────┘
                            │
        ┌───────────────────┴───────────────────────────┐
        │                kioku library                   │
        │  Kioku.Memory   Kioku.Session   Kioku.Recall   │
        │  Kioku.Distill.{L1,L2,L3}                       │
        └───────────────────┬────────────────────────────┘
                            │
        ┌───────────────────┴────────────────────────────┐
        │   Postgres                                      │
        │   schema kiroku: kioku_* tables · event streams  │
        │     · tsvector FTS · pgvector embeddings         │
        │   schema keiro:  framework tables (timers,       │
        │     read-model registry)                         │
        └─────────────────────────────────────────────────┘
```

## Quick taste

```bash
# 1. Point kioku at a Postgres database with the kiroku schema migrated.
export PG_CONNECTION_STRING='host=localhost dbname=kioku user=me'

# 2. Write a memory and read it back. The event log is append-only — there is no
#    way to delete an event — so the demo requires an explicit opt-in.
kioku demo --yes-write-events

# 3. Recall memories relevant to a query within a scope.
kioku recall "how does the user like answers" --scope kioku_demo:demo:demo
```

> Distillation additionally needs an **Anthropic** key (`ANTHROPIC_API_KEY`), which is a separate
> credential from the embeddings endpoint. See [Configuration](configuration.md).

See **[Getting Started](getting-started.md)** for the full setup.
