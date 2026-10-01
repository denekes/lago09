# events-processor: symptom tables with captured evidence

Read when SKILL.md sections 2-5 pointed you here and you need the exact output, the ranked causes, or
the measurement behind a row. Go paths are relative to `events-processor/`; other paths are
repo-relative; `$API` = pinned lago-api (`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`).
Every "VERIFIED" row was reproduced on 2026-10-01 with the real binary (code at `5308258`) built by
`source .claude/skills/build-and-env/scripts/ep-env.sh; (cd events-processor && go build -o "$(mktemp -d)/ep" .)`
and run against an in-process Kafka (kfake) + Redis (miniredis or redis-server) + scratch Postgres.
The harnesses that reproduce these setups belong to `diagnostics-and-tooling` (binary smoke, kfake);
the per-offset loss ledger belongs to `event-accounting-campaign`.

## E1. Startup contract, in order, with the exact failure output

The process is fail-fast: each step panics; the orchestrator restarts it. Nothing below is retried
in-process. `LogAndPanic` (`utils/error_tracker.go:30-34`) logs `msg`=step + `error`, calls Sentry
`CaptureError`, then panics with the error text.

| # | Step (code) | Failure output (VERIFIED unless marked) | Entry id |
|---|---|---|---|
| 0 | dynamic loader finds `libexpression_go.so` | `<bin>: error while loading shared libraries: libexpression_go.so: cannot open shared object file: No such file or directory`, exit 127, before `main` | `build-loader` |
| 1 | memory-cache mode only (`main.go:67`, literal `"true"`): badger, then a BLOCKING Postgres snapshot (`cache/cache.go:63-107`), then 6 CDC consumers | PG unreachable: `Error connecting to the database` (`cache/cache.go:71`) BEFORE any Kafka check; table errors are swallowed (see E6) | `start-db-connect`, `cache-snapshot-failed` |
| 2 | brokers (`processors/main_processor.go:103-107`) | `{"level":"ERROR","msg":"brokers not found"}` + `panic: brokers not found` (plain panic: no Sentry) | `start-brokers` |
| 3 | 3 producers, in order enriched, in-advance, DLQ: env required + `Ping` (`:55-76,118-131`) | `{"msg":"failed to initialize enriched events producer","error":"LAGO_KAFKA_ENRICHED_EVENTS_TOPIC variable is required"}`; unreachable: `"error":"unable to dial: dial tcp 127.0.0.1:1: connect: connection refused"` preceded by WARN `unable to open connection to broker` | `start-topic-var`, `start-kafka-dial` |
| 3a | SASL option (`config/kafka/kafka.go:48-64`) | `panic: runtime error: invalid memory address or nil pointer dereference` / `[signal SIGSEGV ...]` / first frame `github.com/twmb/franz-go/pkg/kgo.validateCfg` (`client.go:146`). NO JSON line, no Sentry | `start-scram` |
| 4 | DB mode only: pool size int, connect (`:133-150`) | `Error converting max connections into integer` (`strconv.Atoi: parsing "200x"`); `Error connecting to the database` (`dial error`, `password authentication failed ... (SQLSTATE 28P01)`, or with empty `DATABASE_URL`: ``failed to connect to `user=root database=` `` + `role "root" does not exist`) | `start-maxconns`, `start-db-connect`, `start-db-url-empty` |
| 5 | Redis flag store: DB int, `Ping` (`:78-100,152-156`) | ~2-3 s of plain `redis: <date> pool.go:419: redis: connection pool: failed to dial after 5 attempts: ...`, then `Error connecting to the flag store` with `dial tcp ...` / `EOF` (TLS vs plaintext) / `strconv.Atoi` | `start-redis-dial`, `start-redis-tls`, `start-redis-db` |
| 6 | consumer group client + `Ping` (`:168-179`, `config/kafka/consumer.go:227-259`) | `Error starting the event consumer` (CODE, not reproduced). Empty raw topic and group are ACCEPTED: logs show `"kafka-topic-consumer":""` and franz-go `"group":"_"`, nothing is consumed | `start-consumer`, `start-empty-topic` |
| 7 | `{"msg":"Starting event consumer"}` then `cg.Start` blocks | healthy start; new group logs franz-go `assigning partitions` with `"At":-2` (= earliest) | - |

Captured order matters for triage: the FIRST failing step hides everything after it. Fix and re-run;
expect the next step's failure until the env is complete.

## E2. Per-event disposition (what happened to a record)

`processors/events_processor/processor.go:43-96`, `config/kafka/consumer.go:82-109`.

