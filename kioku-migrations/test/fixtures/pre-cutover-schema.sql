-- Exact pre-cutover schema fixture. Each section is the historical migration payload
-- from the pinned Kiroku 4312aa8, Keiro f1d67a0, or Kioku pre-cutover tree,
-- ordered exactly as Codd ordered their timestamped filenames.

-- BEGIN 2026-05-16-00-00-00-kiroku-bootstrap.sql (4312aa8)
-- Kiroku Store bootstrap migration (codd)
-- Supports PostgreSQL 17+.
--
-- kiroku-store-migrations is the schema owner. codd applies this file
-- verbatim, records that the timestamped migration ran, and skips it on later
-- runs. Future schema changes add new timestamped SQL files in this directory
-- instead of changing kiroku-store.
--
-- All Kiroku-owned objects live in the dedicated `kiroku` schema, leaving
-- `public` free for application objects. Creating the schema and setting
-- search_path first means every unqualified object name in the rest of this
-- file resolves into the Kiroku schema.
CREATE SCHEMA IF NOT EXISTS kiroku;
SET search_path TO kiroku, pg_catalog;

-- PostgreSQL 18 provides pg_catalog.uuidv7(); PostgreSQL 17 needs this
-- Kiroku-schema fallback before events.event_id DEFAULT uuidv7() is parsed.
-- With search_path set above, the unqualified CREATE FUNCTION lands in the
-- Kiroku schema, and to_regprocedure('uuidv7()') resolves through search_path
-- (pg_catalog first for the built-in, then the Kiroku schema for the fallback).
DO $$
BEGIN
    IF to_regprocedure('pg_catalog.uuidv7()') IS NULL
       AND to_regprocedure('uuidv7()') IS NULL THEN
        EXECUTE $fn$
            CREATE FUNCTION uuidv7()
            RETURNS uuid
            AS $body$
            DECLARE
                unix_ts_ms bytea;
                uuid_bytes bytea;
            BEGIN
                unix_ts_ms = substring(int8send(floor(extract(epoch from clock_timestamp()) * 1000)::bigint) from 3);
                uuid_bytes = uuid_send(gen_random_uuid());
                uuid_bytes = overlay(uuid_bytes placing unix_ts_ms from 1 for 6);
                uuid_bytes = set_byte(uuid_bytes, 6, (b'0111' || get_byte(uuid_bytes, 6)::bit(4))::bit(8)::int);
                RETURN encode(uuid_bytes, 'hex')::uuid;
            END
            $body$
            LANGUAGE plpgsql
            VOLATILE
        $fn$;
    END IF;
END
$$;

-- Streams (including $all as stream_id = 0)
CREATE TABLE IF NOT EXISTS streams (
    stream_id    BIGSERIAL    PRIMARY KEY,
    stream_name  TEXT         NOT NULL,
    category     TEXT         GENERATED ALWAYS AS (split_part(stream_name, '-', 1)) STORED,
    stream_version BIGINT     NOT NULL DEFAULT 0,
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now(),
    deleted_at   TIMESTAMPTZ,
    CONSTRAINT ix_streams_stream_name UNIQUE (stream_name)
);

-- Seed the $all stream
INSERT INTO streams (stream_id, stream_name, stream_version)
VALUES (0, '$all', 0)
ON CONFLICT DO NOTHING;

-- Reset sequence past the reserved stream_id=0
SELECT setval('streams_stream_id_seq', GREATEST((SELECT MAX(stream_id) FROM streams), 1));

