---
name: debugging-playbook
description: "Symptom-to-fix triage for the Lago umbrella repo; start here when something is broken and you hold an error, a log or a wrong count. Maps panics, logs, DLQ codes and dev/CI/release errors to cause, check and fix or owner (explain-error.sh). Use on \"brokers not found\", \"variable is required\", \"Error connecting to the flag store\", \"No commitable record in batch\", SQLSTATE 0A000, \"context canceled\", fetch_billable_metric or an empty error_code in events_dead_letter, raw events missing downstream, \"Your Ruby version is\", a red CI job. Not for probes (use diagnostics-and-tooling)."
---
# Debugging playbook: symptom -> cause -> confirm -> fix

Start here when something is broken and you have an error string, a log, or a wrong number. Each
row gives the exact text, the likely causes ranked, a command that confirms the cause, and the fix
or the skill that owns it. Facts verified 2026-10-01 unless marked; owner decisions OD-1..OD-5 of
2026-10-02 folded in (register: `change-control` §9). Code facts as of `5308258` (events-processor tree
`83e012866f29`); the working branch may carry skills-only commits on top. Most error strings were
reproduced with the real binary.

## When to use / when NOT to use

- Use for: an events-processor panic or log line, a growing DLQ, events missing or wrong in
  ClickHouse, a failing `go build`/`go test`, a broken dev stack, a red CI job, a broken release
  image, or a self-host compose that will not start.
- NOT for building or adapting a probe (kfake, binary smoke, overlay, scratch DB). Use
  `diagnostics-and-tooling`. This skill only tells you which probe answers your question.
- NOT for the history of a failure (why it is like this, what was tried). Use `failure-archaeology`.
- NOT for how the pipeline is supposed to work (topology, commit algorithm, invariants). Use
  `architecture-contract`. For Rails/ClickHouse semantics, use `rails-go-parity`.
- NOT for fixing silent loss or value fidelity. Use `event-accounting-campaign`.
- NOT for what an env var means. Use `config-and-flags`. To bring a stack up, use `run-and-operate`.
  For the toolchain recipe, use `build-and-env`. For the gates a fix must pass, use `change-control`.

## Terms

- **DLQ**: the Kafka topic `events_dead_letter` (env `LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC`), mirrored
  into ClickHouse table `events_dead_letter`. A DLQ record holds `{event, initial_error_message,
  error_message, error_code, failed_at}`.
- **error_code**: the DLQ/log code for the failing step, for example `fetch_billable_metric`. An empty
  code means a produce failure.
- **retryable**: a failure the processor does not commit, hoping for redelivery. It is retried only
  while `ingested_at` is less than 12 h old. Older or missing `ingested_at` sends it to the DLQ.
- **commit prefix**: the processor commits the longest run of processed records from the start of a
  batch (`config/kafka/consumer.go:89-104`; `findMaxCommitableRecord` at `:278-308`).
- **LOST**: in no output topic and not on the DLQ. At most it is in Sentry.
- **DB mode / memory-cache mode**: lookups come from Postgres (dev), or from an in-memory badger cache
  fed by a Postgres snapshot plus Debezium CDC (`LAGO_USE_MEMORY_CACHE=true`). PRODUCTION runs
  memory-cache mode (DECIDED OD-1 (owner, 2026-10-02)).
- **CDC**: change data capture. Debezium publishes Postgres row changes to topics
  `<LAGO_DEBEZIUM_TOPIC_PREFIX>.public.<table>`, and the memory cache consumes them.
- **kfake / binary smoke**: an in-process Kafka, and an end-to-end run of the real binary against
  it. Both harnesses are shipped by `diagnostics-and-tooling`.
- **entry id**: the stable name of a playbook row in `scripts/patterns.txt`, for example
  `start-scram`. Print one with `explain-error.sh --id <id>`.
- `$API`: the pinned lago-api checkout: `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`.
  Go paths are relative to `events-processor/` unless they start with a repo directory.

## 0. Triage protocol

1. Know the mode. A production symptom happens in memory-cache mode (DECIDED OD-1); a dev or local
   repro runs DB mode unless you start it with `LAGO_USE_MEMORY_CACHE=true` (reproduce cache behaviour
   with `diagnostics-and-tooling` `smoke-binary.sh cache` / `cache-cdc`). Capture the FIRST failing line,
   not the last; for a production pod capture the log from process start (the cache snapshot lines are
   written once). A panic stack is the result. The cause is usually the line above it (example: the
   `TestNewConnection` panic hides `connection refused`, `build-and-env` B6).
2. Run `.claude/skills/debugging-playbook/scripts/explain-error.sh "<that line>"`. For a whole log,
   run `.claude/skills/debugging-playbook/scripts/triage-ep-log.sh <file>`.
3. Run the row's **confirm** command before you change anything (change-control N13).
4. While debugging, change nothing in delivery semantics, cross-repo contracts or the ClickHouse
   schema. Those are planned changes, not hotfixes: delivery follows ADR-001 (DECIDED OD-2) as a C4
   change (change-control N7); a ClickHouse schema change is allowed (DECIDED OD-3) but ships as a paired
   lago-api PR with a deploy order (change-control N6, DECIDED OD-4). Write probes outside the repo
   (change-control N10).
5. If the string is unknown (exit 1), triage by area with section 1. Once it is understood, add an
   entry with a real example to `scripts/patterns.txt` and run `scripts/selftest.sh` (expect
   `selftest: 18 passed, 0 failed`). That is a change-class C1 change (skill scripts, change-control
   section 2): paste the selftest summary in the PR.

## 1. What are you looking at?

