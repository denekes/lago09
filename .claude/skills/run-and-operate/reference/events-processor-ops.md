# Operating the events-processor

Read when you run, restart, scale, replay or debug the Go events-processor as a process. Internals
(commit algorithm, per-record disposition, invariants) belong to `architecture-contract`; env-var
semantics to `config-and-flags`; symptom tables to `debugging-playbook`. Paths are relative to
`events-processor/`. Verified 2026-10-01. Code facts as of 5308258 (events-processor tree 83e012866f29);
the working branch may carry skills-only commits on top.
`$API` = pinned lago-api checkout: `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)` (591ae90).

## 1. Startup contract (partially fail-fast; checked failures panic with exit code 2)

Owner of the order and panic contract: `architecture-contract` §2 and its invariant I14 (PARTIAL);
symptom → fix: `debugging-playbook` §2 (`explain-error.sh`). This is the operator's view, with the
outputs captured from the binary on 2026-10-01.

Not caught at startup (accepted silently): an empty `LAGO_KAFKA_CONSUMER_GROUP` (group `_<topic>`) or
empty raw topic (accepted; the consumer idles: `architecture-contract` §2), an empty
`LAGO_DEBEZIUM_TOPIC_PREFIX`, cache-snapshot query errors (swallowed, row "memory cache" below), and
`LAGO_USE_MEMORY_CACHE=1` (= DB mode; only `true` enables, main.go:67). Not reported to Sentry: the
`brokers not found` panic (plain `panic`, processors/main_processor.go:103-107) and the SCRAM SIGSEGV,
which also prints no log line first.

Order (main.go, processors/main_processor.go `StartProcessingEvents`):

| Step | Needs | On failure | Verified |
|---|---|---|---|
| loader (before `main`) | `libexpression_go.so` on the loader path (`LD_LIBRARY_PATH` from `ep-env.sh`; the image copies it to `/usr/lib`, Dockerfile:22) | `error while loading shared libraries: libexpression_go.so: cannot open shared object file`, exit 127 (`build-and-env`) | RAN |
| logger | `ENV` (default `development` → DEBUG) | - | read main.go:31-41 |
| tracer | `TRACING_PROVIDER` / `DD_TRACE_ENABLED` / `OTEL_EXPORTER_OTLP_ENDPOINT` | none (no-op provider) | read main.go:45-51 |
| Sentry | `SENTRY_DSN` | prints `Sentry initialization failed`, continues | read main.go:53-64 |
| memory cache (only if `LAGO_USE_MEMORY_CACHE` is exactly `true`) | `DATABASE_URL`, `LAGO_DEBEZIUM_TOPIC_PREFIX`, brokers | DB connect error → panic; per-table load errors are DISCARDED (`LoadSnapshot` returns a failed Result that `LoadInitialSnapshot` ignores; only the gorm `component=db` logger prints the SQL error) and the process keeps running with an empty cache | read main.go:66-81, cache/cache.go:63-107, 231-243 |
| brokers | `LAGO_KAFKA_BOOTSTRAP_SERVERS` (comma list) | `{"level":"ERROR","msg":"brokers not found"}` then `panic: brokers not found` (no Sentry event) | RAN; processors/main_processor.go:103-107 |
| 3 producers, each with a broker Ping | `LAGO_KAFKA_ENRICHED_EVENTS_TOPIC`, `..._EVENTS_CHARGED_IN_ADVANCE_TOPIC`, `..._EVENTS_DEAD_LETTER_TOPIC` | `panic: LAGO_KAFKA_ENRICHED_EVENTS_TOPIC variable is required`; unreachable broker → `panic: unable to dial: dial tcp 127.0.0.1:1: connect: connection refused` (immediately) | RAN |
| SASL | `LAGO_KAFKA_SCRAM_ALGORITHM` in {`SCRAM-SHA-256`,`SCRAM-SHA-512`} or empty | any other value (e.g. `sha512`) → `panic: runtime error: invalid memory address or nil pointer dereference` … `kgo.validateCfg` (SIGSEGV, exit 2, no prior log line, no Sentry) | RAN; config/kafka/kafka.go:56-63 (no `default` case) |
| DB pool (DB mode only) | `DATABASE_URL`, `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` (int, default 200) | panic `Error connecting to the database` / non-integer → panic | read processors/main_processor.go:133-150 |
| Redis flag store, Ping | `LAGO_REDIS_STORE_URL` (scheme stripped), `_PASSWORD`, `_DB` (int), `_TLS` (default = `ENV==production`) | panic `Error connecting to the flag store` | read processors/main_processor.go:152-156 |
| consumer group, Ping | `LAGO_KAFKA_RAW_EVENTS_TOPIC`, `LAGO_KAFKA_CONSUMER_GROUP` (both NOT validated: an empty group gives `_<topic>`, config/kafka/consumer.go:237) | panic `Error starting the event consumer` | read processors/main_processor.go:168-179 |

