# Postgres `enriched_events` partitioning: audit of docs/database_partitioning.md

Read when you check or repair pg_partman on a Lago Postgres, or before following
`docs/database_partitioning.md`. Verified 2026-10-01 (local Postgres 16.14 without pg_partman, throwaway
databases created and dropped).
`$API` = pinned lago-api checkout: `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)` (591ae90).

## 1. Who uses this table

`public.enriched_events` is a lago-api table. It is written by `Events::PostProcessService` only for
organizations with feature flag `postgres_enriched_events` (`$API/app/services/events/post_process_service.rb:94-99`;
default off). The events-processor never writes Postgres. So partition maintenance matters only where
that flag is on; the table exists (empty) everywhere the migrations ran.

## 2. What the doc gets right

| Claim | Evidence |
|---|---|
| range partitions by month on `timestamp`, premake 3, retention 14 months, keep table, infinite partitions, start 2024-12-01 | `$API/db/migrate/20260109132143_partition_enriched_events.rb` (create_parent + part_config UPDATE) |
| migrations skip gracefully without pg_partman, leaving a regular table | `20260109092932_setup_partman.rb`, `20260109110146_create_enriched_events.rb` (`pg_extension_present?`) |
| maintenance must run `partman.run_maintenance_proc()` periodically, else inserts pile into `enriched_events_default` | pg_partman behaviour; doc :143-150 |
| `pg_partman_bgw` settings `dbname/interval/role = lago/3600/lago` | `scripts/postgresql.conf:81-88` |

## 3. What the doc gets wrong

| # | Doc says | Truth | Proof |
|---|---|---|---|
| PD1 | "No additional setup is required when using the default Docker Compose configuration" (:249-251) | Only `docker-compose.dev.yml` mounts `scripts/postgresql.conf` (`-c config_file=...`, :43,50). Root `docker-compose.yml` uses `getlago/postgres-partman:15.0-alpine`, whose image config is plain `postgres:15.0-alpine` + pg_partman v5.4.0 with CMD `["postgres"]` (Docker Hub registry API, 2026-10-01): partman is available, `pg_partman_bgw` is NOT preloaded. deploy/ uses `postgres:15-alpine` (no partman: table unpartitioned). The all-in-one image installs `postgresql-17-partman` but runner.sh sets no `shared_preload_libraries` | compose files; registry config |
| PD2 | Step 3 DDL (:59-76) defines 15 columns | the schema has 18: `operation_type`, `precise_total_amount_cents numeric(40,15)`, `target_wallet_code` were added by `20260219102644_add_more_enrichment_to_enriched_events.rb` (the original 16-column create also had `properties`, dropped by `20260129145352`) | `$API/db/structure.sql:3045-3065` |
| PD3 | Step 5 `INSERT INTO public.enriched_events SELECT * FROM public.enriched_events_old` | fails: `ERROR: INSERT has more expressions than target columns` | ran on a throwaway DB with the 18-column table built by replaying the three migrations (doc steps 2, 3, 5 verbatim; re-run 2026-10-01) |
| PD4 | Step 4 creates `idx_billing_on_enriched_events` etc. | after step 2 the old indexes still carry those names (renaming a table does not rename its indexes): `ERROR: relation "idx_billing_on_enriched_events" already exists` | ran on a throwaway DB (doc steps 2-4 verbatim; re-run 2026-10-01) |
| PD5 | Step 3 adds `PRIMARY KEY (id, "timestamp")` | `structure.sql` at 591ae90 has no primary key on `enriched_events` (the migration passes `id: false`) | `grep -n 'enriched_events.*PRIMARY KEY' $API/db/structure.sql` → nothing |

