# Production memory-cache operations (events-processor)

Read when you start, restart, size or watch the events-processor in production. Production runs
memory-cache mode, `LAGO_USE_MEMORY_CACHE=true`: DECIDED OD-1 (owner, 2026-10-02). Dev runs DB mode
(no compose file in this repo sets the variable). Mechanism and defects: `architecture-contract`
`reference/memory-cache.md` and WP6-WP10, WP27. Symptom triage: `debugging-playbook` section 5. Fix
owner: `event-accounting-campaign` W6 (DEFAULT APPLIED OD-20; the owner may reassign it).
Code facts as of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only
commits on top. Facts verified 2026-10-02 unless marked. Paths are repo-relative.
Production-side commands (`kubectl`, the Kafka CLI, the Kafka Connect REST API) cannot run in this
sandbox: they are standard tools, flags UNVERIFIED here, and each is read-only unless it carries a
WARNING line.

Safety rules for every step (change-control N11 and its destructive-command rule):
- Never print secrets. No `env | grep LAGO_KAFKA` (it prints `LAGO_KAFKA_PASSWORD`), no `printenv
  DATABASE_URL`, never the whole Debezium connector config (it holds `database.password`,
  `extra/debezium_config.json:6`). Print named non-secret values only:
  `printenv LAGO_USE_MEMORY_CACHE LAGO_DEBEZIUM_TOPIC_PREFIX LAGO_KAFKA_BOOTSTRAP_SERVERS`.
- A command that changes broker or database state carries a WARNING (what is lost), runs on dev by
  default, and on a shared or production cluster only after the owner signs off (recorded: who, when,
  exact targets).

## 0. Verify first: the production CDC config (OPEN DECISION OD-1b (owner))

Nobody here knows the production Debezium connector config, the Kafka auth or the broker list the CDC
consumers get. Ask the production deploy owner (the deploy repo is private) for these four facts, with
secrets masked:

| # | Fact | Read-only check (not runnable here) | Bad answer means |
|---|---|---|---|
| 1 | Does the connector's `column.include.list` carry `charges.pay_in_advance`, `charges.accepts_target_wallet` and `billable_metrics.recurring`? The repo's reference list does not (`extra/debezium_config.json:2`), while the snapshot reads them (`events-processor/models/charges.go:29-30`, `events-processor/models/billable_metrics.go:93`) | `curl -s http://<connect-host>:8083/connectors/<name>/config \| jq -r '."column.include.list"'` (reference name `debezium-postgresql-lago-events-processor`, `extra/debezium_config.json:22`; the jq filter prints the column list only) | WP6 is live: each CDC update of a charge or metric zeroes those flags in the cache, so in-advance events and the recurring fallback stop for every charge or metric edited since the pod started (binary smoke `cache-cdc`: `tx_A … in_advance=no`, re-run 2026-10-02) |
| 2 | Does the connector's `topic.prefix` equal the pod's `LAGO_DEBEZIUM_TOPIC_PREFIX`? | same call, `jq -r '."topic.prefix"'`; `printenv LAGO_DEBEZIUM_TOPIC_PREFIX` in the pod | the CDC consumers read topics nobody writes: the cache never changes after its snapshot (`events-processor/main.go:70`, no validation) |
| 3 | Does the cluster the CDC consumers reach require SASL or TLS? | the main client's `LAGO_KAFKA_SCRAM_ALGORITHM` / `LAGO_KAFKA_TLS` (print those two only) | the CDC clients have no SASL/TLS options (`events-processor/cache/consumer.go:30-35`): no CDC update ever arrives (WP10) |
| 4 | Is `LAGO_KAFKA_BOOTSTRAP_SERVERS` a comma list? | `printenv LAGO_KAFKA_BOOTSTRAP_SERVERS` | the CDC clients get ONE bogus seed and log nothing (`events-processor/cache/consumer.go:28-31`; `debugging-playbook` T5): use one seed address |

Report the answers to the owner as the evidence that closes OD-1b (change-control section 9). Until
then treat WP6 and WP10 as live production risks.

## 1. Startup snapshot: did it load, or was a failure swallowed?

Mechanism: the snapshot runs once per process start, blocks event consumption until it ends
(`events-processor/main.go:77-84`) and drops per-table errors (`events-processor/cache/cache.go:78-106`).
A dropped error leaves that table empty. With `billable_metrics` empty, every event goes to the DLQ as
`fetch_billable_metric` with `initial_error_message` `Key not found` (non-retryable, committed), and the
pod looks healthy.

