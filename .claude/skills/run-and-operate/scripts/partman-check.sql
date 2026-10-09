-- partman-check.sql — READ-ONLY health check of enriched_events partitioning on a Lago Postgres.
--
-- What it answers (docs/database_partitioning.md describes the intended setup):
--   1. server version / database / user
--   2. is pg_partman (and pg_cron) AVAILABLE on the server, and INSTALLED in this database?
--   3. is pg_partman_bgw preloaded (shared_preload_libraries) and configured (pg_partman_bgw.*)?
--   4. is a pg_partman_bgw background worker running right now?
--   5. does public.enriched_events exist, is it PARTITIONED or a regular table, how many columns
--      (18 at lago-api 591ae90; the doc's retroactive DDL has only 15), which partitions exist?
--   6. partman.part_config row for public.enriched_events (premake / retention / infinite)
--   7. a pg_cron job calling run_maintenance_proc (if pg_cron is installed in THIS database)
--   8. verdict lines (OK / WARN / FAIL / INFO)
-- It never writes: only SELECTs on catalogs and, when present, partman.part_config, cron.job and
-- an EXISTS probe on public.enriched_events_default.
--
-- Usage (psql >= 10 for \if; from the repo root):
--   psql "postgres://lago:lago@localhost:5432/lago" -X -q -f .claude/skills/run-and-operate/scripts/partman-check.sql
--   docker compose -f docker-compose.dev.yml exec -T db psql -U lago -d lago -X -q < .claude/skills/run-and-operate/scripts/partman-check.sql
-- Exit status: psql's (0 unless a query errors). Read the "== 8. verdict" lines.
\set ON_ERROR_STOP on
\pset footer off

\echo '== 1. server'
SELECT current_setting('server_version') AS server_version, current_database() AS db, current_user AS db_user;

\echo '== 2. extensions (available on server / installed in this db)'
SELECT name, default_version AS available, coalesce(installed_version, '-') AS installed
FROM pg_available_extensions
WHERE name IN ('pg_partman', 'pg_cron', 'pg_stat_statements')
ORDER BY name;

\echo '== 3. preload and worker settings'
SELECT name, setting
FROM pg_settings
WHERE name IN ('shared_preload_libraries', 'wal_level')
   OR name LIKE 'pg\_partman\_bgw.%'
   OR name LIKE 'cron.%'
ORDER BY name;

\echo '== 4. pg_partman_bgw backends running now'
SELECT count(*) AS pg_partman_bgw_backends FROM pg_stat_activity WHERE backend_type = 'pg_partman_bgw';

\echo '== 5. public.enriched_events'
SELECT (to_regclass('public.enriched_events') IS NOT NULL) AS has_ee,
       (to_regclass('public.enriched_events_default') IS NOT NULL) AS has_ee_default,
       (to_regclass('partman.part_config') IS NOT NULL) AS has_part_config,
       (to_regclass('cron.job') IS NOT NULL) AS has_cron_job,
       (SELECT setting FROM pg_settings WHERE name = 'shared_preload_libraries') LIKE '%pg_partman_bgw%' AS bgw_preloaded,
       EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_partman') AS partman_available,
       EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_partman') AS partman_installed
\gset
\if :has_ee
  SELECT c.oid::regclass AS "table",
         CASE c.relkind WHEN 'p' THEN 'partitioned' WHEN 'r' THEN 'regular (NOT partitioned)' ELSE c.relkind::text END AS kind,
         (SELECT count(*) FROM pg_attribute a WHERE a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped) AS columns
  FROM pg_class c WHERE c.oid = 'public.enriched_events'::regclass;
  SELECT (SELECT relkind FROM pg_class WHERE oid = 'public.enriched_events'::regclass) = 'p' AS ee_partitioned,
         (SELECT count(*) FROM pg_attribute a WHERE a.attrelid = 'public.enriched_events'::regclass AND a.attnum > 0 AND NOT a.attisdropped) AS ee_columns,
         (SELECT count(*) FROM pg_inherits WHERE inhparent = 'public.enriched_events'::regclass) AS ee_partitions
  \gset
  \echo 'partitions (bound, estimated rows):'
  SELECT i.inhrelid::regclass AS partition, pg_get_expr(p.relpartbound, p.oid) AS bound, greatest(p.reltuples, 0)::bigint AS est_rows
  FROM pg_inherits i JOIN pg_class p ON p.oid = i.inhrelid
  WHERE i.inhparent = 'public.enriched_events'::regclass
  ORDER BY 1;
\else
  \echo 'public.enriched_events does not exist in this database (lago-api migrations not applied here)'
  \set ee_partitioned false
  \set ee_columns 0
  \set ee_partitions 0
\endif
\set default_has_rows false
\if :has_ee_default
  SELECT EXISTS (SELECT 1 FROM public.enriched_events_default) AS default_has_rows \gset
\endif

\echo '== 6. partman.part_config for public.enriched_events'
\if :has_part_config
  SELECT parent_table, partition_interval, premake, retention, retention_keep_table, infinite_time_partitions
  FROM partman.part_config WHERE parent_table = 'public.enriched_events';
  SELECT EXISTS (SELECT 1 FROM partman.part_config WHERE parent_table = 'public.enriched_events') AS registered \gset
\else
  \echo 'partman.part_config absent (pg_partman not installed in this database)'
  \set registered false
\endif

\echo '== 7. pg_cron maintenance job (only visible in the database where pg_cron is installed)'
\set cron_job false
\if :has_cron_job
  SELECT jobid, jobname, schedule, database, active FROM cron.job WHERE command ILIKE '%run_maintenance%';
  SELECT EXISTS (SELECT 1 FROM cron.job WHERE command ILIKE '%run_maintenance%' AND active) AS cron_job \gset
\else
  \echo 'cron.job absent here (pg_cron not installed in this database; docs put it in the postgres database)'
\endif

\echo '== 8. verdict'
SELECT line AS verdict FROM (VALUES
  (1, CASE WHEN :'partman_available'::boolean THEN 'OK    pg_partman is available on the server'
           ELSE 'WARN  pg_partman NOT available on the server: lago-api migrations create enriched_events UNPARTITIONED (deploy/ variants use plain postgres:15-alpine)' END),
  (2, CASE WHEN :'partman_installed'::boolean THEN 'OK    pg_partman installed in this database'
           WHEN :'partman_available'::boolean THEN 'WARN  pg_partman available but not installed here (migration 20260109092932_setup_partman skipped or not run yet)'
           ELSE 'INFO  pg_partman not installed in this database' END),
  (3, CASE WHEN NOT :'has_ee'::boolean THEN 'INFO  no public.enriched_events table: nothing to maintain in this database'
           WHEN :'ee_partitioned'::boolean THEN 'OK    public.enriched_events is partitioned (' || :'ee_partitions' || ' partitions attached)'
           ELSE 'WARN  public.enriched_events is a REGULAR table: retroactive conversion = docs/database_partitioning.md steps 1-8, but its DDL is stale (15 cols vs ' || :'ee_columns' || ' here) and step 5 fails' END),
  (4, CASE WHEN :'has_ee'::boolean AND :'ee_columns'::int <> 18 THEN 'INFO  enriched_events has ' || :'ee_columns' || ' columns; lago-api 591ae90 structure.sql has 18'
           WHEN :'has_ee'::boolean THEN 'OK    enriched_events has 18 columns (matches lago-api 591ae90)'
           ELSE NULL END),
  (5, CASE WHEN NOT :'ee_partitioned'::boolean THEN NULL
           WHEN :'registered'::boolean THEN 'OK    registered in partman.part_config'
           ELSE 'FAIL  partitioned but NOT registered in partman.part_config: run docs/database_partitioning.md step 7' END),
  (6, CASE WHEN NOT :'ee_partitioned'::boolean THEN NULL
           WHEN :'bgw_preloaded'::boolean OR :'cron_job'::boolean THEN 'OK    a maintenance scheduler is configured (' ||
                CASE WHEN :'bgw_preloaded'::boolean THEN 'pg_partman_bgw preloaded' ELSE 'pg_cron job' END || ')'
           ELSE 'FAIL  no maintenance scheduler: pg_partman_bgw not in shared_preload_libraries and no pg_cron job seen here (only docker-compose.dev.yml mounts scripts/postgresql.conf)' END),
  (7, CASE WHEN :'default_has_rows'::boolean THEN 'WARN  enriched_events_default contains rows: maintenance has not moved them (or premake did not cover their timestamps)'
           WHEN :'has_ee_default'::boolean THEN 'OK    enriched_events_default is empty'
           ELSE NULL END)
) AS v(n, line)
WHERE line IS NOT NULL
ORDER BY n;