Corrected retroactive conversion (steps 2-6; CANDIDATE: ran end to end on a throwaway Postgres 16
WITHOUT pg_partman, 5 rows copied, 4 indexes on the new parent; re-run 2026-10-01 by extracting this
block verbatim; steps 1, 7, 8 need pg_partman and were not run). Run as the table
owner, in a maintenance window:
```sql
BEGIN;
ALTER TABLE public.enriched_events RENAME TO enriched_events_old;
DROP INDEX IF EXISTS public.idx_billing_on_enriched_events, public.idx_lookup_on_enriched_events,
                     public.idx_unique_on_enriched_events, public.index_enriched_events_on_event_id;
CREATE TABLE public.enriched_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    event_id uuid NOT NULL,
    transaction_id character varying NOT NULL,
    external_subscription_id character varying NOT NULL,
    code character varying NOT NULL,
    "timestamp" timestamp(6) without time zone NOT NULL,
    subscription_id uuid NOT NULL,
    plan_id uuid NOT NULL,
    charge_id uuid NOT NULL,
    charge_filter_id uuid,
    grouped_by jsonb DEFAULT '{}'::jsonb NOT NULL,
    value character varying,
    decimal_value numeric(40,15) DEFAULT 0.0 NOT NULL,
    enriched_at timestamp(6) without time zone NOT NULL,
    operation_type character varying,
    precise_total_amount_cents numeric(40,15),
    target_wallet_code character varying
) PARTITION BY RANGE ("timestamp");
CREATE TABLE public.enriched_events_default PARTITION OF public.enriched_events DEFAULT;
CREATE INDEX idx_billing_on_enriched_events ON public.enriched_events (organization_id, subscription_id, charge_id, charge_filter_id, "timestamp");
CREATE INDEX idx_lookup_on_enriched_events ON public.enriched_events (organization_id, external_subscription_id, code, "timestamp");
CREATE UNIQUE INDEX idx_unique_on_enriched_events ON public.enriched_events (organization_id, external_subscription_id, transaction_id, "timestamp", charge_id);
CREATE INDEX index_enriched_events_on_event_id ON public.enriched_events (event_id);
INSERT INTO public.enriched_events (id, organization_id, event_id, transaction_id, external_subscription_id, code, "timestamp",
  subscription_id, plan_id, charge_id, charge_filter_id, grouped_by, value, decimal_value, enriched_at,
  operation_type, precise_total_amount_cents, target_wallet_code)
SELECT id, organization_id, event_id, transaction_id, external_subscription_id, code, "timestamp",
  subscription_id, plan_id, charge_id, charge_filter_id, grouped_by, value, decimal_value, enriched_at,
  operation_type, precise_total_amount_cents, target_wallet_code
FROM public.enriched_events_old;
-- compare counts before dropping
SELECT (SELECT count(*) FROM public.enriched_events) AS new_rows, (SELECT count(*) FROM public.enriched_events_old) AS old_rows;
DROP TABLE public.enriched_events_old;
COMMIT;
-- then doc steps 7 (partman.create_parent + part_config UPDATE) and 8 (CALL partman.run_maintenance_proc())
```
Re-derive the column list from the pinned schema before running (it changes with lago-api):
`sed -n '/^CREATE TABLE public.enriched_events (/,/^PARTITION BY/p' "$API/db/structure.sql"`.
Fixing the doc itself is a C0 change (docs-and-writing owns the stale-claim register).

## 4. Scheduling maintenance per variant

| Variant | partman available | scheduler | Action |
|---|---|---|---|
| dev | yes | `pg_partman_bgw` hourly via `scripts/postgresql.conf` | none (only if `POSTGRES_USER/DB` stay `lago`) |
| root self-host | yes | NONE | mount a config like dev (`command: -c config_file=/etc/postgresql.conf` + volume) or add `-c shared_preload_libraries=pg_partman_bgw -c pg_partman_bgw.dbname=lago -c pg_partman_bgw.role=lago -c pg_partman_bgw.interval=3600` to the db command (use your `POSTGRES_DB`/`POSTGRES_USER` if not `lago`); restart Postgres; changing the compose file is class C6 (change-control). CANDIDATE, not run here |
| deploy/ | no (plain postgres) | n/a | table is regular; to partition: change the image, then §3 |
| all-in-one | package installed | none | UNVERIFIED |
| managed Postgres | depends on provider | pg_cron (doc :193-245) | doc procedure; pg_cron runs in the `postgres` database, so `cron.job` is only visible there |

## 5. Checking it: `scripts/partman-check.sql`

`psql "<url>" -X -q -f .claude/skills/run-and-operate/scripts/partman-check.sql` (or pipe it into
`docker compose -f docker-compose.dev.yml exec -T db psql -U lago -d lago -X -q`). Expected verdicts,
all observed 2026-10-01:

| Database state | Verdict lines |
|---|---|
| sandbox `lago` DB (PG 16.14, no partman, no Lago schema) | `WARN pg_partman NOT available on the server…`, `INFO pg_partman not installed in this database`, `INFO no public.enriched_events table…` |
| regular 18-column table (migrations ran without partman) | `WARN … REGULAR table: … DDL is stale (15 cols vs 18 here) and step 5 fails`, `OK enriched_events has 18 columns (matches lago-api 591ae90)` |
| partitioned, registered (stub `partman.part_config`), no bgw, one row in default | `OK … partitioned (1 partitions attached)`, `OK registered in partman.part_config`, `FAIL no maintenance scheduler…`, `WARN enriched_events_default contains rows…` |
| after the corrected §3 conversion, before step 7 | `OK … partitioned`, `FAIL partitioned but NOT registered in partman.part_config: run docs/database_partitioning.md step 7`, `FAIL no maintenance scheduler…`, `WARN enriched_events_default contains rows…` |

Against a real pg_partman server (dev stack) the expected healthy output is `OK pg_partman is available`,
`OK pg_partman installed`, `OK … partitioned (N partitions attached)` with N = default + monthly
partitions, `OK registered`, `OK a maintenance scheduler is configured (pg_partman_bgw preloaded)`,
`OK enriched_events_default is empty`, and section 4 showing 1 `pg_partman_bgw` backend: UNVERIFIED
(no pg_partman available in this sandbox).