Healthy start at INFO, the production log level (`ENV` other than `development`,
`events-processor/main.go:33-36`), VERIFIED 2026-10-02 with
`.claude/skills/diagnostics-and-tooling/scripts/smoke-binary.sh cache`: per model one `Starting snapshot load`
(`events-processor/cache/cache.go:237`) and one `Completed snapshot load` with `count` and `duration_ms`
(`:267`), then six `Starting consumer` lines carrying `group_id` `lago_evp_<model>_<uuid>`
(`events-processor/cache/consumer.go:40-45`), then `Starting event consumer`.

1. Capture the log FROM PROCESS START (the snapshot lines are written once):
   `kubectl logs <pod> > ep.log` (current container), `kubectl logs <pod> --previous > ep.log` (the
   container before a restart). Not runnable here.
2. `.claude/skills/debugging-playbook/scripts/triage-ep-log.sh ep.log`, section `== memory-cache mode`.
   Healthy: `snapshot loads: started 6, completed 6` and a `snapshot rows:` line with non-zero
   `billable_metrics`, `charges`, `subscriptions`. Swallowed failure: `WARNING: EMPTY/PARTIAL CACHE`
   (VERIFIED on the bundled real log `testdata/cache-empty-snapshot.log`). `not active in this log` on a
   production pod = the start is not in the captured log: go back to step 1.
3. Cross-check the row counts against Postgres, read-only, same filters as the snapshot
   (`events-processor/models/billable_metrics.go:85-105`, `events-processor/models/subscriptions.go:56-77`,
   `events-processor/models/charges.go:21-42`; validated on a scratch Postgres 16, 2026-10-02):
   ```sql
   SELECT 'billable_metrics' AS model, count(*) FROM billable_metrics WHERE deleted_at IS NULL
   UNION ALL SELECT 'subscriptions', count(*) FROM subscriptions
     WHERE terminated_at IS NULL OR terminated_at >= now() - interval '1 month'
   UNION ALL SELECT 'charges', count(*) FROM charges WHERE deleted_at IS NULL;
   ```
   Expect each to match the `count` of that model's `Completed snapshot load`, give or take the edits
   made since the start. `count` 0 against a non-empty table = the pod snapshotted another database.
4. Look for the DLQ signature: a burst of `Key not found` across MANY codes right after a start (one
   code alone is a wrong or deleted metric). ClickHouse, validated with `clickhouse local` 26.2 on the
   `events_dead_letter` columns (`$API/db/clickhouse_migrate/20251110100317_create_events_dead_letter.rb:10-21`):
   ```sql
   SELECT toStartOfMinute(failed_at) AS minute, count() AS n,
          countIf(initial_error_message = 'Key not found') AS key_not_found, uniqExact(code) AS codes
   FROM events_dead_letter
   WHERE error_code = 'fetch_billable_metric' AND failed_at > now() - INTERVAL 2 HOUR
   GROUP BY minute ORDER BY minute;
   ```
5. Fix the cause (`DATABASE_URL`, permissions, statement timeout), then restart: only a start
   re-snapshots. Events already in the DLQ stay there. No DLQ replay tool exists today; ADR-001
   (DECIDED OD-2 (owner, 2026-10-02), `event-accounting-campaign` `reference/delivery-options.md`) plans an
   operator-gated DLQ to raw-topic replay with a replay header. Until it ships, a manual re-feed is
   CANDIDATE and needs owner sign-off: it re-runs in-advance and refresh side effects, which are safe
   only where downstream dedup holds (`architecture-contract` I12, CONDITIONAL).

## 2. CDC freshness: lag and staleness

Mechanism: six CDC consumers apply Debezium rows to the cache (`events-processor/cache/consumer.go:92-175`)
and commit after every poll (`:83-85`). The process exports no lag. A fetch error is logged as ERROR
`Fetch error` (`pkg=cache`) and retried forever (`:66-74`); a comma broker list or a secured cluster logs
nothing at all. Applied rows log only at DEBUG (`Cache updated from stream`, `:169`), which production's
INFO level hides.

Check from the source to the cache (read-only; not runnable here):