<!-- evidence-check: off routing table (symptom -> section); evidence lives in the target sections -->
| You are looking at | First command | Go to |
|---|---|---|
| events-processor exits or restarts at startup (panic, exit 2, exit 127) | `explain-error.sh "<first ERROR or panic line>"` | section 2 |
| DLQ volume growing | ClickHouse: count `events_dead_letter` by `error_code` (`reference/events-processor.md` E3) | section 3 |
| events missing in ClickHouse / counts lower than sent | `triage-ep-log.sh ep.log`, then the `events_raw` NOT IN query (E4.1) | section 4 |
| Postgres `SQLSTATE 53300` (connection limit) in events-processor logs, often during a burst | `explain-error.sh "<line>"` | sections 3-4 |
| ERROR `error while marshaling enriched events` with no `error` field | `explain-error.sh "<line>"` | section 4 |
| lago-api: a filtered webhook endpoint never gets refund failures; wallet ongoing balances never refresh | `explain-error.sh "<webhook type or validation error>"` | section 4.1 |
| wrong values: 0, `"1e+06"`, `"<nil>"`, unique_count too high | the `events_enriched` string query (E5) | section 4 |
| `context canceled` in logs around a restart | `explain-error.sh "<line>"` (benign vs regression) | section 3 |
| production, right after a restart: everything DLQs as `fetch_billable_metric` `Key not found` | `triage-ep-log.sh` on the log from start (`snapshot loads: started 6, completed 6`?) | section 5 |
| production: in-advance events stopped after a charge edit (back after a deploy) | the production Debezium column list (OPEN DECISION OD-1b (owner)) | section 5 |
| production: a new metric, subscription or edit is not seen (stale cache) | CDC lag checks (`run-and-operate` `reference/memory-cache-ops.md` §2) | section 5 |
| `go build` / `go vet` fails | `explain-error.sh "<line>"` | section 6 |
| `go test` fails or panics | first `--- FAIL` line, then the line above any panic | section 6 |
| dev stack (`docker compose -f docker-compose.dev.yml`) broken | `docker compose -f docker-compose.dev.yml config -q` (works without a daemon) | section 7 |
| CI red | the job name, then `reference/dev-ci-release.md` rows CI1-CI5 | section 7 |
| release image (`getlago/lago`) build broken | the failing Dockerfile step | section 7, `reference/traps.md` T14 |
| self-host compose / `deploy/` broken | `docker compose -f <file> config -q` | section 7 |
<!-- evidence-check: on -->

## 2. events-processor startup

Startup is only PARTIALLY fail-fast (`architecture-contract` I14; startup order and panic contract:
`architecture-contract` section 2). Most checks panic at the first failure: fix one, then expect the
next. Some bad values are accepted silently (empty topic or group, swallowed snapshot errors) or crash
without a log line (SCRAM). The order with captured output is `reference/events-processor.md` E1.
Never print secret env vars (`*_PASSWORD`, `DATABASE_URL`) while checking.

<!-- evidence-check: off triage table; per-row evidence = the Entry id's "evidence:" line in scripts/patterns.txt (explain-error.sh --id <entry>) and reference/events-processor.md E1 -->
| Symptom (exact text) | Likely causes, ranked | Confirm | Fix / owner | Entry |
|---|---|---|---|---|
| `error while loading shared libraries: libexpression_go.so` (exit 127) | 1 `LD_LIBRARY_PATH` not set; 2 image without the `.so` | `ldd <bin> \| grep expression` | `source .claude/skills/build-and-env/scripts/ep-env.sh` (any cwd) | `build-loader` |
| `panic: brokers not found` | `LAGO_KAFKA_BOOTSTRAP_SERVERS` empty | `printenv LAGO_KAFKA_BOOTSTRAP_SERVERS` | set it (`config-and-flags`) | `start-brokers` |
| `panic: LAGO_KAFKA_<X>_TOPIC variable is required` | that topic var is empty. The order is enriched, then in-advance, then dead-letter | the name is in the message | set it | `start-topic-var` |
| `panic: runtime error: invalid memory address ...` + frame `kgo.validateCfg` (no JSON line before it) | `LAGO_KAFKA_SCRAM_ALGORITHM` is not exactly `SCRAM-SHA-256` or `SCRAM-SHA-512` (`config/kafka/kafka.go:56-63`) | `printenv LAGO_KAFKA_SCRAM_ALGORITHM` | fix the value; vocabulary in `config-and-flags` | `start-scram` |
| `unable to dial: dial tcp ...` after WARN `unable to open connection to broker` | 1 wrong broker address; 2 broker not up; 3 TLS mismatch | `nc -vz <host> <port>` | fix the address or wait | `start-kafka-dial` |
| `Error converting max connections into integer` | `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` is not an int | `printenv LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` | plain integer (default 200) | `start-maxconns` |
| `Error connecting to the database` (in cache mode it comes BEFORE the Kafka checks) | 1 PG down; 2 wrong URL; 3 `SQLSTATE 28P01` bad password; 4 empty `DATABASE_URL`: ``user=root database=`` | `pg_isready -d "$DATABASE_URL"` | fix PG or URL | `start-db-connect`, `start-db-url-empty` |
| `Error connecting to the flag store` + `dial tcp` | Redis unreachable. An empty URL means localhost:6379 | `redis-cli -u "redis://${LAGO_REDIS_STORE_URL#*://}" ping` | fix URL or Redis | `start-redis-dial` |
| `Error connecting to the flag store` + `EOF` | TLS against a plaintext Redis: `ENV=production` turns TLS on when `LAGO_REDIS_STORE_TLS` is unset. `rediss://` does NOT turn it on | `printenv ENV LAGO_REDIS_STORE_TLS` | set `LAGO_REDIS_STORE_TLS` explicitly | `start-redis-tls` |
| process runs, consumes nothing, logs `"kafka-topic-consumer":""` / `"group":"_"` | raw topic or consumer group empty | `printenv LAGO_KAFKA_RAW_EVENTS_TOPIC LAGO_KAFKA_CONSUMER_GROUP` | set both. A NEW group name replays the raw topic from the earliest offset | `start-empty-topic` |
<!-- evidence-check: on -->