| Outcome | Log signature | Committed? | On DLQ? | Sentry |
|---|---|---|---|---|
| success | none (no per-event INFO line) | yes | no | no |
| JSON unmarshal error | ERROR `Error unmarshalling message` + `error` | yes | **NO (lost)** | yes |
| non-retryable failure | ERROR `<error_message>` + `error_code` + `error` | yes | yes, with code | only if capturable (not-found: no) |
| retryable failure, `ingested_at` < 12 h | same ERROR line | **no** (commit = longest processed prefix) | **no** | yes |
| retryable failure, `ingested_at` >= 12 h or missing (zero time) | same ERROR line | yes | yes, with code | yes |
| enriched or in-advance produce failed | ERROR `record had a produce error while synchronously producing` (`component=kafka-producer`); NO per-event line | yes | yes, `error_code` = `""`, `initial_error_message` = `failed to push to <topic> topic` | yes |
| DLQ produce failed too | + ERROR `error while pushing to dead letter topic` | yes | **NO (lost)** | yes (with event) |
| first record of the batch unprocessed | WARN `No commitable record in batch, skipping commit. ... batch_size: N processed: M` | nothing in the batch | - | - |

DLQ record = `{event, initial_error_message, error_message, error_code, failed_at}` (`models/event.go:50-56`),
no Kafka key; its `ingested_at` loses milliseconds (`utils/time.go:103-111`). In ClickHouse it lands in
`events_dead_letter` (`$API/db/clickhouse_migrate/20251110100317_create_events_dead_letter.rb`).

## E3. DLQ error codes

| `error_code` | `error_message` (= log `msg`) | Retryable | Live evidence 2026-10-01 | Most likely causes, ranked |
|---|---|---|---|---|
| `build_enriched_event` | Error while converting event to enriched event | no | smoke tx_C `strconv.ParseFloat: parsing "2025-03-06 12:00:00": invalid syntax` | 1 timestamp not unix-seconds / RFC3339; 2 wrong JSON type. The text is ParseFloat's even when RFC3339 failed (`utils/time.go:25-27`) |
| `fetch_billable_metric` | Error fetching billable metric | no for `record not found` / `Key not found`; **yes** for DB errors | smoke tx_B; `42P01` against an empty DB; `0A000` after `ALTER TABLE billable_metrics ADD COLUMN` | 1 wrong code/org or deleted metric; 2 cache mode with empty snapshot (ALL events); 3 Rails migration + `SELECT *` (0A000 burst); 4 wrong `DATABASE_URL` (42P01) |
| `evaluate_expression` | Error evaluating custom expression | no | smoke tx_E (property `flag:true` next to the used `a`) | 1 a bool/null/object/array property anywhere in `properties`; 2 property used by the expression missing; 3 parse error / function not in lago-expression v0.2.0 (`min` vs `least`). The message embeds the whole event JSON (PII) |
| `fetch_subscription` | Error fetching subscription | yes | `subscriptions` renamed mid-run -> `42P01` | DB/badger error. A MISSING subscription is not an error: the event is enriched with `subscription_id:""` (`enrichment_service.go:61-67`) |
| `fetch_pay_in_advance_charge` | Error fetching pay in advance charge | yes | `charges` renamed mid-run; the enriched event had ALREADY been produced | DB/badger error on charges (`processor.go:115-119`) |
| `flag_subscription_refresh` | Error flagging subscription refresh | yes | `redis-server` shut down mid-run: `dial tcp 127.0.0.1:16380: connect: connection refused` | Redis down; pool timeout (PoolSize 10, `config/redis/redis.go:38`, vs up to 10 000 goroutines per poll); with `context canceled` = regression of `02a4bc8` |
| `""` | `""` | n/a | `LAGO_KAFKA_ENRICHED_EVENTS_TOPIC=missing_topic`: DLQ row `"initial_error_message":"failed to push to missing_topic topic","error_message":"","error_code":""` | topic missing (`UNKNOWN_TOPIC_OR_PARTITION`), broker outage, record too large |

Count DLQ rows by code in ClickHouse (query validated with `clickhouse local` 26.2 against the same
columns; run it on your ClickHouse):
```sql
SELECT error_code, any(initial_error_message) AS example, count() AS n
FROM events_dead_letter
WHERE failed_at > now() - INTERVAL 1 HOUR
GROUP BY error_code ORDER BY n DESC;
```

## E4. Silent loss: the mechanisms and how each one shows (or does not)

| # | Mechanism | What you see | What you do NOT see | Confirm |
|---|---|---|---|---|
| L1 | retryable failure, later batch on the same partition commits | ERROR line with a retryable code; maybe WARN `No commitable record in batch` | no DLQ row, no enriched row, no retry | E4.1 ledger; the transaction_id is in `events_raw` but in neither output table (query below) |
| L2 | unmarshal error | ERROR `Error unmarshalling message` | no DLQ row, no enriched row; whether ClickHouse `events_raw` (its own Kafka engine on the raw topic) keeps such a record is UNVERIFIED, so the NOT IN query may miss it | Sentry |
| L3 | DLQ produce failure after an enriched/in-advance produce failure | `record had a produce error...` + `error while pushing to dead letter topic` | the event anywhere but Sentry | Sentry, broker logs |
| L4 | values zeroed downstream | nothing in EP logs | - | E5 |
| L5 | time 1 ms early for subscription lookup (`utils/time.go:20-23`, about half of ms timestamps) | event enriched with `subscription_id:""` at a subscription boundary | - | `rails-go-parity` probes |