Rerun the RAN rows: build with R5 of `runbooks.md`, then
`env -i PATH="$PATH" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" "$out/event_processors"` (add one variable at a
time). A healthy start logs `Starting event consumer`, then franz-go group lines (`joined, balancing
group`, `assigning partitions`) and `Starting consume for topic <t> partition <n>`.

Trap: `ENV=production` turns Redis TLS ON unless `LAGO_REDIS_STORE_TLS=false` (main_processor.go:84-91);
TLS then uses `InsecureSkipVerify` (config/redis/redis.go:42-47). Rails uses different names
(`LAGO_REDIS_STORE_SSL`) for the same Redis: set both.

## 2. Shutdown, grace period and batch size

Sequence (seen in the binary smoke log, 2026-10-01): `Received shutdown signal` → `Gracefully shutting
down consumer group` → `Shuting down partion consumer` → `partition consumer quit` → `leaving group` →
`Consumer group shutdown is complete` → `Event processor stopped`, exit 0.

- SIGTERM/SIGINT cancels the root context (main.go:90-99); the poll loop stops; each partition consumer
  finishes the batch it holds, because `processRecordsAndCommit` runs on `context.Background()`
  (config/kafka/consumer.go:83), then commits; then the client leaves the group (:207-225).
- One poll returns up to **10,000 records** (consumer.go:168), each processed concurrently (one
  goroutine per record, no limit), each doing 1-3 Postgres queries (DB mode), 1-2 synchronous produces
  and a Redis ZADD. The shared limits are the DB pool (200) and the Redis pool (10, 4 s pool timeout).
- Grace periods that apply: `docker compose stop` default 10 s (no `stop_grace_period` in any compose
  file); dev `air` `kill_delay = "10s"`; Kubernetes default 30 s (the public Helm chart sets none).
- If SIGKILL lands before the commit, the whole batch is redelivered after restart: duplicates on
  `events_enriched` (collapse only at ClickHouse merge; billing reads with `FINAL` only for orgs with
  `clickhouse_deduplication_enabled`, default false: `architecture-contract` I12), on
  `events_dead_letter` (never collapse), duplicate
  `events_charged_in_advance` messages (fee creation is guarded by the unique indexes
  `idx_pay_in_advance_duplication_guard_charge[_filter]`, `$API/db/structure.sql:7785,7792`, and by
  `already_processed?`, `$API/app/services/events/pay_in_advance_service.rb:15,55`; how the job handles
  an index violation: UNVERIFIED) and extra refresh flags.
- Measure the real drain time from the log timestamps of `Gracefully shutting down consumer group` and
  `Consumer group shutdown is complete`; there is no metric. Batch-vs-grace in production: UNVERIFIED.
- Memory-cache mode: `Cache.Wait()` (cache/cache.go:59-61) is never called, so badger can close while a
  CDC goroutine is mid-record (`architecture-contract`).

## 3. Consumer groups, offset reset and replay consequences

- Raw-topic group id = `<LAGO_KAFKA_CONSUMER_GROUP>_<LAGO_KAFKA_RAW_EVENTS_TOPIC>` (consumer.go:237;
  dev `lago_dev_events-raw`). Consumer-group naming is cross-repo contract K7 in change-control.
- A group with no committed offsets starts at the EARLIEST offset (franz-go default
  `resetOffset: NewOffset().AtStart()`, franz-go@v1.20.5 `pkg/kgo/config.go:578`; the smoke log shows
  `"input":{"events-raw":{"0":{"At":-2,...}}}` for a new group). Therefore **changing
  `LAGO_KAFKA_CONSUMER_GROUP` or the raw topic name = replay of the whole retained raw topic.**
- franz-go defaults are untouched (no `SessionTimeout`/`RebalanceTimeout` options in the code):
  session 45 s, rebalance 60 s, heartbeat 3 s (config.go:594-596). `BlockRebalanceOnPoll` holds
  rebalances while a batch is in flight.
- The raw topic has a second, independent consumer: ClickHouse `events_raw_queue` (group `clickhouse`).
  Resetting the events-processor group does not touch `events_raw`.