## 3. events-processor runtime: DLQ codes and log lines

Per-event failures log `msg` = error_message plus `error_code` and `error`. Whether a failure is
retried depends on the FAILURE, not the code (owner: `architecture-contract` section 9): not-found
lookups go to the DLQ at once; DB, badger and Redis errors are neither committed nor sent to the DLQ
while `ingested_at` is less than 12 h old, so they feed section 4. Full table with live evidence:
`reference/events-processor.md` E2-E3.

<!-- evidence-check: off triage table; per-row evidence = the Entry id's "evidence:" line in scripts/patterns.txt and reference/events-processor.md E2-E3 -->
| `error_code` / line | Likely causes, ranked | Confirm | Entry |
|---|---|---|---|
| `build_enriched_event` | timestamp is neither unix seconds nor RFC3339, e.g. `"2025-03-06 12:00:00"` | DLQ `.event.timestamp` | `dlq-build-enriched-event` |
| `fetch_billable_metric` + `record not found` / `Key not found` | `Key not found` = cache mode (production): 1 empty snapshot (MANY codes, right after a start); 2 stale cache (only metrics created after the pod started); 3 wrong code or org; 4 metric deleted. `record not found` = DB mode: 3 or 4 | SQL in the entry; `triage-ep-log.sh` | `dlq-bm-not-found` |
| `fetch_billable_metric` + `cached plan must not change result type (SQLSTATE 0A000)` | (retried DB error) a lago-api migration changed `billable_metrics`; EP still reads it with `SELECT *` (`models/billable_metrics.go:59-66`) | correlate with the API deploy time | `dlq-cached-plan`, T2 |
| any code + `relation "<t>" does not exist (SQLSTATE 42P01)` | (retried DB error) `DATABASE_URL` points at the wrong database | `psql "$DATABASE_URL" -c '\dt'` | `dlq-missing-relation` |
| any `fetch_*` code + `SQLSTATE 53300`: `too many connections for database`, `remaining connection slots are reserved`, `sorry, too many clients already` | (retried DB error) DB-mode pool × replicas (+ other clients) above the Postgres budget; each record of a burst opens its own connection. Silent loss of most of the burst (section 4) | `SHOW max_connections`, `pg_stat_activity` counts, `datconnlimit` (entry) | `loss-db-connections` |
| `evaluate_expression` | 1 a bool/null/object/array property ANYWHERE in `properties`; 2 a missing property; 3 a parse error. The message embeds the event JSON (PII) | property types | `dlq-evaluate-expression` |
| `fetch_subscription` | (retried) DB/badger error. A missing subscription is NOT an error: the event is enriched with `subscription_id:""` | the `component=db` line before it | `dlq-fetch-subscription` |
| `fetch_pay_in_advance_charge` | (retried) DB error on `charges`. The enriched event was ALREADY produced, so a redelivery duplicates it | same | `dlq-pay-in-advance` |
| `flag_subscription_refresh` | (retried) 1 Redis down; 2 pool timeout (pool 10, `config/redis/redis.go:38`) | plain `redis: ... pool.go` lines before it | `dlq-flag-refresh` |
| `flag_subscription_refresh` + `context canceled` | REGRESSION of `02a4bc8`: a per-record write got the process/signal context instead of the batch context (change-control N5) | errors cluster at `Received shutdown signal` | `dlq-flag-ctx-canceled`, T3 |
| DLQ row with `error_code` `""`, log `record had a produce error while synchronously producing` | (committed) 1 topic missing (`UNKNOWN_TOPIC_OR_PARTITION`); 2 broker outage; 3 record too large. After a failed enriched push the in-advance event is still produced | DLQ `initial_error_message` `failed to push to <topic> topic` | `dlq-empty-code` |
| WARN `No commitable record in batch, skipping commit` | the FIRST record of a batch failed retryably | see section 4 | `loss-retryable-skip` |
| stderr `panicked at ... bigdecimal-0.4.6 ... Division by zero`, then `fatal runtime error: failed to initiate panic`, `SIGABRT: abort`; the process exits 2 and dies again after every restart | an expression metric divides by a property that is 0 in some event: the expression engine panics inside the CGO call and aborts the whole process before any commit or DLQ write, so the record is re-read after each restart (poison record; partition wedged). Only events the processor evaluates itself (connector or direct producers) can do this; the billing API answers 500 for the same event | find the metric with a `/` in `expression`; `rails-go-parity` P37 probe (`run-probe.sh value -divzero`) | `run-divzero-abort`; `reimplementation-kit` RBD-37 |
| ERROR `Fetch error` (main consumer), then the process exits | broker-side error; there is no in-process recovery (`config/kafka/consumer.go:175-183`) | the `error` field | `run-fetch-panic` |
| `Error when committing offets to kafka` (typo is in the code) | rebalance or coordinator move. The result is duplicates, not loss; billing dedups them only for orgs with `clickhouse_deduplication_enabled` | - | `run-commit-error` |
| INFO `heartbeat errored ... context canceled`, `Context canceled during fetch` | a normal shutdown | followed by `Event processor stopped` | `run-shutdown-ctx` |
<!-- evidence-check: on -->

## 4. Events missing or wrong downstream

The pipeline loses records silently in several ways. Only some leave a log line. Loss IDs L1-L7 are
`architecture-contract`'s. Mechanisms, a ledger measured with the real binary, and the queries are in
`reference/events-processor.md` E4-E5. The E4.1 query includes connector rows, whose `ingested_at`
ClickHouse reads as 1970 (production audit: `event-accounting-campaign`
`reference/observability-and-production.md` section 3).