-- Events (flat table — stream membership tracked in stream_events)
CREATE TABLE IF NOT EXISTS events (
    event_id       UUID         PRIMARY KEY DEFAULT uuidv7(),
    event_type     TEXT         NOT NULL,
    causation_id   UUID,
    correlation_id UUID,
    data           JSONB        NOT NULL,
    metadata       JSONB,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Stream-event junction (each event gets 2+ rows: source stream + $all + any links)
CREATE TABLE IF NOT EXISTS stream_events (
    event_id                UUID   NOT NULL REFERENCES events(event_id),
    stream_id               BIGINT NOT NULL REFERENCES streams(stream_id),
    stream_version          BIGINT NOT NULL,
    original_stream_id      BIGINT NOT NULL,
    original_stream_version BIGINT NOT NULL,
    PRIMARY KEY (event_id, stream_id)
);

-- Indexes

-- Primary read path: fetch events from a stream in order
CREATE INDEX IF NOT EXISTS ix_stream_events_stream_version
    ON stream_events (stream_id, stream_version);

-- Event type filtering (for server-side subscription filtering)
CREATE INDEX IF NOT EXISTS ix_events_event_type
    ON events (event_type);

-- Correlation tracing
CREATE INDEX IF NOT EXISTS ix_events_correlation_id
    ON events (correlation_id) WHERE correlation_id IS NOT NULL;

-- Causation tracing
CREATE INDEX IF NOT EXISTS ix_events_causation_id
    ON events (causation_id) WHERE causation_id IS NOT NULL;

-- Category filtering (for readCategory — uses generated column, not LIKE)
CREATE INDEX IF NOT EXISTS ix_streams_category
    ON streams (category);

-- Category read path: find $all entries by originating stream, ordered by global position
-- Enables efficient category reads by allowing the planner to: look up category stream_ids →
-- index scan $all for each → merge ordered by stream_version
CREATE INDEX IF NOT EXISTS ix_stream_events_all_by_origin
    ON stream_events (original_stream_id, stream_version)
    WHERE stream_id = 0;

-- Subscriptions (checkpoint persistence for subscription positions).
-- consumer_group_member / consumer_group_size carry static consumer-group
-- topology (ExecPlan 28 / EP-1). Non-group subscriptions are member 0, size 1.
-- The unique key is composite (subscription_name, consumer_group_member) so each
-- group member persists its own checkpoint under one shared subscription name.
CREATE TABLE IF NOT EXISTS subscriptions (
    subscription_id       BIGSERIAL    PRIMARY KEY,
    subscription_name     TEXT         NOT NULL,
    stream_name           TEXT         NOT NULL DEFAULT '$all',
    last_seen             BIGINT       NOT NULL DEFAULT 0,
    consumer_group_member INT          NOT NULL DEFAULT 0,
    consumer_group_size   INT          NOT NULL DEFAULT 1,
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at            TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- Idempotent convergence for databases created before EP-1: add the columns if
-- missing, drop the old auto-named single-column unique constraint if present,
-- and install the composite unique index. All guarded so the bootstrap body is
-- still safe in disposable local databases; codd records the timestamped
-- migration and does not reapply it after a successful run.
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS consumer_group_member INT NOT NULL DEFAULT 0;
ALTER TABLE subscriptions ADD COLUMN IF NOT EXISTS consumer_group_size   INT NOT NULL DEFAULT 1;
ALTER TABLE subscriptions DROP CONSTRAINT IF EXISTS subscriptions_subscription_name_key;
CREATE UNIQUE INDEX IF NOT EXISTS ix_subscriptions_name_member
    ON subscriptions (subscription_name, consumer_group_member);

-- Triggers

-- NOTIFY on stream changes (fires once per append, not per event)
CREATE OR REPLACE FUNCTION notify_events() RETURNS TRIGGER AS $$
BEGIN
    PERFORM pg_notify(
        TG_TABLE_SCHEMA || '.events',
        NEW.stream_name || ',' || NEW.stream_id || ',' || NEW.stream_version
    );
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS stream_events_notify ON streams;
CREATE TRIGGER stream_events_notify
    AFTER INSERT OR UPDATE ON streams
    FOR EACH ROW EXECUTE FUNCTION notify_events();

-- Immutability: prevent event mutation
CREATE OR REPLACE FUNCTION prevent_mutation() RETURNS TRIGGER AS $$
BEGIN
    RAISE EXCEPTION 'Immutable table: % cannot be updated', TG_TABLE_NAME;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS no_update_events ON events;
CREATE TRIGGER no_update_events
    BEFORE UPDATE ON events
    FOR EACH ROW EXECUTE FUNCTION prevent_mutation();

DROP TRIGGER IF EXISTS no_update_stream_events ON stream_events;
CREATE TRIGGER no_update_stream_events
    BEFORE UPDATE ON stream_events
    FOR EACH ROW EXECUTE FUNCTION prevent_mutation();

-- Gated hard deletes (for maintenance/GDPR only)
CREATE OR REPLACE FUNCTION protect_deletion() RETURNS TRIGGER AS $$
BEGIN
    IF current_setting('kiroku.enable_hard_deletes', true) = 'on' THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'Hard deletes require: SET LOCAL kiroku.enable_hard_deletes = ''on''';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS no_delete_events ON events;
CREATE TRIGGER no_delete_events
    BEFORE DELETE ON events
    FOR EACH ROW EXECUTE FUNCTION protect_deletion();

DROP TRIGGER IF EXISTS no_delete_stream_events ON stream_events;
CREATE TRIGGER no_delete_stream_events
    BEFORE DELETE ON stream_events
    FOR EACH ROW EXECUTE FUNCTION protect_deletion();

DROP TRIGGER IF EXISTS no_delete_streams ON streams;
CREATE TRIGGER no_delete_streams
    BEFORE DELETE ON streams
    FOR EACH ROW EXECUTE FUNCTION protect_deletion();

-- TRUNCATE bypasses row-level triggers, so the BEFORE DELETE triggers above
-- do not protect against an operator running TRUNCATE on these tables. Add
-- statement-level BEFORE TRUNCATE triggers gated by the same GUC so the
-- protection is symmetric. See EP-1 F6.
CREATE OR REPLACE FUNCTION protect_truncation() RETURNS TRIGGER AS $$
BEGIN
    IF current_setting('kiroku.enable_hard_deletes', true) = 'on' THEN
        RETURN NULL;
    END IF;
    RAISE EXCEPTION 'TRUNCATE requires: SET LOCAL kiroku.enable_hard_deletes = ''on''';
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS no_truncate_events ON events;
CREATE TRIGGER no_truncate_events
    BEFORE TRUNCATE ON events
    FOR EACH STATEMENT EXECUTE FUNCTION protect_truncation();

DROP TRIGGER IF EXISTS no_truncate_stream_events ON stream_events;
CREATE TRIGGER no_truncate_stream_events
    BEFORE TRUNCATE ON stream_events
    FOR EACH STATEMENT EXECUTE FUNCTION protect_truncation();

DROP TRIGGER IF EXISTS no_truncate_streams ON streams;
CREATE TRIGGER no_truncate_streams
    BEFORE TRUNCATE ON streams
    FOR EACH STATEMENT EXECUTE FUNCTION protect_truncation();
-- END 2026-05-16-00-00-00-kiroku-bootstrap.sql

-- BEGIN 2026-05-17-00-00-00-keiro-bootstrap.sql (f1d67a0)
-- Pin the session search_path so unqualified names resolve into the kiroku
-- schema when this migration is applied incrementally to an existing database
-- (search_path is session-scoped; see
-- docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md).
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS keiro_snapshots (
  stream_id BIGINT PRIMARY KEY,
  stream_version BIGINT NOT NULL,
  state JSONB NOT NULL,
  state_codec_version BIGINT NOT NULL,
  regfile_shape_hash TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS keiro_snapshots_compat_idx
  ON keiro_snapshots (stream_id, state_codec_version, regfile_shape_hash, stream_version DESC);

CREATE TABLE IF NOT EXISTS keiro_read_models (
  name TEXT PRIMARY KEY,
  version BIGINT NOT NULL,
  shape_hash TEXT NOT NULL,
  last_built_at TIMESTAMPTZ,
  status TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS keiro_timers (
  timer_id UUID PRIMARY KEY,
  process_manager_name TEXT NOT NULL,
  correlation_id TEXT NOT NULL,
  fire_at TIMESTAMPTZ NOT NULL,
  payload JSONB NOT NULL,
  status TEXT NOT NULL DEFAULT 'scheduled',
  attempts BIGINT NOT NULL DEFAULT 0,
  fired_event_id UUID,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS keiro_timers_due_idx
  ON keiro_timers (status, fire_at, process_manager_name);
-- END 2026-05-17-00-00-00-keiro-bootstrap.sql

-- BEGIN 2026-05-17-01-00-00-keiro-outbox.sql (f1d67a0)
-- Pin the session search_path so unqualified names resolve into the kiroku
-- schema when this migration is applied incrementally to an existing database
-- (search_path is session-scoped; see
-- docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md).
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS keiro_outbox (
  outbox_id UUID PRIMARY KEY,
  message_id TEXT NOT NULL,
  source TEXT NOT NULL,
  destination TEXT NOT NULL,
  message_key TEXT,
  event_type TEXT NOT NULL,
  schema_version BIGINT NOT NULL,
  content_type TEXT NOT NULL,
  schema_registry TEXT,
  schema_subject TEXT,
  schema_version_ref BIGINT,
  schema_id BIGINT,
  schema_fingerprint TEXT,
  source_event_id UUID,
  source_global_position BIGINT,
  causation_id UUID,
  correlation_id UUID,
  traceparent TEXT,
  tracestate TEXT,
  payload_bytes BYTEA NOT NULL,
  attributes JSONB,
  occurred_at TIMESTAMPTZ NOT NULL,
  status TEXT NOT NULL DEFAULT 'pending',
  attempt_count BIGINT NOT NULL DEFAULT 0,
  next_attempt_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_error TEXT,
  published_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  UNIQUE (source, message_id)
);

CREATE INDEX IF NOT EXISTS keiro_outbox_pending_idx
  ON keiro_outbox (status, next_attempt_at, created_at);

CREATE INDEX IF NOT EXISTS keiro_outbox_head_of_line_idx
  ON keiro_outbox (source, message_key, created_at)
  WHERE status NOT IN ('sent', 'dead') AND message_key IS NOT NULL;
-- END 2026-05-17-01-00-00-keiro-outbox.sql

-- BEGIN 2026-05-17-02-00-00-keiro-inbox.sql (f1d67a0)
-- Pin the session search_path so unqualified names resolve into the kiroku
-- schema when this migration is applied incrementally to an existing database
-- (search_path is session-scoped; see
-- docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md).
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS keiro_inbox (
  source TEXT NOT NULL,
  dedupe_key TEXT NOT NULL,
  message_id TEXT,
  source_event_id UUID,
  source_global_position BIGINT,
  destination TEXT,
  event_type TEXT,
  schema_version BIGINT,
  content_type TEXT NOT NULL,
  schema_registry TEXT,
  schema_subject TEXT,
  schema_version_ref BIGINT,
  schema_id BIGINT,
  schema_fingerprint TEXT,
  causation_id UUID,
  correlation_id UUID,
  traceparent TEXT,
  tracestate TEXT,
  kafka_topic TEXT,
  kafka_partition BIGINT,
  kafka_offset BIGINT,
  payload_bytes BYTEA NOT NULL,
  attributes JSONB,
  occurred_at TIMESTAMPTZ,
  status TEXT NOT NULL DEFAULT 'processing',
  received_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at TIMESTAMPTZ,
  failed_at TIMESTAMPTZ,
  last_error TEXT,
  PRIMARY KEY (source, dedupe_key)
);

CREATE INDEX IF NOT EXISTS keiro_inbox_received_idx
  ON keiro_inbox (received_at);

CREATE INDEX IF NOT EXISTS keiro_inbox_completed_idx
  ON keiro_inbox (completed_at)
  WHERE status = 'completed';
-- END 2026-05-17-02-00-00-keiro-inbox.sql

-- BEGIN 2026-05-17-03-00-00-keiro-timer-recovery.sql (f1d67a0)
-- Pin the session search_path so unqualified names resolve into the kiroku
-- schema when this migration is applied incrementally to an existing database
-- (search_path is session-scoped; see
-- docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md).
SET search_path TO kiroku, pg_catalog;

ALTER TABLE keiro_timers
  ADD COLUMN IF NOT EXISTS last_error TEXT;

DROP INDEX IF EXISTS keiro_timers_due_idx;

CREATE INDEX IF NOT EXISTS keiro_timers_due_idx
  ON keiro_timers (status, fire_at, process_manager_name)
  WHERE status IN ('scheduled', 'firing');
-- END 2026-05-17-03-00-00-keiro-timer-recovery.sql

-- BEGIN 2026-05-26-00-00-00-add-subscription-dead-letters.sql (4312aa8)
-- Add the kiroku.dead_letters table (MasterPlan 6 / EP-2, docs/plans/40-...).
--
-- Forward, additive migration: codd applies this file once, records it, and
-- skips it on later runs. It does not edit the bootstrap migration and does not
-- mutate existing event data.
--
-- A dead-letter row records one event that a subscription handler asked to
-- "dead-letter" (return DeadLetter, or exhaust its bounded retry budget). The
-- event itself stays immutable in kiroku.events; this table references it by
-- event_id and global_position rather than copying the payload. The
-- consumer_group_member column (default 0, matching kiroku.subscriptions)
-- attributes the row to the member that produced it, so a consumer group's dead
-- letters are per-member. The worker writes a row and advances the member's
-- checkpoint in one atomic statement (see SQL.insertDeadLetterAndCheckpointStmt).

CREATE TABLE IF NOT EXISTS kiroku.dead_letters (
    dead_letter_id        BIGSERIAL    PRIMARY KEY,
    subscription_name     TEXT         NOT NULL,
    consumer_group_member INT          NOT NULL DEFAULT 0,
    global_position       BIGINT       NOT NULL,
    event_id              UUID         NOT NULL REFERENCES kiroku.events(event_id),
    reason                JSONB        NOT NULL,
    reason_summary        TEXT         NOT NULL,
    attempt_count         INT          NOT NULL,
    created_at            TIMESTAMPTZ  NOT NULL DEFAULT now(),
    UNIQUE (subscription_name, consumer_group_member, global_position, event_id)
);

-- Operator read path: list a subscription member's dead letters by recency.
CREATE INDEX IF NOT EXISTS ix_dead_letters_subscription_created_at
    ON kiroku.dead_letters (subscription_name, consumer_group_member, created_at);
-- END 2026-05-26-00-00-00-add-subscription-dead-letters.sql

-- BEGIN 2026-06-03-00-00-00-keiro-workflow-steps.sql (f1d67a0)
-- The fast-lookup index of journaled workflow steps. The journal stream
-- (wf:<name>-<id>) is the source of truth for replay; this table is a derived
-- view kept in sync inside the same transaction as each journal append. It
-- lets the runtime hot path and the EP-42 resume worker look up a step (or
-- discover unfinished workflows) without rescanning the journal stream.
--
-- The reserved step name '__workflow_completed__' is written when a workflow
-- finishes (see Keiro.Workflow.Types.completedStepName); its absence is how
-- findUnfinishedWorkflowIds distinguishes an in-flight workflow from a
-- completed one.
-- Pin the session search_path so unqualified names resolve into the kiroku
-- schema when this migration is applied incrementally to an existing database
-- (search_path is session-scoped; see
-- docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md).
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS keiro_workflow_steps (
  workflow_id    text        NOT NULL,
  workflow_name  text        NOT NULL,
  step_name      text        NOT NULL,
  result         jsonb       NOT NULL,
  recorded_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (workflow_id, step_name)
);

CREATE INDEX IF NOT EXISTS keiro_workflow_steps_workflow_idx
  ON keiro_workflow_steps (workflow_id);
-- END 2026-06-03-00-00-00-keiro-workflow-steps.sql

-- BEGIN 2026-06-03-01-00-00-keiro-awakeables.sql (f1d67a0)
-- The keiro_awakeables table: durable promises an external system resolves.
--
-- A workflow's `awakeable` allocates a deterministic id, inserts a 'pending'
-- row here, and suspends; an external caller later runs `signalAwakeable`,
-- which flips the row to 'completed' (storing the payload) and appends a
-- StepRecorded "awk:<uuid>" to the owning workflow's journal so the next
-- runWorkflow takes the awaitStep hit path. `cancelAwakeable` flips a still
-- 'pending' row to 'cancelled'; a subsequent run then throws.
--
-- The journal stream (wf:<name>-<id>) remains the source of truth for replay;
-- this table is the external-completion handshake plus operator-visible state
-- (a stuck 'pending' row is a workflow waiting on a callback that never came).
-- Pin the session search_path so unqualified names resolve into the kiroku
-- schema when this migration is applied incrementally to an existing database
-- (search_path is session-scoped; see
-- docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md).
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS keiro_awakeables (
  awakeable_id        UUID PRIMARY KEY,
  owner_workflow_name TEXT        NOT NULL,
  owner_workflow_id   TEXT        NOT NULL,
  status              TEXT        NOT NULL DEFAULT 'pending',
  payload             JSONB,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at        TIMESTAMPTZ,
  CONSTRAINT keiro_awakeables_status_chk
    CHECK (status IN ('pending', 'completed', 'cancelled'))
);

-- Gauge support (EP-44 keiro.workflow.awakeables.pending) and operator triage.
CREATE INDEX IF NOT EXISTS keiro_awakeables_pending_idx
  ON keiro_awakeables (status)
  WHERE status = 'pending';

-- Find all awakeables owned by one workflow instance (operator repair, EP-42/EP-43).
CREATE INDEX IF NOT EXISTS keiro_awakeables_owner_idx
  ON keiro_awakeables (owner_workflow_name, owner_workflow_id);
-- END 2026-06-03-01-00-00-keiro-awakeables.sql

-- BEGIN 2026-06-03-02-00-00-keiro-workflow-children.sql (f1d67a0)
-- The keiro_workflow_children table: durable parent->child workflow links.
--
-- A parent workflow's `spawnChild` records the child in the parent's journal
-- as a StepRecorded "child:<childId>" (so a replay short-circuits the spawn)
-- and inserts a 'running' row here linking the child's (id, name) back to the
-- parent's (id, name) plus the parent-journal step the parent awaits
-- ("child:<childId>:result"). When the child completes, `childCompletionHook`
-- flips the row to 'completed' (storing the child's result) and appends that
-- await step to the parent's journal so the parent's `awaitChild` resolves.
-- `cancelChild` flips a still-'running' row to 'cancelled' and writes a
-- WorkflowCancelled marker to the child's journal so the child stops.
--
-- The journal streams (wf:<name>-<id>) remain the source of truth for replay;
-- this table is the parent<->child relation plus operator-visible state and
-- the discovery seed that lets the resume worker drive a zero-step child.
-- Pin the session search_path so unqualified names resolve into the kiroku
-- schema when this migration is applied incrementally to an existing database
-- (search_path is session-scoped; see
-- docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md).
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS keiro_workflow_children (
  child_id      TEXT        NOT NULL,
  child_name    TEXT        NOT NULL,
  parent_id     TEXT        NOT NULL,
  parent_name   TEXT        NOT NULL,
  await_step    TEXT        NOT NULL,   -- "child:<childId>:result" in the parent journal
  status        TEXT        NOT NULL DEFAULT 'running',
  result        JSONB,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at  TIMESTAMPTZ,
  PRIMARY KEY (child_id, child_name),
  CONSTRAINT keiro_workflow_children_status_chk
    CHECK (status IN ('running', 'completed', 'cancelled'))
);

-- List all children of one parent (operator inspection, awaitChild arm re-assertion).
CREATE INDEX IF NOT EXISTS keiro_workflow_children_parent_idx
  ON keiro_workflow_children (parent_id, parent_name);

-- Discovery for the resume worker: children still running (zero-step children too).
CREATE INDEX IF NOT EXISTS keiro_workflow_children_running_idx
  ON keiro_workflow_children (status)
  WHERE status = 'running';
-- END 2026-06-03-02-00-00-keiro-workflow-children.sql

-- BEGIN 2026-06-05-00-00-00-keiro-workflow-generation.sql (f1d67a0)
-- Resolve unqualified names into the Kiroku schema (search_path is session-scoped;
-- see docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md).
-- The kiroku schema and keiro_workflow_steps already exist.
SET search_path TO kiroku, pg_catalog;

-- Continue-as-new (EP-48) rotates a long-running workflow onto a fresh journal
-- *generation* so its history stays bounded. The logical identity
-- (workflow_id, workflow_name) is stable; the generation discriminates the
-- physical journal stream wf:<name>-<id>#<gen>. Generation 0 is the pre-rotation
-- default, so every existing row and every never-rotating workflow is unaffected.
ALTER TABLE keiro_workflow_steps
  ADD COLUMN IF NOT EXISTS generation integer NOT NULL DEFAULT 0;

-- Fold the generation (and workflow_name) into the key so two generations of the
-- same logical workflow do not collide on a reserved step name (e.g. the terminal
-- markers). Adding columns to the key is a strict relaxation: no existing row can
-- violate the wider key. The as-shipped key is (workflow_id, step_name) — plan 47
-- (which would have keyed on (workflow_id, workflow_name, step_name)) has NOT landed,
-- so this migration re-keys with workflow_name AND generation in one step, doing both
-- jobs at once. The base table's primary-key constraint is named
-- keiro_workflow_steps_pkey (Postgres default <table>_pkey).
ALTER TABLE keiro_workflow_steps DROP CONSTRAINT keiro_workflow_steps_pkey;
ALTER TABLE keiro_workflow_steps
  ADD PRIMARY KEY (workflow_id, workflow_name, generation, step_name);

-- Support the current-generation lookup (MAX(generation) per id+name). Replaces the
-- old (workflow_id)-only lookup index.
DROP INDEX IF EXISTS keiro_workflow_steps_workflow_idx;
CREATE INDEX IF NOT EXISTS keiro_workflow_steps_workflow_idx
  ON keiro_workflow_steps (workflow_id, workflow_name, generation);
-- END 2026-06-05-00-00-00-keiro-workflow-generation.sql

-- BEGIN 2026-06-05-01-00-00-keiro-subscription-shards.sql (f1d67a0)
-- The keiro_subscription_shards table: cooperative ownership of category
-- subscription buckets (EP-51).
--
-- A "bucket" is a kiroku consumer-group member index in [0, shard_count): the
-- stream key (originating stream_id) hashes to one bucket via
--   (((hashtextextended(stream_id::text, 0) % shard_count) + shard_count) % shard_count)
-- exactly as kiroku's readCategoryForwardConsumerGroupStmt does. This table does
-- NOT re-hash anything; it records WHO owns each bucket right now, as a renewable
-- lease. A live worker renews lease_expires_at on a heartbeat; a dead worker stops
-- renewing, its lease expires, and another worker re-claims the bucket (failover).
--
-- One row per (subscription_name, bucket). owner_worker_id NULL means unowned
-- (free to claim). The journal/checkpoints stay in kiroku's `subscriptions` table
-- keyed (subscription_name, consumer_group_member); this table only governs
-- assignment, never event position.
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS keiro_subscription_shards (
  subscription_name  TEXT        NOT NULL,
  bucket             INT         NOT NULL,        -- kiroku consumer-group member index
  shard_count        INT         NOT NULL,        -- N; fixed per subscription_name
  owner_worker_id    UUID,                        -- NULL = unowned / claimable
  lease_expires_at   TIMESTAMPTZ,                 -- NULL when unowned
  heartbeat_at       TIMESTAMPTZ,                 -- last renewal (observability)
  updated_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (subscription_name, bucket),
  CONSTRAINT keiro_subscription_shards_bucket_range_chk
    CHECK (bucket >= 0 AND bucket < shard_count),
  CONSTRAINT keiro_subscription_shards_count_chk
    CHECK (shard_count >= 1)
);

-- Fast lookup of an owner's currently-held buckets (renew path) and of
-- claimable buckets (claim path filters on lease_expires_at).
CREATE INDEX IF NOT EXISTS keiro_subscription_shards_owner_idx
  ON keiro_subscription_shards (subscription_name, owner_worker_id);

-- Find expired/unowned buckets cheaply during a claim sweep.
CREATE INDEX IF NOT EXISTS keiro_subscription_shards_lease_idx
  ON keiro_subscription_shards (subscription_name, lease_expires_at);
-- END 2026-06-05-01-00-00-keiro-subscription-shards.sql

-- BEGIN 2026-06-11-00-00-00-notify-trigger-append-guard.sql (4312aa8)
-- Guard append notifications at the trigger level.
--
-- The trigger function and payload format stay unchanged:
--   stream_name,stream_id,stream_version
--
-- INSERT covers newly-created streams. UPDATE covers later appends to an
-- existing stream. Both exclude the internal $all row (stream_id = 0), and the
-- UPDATE trigger only fires when an append advances stream_version, not for
-- lifecycle updates such as soft-delete or undelete.

DROP TRIGGER IF EXISTS stream_events_notify ON kiroku.streams;

DROP TRIGGER IF EXISTS stream_events_notify_insert ON kiroku.streams;
CREATE TRIGGER stream_events_notify_insert
    AFTER INSERT ON kiroku.streams
    FOR EACH ROW
    WHEN (NEW.stream_id <> 0)
    EXECUTE FUNCTION kiroku.notify_events();

DROP TRIGGER IF EXISTS stream_events_notify_update ON kiroku.streams;
CREATE TRIGGER stream_events_notify_update
    AFTER UPDATE ON kiroku.streams
    FOR EACH ROW
    WHEN (NEW.stream_id <> 0
          AND NEW.stream_version IS DISTINCT FROM OLD.stream_version)
    EXECUTE FUNCTION kiroku.notify_events();
-- END 2026-06-11-00-00-00-notify-trigger-append-guard.sql

-- BEGIN 2026-06-11-00-00-01-dead-letters-event-id-index.sql (4312aa8)
-- Index dead_letters by event_id (MasterPlan 9 / EP-5, docs/plans/60-...).
--
-- dead_letters.event_id has a FK to kiroku.events. The UNIQUE key leads with
-- subscription_name, so every referential-integrity check triggered by a
-- DELETE on kiroku.events (the hard-delete path) was a sequential scan of
-- dead_letters, and the hard-delete transaction's own dead-letter pre-delete
-- (Kiroku.Store.SQL.deleteDeadLettersForOrphanedEventsStmt) needs the same
-- access path.
CREATE INDEX IF NOT EXISTS ix_dead_letters_event_id
    ON kiroku.dead_letters (event_id);
-- END 2026-06-11-00-00-01-dead-letters-event-id-index.sql

-- BEGIN 2026-06-11-00-00-02-index-hygiene-and-streams-fillfactor.sql (4312aa8)
-- Index hygiene and $all hot-row tuning (MasterPlan 9 / EP-5, docs/plans/60-...).

-- 1. ix_events_event_type is referenced by no statement in kiroku-store; it is
--    pure write amplification on every append. Server-side event-type pushdown
--    (see the EventTypeFilter haddock in kiroku-store) should re-add a
--    fit-for-purpose index when it ships.
DROP INDEX IF EXISTS kiroku.ix_events_event_type;

-- 2. Stream versions are unique per stream by construction (assigned under the
--    stream row lock; $all versions are the global position). Enforce it so a
--    version-assignment bug surfaces as a loud 23505 instead of silent
--    duplicates. Built as a new unique index, then the old non-unique index is
--    dropped (an index cannot be altered to unique in place).
CREATE UNIQUE INDEX IF NOT EXISTS ux_stream_events_stream_version
    ON kiroku.stream_events (stream_id, stream_version);
DROP INDEX IF EXISTS kiroku.ix_stream_events_stream_version;

-- 3. readDeadLetters orders by (global_position DESC, dead_letter_id DESC) --
--    the store's canonical, deterministic "newest first". Re-key the read
--    index to match so the read is index-ordered instead of sorting each time.
CREATE INDEX IF NOT EXISTS ix_dead_letters_subscription_position
    ON kiroku.dead_letters
       (subscription_name, consumer_group_member,
        global_position DESC, dead_letter_id DESC);
DROP INDEX IF EXISTS kiroku.ix_dead_letters_subscription_created_at;

-- 4. The $all row (stream_id 0) is updated by every append in the database.
--    Its updated column (stream_version) is not indexed, so updates are
--    HOT-eligible when the page has free space; fillfactor 50 reserves that
--    space on newly written pages. Existing pages converge through normal
--    update/prune activity (VACUUM cannot run inside this migration's
--    transaction). Autovacuum tuning for this table is left to operators.
ALTER TABLE kiroku.streams SET (fillfactor = 50);
-- END 2026-06-11-00-00-02-index-hygiene-and-streams-fillfactor.sql

-- BEGIN 2026-06-11-00-00-03-stream-name-length-check.sql (4312aa8)
-- Defense-in-depth bound on stream-name length (MasterPlan 9 / EP-5,
-- docs/plans/60-...). The Haskell store validates this before any SQL
-- (StoreError StreamNameTooLong, maxStreamNameBytes = 512); the constraint
-- catches writers that bypass the library (raw SQL via runTransaction,
-- psql sessions). 512 bytes is far below pg_notify's 8,000-byte payload
-- limit, so the append-notification trigger can never abort on payload size.
ALTER TABLE kiroku.streams
    ADD CONSTRAINT chk_streams_stream_name_length
    CHECK (octet_length(stream_name) <= 512);
-- END 2026-06-11-00-00-03-stream-name-length-check.sql

-- BEGIN 2026-06-11-00-00-04-keiro-workflows-instances.sql (f1d67a0)
-- Workflow instance state used by the resume worker and by later discovery /
-- pruning work. The journal remains the source of truth; this table is a
-- transactional summary maintained beside journal-index writes.
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS keiro_workflows (
  workflow_id      TEXT        NOT NULL,
  workflow_name    TEXT        NOT NULL,
  generation       INTEGER     NOT NULL DEFAULT 0,
  status           TEXT        NOT NULL DEFAULT 'running',
  attempts         INTEGER     NOT NULL DEFAULT 0,
  last_error       TEXT,
  next_attempt_at  TIMESTAMPTZ,
  leased_by        TEXT,
  lease_expires_at TIMESTAMPTZ,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  completed_at     TIMESTAMPTZ,
  PRIMARY KEY (workflow_id, workflow_name),
  CONSTRAINT keiro_workflows_status_chk
    CHECK (status IN ('running', 'suspended', 'completed', 'cancelled', 'failed'))
);

CREATE INDEX IF NOT EXISTS keiro_workflows_active_idx
  ON keiro_workflows (status)
  WHERE status IN ('running', 'suspended');

WITH current_gen AS (
  SELECT workflow_id, workflow_name, MAX(generation) AS generation
  FROM keiro_workflow_steps
  GROUP BY workflow_id, workflow_name
),
terminal AS (
  SELECT
    cg.workflow_id,
    cg.workflow_name,
    cg.generation,
    CASE
      WHEN EXISTS (
        SELECT 1 FROM keiro_workflow_steps s
        WHERE s.workflow_id = cg.workflow_id
          AND s.workflow_name = cg.workflow_name
          AND s.generation = cg.generation
          AND s.step_name = '__workflow_completed__'
      ) THEN 'completed'
      WHEN EXISTS (
        SELECT 1 FROM keiro_workflow_steps s
        WHERE s.workflow_id = cg.workflow_id
          AND s.workflow_name = cg.workflow_name
          AND s.generation = cg.generation
          AND s.step_name = '__workflow_cancelled__'
      ) THEN 'cancelled'
      WHEN EXISTS (
        SELECT 1 FROM keiro_workflow_steps s
        WHERE s.workflow_id = cg.workflow_id
          AND s.workflow_name = cg.workflow_name
          AND s.generation = cg.generation
          AND s.step_name = '__workflow_failed__'
      ) THEN 'failed'
      ELSE 'running'
    END AS status
  FROM current_gen cg
)
INSERT INTO keiro_workflows (workflow_id, workflow_name, generation, status, completed_at)
SELECT workflow_id, workflow_name, generation, status,
       CASE WHEN status IN ('completed', 'cancelled', 'failed') THEN now() ELSE NULL END
FROM terminal
ON CONFLICT (workflow_id, workflow_name) DO NOTHING;

INSERT INTO keiro_workflows (workflow_id, workflow_name, generation, status)
SELECT child_id, child_name, 0, 'running'
FROM keiro_workflow_children
WHERE status = 'running'
ON CONFLICT (workflow_id, workflow_name) DO NOTHING;

ALTER TABLE keiro_workflow_children DROP CONSTRAINT IF EXISTS keiro_workflow_children_status_chk;
ALTER TABLE keiro_workflow_children ADD CONSTRAINT keiro_workflow_children_status_chk
  CHECK (status IN ('running', 'completed', 'cancelled', 'failed'));
-- END 2026-06-11-00-00-04-keiro-workflows-instances.sql

-- BEGIN 2026-06-15-13-22-31-keiro-messaging-crash-recovery.sql (f1d67a0)
-- messaging crash recovery
--
-- Pin the session search_path so unqualified names resolve into the kiroku
-- schema when this migration is applied incrementally to an existing database
-- (search_path is session-scoped; see
-- docs/plans/46-keiro-framework-migrations-self-set-search-path-for-incremental-upgrades.md).
SET search_path TO kiroku, pg_catalog;

-- H5: per-message failure accounting for the inbox poison-message path.
ALTER TABLE keiro_inbox
  ADD COLUMN IF NOT EXISTS attempt_count BIGINT NOT NULL DEFAULT 0;

-- H3: lets the backlog gauge count rows without a sequential scan.
CREATE INDEX IF NOT EXISTS keiro_inbox_backlog_idx
  ON keiro_inbox (status)
  WHERE status IN ('processing', 'failed');

-- H4: lets garbageCollectSent find expired sent rows without a sequential scan.
CREATE INDEX IF NOT EXISTS keiro_outbox_sent_gc_idx
  ON keiro_outbox (published_at)
  WHERE status = 'sent';

-- L8: supports the PerSourceStream head-of-line predicate (any key, including
-- NULL); the existing keiro_outbox_head_of_line_idx excludes NULL keys.
CREATE INDEX IF NOT EXISTS keiro_outbox_source_order_idx
  ON keiro_outbox (source, created_at, outbox_id)
  WHERE status NOT IN ('sent', 'dead');
-- END 2026-06-15-13-22-31-keiro-messaging-crash-recovery.sql

-- BEGIN 2026-06-15-21-49-37-keiro-projection-dedup.sql (f1d67a0)
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS keiro_projection_dedup (
  projection_name TEXT        NOT NULL,
  event_id        UUID        NOT NULL,
  applied_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (projection_name, event_id)
);

CREATE INDEX IF NOT EXISTS keiro_projection_dedup_applied_at_idx
  ON keiro_projection_dedup (applied_at);
-- END 2026-06-15-21-49-37-keiro-projection-dedup.sql

-- BEGIN 2026-06-15-22-10-00-keiro-workflow-gc-index.sql (f1d67a0)
-- Resolve unqualified names into the Kiroku schema.
SET search_path TO kiroku, pg_catalog;

-- GC eligibility scan: terminal instances ordered by terminal age.
CREATE INDEX IF NOT EXISTS keiro_workflows_gc_idx
  ON keiro_workflows (status, completed_at);
-- END 2026-06-15-22-10-00-keiro-workflow-gc-index.sql

-- BEGIN 2026-06-15-22-20-00-keiro-workflows-wake-after.sql (f1d67a0)
-- Resolve unqualified names into the Kiroku schema.
SET search_path TO kiroku, pg_catalog;

-- Self-expiring resume hint for workflows parked only on a sleep timer.
ALTER TABLE keiro_workflows
  ADD COLUMN IF NOT EXISTS wake_after TIMESTAMPTZ;
-- END 2026-06-15-22-20-00-keiro-workflows-wake-after.sql

-- BEGIN 2026-06-24-00-00-00-kioku-base.sql (HEAD)
-- codd: in-txn

-- Migration: kioku-base
-- Created: 2026-06-24-00-00-00 UTC
-- kioku read-model tables live in the kiroku schema.
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS kioku_memories (
  memory_id     text PRIMARY KEY,
  agent_id      text NOT NULL,
  session_id    text,
  namespace     text NOT NULL,
  scope_kind    text,
  scope_ref     text,
  memory_type   text NOT NULL,
  content       text NOT NULL,
  priority      integer NOT NULL DEFAULT 100,
  confidence    text NOT NULL DEFAULT 'medium',
  tags          jsonb NOT NULL DEFAULT '[]',
  status        text NOT NULL DEFAULT 'active',
  superseded_by text,
  supersedes    text,
  content_tsv   tsvector GENERATED ALWAYS AS (to_tsvector('english', content)) STORED,
  created_at    timestamptz NOT NULL,
  updated_at    timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS kioku_memories_status_idx ON kioku_memories (status);
CREATE INDEX IF NOT EXISTS kioku_memories_scope_idx
  ON kioku_memories (namespace, scope_kind, scope_ref) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS kioku_memories_type_idx ON kioku_memories (memory_type) WHERE status = 'active';
CREATE INDEX IF NOT EXISTS kioku_memories_session_idx ON kioku_memories (session_id);
CREATE INDEX IF NOT EXISTS kioku_memories_tsv_idx ON kioku_memories USING gin (content_tsv);

CREATE TABLE IF NOT EXISTS kioku_sessions (
  session_id          text PRIMARY KEY,
  agent_id            text NOT NULL,
  focus               text NOT NULL,
  namespace           text NOT NULL,
  scope_kind          text,
  scope_ref           text,
  subject_ref         text,
  previous_session_id text,
  status              text NOT NULL DEFAULT 'running',
  started_at          timestamptz NOT NULL,
  completed_at        timestamptz,
  model_used          text,
  summary             text,
  error_message       text,
  created_at          timestamptz NOT NULL DEFAULT NOW(),
  updated_at          timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS kioku_sessions_status_idx ON kioku_sessions (status);
CREATE INDEX IF NOT EXISTS kioku_sessions_agent_idx ON kioku_sessions (agent_id);
CREATE INDEX IF NOT EXISTS kioku_sessions_scope_idx ON kioku_sessions (namespace, scope_kind, scope_ref);

CREATE TABLE IF NOT EXISTS kioku_turns (
  turn_id       text PRIMARY KEY,
  session_id    text NOT NULL,
  turn_index    integer NOT NULL,
  role          text NOT NULL,
  content       text NOT NULL,
  tool_summary  text,
  prompt_tokens integer,
  output_tokens integer,
  recorded_at   timestamptz NOT NULL,
  UNIQUE (session_id, turn_index)
);

CREATE INDEX IF NOT EXISTS kioku_turns_session_idx ON kioku_turns (session_id, turn_index);
-- END 2026-06-24-00-00-00-kioku-base.sql

-- BEGIN 2026-06-24-01-00-00-kioku-memory-embeddings.sql (HEAD)
-- codd: in-txn

-- Migration: kioku-memory-embeddings
-- Created: 2026-06-24-01-00-00 UTC
-- Adds optional pgvector-backed embedding columns for hybrid recall.
SET search_path TO kiroku, pg_catalog;

DO $$
DECLARE
  vector_available boolean := false;
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS vector;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'pgvector extension is unavailable (%: %); skipping kioku memory embedding columns and ANN index', SQLSTATE, SQLERRM;
  END;

  SELECT EXISTS (
    SELECT 1
    FROM pg_extension
    WHERE extname = 'vector'
  ) INTO vector_available;

  IF vector_available THEN
    EXECUTE 'ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS embedding vector(1536)';
    ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS embedding_model text;
    ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS dimensions integer;
    ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS content_hash text;

    EXECUTE 'CREATE INDEX IF NOT EXISTS kioku_memories_embedding_hnsw ON kioku_memories USING hnsw (embedding vector_cosine_ops) WHERE embedding IS NOT NULL';
    CREATE INDEX IF NOT EXISTS kioku_memories_content_hash_idx ON kioku_memories (content_hash);
  END IF;
END $$;
-- END 2026-06-24-01-00-00-kioku-memory-embeddings.sql

-- BEGIN 2026-06-24-02-00-00-kioku-distillation.sql (HEAD)
-- codd: in-txn

-- Migration: kioku-distillation
-- Created: 2026-06-24-02-00-00 UTC
-- Adds distillation pyramid read models and consolidation audit rows.
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS kioku_scenes (
  scene_id text PRIMARY KEY,
  namespace text NOT NULL,
  scope_kind text,
  scope_ref text,
  scene_key text NOT NULL,
  title text NOT NULL,
  body_md text NOT NULL,
  atom_ids jsonb NOT NULL DEFAULT '[]',
  source_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (namespace, scope_kind, scope_ref, scene_key)
);

CREATE INDEX IF NOT EXISTS kioku_scenes_scope_idx
  ON kioku_scenes (namespace, scope_kind, scope_ref);

CREATE TABLE IF NOT EXISTS kioku_personas (
  persona_id text PRIMARY KEY,
  namespace text NOT NULL,
  scope_kind text,
  scope_ref text,
  body_md text NOT NULL,
  scene_count integer NOT NULL DEFAULT 0,
  source_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT NOW(),
  updated_at timestamptz NOT NULL DEFAULT NOW(),
  UNIQUE (namespace, scope_kind, scope_ref)
);

CREATE TABLE IF NOT EXISTS kioku_consolidation_decisions (
  decision_id text PRIMARY KEY,
  session_id text,
  namespace text NOT NULL,
  scope_kind text,
  scope_ref text,
  candidate_content text NOT NULL,
  decision text NOT NULL CHECK (decision IN ('store', 'update', 'merge', 'skip')),
  target_ids jsonb NOT NULL DEFAULT '[]',
  result_memory_id text,
  rationale text,
  decided_at timestamptz NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS kioku_consolidation_session_idx
  ON kioku_consolidation_decisions (session_id);

CREATE INDEX IF NOT EXISTS kioku_consolidation_scope_idx
  ON kioku_consolidation_decisions (namespace, scope_kind, scope_ref);
-- END 2026-06-24-02-00-00-kioku-distillation.sql

-- BEGIN 2026-06-27-20-35-00-kioku-session-delegation-lineage.sql (HEAD)
-- codd: in-txn

SET search_path TO kiroku, pg_catalog;

ALTER TABLE kioku_sessions
  ADD COLUMN IF NOT EXISTS parent_session_id text,
  ADD COLUMN IF NOT EXISTS delegation_depth integer NOT NULL DEFAULT 0;

CREATE INDEX IF NOT EXISTS kioku_sessions_parent_session_idx
  ON kioku_sessions (parent_session_id, started_at)
  WHERE parent_session_id IS NOT NULL;
-- END 2026-06-27-20-35-00-kioku-session-delegation-lineage.sql

-- BEGIN 2026-06-27-21-10-35-kioku-awaiting-session-state.sql (HEAD)
-- codd: in-txn

-- Migration: kioku-awaiting-session-state
-- Created: 2026-06-27-21-10-35 UTC
-- Adds park-and-resume columns to the session read model.
SET search_path TO kiroku, pg_catalog;

ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS awaiting_reason text;
ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS awaiting_correlation_key text;
ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS awaiting_deadline timestamptz;
ALTER TABLE kioku_sessions ADD COLUMN IF NOT EXISTS resume_input text;

CREATE INDEX IF NOT EXISTS kioku_sessions_awaiting_corr_idx
  ON kioku_sessions (namespace, awaiting_correlation_key)
  WHERE status = 'awaiting';
-- END 2026-06-27-21-10-35-kioku-awaiting-session-state.sql

-- BEGIN 2026-07-03-14-37-18-kioku-session-readmodel-registry-bump.sql (HEAD)
-- codd: in-txn

-- Migration: kioku-session-readmodel-registry-bump
-- Created: 2026-07-03-14-37-18 UTC
-- Body rewritten 2026-07-11: locate keiro_read_models dynamically. See
-- docs/plans/14-align-read-model-reconciliation-with-keiro-schema-relocation-and-guard-embedded-migrations.md
--
-- The session read model reshaped v1 -> v2 (delegation lineage) -> v3 (awaiting
-- park/resume) through the two preceding, purely additive column migrations.
-- Those ALTER TABLE migrations left the underlying kioku_sessions data correct
-- for v3, but they did not touch the keiro_read_models registry. Because
-- registerReadModel only inserts a row (never bumps an existing one), any
-- database that registered a session read model before this upgrade stays
-- pinned at its old version, and every session query then fails closed with
-- ReadModelStaleSchema. Reconcile those rows to the current v3 identity.
--
-- keiro_read_models lives in a different schema depending on the keiro cohort:
-- in `kiroku` on the pinned cohort (keiro's bootstrap runs under
-- `SET search_path TO kiroku`), in a dedicated `keiro` schema after keiro's
-- schema relocation, and in `public` on some long-lived development databases.
-- Hard-coding a search_path here would make this file fail with undefined_table
-- on every fresh database built against a relocated keiro -- keiro's bootstrap
-- sorts before this file on every cohort, so there is no later migration that
-- could rescue it. Resolve the table dynamically instead, so this file is
-- correct on all three layouts and survives the pin bump.
--
-- A missing table means keiro's bootstrap did not run, i.e. a genuinely broken
-- database: fail loudly rather than silently reconciling nothing.
-- Idempotent: the guard skips rows already at v3.
DO $do$
DECLARE
  registry regclass;
BEGIN
  registry := COALESCE(
    to_regclass('keiro.keiro_read_models'),
    to_regclass('kiroku.keiro_read_models'),
    to_regclass('public.keiro_read_models'));

  IF registry IS NULL THEN
    RAISE EXCEPTION 'keiro_read_models not found in the keiro, kiroku, or public schemas';
  END IF;

  EXECUTE format($sql$
    UPDATE %s
    SET version = 3,
        shape_hash = 'kioku-session-v3',
        status = 'live',
        last_built_at = now(),
        updated_at = now()
    WHERE name IN (
        'kioku-session-by-id',
        'kioku-sessions-by-namespace',
        'kioku-sessions-by-scope',
        'kioku-sessions-by-focus',
        'kioku-sessions-by-started-range',
        'kioku-session-chain',
        'kioku-session-delegation-children',
        'kioku-sessions-awaiting-by-correlation-key'
      )
      AND (version <> 3 OR shape_hash <> 'kioku-session-v3')
  $sql$, registry);
END
$do$;
-- END 2026-07-03-14-37-18-kioku-session-readmodel-registry-bump.sql

-- BEGIN 2026-07-10-14-41-38-kioku-l1-watermarks.sql (HEAD)
-- codd: in-txn

-- Migration: kioku-l1-watermarks
-- Created: 2026-07-10-14-41-38 UTC
-- Per-session L1 distillation watermark: the highest turn index covered by a
-- fully successful pass. Read to skip re-extraction on timer re-fires; written
-- only after a pass completes without error.
SET search_path TO kiroku, pg_catalog;

CREATE TABLE IF NOT EXISTS kioku_l1_watermarks (
  session_id text PRIMARY KEY,
  last_turn_index integer NOT NULL DEFAULT 0,
  distilled_at timestamptz NOT NULL DEFAULT NOW()
);
-- END 2026-07-10-14-41-38-kioku-l1-watermarks.sql

-- BEGIN 2026-07-11-17-35-11-kioku-schema-hardening.sql (HEAD)
-- codd: in-txn

-- Migration: kioku-schema-hardening
-- Created: 2026-07-11-17-35-11 UTC
--
-- Four defects in the read-model schema, fixed together because they are all
-- constraint/index DDL on the same five scope-carrying tables:
--
--   1. The recursive supersession CTE (selectSupersessionChainStmt) joins on
--      `supersedes` and `superseded_by`, neither of which had an index, so every
--      recursion level was a sequential scan.
--   2. The session list/range/focus queries sort whole namespaces with no
--      supporting index.
--   3. The UNIQUE constraints on kioku_scenes and kioku_personas enforce nothing
--      for global-scope rows, because SQL treats NULLs as distinct: two global
--      personas for one namespace both satisfy UNIQUE (namespace, scope_kind,
--      scope_ref). PostgreSQL 15+ NULLS NOT DISTINCT closes that hole.
--   4. Nothing prevented a half-populated scope (scope_kind set, scope_ref NULL).
--      Such a row reads back as global (see Kioku.Api.Scope.scopeFromColumns) yet
--      matches no exact-scope query.
--
-- Everything below is idempotent: the repairs match nothing on a second pass, the
-- constraints are dropped before being added, and the indexes use IF NOT EXISTS.
SET search_path TO kiroku, pg_catalog;

-- Repair 1: normalise half-populated scope pairs to fully NULL, so the CHECK below
-- can be added to a non-empty database. This is not a behaviour change: such rows
-- already read back as global scopes.
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

-- Repair 2: drop duplicate global-scope scenes/personas, keeping the newest row per
-- logical scope, so the NULLS NOT DISTINCT constraints below can be added. Only
-- NULL-scoped duplicates can exist -- the old constraints already blocked the rest.
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

-- Scope uniqueness that also holds for global scopes. The upserts target the primary
-- keys (ON CONFLICT (scene_id) / (persona_id)), so replacing these constraints does
-- not disturb them.
ALTER TABLE kioku_scenes
  DROP CONSTRAINT IF EXISTS kioku_scenes_namespace_scope_kind_scope_ref_scene_key_key;
ALTER TABLE kioku_scenes
  DROP CONSTRAINT IF EXISTS kioku_scenes_scope_scene_key_unique;
ALTER TABLE kioku_scenes
  ADD CONSTRAINT kioku_scenes_scope_scene_key_unique
  UNIQUE NULLS NOT DISTINCT (namespace, scope_kind, scope_ref, scene_key);

ALTER TABLE kioku_personas
  DROP CONSTRAINT IF EXISTS kioku_personas_namespace_scope_kind_scope_ref_key;
ALTER TABLE kioku_personas
  DROP CONSTRAINT IF EXISTS kioku_personas_scope_unique;
ALTER TABLE kioku_personas
  ADD CONSTRAINT kioku_personas_scope_unique
  UNIQUE NULLS NOT DISTINCT (namespace, scope_kind, scope_ref);

-- A scope is either global (both columns NULL) or an entity scope (both set).
ALTER TABLE kioku_memories DROP CONSTRAINT IF EXISTS kioku_memories_scope_pair_check;
ALTER TABLE kioku_memories ADD CONSTRAINT kioku_memories_scope_pair_check
  CHECK ((scope_kind IS NULL) = (scope_ref IS NULL));

ALTER TABLE kioku_sessions DROP CONSTRAINT IF EXISTS kioku_sessions_scope_pair_check;
ALTER TABLE kioku_sessions ADD CONSTRAINT kioku_sessions_scope_pair_check
  CHECK ((scope_kind IS NULL) = (scope_ref IS NULL));

ALTER TABLE kioku_scenes DROP CONSTRAINT IF EXISTS kioku_scenes_scope_pair_check;
ALTER TABLE kioku_scenes ADD CONSTRAINT kioku_scenes_scope_pair_check
  CHECK ((scope_kind IS NULL) = (scope_ref IS NULL));

ALTER TABLE kioku_personas DROP CONSTRAINT IF EXISTS kioku_personas_scope_pair_check;
ALTER TABLE kioku_personas ADD CONSTRAINT kioku_personas_scope_pair_check
  CHECK ((scope_kind IS NULL) = (scope_ref IS NULL));

ALTER TABLE kioku_consolidation_decisions
  DROP CONSTRAINT IF EXISTS kioku_consolidation_decisions_scope_pair_check;
ALTER TABLE kioku_consolidation_decisions
  ADD CONSTRAINT kioku_consolidation_decisions_scope_pair_check
  CHECK ((scope_kind IS NULL) = (scope_ref IS NULL));

-- Indexes for the recursive supersession chain: its join arms are
-- `m.supersedes = c.memory_id OR m.superseded_by = c.memory_id`, and only the other
-- two arms hit the primary key.
CREATE INDEX IF NOT EXISTS kioku_memories_supersedes_idx
  ON kioku_memories (supersedes) WHERE supersedes IS NOT NULL;
CREATE INDEX IF NOT EXISTS kioku_memories_superseded_by_idx
  ON kioku_memories (superseded_by) WHERE superseded_by IS NOT NULL;

-- Indexes for the session list queries, which order by started_at within a namespace
-- (and, for the focus query, within a focus).
CREATE INDEX IF NOT EXISTS kioku_sessions_namespace_started_idx
  ON kioku_sessions (namespace, started_at DESC);
CREATE INDEX IF NOT EXISTS kioku_sessions_namespace_focus_idx
  ON kioku_sessions (namespace, focus, started_at DESC);

-- Pure write amplification: duplicates the index implied by
-- UNIQUE (session_id, turn_index) on the same table.
DROP INDEX IF EXISTS kioku_turns_session_idx;
-- END 2026-07-11-17-35-11-kioku-schema-hardening.sql

-- BEGIN 2026-07-11-17-45-43-kioku-embedding-schema-heal.sql (HEAD)
-- codd: in-txn

-- Migration: kioku-embedding-schema-heal
-- Created: 2026-07-11-17-45-43 UTC
--
-- A catch-up for 2026-06-24-01-00-00-kioku-memory-embeddings.sql, which is one-shot in the
-- worst way: it adds the embedding columns only if `CREATE EXTENSION vector` succeeds, but
-- codd records it applied either way. A database whose server had no pgvector at that
-- moment is therefore degraded *permanently* -- installing pgvector later changes nothing,
-- because the migration that would have used it will never run again. (This repository's
-- own dev database was in exactly that state.) This migration re-attempts the DDL, so any
-- database that gains the extension before its next `just migrate` heals itself.
--
-- It also fixes a bug in the original that only shows up when pgvector is installed in
-- `public`, which is where operators usually put it. There, `CREATE EXTENSION IF NOT EXISTS`
-- is a no-op, the `pg_extension` probe passes -- and then the *unqualified* `vector(1536)`
-- fails with `42704: type "vector" does not exist`, because migrations run with
-- `search_path = kiroku, pg_catalog`. The original migration aborts rather than degrading.
-- Below, the type and the operator class are schema-qualified with wherever the extension
-- actually lives, so the DDL succeeds under either layout.
--
-- Every statement is IF NOT EXISTS, so this is a no-op on a healthy database and on one
-- that is still missing pgvector.
SET search_path TO kiroku, pg_catalog;

DO $$
DECLARE
  vector_schema text;
BEGIN
  BEGIN
    -- With this migration's search_path, a fresh install lands in `kiroku`, which is also
    -- the schema the application's connections search -- so the type and the `<=>` operator
    -- resolve unqualified at query time.
    CREATE EXTENSION IF NOT EXISTS vector;
  EXCEPTION
    WHEN OTHERS THEN
      RAISE NOTICE 'pgvector extension is unavailable (%: %); leaving kioku memory embedding columns absent and recall keyword-only', SQLSTATE, SQLERRM;
  END;

  SELECT n.nspname
    INTO vector_schema
    FROM pg_extension e
    JOIN pg_namespace n ON n.oid = e.extnamespace
   WHERE e.extname = 'vector';

  IF vector_schema IS NULL THEN
    RETURN;
  END IF;

  EXECUTE format(
    'ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS embedding %I.vector(1536)',
    vector_schema
  );
  ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS embedding_model text;
  ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS dimensions integer;
  ALTER TABLE kioku_memories ADD COLUMN IF NOT EXISTS content_hash text;

  EXECUTE format(
    'CREATE INDEX IF NOT EXISTS kioku_memories_embedding_hnsw ON kioku_memories USING hnsw (embedding %I.vector_cosine_ops) WHERE embedding IS NOT NULL',
    vector_schema
  );
  CREATE INDEX IF NOT EXISTS kioku_memories_content_hash_idx ON kioku_memories (content_hash);

  -- The columns are correct in any schema, but naming the type is not: the application
  -- connects with `search_path = kiroku, pg_catalog` (Kiroku.Store.Connection's `schema`
  -- plus an empty `extraSearchPath`), and recall casts with a bare `$1::vector`. If the
  -- extension lives anywhere else, that cast cannot resolve and the vector path stays
  -- unusable no matter how healthy the schema looks.
  IF vector_schema <> 'kiroku' THEN
    RAISE WARNING 'pgvector is installed in schema %, not kiroku. The embedding columns exist, but kioku connects with search_path = kiroku, pg_catalog and cannot name the vector type, so recall will degrade to keyword-only. Fix by adding % to the store''s extraSearchPath, or by moving the extension: ALTER EXTENSION vector SET SCHEMA kiroku;', vector_schema, vector_schema;
  END IF;
END $$;
-- END 2026-07-11-17-45-43-kioku-embedding-schema-heal.sql

-- BEGIN 2026-07-11-18-18-36-kioku-scope-identity-recompute.sql (HEAD)
-- codd: in-txn

-- Migration: kioku-scope-identity-recompute
-- Created: 2026-07-11-18-18-36 UTC
--
-- Scene and persona primary keys are derived from the scope. The old derivation joined
-- namespace/kind/ref with '/' and no escaping, so two genuinely different scopes could
-- produce one id:
--
--   ScopeGlobal (Namespace 'a/b/c')                 -> 'a/b/c'
--   ScopeEntity (Namespace 'a') (ScopeKind 'b') 'c' -> 'a/b/c'
--
-- Both then wrote the same row, and since the upserts do not update the scope columns on
-- conflict, the second scope's body landed on a row still attributed to the first.
--
-- Kioku.Distill.ScopeIdentity now percent-escapes each component before joining. This
-- migration brings persisted ids in line with it. Components containing none of '%', '/' or
-- ':' escape to themselves, so almost every database has nothing to rewrite -- the WHERE
-- clauses below match only the ambiguous rows.
--
-- A row that had absorbed a second scope's content keeps the id derived from its *stored*
-- scope columns, i.e. it stays with the first writer. The second scope's scene or persona
-- simply regenerates under its own, now-distinct id on the next distillation timer: scenes
-- and personas are caches of kioku_memories, not records of truth.
--
-- Re-running recomputes the same values, so this is idempotent.
SET search_path TO kiroku, pg_catalog;

CREATE OR REPLACE FUNCTION pg_temp.kioku_escape_scope_component(component text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  -- '%' first, or the encoding is not injective.
  SELECT replace(replace(replace(component, '%', '%25'), '/', '%2F'), ':', '%3A')
$$;

-- The COALESCE collapses the kind/ref segment for global rows. The scope-pair CHECK added by
-- the schema-hardening migration guarantees kind and ref are NULL together, so there is no
-- half-populated case to worry about.
CREATE OR REPLACE FUNCTION pg_temp.kioku_scope_identity(namespace text, scope_kind text, scope_ref text)
RETURNS text
LANGUAGE sql IMMUTABLE
AS $$
  SELECT pg_temp.kioku_escape_scope_component(namespace)
      || COALESCE(
           '/' || pg_temp.kioku_escape_scope_component(scope_kind)
               || '/' || pg_temp.kioku_escape_scope_component(scope_ref),
           ''
         )
$$;

UPDATE kioku_scenes
   SET scene_id = 'kioku_scene:'
               || pg_temp.kioku_scope_identity(namespace, scope_kind, scope_ref)
               || ':'
               || pg_temp.kioku_escape_scope_component(scene_key)
 WHERE namespace ~ '[%/:]'
    OR scope_kind ~ '[%/:]'
    OR scope_ref ~ '[%/:]'
    OR scene_key ~ '[%/:]';

UPDATE kioku_personas
   SET persona_id = 'kioku_persona:'
                 || pg_temp.kioku_scope_identity(namespace, scope_kind, scope_ref)
 WHERE namespace ~ '[%/:]'
    OR scope_kind ~ '[%/:]'
    OR scope_ref ~ '[%/:]';
-- END 2026-07-11-18-18-36-kioku-scope-identity-recompute.sql