### E4.1 Measured ledger (real binary, DB mode, 2026-10-01)

Raw topic offsets and the committed offset of each consumer group, read with a kadm client. That
one-off probe is not shipped here; to re-measure L1 today, run the `event-accounting-campaign`
accounting probe (its fault matrix includes "transient DB error, then more traffic" -> LOST).

| Run | Offset | transaction_id | Outcome |
|---|---|---|---|
| empty `DATABASE_URL` database | 0 | `tx_fresh_retryable` (ingested now) | `fetch_billable_metric` 42P01, retryable -> not committed, WARN `No commitable record ... batch_size: 2 processed: 1` |
| | 1 | `tx_old_dlq` (ingested 13 h ago) | same error, >= 12 h -> DLQ |
| | 2 | `tx_old_dlq_2` (13 h, later batch) | DLQ, commit -> **group committed = 3: offset 0 skipped forever, never on the DLQ** |
| tables altered mid-run (pool size 1) | 6 | `tx_cachedplan` | 0A000 after `ALTER TABLE billable_metrics ADD COLUMN`, retryable |
| | 7 | `tx_after_cachedplan` | succeeded (pgx re-prepared) -> commit past 6: **offset 6 LOST** (in no output topic) |
| | 8 | `tx_charges_gone` | enriched PRODUCED, then `fetch_pay_in_advance_charge` -> uncommitted (a restart re-produces it: duplicate) |
| | 9 | `tx_subs_gone` | `fetch_subscription` -> uncommitted; group committed = 8 |

Find candidates for L1/L2 in ClickHouse (raw has the record, neither output table does). Validated with
`clickhouse local` (the `LEFT ANTI JOIN` form returned nothing there; use `NOT IN`):
```sql
SELECT organization_id, transaction_id, code, ingested_at
FROM events_raw
WHERE ingested_at > now() - INTERVAL 1 DAY
  AND (organization_id, transaction_id) NOT IN (SELECT organization_id, transaction_id FROM events_enriched)
  AND (organization_id, transaction_id) NOT IN (SELECT organization_id, transaction_id FROM events_dead_letter)
ORDER BY ingested_at LIMIT 100;
```
`events_raw` is fed from the raw topic by its own ClickHouse Kafka engine
(`$API/db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:9-10`). Results are candidates,
not proof: events still in flight or consumer lag also show up. Do not change commit logic to "fix"
what you find (change-control N7, OPEN DECISION OD-2 (owner)); feed it to `event-accounting-campaign`.

## E5. Wrong values

| Symptom | Mechanism | Confirm | Owner |
|---|---|---|---|
| `value` `"1e+06"`, `"1.2345678e+07"`, `"1e-07"` | `fmt.Sprintf("%v", properties[field_name])` on float64 (`enrichment_service.go:114`) | probe: `%v` of 1000000 = `"1e+06"`; smoke tx_A `"1e-07"` | `rails-go-parity` (contract), `event-accounting-campaign` W2 |
| `value` `"<nil>"` | property missing or null | `%v` of a missing key = `"<nil>"` | same |
| sum/max/latest = 0 in ClickHouse | `decimal_value Decimal(38,26) DEFAULT toDecimal128OrZero(value, 26)` (`$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32`): `'<nil>'` -> 0, `'1000000000000'` -> 0, `'999999999999'` ok, `'1e+06'` -> 1000000 | `clickhouse local` 26.2.19.43, verified 2026-10-01 | OPEN DECISION OD-3 (owner) for schema changes |
| unique_count too high | raw string compare: `"1e+06"` != `"1000000"`; `"<nil>"` counts once | `rails-go-parity` (its contract rows P10-P12) | `rails-go-parity` |
| integer above 2^53 off by one | JSON -> float64 | `9007199254740993` -> `9007199254740992` | `event-accounting-campaign` |
| event at a subscription boundary not matched | `ToTime` float math 1 ms early; RFC3339 offset not normalized (`utils/time.go:20-29`) | `rails-go-parity` time probe | `rails-go-parity` |
| `precise_total_amount_cents` `""` in enriched/DLQ | field absent; Rails always sends a value (`"0.0"` fallback, `$API/app/services/events/kafka_producer_service.rb:46`); connectors send `"0"` for any non-number | DLQ payloads | `rails-go-parity` |