| # | Check | Command | Healthy | If not |
|---|---|---|---|---|
| 1 | connector running | `curl -s http://<connect-host>:8083/connectors/<name>/status \| jq -r '.connector.state, .tasks[].state'` | `RUNNING` for the connector and its task (`tasks.max` 1, `extra/debezium_config.json:42`) | no change reaches any cache: the deploy owner restarts the connector |
| 2 | replication slot keeps up (SQL validated on Postgres 16, 2026-10-02) | `SELECT slot_name, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS behind FROM pg_replication_slots WHERE slot_name = 'lago_dbz_evt_proc';` (slot name: `extra/debezium_config.json:33`) | `active` = `t`; `behind` small and not growing | inactive slot = connector down. WAL piles up on the primary because the slot is kept (`slot.drop.on.stop` `false`, `:31`): disk risk |
| 3 | the running pod's CDC groups have no lag | group ids: `grep -o '"group_id":"lago_evp_[^"]*"' ep.log`; then `rpk group describe <id>` (Redpanda) or `kafka-consumer-groups.sh --bootstrap-server <b> --describe --group <id>` (add `--command-config` on a SASL cluster) | lag 0, or briefly above 0 | sustained lag = stale cache; no member = the consumer is dead or never connected (WP10) |
| 4 | end-to-end freshness | `SELECT max(updated_at) FROM charges;` against the newest record of `<prefix>.public.charges` (Redpanda Console or your Kafka tooling; UNVERIFIED tooling) | same edit | topic behind Postgres: connector side (rows 1-2); topic current but group lagging: consumer side (row 3) |
| 5 | CDC errors in the log | `.claude/skills/debugging-playbook/scripts/triage-ep-log.sh ep.log` | `CDC fetch errors: 0`, `CDC decode/write errors: 0` | `debugging-playbook` entries `cache-cdc-fetch`, `cache-cdc-write` |

What a stale cache looks like downstream: a new billable metric DLQs as `fetch_billable_metric`
`Key not found` for that code only; a new subscription's events are enriched with `subscription_id:""`
(no in-advance event, no refresh flag); an edited charge stops its in-advance events (WP6); a deleted
metric is still enriched. Triage: `debugging-playbook` section 5.

Heartbeat note (UNVERIFIED here, Debezium documentation not fetched from this sandbox): the reference
config disables heartbeats (`heartbeat.interval.ms` `0`, `extra/debezium_config.json:13`). Debezium
recommends heartbeats so the slot's confirmed position advances while only uncaptured tables change;
watch row 2 over a quiet period before relying on it.

## 3. Restart = CDC replay + six new groups; orphan-group cleanup

Facts:
- Every process start creates six groups `lago_evp_<model>_<uuid>` (`events-processor/cache/consumer.go:27`;
  smoke prints `consumer_groups: … + 6 lago_evp_<model>_<uuid>`, re-run 2026-10-02). As new groups they
  read every CDC topic from the earliest retained offset (franz-go default reset `AtStart`,
  `franz-go@v1.20.5/pkg/kgo/config.go:578`). Replay time grows with the retained CDC volume; raw-event
  consumption starts in parallel (`events-processor/main.go:78-84`).
- Old groups are never removed: six orphans per restart per replica. An orphan holds only committed
  offsets: no data, no consumer. Cost: broker metadata and noise in lag dashboards (broker cost UNVERIFIED).
- A restart re-reads the full rows, so it temporarily repairs WP6 for edited charges and metrics until
  their next edit (`architecture-contract` `reference/memory-cache.md` §4; INFERRED). In-advance volume
  that drops after an edit and returns after a deploy is that defect, not a fix.
- Do not "fix" the replay with one fixed, shared group id or by starting at the latest offset: replicas
  would split the CDC partitions, and changes made between the snapshot and the consumer start would be
  lost (`architecture-contract` `reference/memory-cache.md` §3). The design belongs to campaign W6.

Orphan cleanup (each numbered step is read-only except step 4):

<!-- evidence-check: off normative procedure; the facts it relies on are cited in the bullets above -->
0. Gate. On a shared or production broker this is an operational change: get the owner's sign-off for
   the exact group list before step 4 and record it. On a dev broker no gate is needed.
1. List the CDC groups: `rpk group list | grep '^lago_evp_'` or
   `kafka-consumer-groups.sh --bootstrap-server <b> --list | grep '^lago_evp_'`.