| Replay output | Effect | Evidence |
|---|---|---|
| `events_enriched` | duplicates until ClickHouse merges (ReplacingMergeTree on org, code, ext_sub, date, timestamp, transaction_id); before the merge, billing double-counts them unless the org has `clickhouse_deduplication_enabled` (`FINAL`; default false) | `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb`; `$API/app/services/billable_metrics/aggregations/base_service.rb:161-169` |
| `events_charged_in_advance` | re-consumed by Karafka → `PayInAdvanceJob`; DB unique indexes and `already_processed?` guard duplicate fees | structure.sql:7785,7792; `$API/app/services/events/pay_in_advance_service.rb:55` |
| `events_dead_letter` | every still-failing event is DLQ'd again (MergeTree keeps all copies) | `$API/db/clickhouse_migrate/20251110100317_create_events_dead_letter.rb` |
| Redis `subscription_refreshed_v2` | extra refresh flags → extra Rails refresh work | models/stores.go:54-69 |
| Old events with now-missing billable metric | DLQ `fetch_billable_metric` | enrichment_service.go:42 |

Commands (dev; `rpk` inside the redpanda container; standard rpk CLI, not run here, flags UNVERIFIED).
Read-only inspection:
```bash
docker compose -f docker-compose.dev.yml exec redpanda rpk group list
docker compose -f docker-compose.dev.yml exec redpanda rpk group describe lago_dev_events-raw     # lag per partition
```
WARNING (dev only): a seek moves the committed offsets. `--to end` SKIPS every unconsumed raw record
(those offsets are never enriched: data loss for them); `--to start` replays the whole retained topic
(table above).
```bash
docker compose -f docker-compose.dev.yml stop events-processor                                    # group must be empty to seek
docker compose -f docker-compose.dev.yml exec redpanda rpk group seek lago_dev_events-raw --to end --topics events-raw   # SKIPS unconsumed records; dev only
```
Any seek, reset or group delete on a shared or production cluster is an operational change with
delivery consequences: do not run it without the owner's sign-off for that operation (the delivery
contract itself is ADR-001, DECIDED OD-2 (owner, 2026-10-02); production's memory-cache CDC groups have
their own gated cleanup in `memory-cache-ops.md` §3). change-control N7 covers code changes to
commit/delivery semantics.

## 4. The DLQ (`events_dead_letter`)

What lands there and why (owner of `error_code` → cause → retryable: `architecture-contract` §9):
retryability is a property of the failure, not of the code. A failed result is retryable by default
(`utils/result.go:113-129`); non-retryable → DLQ at once; retryable → DLQ only once 12 h have passed
since its `ingested_at` (`processors/events_processor/processor.go:74`). Codes you will see:
`build_enriched_event`, `fetch_billable_metric`, `evaluate_expression`, `fetch_subscription` (a missing
subscription is NOT an error: the event is enriched without one), `fetch_pay_in_advance_charge`,
`flag_subscription_refresh`, and an empty code with `initial_error_message`
`failed to push to <topic> topic` (produce failure,
processors/events_processor/event_producer_service.go:87-89). What does NOT land there:
unparseable JSON (committed, Sentry + log only, processor.go:49-60), retryable failures younger than
12 h (not committed; may be skipped forever by a later commit: architecture-contract), and a DLQ produce
failure (Sentry only). Decoding the codes: `debugging-playbook`. Target behaviour (not built yet): ADR-001
(DECIDED OD-2) sends PERMANENT failures to the DLQ at once with a cause (unmarshal errors too), retries
TRANSIENT ones through a retry topic and DLQs them after N attempts or the 12 h max age, and pauses on
SYSTEMIC failures (`event-accounting-campaign` `reference/delivery-options.md`). In production's
memory-cache mode, a burst of `fetch_billable_metric` `Key not found` across many codes right after a start
is a swallowed snapshot failure: `memory-cache-ops.md` §1.

Inspect (dev; not runnable here):
```bash
# raw Kafka records
docker compose -f docker-compose.dev.yml exec redpanda rpk topic consume events_dead_letter --offset start --num 5
# ClickHouse copy (exists once lago-api ClickHouse migrations ran)
docker compose -f docker-compose.dev.yml exec clickhouse clickhouse-client --password default \
  --query "SELECT error_code, count() FROM events_dead_letter GROUP BY error_code ORDER BY 2 DESC"
docker compose -f docker-compose.dev.yml exec clickhouse clickhouse-client --password default \
  --query "SELECT failed_at, organization_id, transaction_id, error_code, error_message FROM events_dead_letter ORDER BY failed_at DESC LIMIT 20"
```
UI: https://console.lago.dev (Redpanda Console). DLQ rows and Sentry events carry the full event
including customer `properties` (PII: `security-and-supply-chain`).

## 5. Replay tooling: there is none for the DLQ

- Nothing in this repo or in lago-api @591ae90 reads `events_dead_letter` back into the pipeline
  (`grep -rn -i dead_letter $API/app $API/lib $API/config` → only the ClickHouse model
  `app/models/clickhouse/events_dead_letter.rb`; Karafka's own DLQ `unprocessed_events` for the
  in-advance consumer is configured in `$API/karafka.rb:55`).