Spot the bad strings in ClickHouse (validated with `clickhouse local` on the same column types):
```sql
SELECT code,
       countIf(value = '<nil>') AS nil_values,
       countIf(value LIKE '%e+%' OR value LIKE '%e-%') AS exponent_values,
       countIf(decimal_value = 0 AND value NOT IN ('0', '0.0')) AS zeroed
FROM events_enriched
WHERE timestamp > now() - INTERVAL 1 DAY
GROUP BY code ORDER BY zeroed DESC;
```

## E6. Memory-cache mode (OPEN DECISION OD-1 (owner): production use UNKNOWN)

| Symptom | Cause | Confirm | Evidence |
|---|---|---|---|
| EVERY event DLQs as `fetch_billable_metric` `Key not found` | snapshot failed and was swallowed (`cache/cache.go:78-106`, `LoadSnapshot` returns the error unlogged at `:240-243`) | `triage-ep-log.sh`: `snapshot loads: started 6, completed 0`; `component=db` 42P01 lines at startup | VERIFIED: empty DB -> 8 of 9 events DLQ'd, committed 9/9, process kept running |
| edits (new metric, new charge) never reach the cache, nothing logged | comma-separated `LAGO_KAFKA_BOOTSTRAP_SERVERS`: CDC clients pass the raw string as ONE seed (`cache/consumer.go:28-31`) and have no logger | `env \| grep BOOTSTRAP` contains a comma; DEBUG `Cache updated from stream` never appears | VERIFIED: comma list -> CDC consumers start, 0 WARN/ERROR lines; `diagnostics-and-tooling` `cdc-brokers` measures visible=false |
| CDC never connects on a SASL/TLS cluster | CDC clients have no SASL/TLS options (`cache/consumer.go:30-35`) | `cache-cdc-fetch` lines if the error surfaces | CODE |
| pay-in-advance stops for a plan after any charge edit; recurring fallback stops after a metric edit | `extra/debezium_config.json:2` `column.include.list` lacks `charges.pay_in_advance`, `charges.accepts_target_wallet`, `billable_metrics.recurring`; CDC upserts replace the whole cached row | `python3 -c "import json;print(json.load(open('extra/debezium_config.json'))['column.include.list'])"`; `events_charged_in_advance` volume drops while `events_enriched` continues | VERIFIED (smoke cache-cdc row A: in_advance=no) |
| event at the exact ms a subscription starts: DB mode matches, cache mode does not | cache compares at full precision (`cache/subscriptions.go:56-66`), DB truncates to ms (`models/subscriptions.go:32-33`) | smoke row H | VERIFIED |
| brand-new subscription's first events enriched with `subscription_id:""` | CDC lag; not-found is not an error | timing of the subscription insert vs event | UNVERIFIED in prod |
| `LAGO_USE_MEMORY_CACHE=TRUE` (or `1`) runs DB mode | only the literal `true` enables it (`main.go:67`) | no `Starting snapshot load` lines | CODE |
| broker accumulates `lago_evp_<model>_<uuid>` groups | fresh UUID group per start (`cache/consumer.go:27`), full replay each start | `rpk group list` | VERIFIED (6 groups per start) |

## E7. Shutdown and `context canceled`

Healthy SIGTERM sequence (VERIFIED, smoke): `Received shutdown signal` -> `Gracefully shutting down consumer
group` -> `partition consumer quit` -> franz-go INFO `heartbeat errored ... "err":"context canceled"` ->
`leaving group` -> `Consumer group shutdown is complete` -> `Event processor stopped`. In cache mode also
INFO `Context canceled during fetch` per model. All benign (`run-shutdown-ctx`).

Not benign: `flag_subscription_refresh` with `"error":"context canceled"` around shutdown. That was every
rolling restart until `02a4bc8` (#785) scoped Redis writes per record; seeing it again means someone passed
the process context to a per-record side effect (change-control N5; `dlq-flag-ctx-canceled`).

## E8. Rails side of the refresh flag

| Symptom | Check | Evidence |
|---|---|---|
| wallets / alerts / lifetime usage never refresh for ClickHouse orgs | lago-api runs `ConsumeSubscriptionRefreshedQueueJob` every 10 s ONLY if both `LAGO_REDIS_STORE_URL` and `LAGO_CLICKHOUSE_ENABLED` are present on the API side (`$API/clock.rb:209-215`) | VERIFIED by reading `$API` |
| ZSET grows without bound | same gate; or API reading another Redis DB (`LAGO_REDIS_STORE_DB`, dev = 1) | `redis-cli -n <db> ZCARD subscription_refreshed_v2`; member format `<org>:<sub>\|<10 s bucket>`, score = EP wall clock (`models/stores.go:54-69`) |