<!-- evidence-check: off triage table; per-row evidence = the Entry id's "evidence:" line in scripts/patterns.txt and reference/events-processor.md -->
| Symptom | Mechanism (ranked by how often it explains the gap) | Confirm | Owner |
|---|---|---|---|
| raw count > enriched + DLQ | L1: a retryable failure was committed past by a later batch. Measured 2026-10-01: the offset is never redelivered and never on the DLQ | `events_raw` NOT IN query (E4.1); retryable ERROR lines; `No commitable record` WARNs | `event-accounting-campaign` W1; target contract ADR-001 (DECIDED OD-2) |
| | L1 at scale: Postgres connection exhaustion (`architecture-contract` WP12). Measured on the reference binary: a pool of 200 against a 30-connection limit lost 85-170 of a 201-record burst in nine kit runs (`events-processor-spec` EPC-30; re-run 2026-10-02: 170) | `SQLSTATE 53300` lines (`triage-ep-log.sh` NOTE), one WARN `No commitable record` at most | sizing: `config-and-flags` (pool rule); delivery: `event-accounting-campaign`, `reimplementation-kit` RBD-10 |
| | L2: unmarshal error: committed, no DLQ. Example: a numeric `precise_total_amount_cents` from connectors (still in `events_raw`: E4.1 connector-aware query) | `Error unmarshalling message` lines; Sentry | `event-accounting-campaign` (T7) |
| | non-finite `timestamp` (`"NaN"`, `"Inf"`): it parses, the enriched record cannot be serialised, nothing is produced, no DLQ, committed (`events-processor-spec` EPC-08, re-checked 2026-10-02). Hex floats (`"0x1.9f0e3a8p+30"`) pass silently as seconds | ERROR `error while marshaling enriched events` without `error`; Sentry `json: unsupported value` | `event-accounting-campaign`; `reimplementation-kit` RBD-4 (`loss-nonfinite-timestamp`) |
| | L4: enriched produce failed AND DLQ produce failed | `error while pushing to dead letter topic` | same |
| | ClickHouse ingestion behind or broken (its own Kafka engine; topic and broker list are fixed in the DDL at migration time) | ClickHouse consumer state (UNVERIFIED here, no ClickHouse server) | `config-and-flags` section 7, `run-and-operate` |
| sum/max/latest = 0 or too low (L6) | `value` `"<nil>"`, \|x\| >= 1e12 (negatives too) or a non-numeric `%v` string (`true`, `map[x:1]`) becomes 0 through `toDecimal128OrZero(value, 26)` (`Decimal(38,26)`); `"1e+06"` parses | E5 query; `explain-error.sh --id values-decimal-overflow` | `event-accounting-campaign` W2 (a ClickHouse schema change is allowed: DECIDED OD-3); `rails-go-parity` |
| unique_count too high | `"1e+06"` vs `"1000000"`, and `"<nil>"`, are compared as raw strings | E5 query | `rails-go-parity` |
| event not matched to its subscription at a boundary (L7) | `ToTime` float math lands 1 ms early; RFC3339 offset not normalized; cache mode compares at microsecond precision | `rails-go-parity` time and subscription probes | `rails-go-parity` |
| wallets / alerts / lifetime usage never refresh | lago-api's clock consumes the ZSET only if BOTH `LAGO_REDIS_STORE_URL` and `LAGO_CLICKHOUSE_ENABLED` are present (`$API/clock.rb:209-215`) | `redis-cli -n <db> ZCARD subscription_refreshed_v2` grows | `run-and-operate` |
<!-- evidence-check: on -->

### 4.1 lago-api side: pinned behaviour that looks like a pipeline bug

lago-api facts at the pin 591ae90. The kit executed both rows against that pin (`billing-engine-spec`
vectors); the code fixes live in lago-api, so this repo can only route around them.

<!-- evidence-check: off triage table; per-row evidence = the Entry id's "evidence:" line in scripts/patterns.txt and the cited billing-engine-spec vectors -->
| Symptom | Cause | Confirm | Fix / owner | Entry |
|---|---|---|---|---|
| a webhook endpoint with an `event_types` filter never receives refund failures, even with `credit_note.provider_refund_failure` listed; adding `credit_note.refund_failure` to the filter is rejected (`contains invalid types`) | configured and filterable as `credit_note.provider_refund_failure` (`$API/config/webhook_event_types.yml:86-87`), emitted as `credit_note.refund_failure` (`$API/app/services/webhooks/credit_notes/payment_provider_refund_failure_service.rb:19-20`); delivery matches the emitted name (`$API/app/services/webhooks/base_service.rb:41-43`). EXECUTED: `billing-engine-spec` webhooks.type_info.001, webhooks.endpoint_receives.005, webhooks.normalize_event_types.009 | the endpoint's `event_types` is a non-empty list; an unfiltered endpoint receives `credit_note.refund_failure` | use an unfiltered endpoint (`event_types` null, or `["*"]`, which lago-api turns into null) and filter by `webhook_type` on the receiver; code fix in lago-api: `reimplementation-kit` RBD-83 (ruling proposed, not decided) | `api-refund-failure-webhook` |
| wallet ongoing balances never refresh: all-in-one image, agentic demo, any deploy without a cache setting, and dev | the clock schedules `refresh_wallets_ongoing_balance` only when `LAGO_MEMCACHE_SERVERS` or `LAGO_REDIS_CACHE_URL` is present and `LAGO_DISABLE_WALLET_REFRESH` is not `true` (`$API/clock.rb:55-57`); `docker/runner.sh:5-21` sets neither cache variable; dev sets `LAGO_DISABLE_WALLET_REFRESH=true` (`.env.development.default:11`). EXECUTED: `billing-engine-spec` clock.jobs_due.001 (`reimplementation-kit` RBD-79) | in the clock container: `sh -c '[ -n "$LAGO_REDIS_CACHE_URL$LAGO_MEMCACHE_SERVERS" ] && echo cache set \|\| echo no cache'` (prints no value) | set a cache URL and leave `LAGO_DISABLE_WALLET_REFRESH` unset: `run-and-operate` section 8, `config-and-flags` | - |
<!-- evidence-check: on -->

## 5. Memory-cache mode = production (DECIDED OD-1)