2. Build the KEEP list: the six `group_id` values each RUNNING replica logged at its start
   (`grep -o '"group_id":"lago_evp_[^"]*"'` on each pod's log from start). Never delete a KEEP group.
3. Candidates = listed minus KEEP. Each must show no member: `rpk group describe <g>` or
   `kafka-consumer-groups.sh --bootstrap-server <b> --describe --group <g> --state` (state `Empty`, 0 members).
   Kafka refuses to delete a group that still has members (standard broker behaviour, UNVERIFIED here); do
   not rely on that: steps 2-3 are the gate.
4. WARNING: deleting a group removes its committed offsets for good. For a true orphan nothing is lost (no
   process reuses its UUID); for a KEEP group the replica loses its committed CDC position. Dev only, or
   production after step 0:
   `rpk group delete <g> [<g> ...]` or `kafka-consumer-groups.sh --bootstrap-server <b> --delete --group <g>`.
5. Verify: list again; every KEEP group is still there with its members.

<!-- evidence-check: on -->

Never in this runbook: delete or seek the raw-topic group `<LAGO_KAFKA_CONSUMER_GROUP>_<raw topic>` (that
replays or skips raw events: `events-processor-ops.md` §3), or seek a CDC group.

## 4. Memory and warm-up sizing

Measured, synthetic (a scratch program called the real `cache.SetSubscription` 1,000,000 times, short
rows, one org and plan, 4 vCPU, then a forced GC): RSS 823 MB on 2026-10-01 and 801 MB on 2026-10-02
(`VmRSS 800900 kB`), Go heap in use 426 MB both times, 13.4 s and 20.8 s to insert (the second run on a
busier sandbox). Lookup worked.

Caveat (why this is a lower bound): no snapshot path (during warm-up the whole table is first held as a
Go slice, `events-processor/models/query_streaming.go:96`, so the peak is higher); one table of six; short
synthetic ids; no production `GOGC` or memory limit; the production snapshot also holds subscriptions
terminated in the last month (`events-processor/models/subscriptions.go:56-77`), and CDC-terminated ones
stay 30 days (`events-processor/cache/subscriptions.go:119-128`).

Sizing (CANDIDATE rule of thumb, not measured on production data):
- Budget at least ~0.8 GB per 1M cached subscriptions, plus charges and metrics, plus the warm-up peak.
  The documented pod size is 2 Gi and 2 cores (`docs/architecture.md:262`).
- CANDIDATE: measure on a production-sized copy in staging: container RSS at peak during warm-up and after the six
  `Completed snapshot load` lines (`count` gives the rows, the first `Starting snapshot load` to the last
  `Completed snapshot load` gives the warm-up time).
- An OOM kill during warm-up gives a restart loop that never consumes. Raw-topic lag grows during every
  warm-up (consumption starts after the snapshot, `events-processor/main.go:77-84`) and there is no
  readiness signal (no HTTP listener: `architecture-contract` section 10).

## 5. Production cache incident -> where to go

<!-- evidence-check: off routing table; evidence lives in the target sections -->
| You see | Section here | Triage entry (`debugging-playbook`) |
|---|---|---|
| right after a restart, everything goes to the DLQ as `fetch_billable_metric` / `Key not found` | §1 | `cache-snapshot-failed`, T4 |
| in-advance events stop after someone edits a charge (and return after a deploy) | §0 row 1, §3 | T6 |
| a new metric or subscription is never picked up; edits never show | §0 rows 2-4, §2 | T5, `cache-cdc-fetch` |
| `lago_evp_*` groups pile up on the broker | §3 | section 5 |
| pod OOM-killed or slow to start | §4 | - |
<!-- evidence-check: on -->

## Provenance and maintenance

- Sources: `events-processor/{main.go,cache/cache.go,cache/consumer.go,cache/subscriptions.go,models/*.go}`,
  `extra/debezium_config.json`, `docs/architecture.md:262`, `$API/db/clickhouse_migrate/20251110100317_create_events_dead_letter.rb`,
  franz-go v1.20.5 `pkg/kgo/config.go`. Runs on 2026-10-02: `smoke-binary.sh cache` and `cache-cdc` (both
  `EXPECTED-TODAY: MATCH`), the scratch memory benchmark, the Postgres queries on a scratch database built
  from `diagnostics-and-tooling` `fixtures/smoke-schema.sql` (counts 3 / 1 / 2 = the smoke snapshot counts),
  the ClickHouse query in `clickhouse local` 26.2.
- Re-verify (one line each):
  - `grep -n 'lago_evp_' events-processor/cache/consumer.go` → `:27`
  - `grep -n 'Completed snapshot load\|Starting snapshot load' events-processor/cache/cache.go` → `237`, `267`
  - `grep -o 'public.charges.([^)]*)' extra/debezium_config.json` → no `pay_in_advance` (as of 2026-10-02)
  - `.claude/skills/diagnostics-and-tooling/scripts/smoke-binary.sh cache-cdc | grep '^tx_A'` → `in_advance=no`
- Update triggers: the owner's answer to OD-1b; any change under `events-processor/cache/`, `main.go` or to
  `extra/debezium_config.json`; a campaign W6 change; a franz-go bump.