- Related but different: lago-api rake `events:reprocess` (`$API/lib/tasks/events.rake:89-117`,
  `ORGANIZATION_ID=… REPROCESS=true`) re-reads ClickHouse `events_raw` for subscriptions that
  `PreEnrichmentCheckService` flags (recurring metrics before 2025-11-25, pricing-group keys before
  2026-03-06, charges/filters created after the subscription start) and re-produces them to the raw topic
  with `source_metadata.reprocess`. It is a re-enrichment migration aid, not a DLQ replay.
  `events:recover_pay_in_advance_fees` (:119-) recovers fees for events never post-processed.
- No replay tool exists today. ADR-001 (DECIDED OD-2 (owner, 2026-10-02), point 5) plans an
  operator-gated DLQ to raw-topic replay tool that stamps a replay header, safe only together with the
  downstream idempotency ADR-001 requires (design and build: `event-accounting-campaign`). Until it ships,
  a manual re-feed (consume `.event` from DLQ records, re-produce to the raw topic) is CANDIDATE and needs
  the owner's sign-off: it re-runs pay-in-advance and refresh side effects, which dedup only where
  `architecture-contract` I12 (CONDITIONAL) holds.

## 6. Scaling

- Parallelism = partitions of the raw topic in one group; extra replicas beyond the partition count idle.
  Dev topics are created by `rpk topic create <names>` without `-p` (scripts/create-topics.sh:17), i.e.
  the broker default partition count (1 on a default Redpanda: UNVERIFIED here).
- Within one process, all records of a poll run concurrently; one slow partition stalls hand-off to the
  others (unbuffered channel, consumer.go:122,195). Output order is not preserved; output keys are
  `org-transaction_id`.
- docs/architecture.md:262 sizes the Events Processor Worker at 2 cores / 2 Gi, 1 replica; the Helm chart
  hard-codes `replicas: 1`. Postgres load in DB mode: up to `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS`
  connections per replica (code default 200, processors/main_processor.go:134; the public Helm chart
  sets 10 via `eventsProcessor.databasePool`). In memory-cache mode (production, DECIDED OD-1) Postgres sees
  only the 10-connection snapshot pool at start (cache/cache.go:63-73); each replica then holds a full cache
  and its own 6 CDC groups (`memory-cache-ops.md` §3-§4).
- A fetch error other than context cancellation panics the process (consumer.go:175-183): rely on the
  restart policy (`restart: unless-stopped` in dev).

## 7. Memory-cache mode (production: DECIDED OD-1; full runbook `memory-cache-ops.md`)

Production runs memory-cache mode (DECIDED OD-1 (owner, 2026-10-02)); dev runs DB mode. Enable:
`LAGO_USE_MEMORY_CACHE=true` (exact string) + `LAGO_DEBEZIUM_TOPIC_PREFIX` matching the Debezium
connector (`extra/debezium_config.json` uses `lago_proc_cdc`; the README example `lago_dbz` does not
match) + Postgres `wal_level=logical` (dev `scripts/postgresql.conf:44`) + the connector registered on
`redpanda-kafka-connect` (no script or doc registers it: UNVERIFIED procedure). The production connector
config, Kafka auth and broker list are OPEN DECISION OD-1b (owner): verify them first (`memory-cache-ops.md` §0).

Operational facts (production-relevant; each has a check in `memory-cache-ops.md`):
- Startup blocks on a full snapshot of 6 tables (whole tables held in memory before writing to badger,
  models/query_streaming.go:95-113); ~0.8 GB RSS per 1M subscriptions on synthetic rows (§4 there).
- Snapshot query errors are discarded, not fatal (only the DB logger prints them; cache/cache.go:63-107):
  the process runs with an empty cache and DLQs events as `fetch_billable_metric` (`Key not found`) (§1 there).
- CDC consumers use a NEW group `lago_evp_<model>_<uuid>` per start (cache/consumer.go:27) → every
  restart replays every CDC topic from the start and leaves 6 orphan groups per replica. Cleanup has a
  KEEP-list gate, an empty-state gate, a WARNING and owner sign-off on production (§3 there).
- CDC consumers pass `LAGO_KAFKA_BOOTSTRAP_SERVERS` unsplit and without SASL/TLS (cache/consumer.go:28-35):
  a comma-separated list or an authenticated cluster silently gets no CDC updates (§0, §2 there).
- 3 of the 6 cached models have no readers since `d9c32b6`.

Details and defects: `architecture-contract` WP6-WP10, WP27; parity of DB vs cache results:
`rails-go-parity`. Fix owner: `event-accounting-campaign` W6 (DEFAULT APPLIED OD-20; the owner may
reassign it).