Production runs memory-cache mode (DECIDED OD-1 (owner, 2026-10-02)), so these are production symptoms,
not edge cases. What is still unknown is the production CDC config (Debezium column list, Kafka auth,
brokers): OPEN DECISION OD-1b (owner); check it first when a cache symptom appears (`run-and-operate`
`reference/memory-cache-ops.md` §0). Fix owner: `event-accounting-campaign` W6 (DEFAULT APPLIED OD-20);
as-is defects `architecture-contract` WP6-WP10, WP27. Detail and evidence: `reference/events-processor.md` E6.

<!-- evidence-check: off triage table; per-row evidence = the Entry id's "evidence:" line in scripts/patterns.txt, reference/events-processor.md E6 and architecture-contract WP6-WP10 -->
| Symptom | Cause | Confirm | Entry |
|---|---|---|---|
| right after a (re)start, EVERY event DLQs `fetch_billable_metric` `Key not found`, across many codes | the snapshot failed and was swallowed (`cache/cache.go:78-106`), so the cache is empty; or it read the wrong database (0 rows) | `triage-ep-log.sh` on the log from start: `snapshot loads: started 6, completed 0` or `WARNING: snapshot loaded 0 billable_metrics`; DLQ burst query (`run-and-operate` `reference/memory-cache-ops.md` §1) | `cache-snapshot-failed`, T4 |
| pay-in-advance stops for a plan after a charge edit; recurring fallback stops after a metric edit; both come back after a restart | `extra/debezium_config.json:2` omits `pay_in_advance`, `accepts_target_wallet`, `recurring`; a CDC update rewrites the cached row without them; a restart re-snapshots full rows | the production connector's column list (OD-1b); `events_charged_in_advance` volume per plan around the edit; smoke `cache-cdc` row A | T6 |
| stale cache: a new metric DLQs `Key not found` for that code only, a new subscription's events have `subscription_id:""`, a deleted metric is still enriched | CDC not delivering: connector down, slot behind, consumer lag, comma broker list, or SASL/TLS (CDC clients have neither, `cache/consumer.go:28-35`) | `reference/memory-cache-ops.md` §2 (connector state, slot lag, `lago_evp_*` group lag); a comma in `LAGO_KAFKA_BOOTSTRAP_SERVERS` | T5, `cache-cdc-fetch` |
| CDC errors on a secured cluster | the CDC clients have no SASL/TLS options | `cache-cdc-fetch` lines | `cache-cdc-fetch` |
| `lago_evp_<model>_<uuid>` groups pile up on the broker | 6 new groups per process start, never removed (`cache/consumer.go:27`) | `rpk group list` | gated cleanup: `run-and-operate` `reference/memory-cache-ops.md` §3 |
| event at the exact ms a subscription starts: matched in DB mode (dev), not in cache mode (production) | full-precision compare (`cache/subscriptions.go:56-66`) | binary smoke row H | - |
| `LAGO_USE_MEMORY_CACHE=TRUE` or `1` runs DB mode | only the literal `true` enables it (`main.go:67`) | no `Starting snapshot load` lines | - |
<!-- evidence-check: on -->

## 6. Build and test failures

Baseline (as of 2026-10-01): `.claude/skills/build-and-env/scripts/ep-test.sh` passes 6 packages,
and `-v` shows 235 `--- PASS`. This section is a router: the fix for each row lives in the owner row
(build, toolchain and Postgres-for-tests: `build-and-env` B#; test harness: `validation-and-qa` HD# /
section 10). Lookup table with row ids BT1-BT14: `reference/build-and-test.md`.

<!-- evidence-check: off lookup table; owner rows with reproductions are build-and-env B# and validation-and-qa HD# -->
| Exact text | Cause | Fix: owner row | Entry |
|---|---|---|---|
| `/usr/bin/ld: cannot find -lexpression_go` | `CGO_LDFLAGS` lacks `-L` | `build-and-env` B1 (`source .claude/skills/build-and-env/scripts/ep-env.sh`) | `build-link` |
| `events_processor.test: error while loading shared libraries: libexpression_go.so` | `LD_LIBRARY_PATH` | `build-and-env` B2 (same) | `build-loader` |
| `build constraints exclude all Go files in .../expression-go@v0.1.4` | cgo off | `build-and-env` B3 | `build-cgo-disabled` |
| `go: go.mod requires go >= 1.25.0 (running go 1.24.7; GOTOOLCHAIN=local)` | old Go, no auto-download | `build-and-env` B5 | `build-go-toolchain` |
| `go: no such tool "covdata"` (exit 1) | the go1.25.0 module toolchain has no covdata | `build-and-env` B4 | `test-covdata` |
| `--- FAIL: TestNewConnection` + nil-pointer panic at `database_test.go:24` | Postgres down. The real error is ABOVE the stack | `build-and-env` B6 | `test-pg-down`, T10 |
| `--- FAIL: TestEvaluateExpression/<subtest>` (`expected: string("36")`) when run alone | 2 order-dependent subtests | run the parent test; `validation-and-qa` HD3 | `test-order-dependent` |
| `could not match actual sql` | the SQL changed and the sqlmock pin did not | update the pin in the same PR: a change-class C3 change (change-control N4; `validation-and-qa` section 10) | `test-sqlmock-mismatch` |
| `Error: unknown flag: --cache-dir` | golangci-lint v2 | `build-and-env` B14 (`GOLANGCI_LINT_CACHE=<dir> golangci-lint run --allow-serial-runners ./...`; lint policy OPEN DECISION OD-6 (owner)) | `test-lint-cache-dir` |
| `ERROR Failed to cache item ... DB Closed` in a PASSING run | deliberate negative tests | nothing (`validation-and-qa`) | - |
<!-- evidence-check: on -->

## 7. Dev stack, CI, release image, self-host

All rows with text and commands are in `reference/dev-ci-release.md` (rows DEV, CI, RD, SH). These cost the most time:

<!-- evidence-check: off triage table; per-row evidence = the Entry id's "evidence:" line in scripts/patterns.txt and reference/dev-ci-release.md -->
| Symptom | Cause | Fix | Entry |
|---|---|---|---|
| `lago: command not found` / `unknown command "exec" for "lago"` | `lago` is a shell alias (`docs/dev_environment.md:53`) | `docker compose -f docker-compose.dev.yml ...` | `dev-lago-alias` |
| front will not start (exact text UNVERIFIED, no daemon) | external volume `lago_front_pnpm_store` (`docker-compose.dev.yml:11-12`) | `docker volume create lago_front_pnpm_store` | `dev-pnpm-volume` |
| `ERR EntryPoint doesn't exist entryPointName=ws` | only `web` and `websecure` exist (`traefik/traefik.yml:13-17`) | fix the label | `dev-traefik-entrypoint`, T12 |
| `RedisClient::CannotConnectError` in `migrate`; `unable to create topics ... connection refused` | an infra dependency edge without `service_healthy` | add the health condition: change class C6 (change-control N12) | `dev-compose-race`, T13 |
| root compose: `did not find expected key` | an uncommented `# - SIDEKIQ_X=true` hint | `"SIDEKIQ_EVENTS": "true"` | `dev-sidekiq-yaml` |
| jobs never run after `SIDEKIQ_EVENTS=true` | no `api-events-worker` serving queue `events` | start the worker | `dev-sidekiq-no-worker` |
| ClickHouse still on with `LAGO_CLICKHOUSE_ENABLED=false` | MIXED (see `config-and-flags`): 12 `.present?` read sites stay ON, org creation and 2 seeds turn OFF | unset it or set it empty | `dev-clickhouse-false` |
| API email delivery errors in dev | 1 Mailpit not started (profile); 2 CANDIDATE: the lago-api dev SMTP host is `mailhog`, the service is `mailpit` | `docker compose -f docker-compose.dev.yml up -d --wait mailpit` (needs a daemon); then T15 | `dev-mail` |
| PR changing only `events-processor-tests.yml` runs no tests | PR path filter `events-processor/**` | it first runs on push to `main`; lint the workflow locally first | row CI1 |
| actionlint: `actions/checkout@v3 ... too old to run on GitHub Actions` | old action majors (`events-processor-tests.yml:38,41,59`) | bump in a change-class C5 PR | `ci-action-too-old` |
| release image: `ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY` / Ruby or Node mismatch / Bundler `--without` | `docker/Dockerfile` is built only at release; ARGs `:1-2` lag api/front; `pnpm@latest` (`:12`, inert while front pins `packageManager`) | compare ARGs before tagging (`release-and-images`) | `rel-*`, T14 |
| `unknown flag: --profile` | `deploy/README.md` syntax | `docker compose -f <file> --profile all up -d` | `selfhost-profile-flag` |
| `unexpected character "\x1b" in variable name` | `deploy/deploy.sh` wrote status lines into `.env` | delete those lines | `selfhost-env-escape` |
<!-- evidence-check: on -->

## 8. Traps that cost real time

Each trap has its story, tell-tale and shortcut in `reference/traps.md`. Read it before you sink an
hour into one of these areas.

<!-- evidence-check: off trap index; story, shas and evidence per trap in reference/traps.md -->
| # | Trap | What it cost | Tell-tale |
|---|---|---|---|
| T1 | a retryable failure is silently skipped | 401-day, 6-commit chain ending in a production segfault (`cec0eb2`..`9acd83e`, ING-15); the skip is still live | `No commitable record`; retryable codes with no DLQ rows |
| T2 | SQLSTATE 0A000 after a Rails column add | 169 days (`bd92069`..`9acd83e`), then `3ac94a2`; `billable_metrics` still exposed | 0A000 burst after an API deploy |
| T3 | `context canceled` on every rolling restart | 275 days (`b6d3616`..`02a4bc8`) | `flag_subscription_refresh` + `context canceled` at SIGTERM |
| T4 | empty memory cache, so everything DLQs | silent, no alert (reproduced 2026-10-01) | `Key not found` for every code |
| T5 | comma broker list makes the CDC consumers silently dead | open 157 days | nothing at all |
| T6 | Debezium column list stops pay-in-advance | open since `fff5858` | in-advance volume drops after an edit |
| T7 | numeric `precise_total_amount_cents` drops connector events | open 378 days (`190aa81`) | `cannot unmarshal number ... precise_total_amount_cents` |
| T8 | `"<nil>"` and \|x\| >= 1e12 become 0 (`"1e+06"` parses; unique_count compares raw strings) | since the first commit | sums 0, unique_count high |
| T9 | "direct go test won't work" (it does) | every Docker-less newcomer | link/loader/covdata errors |
| T10 | `TestNewConnection` panic hides "Postgres down" | every sandbox restart | SIGSEGV at `database_test.go:24` |
| T11 | a single subtest fails alone | time lost per occurrence | `expected: string("36")` |
| T12 | Traefik `ws` entrypoint; its fix PR moved the submodules | 1210 days of errors; revert `647de3e` | `EntryPoint doesn't exist` |
| T13 | dev compose races; `lago_test` never created | 774 days for the DB | failures vanish on retry |
| T14 | the all-in-one image breaks on release day | 10 `fix` commits under `docker/` since 2025-05; `getlago/lago` v1.33.0-v1.33.2 and v1.48.0-v1.50.0 never published (as of 2026-10-01; list: `release-and-images`) | red release workflow |
| T15 | Mailpit is up, but dev mail still fails (CANDIDATE) | new 2026-10-01 | delivery error with Mailpit running |
| T16 | deleted billable metrics still matched | 18 days (`fff5858`..`8ceca4b`) | enrichment for a deleted code |
<!-- evidence-check: on -->

## 9. Escalation: when to stop debugging and open an owner question

Stop and write the question (template and routing: `research-methodology`; gate: change-control
section 9) when one of these holds:

| You found / need | Stop because | Label |
|---|---|---|
| the fix changes commit, retry or DLQ behaviour (T1; `architecture-contract` L1-L5; a new DLQ `error_code` counts, change class C4) | it is a C4 change that must conform to ADR-001, the decided delivery contract (change-control N7); a deviation needs an ADR-001 amendment by the owner | DECIDED OD-2 (owner, 2026-10-02): ADR-001 in `event-accounting-campaign` |
| someone wants to re-feed DLQ rows | no DLQ replay tool exists today; ADR-001 plans an operator-gated one; a manual re-feed re-runs side effects | CANDIDATE; owner sign-off |
| the impact of a memory-cache defect (T4-T6) in production | production runs cache mode, but its Debezium column list, Kafka auth and brokers are unknown here | DECIDED OD-1 (owner, 2026-10-02); OPEN DECISION OD-1b (owner); fixes: `event-accounting-campaign` W6 (DEFAULT APPLIED OD-20) |
| zeroed values need `decimal_value` precision or a new column | a ClickHouse schema change is allowed, but its DDL lives in lago-api: paired PR + deploy order (change-control N6) | DECIDED OD-3 (owner, 2026-10-02); `event-accounting-campaign` W2 |
| the fix changes a topic name, the ZSET name/member/bucket, or a payload or `value` format | cross-repo contract (change-control N6): a paired PR in every repo that reads or writes the changed part (lago-api reads all of these) | DECIDED OD-4 (owner, 2026-10-02) |
| behaviour depends on lago-api flags `pre_filter_events`, `lazy_charge_usage_cache`, `enriched_events_aggregation` (e.g. Rails reading `events_enriched_expanded`) | production flag state is unknown | OPEN DECISION OD-8 (owner) |
| a secret or licence value shows up in history, logs or DLQ payloads | never print it; rotation unknown | OPEN DECISION OD-9 (owner) |
| full event JSON (PII) in Sentry extras, `evaluate_expression` messages or the TTL-less DLQ | retention policy is an owner call (`security-and-supply-chain`) | OPEN DECISION OD-19 (owner) |
| someone insists on new lint rules | gate policy (`ep-test.sh` is already an accepted pre-PR gate: DECIDED OD-5 (owner, 2026-10-02); `lago exec` stays valid too) | OPEN DECISION OD-6 (owner) |
| you reproduced locally (binary smoke, kfake) and it does NOT reproduce, and the remaining hypotheses need production facts (env, replicas, partitions, ClickHouse version, grace period) | those facts are invisible from this repo (UNVERIFIED) | owner question via `research-methodology` |

Time-box: if two cheap confirms (logs + one query or probe) have not moved you closer, write down
what you measured and escalate. Do not guess and change code.

## Scripts

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/explain-error.sh` | map a string or log line to playbook entries; `-` reads stdin; `--brief`, `--list`, `--id`, `--self-test` | `.claude/skills/debugging-playbook/scripts/explain-error.sh 'panic: brokers not found'` | `[start-brokers] (startup) LAGO_KAFKA_BOOTSTRAP_SERVERS is empty or unset ...` + cause/confirm/fix/see/evidence; exit 0. Unknown string: `UNKNOWN`, exit 1; usage error exit 2 |
| `scripts/triage-ep-log.sh` | bucket an events-processor log by error_code, msg, panic; silent-loss counters; snapshot completeness and row counts; playbook ids | `.claude/skills/debugging-playbook/scripts/triage-ep-log.sh .claude/skills/debugging-playbook/scripts/testdata/cache-empty-snapshot.log` | `snapshot loads: started 6, completed 0`, `WARNING: EMPTY/PARTIAL CACHE`, ids `cache-snapshot-failed`, `dlq-bm-not-found`; exit 0 (1 = not an EP log, 2 = usage, 3 = findings with `--fail-on-findings`). On `testdata/cache-healthy.log` (2026-10-02): `started 6, completed 6`, `snapshot rows: … billable_metrics=3 … charges=2 subscriptions=1` |
| `scripts/selftest.sh` | bash -n, pattern self-test, exit codes, triage output vs `testdata/*.expected`, same output with `docker compose logs` / `kubectl logs --timestamps` prefixes | `.claude/skills/debugging-playbook/scripts/selftest.sh` | `selftest: 18 passed, 0 failed` (as of 2026-10-02) |
| `scripts/patterns.txt` | the entry database (74 entries, 118 patterns, 98 examples; `--self-test` prints the counts) | `explain-error.sh --list` | id, area, title per line |
| `scripts/testdata/*.log` | REAL logs from 2026-10-01 runs (startup failures, DB-mode runtime, empty-cache run), a REAL healthy cache-mode run from 2026-10-02 (`cache-healthy.log`, INFO level), REAL 2026-10-02 reference-binary runs of `events-processor-spec` EPC-08 (`epc08-time-formats.log`: 2 non-finite timestamps) and EPC-30 (`epc30-db-connections.log`, excerpt: SQLSTATE 53300) + one SYNTHETIC file built from code format strings | input for `selftest.sh` | see `*.expected`; on `epc30-db-connections.log`: `NOTE: 5 line(s) carry SQLSTATE 53300`, id `loss-db-connections` |

All scripts are read-only, need only bash, awk and sort, and write at most one `mktemp -d` dir.
To triage a live log: `kubectl logs <pod> > ep.log`, or `docker compose -f docker-compose.dev.yml
logs --no-color events-processor > ep.log` (needs a daemon). Then run `triage-ep-log.sh ep.log`.

## Provenance and maintenance

- Sources: `events-processor/` (`main.go`, `processors/main_processor.go`,
  `processors/events_processor/*.go`, `config/kafka/*.go`, `config/redis/redis.go`, `cache/*.go`,
  `models/*.go`, `utils/*.go`), `docker-compose.dev.yml`, `docker-compose.yml`, `traefik/traefik.yml`,
  `extra/debezium_config.json`, `connectors/*.yml`, `docker/Dockerfile`, `.github/workflows/*.yml`,
  `deploy/`, `docs/dev_environment.md`; `$API` (`clock.rb`, `config/environments/development.rb`,
  `app/services/events/stores/store_factory.rb`, `app/services/organizations/create_service.rb`,
  `app/services/billable_metrics/aggregations/base_service.rb`, `app/jobs/events/*`, `db/clickhouse_migrate/*`);
  history commits cited per trap. Runtime evidence: real binary runs on 2026-10-01 against kfake,
  miniredis/redis-server and scratch Postgres databases (dropped afterwards); `clickhouse local` 26.2.19.43.
  Kit evidence (2026-10-02): `events-processor-spec` EPC-08 and EPC-30 runs of the reference binary
  (tree 83e012866f29), `billing-engine-spec` vectors webhooks.type_info.001, webhooks.endpoint_receives.005,
  webhooks.normalize_event_types.009, clock.jobs_due.001 executed at lago-api 591ae90; ids
  `reimplementation-kit` RBD-4, RBD-10, RBD-79, RBD-83.
- Volatile facts, each with a one-line re-check (expected values as of 2026-10-01):
  - code unchanged since the as-of commit: `git diff --stat 5308258 HEAD -- . ':!.claude'` -> empty
  - entry count: `grep -c '^id: ' .claude/skills/debugging-playbook/scripts/patterns.txt` -> `73` (as of 2026-10-02)
  - scripts healthy: `.claude/skills/debugging-playbook/scripts/selftest.sh | tail -1` -> `selftest: 18 passed, 0 failed` (as of 2026-10-02)
  - DB exhaustion loss (needs Postgres; reference binary from `.claude/skills/events-processor-spec/scripts/maintainer/build-go-reference.sh --print-env`, which prints `EP_REF_BIN` and `EP_REF_LD_LIBRARY_PATH`): `bash .claude/skills/events-processor-spec/scripts/run-suite.sh --impl-cmd "$EP_REF_BIN" --impl-env LD_LIBRARY_PATH=$EP_REF_LD_LIBRARY_PATH --mode db --profile corrected --only EPC-30` -> `EPC-30-db-connection-burst compat=- corrected=FAIL`; its `--keep` dir's `.out` ledger lists 85-170 `NO_OUTPUT_COMMITTED` rows (170 on 2026-10-02)
  - unlogged marshal error: `grep -n 'error while marshaling enriched events' events-processor/processors/events_processor/event_producer_service.go` -> `:35` (no error attribute)
  - refund-failure name: `grep -n -A1 'def webhook_type' "$API/app/services/webhooks/credit_notes/payment_provider_refund_failure_service.rb"` -> `"credit_note.refund_failure"`; `grep -n 'provider_refund_failure' "$API/config/webhook_event_types.yml"` -> `:86-87`
  - wallet refresh gate: `sed -n 55,57p "$API/clock.rb"` -> `LAGO_MEMCACHE_SERVERS`, `LAGO_REDIS_CACHE_URL`, `LAGO_DISABLE_WALLET_REFRESH`
  - startup strings: `grep -n 'brokers not found\|variable is required\|max connections into integer\|flag store' events-processor/processors/main_processor.go` -> lines 57, 105-106, 136, 154
  - commit-skip WARN: `grep -n 'No commitable record' events-processor/config/kafka/consumer.go` -> `:98`
  - `SELECT *` residual: `grep -n 'Connection.First(' events-processor/models/billable_metrics.go` -> `:61`
  - value formatting: `grep -n 'Sprintf("%v"' events-processor/processors/events_processor/enrichment_service.go` -> `:114`
  - CDC raw broker string: `grep -n 'SeedBrokers(brokers)' events-processor/cache/consumer.go` -> `:31`
  - Debezium columns: `grep -c 'pay_in_advance' extra/debezium_config.json` -> `0`
  - floating pnpm: `grep -n 'pnpm@latest' docker/Dockerfile` -> `:12`
  - old actions: `grep -n 'checkout@v3\|setup-go@v4' .github/workflows/events-processor-tests.yml` -> 38, 41, 59
  - dev SMTP host: `grep -n 'address:' "$API/config/environments/development.rb"` -> `"mailhog"`
  - pins the `$API` facts depend on: `git ls-tree HEAD api front` -> `591ae90...` / `0c5e539...`
  - missing single images (full list and sweep: `release-and-images`): `for t in v1.33.0 v1.33.2 v1.33.3 v1.48.0 v1.48.1 v1.49.0 v1.50.0; do curl -s -o /dev/null -w "$t %{http_code}\n" https://hub.docker.com/v2/repositories/getlago/lago/tags/$t; done` -> 404, 404, 200, 404, 200, 404, 404
  - release-day fixes: `git -C "$(.claude/skills/research-methodology/scripts/history-setup.sh)" log --oneline -- docker/ | grep -ic fix` -> `10`
  - connector ptac mapping: `grep -n 'precise_total_amount_cents.type() == "number"' connectors/*.yml` -> http.yml:32, kinesis.yml:38, sqs.yml:34
- Update triggers: any change to an events-processor log message, `error_code` or `LogAndPanic` call
  (re-run `selftest.sh`; update `patterns.txt` examples and `testdata/*.expected` with `selftest.sh
  --update`, then review the diff); a franz-go bump (the `client.go:146` frame of `start-scram`);
  a lago-expression or Go bump; compose service renames; `docker/Dockerfile` ARG changes; an
  api/front gitlink bump (re-check every `$API` citation and section 4.1); a closed OPEN DECISION (grep `OD-` here);
  an owner ruling on `reimplementation-kit` RBD-4, RBD-10, RBD-79 or RBD-83, or a kit re-mint of EPC-08/EPC-30.
