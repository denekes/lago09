---
name: architecture-contract
description: As-is architecture contract of the Go events-processor and its edges - topology (raw topic -> events_enriched / events_charged_in_advance / events_dead_letter + Redis ZSET subscription_refreshed_v2), where topic/group/key names come from, fail-fast startup panics, per-partition/per-record concurrency, the Kafka commit algorithm and per-record disposition (where records are silently lost), DB mode vs memory-cache mode (badger + Debezium CDC), load-bearing design decisions with their recorded WHY, invariants I1-I15, known weak points. Use when reading or changing events-processor consumer.go, processor.go, main_processor.go, cache/ or models SQL, or on "brokers not found", "variable is required", "No commitable record in batch", "fetch_billable_metric", "LAGO_USE_MEMORY_CACHE", "lago_evp_", "BlockRebalanceOnPoll", "consumer group". Not for Rails/ClickHouse parity (use rails-go-parity), env-var registry (use config-and-flags), fixing loss (use event-accounting-campaign), live triage (use debugging-playbook).
---
# Architecture contract: events-processor

What the Go `events-processor/` IS today: its edges, the decisions it rests on and why, the invariants that must
hold, and its weak points stated plainly. It describes; it does not prescribe fixes.
Facts verified 2026-10-01 against HEAD 5308258 unless marked. Paths are repo-relative, except Go source paths in
sections 2-10, which are relative to `events-processor/` (e.g. `config/kafka/consumer.go`). `$API` is the pinned
lago-api checkout (`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`).

## When to use / when NOT to use

Use when you need to:
- understand or explain the data flow, topic/group/key naming, or the Redis refresh signal;
- change anything in `events-processor/config/kafka/`, `processors/`, `cache/`, `models/` or `main.go`, and need the
  invariants, the commit/disposition rules and the history behind each mechanism first;
- read a startup panic, a `No commitable record in batch` warning, or a DLQ `error_code` in context;
- decide whether a change touches delivery semantics or a cross-repo contract (then go to `change-control`).

Do NOT use for (go to the sibling instead):
- what Go must mirror from Rails/ClickHouse, payload semantics, value/time divergences → `rails-go-parity`;
- billing glossary and the event lifecycle POST /events → invoice → `domain-reference`;
- the full env-var registry, defaults, boolean-parsing traps → `config-and-flags`;
- symptom → cause → fix triage, DLQ triage → `debugging-playbook`;
- the plan to fix silent loss (W1-W5) and its gates → `event-accounting-campaign`;
- incident narratives and do-not-re-fight rules → `failure-archaeology`;
- building/running probes (kfake harness, smoke binary) → `diagnostics-and-tooling`; running the stack → `run-and-operate`;
- build/test environment (`cannot find -lexpression_go`) → `build-and-env`; gates and change classes → `change-control`.

## Terms

- **raw topic**: `$LAGO_KAFKA_RAW_EVENTS_TOPIC` (dev `events-raw`), input of events-processor (EP).
- **batch**: the records of ONE partition returned by one `PollRecords(ctx, 10000)`; processed together, committed once.
- **partition consumer**: the goroutine that owns one assigned partition and processes its batches one at a time.
- **marked processed**: the record is in the slice `ProcessEvents` returns; only such records may be committed.
- **commitable prefix**: the processed records below the lowest unprocessed offset of the batch.
- **retryable / capturable**: flags on `utils.Result`; failures default to both true (`utils/result.go:113-129`).
- **DLQ**: `$LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC` (dev `events_dead_letter`), payload `FailedEvent`.
- **DB mode / memory-cache mode**: lookups via live Postgres queries vs an in-memory badger store fed by a Postgres
  snapshot + Debezium CDC (`LAGO_USE_MEMORY_CACHE=true`).
- **CDC topic**: Debezium change stream `$LAGO_DEBEZIUM_TOPIC_PREFIX.public.<table>`.
- **refresh ZSET**: Redis sorted set `subscription_refreshed_v2` that tells Rails which subscriptions to refresh.
- **http_ruby / api_post_processed**: `source` set by Rails; `source_metadata.api_post_processed=true` means Rails
  already post-processed the event (Postgres-store org).
- **kfake**: franz-go's in-process fake Kafka broker, used for probes (harness in `diagnostics-and-tooling`).

## 1. Topology (one screen)

```text
 Rails Events::KafkaProducerService (source http_ruby, NO key) ────────────┐
 Rails ReEnrichSubscriptionEventsService ──────────────────────────────────┤
 connectors/{http,sqs,kinesis}.yml (${KAFKA_TOPIC}, key <org>-<ext_sub>) ──┘
   ▼
 RAW $LAGO_KAFKA_RAW_EVENTS_TOPIC (dev events-raw) ──► also CH events_raw_queue → events_raw (not EP)
   │ group <LAGO_KAFKA_CONSUMER_GROUP>_<raw topic> (dev lago_dev_events-raw; new id ⇒ earliest offset)
   ▼
 ┌─ events-processor (Go, this repo) ────────────────────────────────┐   lookups
 │ poll ≤10 000 → 1 goroutine per partition → 1 per record           │◄── DB mode: Postgres (pool dflt 200)
 │ unmarshal → billable metric → expression → value → subscription   │◄── cache mode (OD-1): badger ← PG
 │ → produce enriched [→ in-advance] [→ ZADD] → mark → commit prefix │    snapshot + 6 CDC topics
 └─┬─────────────────────────────────────────────────────────────────┘    <prefix>.public.<table>
   ├─► ENRICHED   $LAGO_KAFKA_ENRICHED_EVENTS_TOPIC (events_enriched), key <org>-<transaction_id>
   │      └─► CH events_enriched_queue → events_enriched_mv → events_enriched (ReplacingMergeTree)
   ├─► IN-ADVANCE $LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC (events_charged_in_advance), same key
   │      └─► Karafka EventsChargedInAdvanceConsumer → Events::PayInAdvanceJob (delayed)
   ├─► DLQ        $LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC (events_dead_letter), NO key
   │      └─► CH events_dead_letter_queue → MV → events_dead_letter (plain MergeTree)
   └─► REDIS      ZSET subscription_refreshed_v2, member <org>:<subscription_id>|<10 s bucket>, score = now
          └─► Rails clock every 10 s: ConsumeSubscriptionRefreshedQueueJob (ZRANGEBYSCORE, then ZREM)
```

- EP has **no ClickHouse client and no HTTP listener**; ClickHouse reads Kafka through engines whose broker/topic/group
  are baked into DDL at migration time (`$API/db/clickhouse_migrate/*_queue.rb:8-11`).
- Every topic name comes from an env var with **no default in code** (`events-processor/processors/main_processor.go:118,123,128,171`).
  The three produced topics are required; the raw topic and group are not validated.
- Group id `<LAGO_KAFKA_CONSUMER_GROUP>_<raw topic>` (`events-processor/config/kafka/consumer.go:237`). A new id starts at
  the **earliest** offset (franz-go default) ⇒ renaming either part replays the retained raw topic.
- Keys: enriched / in-advance `<organization_id>-<transaction_id>`
  (`events-processor/processors/events_processor/event_producer_service.go:30,41`), DLQ none.
- Full tables, payload shapes and downstream evidence: [reference/topology-and-naming.md](reference/topology-and-naming.md)
  (read when you rename a topic, touch a payload, or bump the api submodule). Regenerate with `scripts/topic-map.sh`.

## 2. Startup contract (fail-fast)

Order and failure of each step (captured from the real binary with `scripts/startup-contract.sh`):

| # | Step | Failure → log `msg` / panic text |
|---|---|---|
| 0 | loader finds `libexpression_go.so` | `error while loading shared libraries: libexpression_go.so…` (exit 127, before `main`) |
| 1 | logger (`service=post_process`; DEBUG unless `ENV` set and ≠ `development`), tracer, Sentry (`main.go:31-64`) | Sentry init error only printed |
| 2 | cache mode iff `LAGO_USE_MEMORY_CACHE` == `"true"` (`main.go:67`): badger → **blocking PG snapshot** → 6 CDC consumers | PG unreachable → `Error connecting to the database` (before any Kafka check); table errors **swallowed** |
| 3 | brokers (`main_processor.go:103-107`) | `brokers not found` / `panic: brokers not found` |
| 4 | producers enriched → in-advance → DLQ: env required + `Ping` (`:55-76,118-131`) | `failed to initialize enriched events producer` / `panic: LAGO_KAFKA_ENRICHED_EVENTS_TOPIC variable is required`; unreachable: `panic: unable to dial: …`; bad `LAGO_KAFKA_SCRAM_ALGORITHM` → **SIGSEGV, no log** |
| 5 | DB mode only: pool size int, connect (`:133-150`) | `Error converting max connections into integer`; `Error connecting to the database` |
| 6 | Redis flag store + `Ping` (`:152-156`) | `Error connecting to the flag store` (bad DB int, unreachable, or `ENV=production` ⇒ TLS ⇒ `panic: EOF` on plaintext Redis) |
| 7 | consumer group + `Ping` (`:168-179`) | `Error starting the event consumer`; empty topic/group accepted (group `_`, idles) |
| 8 | `Starting event consumer` → `cg.Start` blocks | — |

`LogAndPanic` (`utils/error_tracker.go:30-34`) logs `msg`=step, `error`=err, captures to Sentry, then panics with the
**error text**. Full captured outputs, the healthy-start log (`"At":-2` = earliest), and the SIGTERM sequence:
[reference/startup-and-shutdown.md](reference/startup-and-shutdown.md) (read when a pod does not start or stop cleanly).

## 3. Concurrency model

- 1 poll goroutine: `PollRecords(ctx, 10000)` (`config/kafka/consumer.go:168`); per partition, the batch is sent on an
  **unbuffered** channel (`:122,195`) — the loop blocks until that partition consumer is idle ⇒ head-of-line blocking.
- 1 goroutine per assigned partition (`:111-130`), one batch in flight; `kgo.BlockRebalanceOnPoll()` (`:245`) +
  `AllowRebalance()` after dispatch (`:203`): rebalances happen between polls; revoke/lost (`:132-150`) waits for the
  in-flight batch to finish and commit.
- 1 goroutine **per record**, unbounded `errgroup` (`processors/events_processor/processor.go:38-44`); per event up to
  2 more for `ProduceSync` to enriched / in-advance (`:110-126`), joined before the record is marked.
- Batch context = `context.Background()` (`consumer.go:83`), threaded unchanged to every record (there is no
  per-record derived ctx): SIGTERM never cancels in-flight work, and there is **no context deadline** on the hot
  path (no gorm `WithContext`, unbounded produce retries). Only Redis calls are bounded, by go-redis client timeouts
  (dial 5 s, read/write 3 s, pool wait 4 s; `config/redis/redis.go:35-39`).
- Shutdown: cancel → poll exits → close each `quit`, wait `done` → `client.Close()` (leave group) → deferred closes.
- Details, goroutine tree, franz-go defaults: [reference/concurrency-and-commit.md](reference/concurrency-and-commit.md)
  (read before touching `config/kafka/` or the per-record fan-out).

## 4. Commit algorithm, disposition, and where records are lost

Commit (`config/kafka/consumer.go:82-109`): all marked ⇒ `CommitRecords(batch)`; else commit the commitable prefix
(`findMaxCommitableRecord`, `:278-308`); empty prefix ⇒ `WARN No commitable record in batch, skipping commit` and
no commit (`9acd83e`). Commit errors are logged + captured, not retried. **The fetch position is never rewound.**

| Record outcome | Decided at | Marked (committable)? | DLQ? | Sentry? |
|---|---|---|---|---|
| unmarshal error (bad JSON, numeric `precise_total_amount_cents`, unparsable `ingested_at`) | `processor.go:49-60` | yes | **no** | yes |
| success | `processor.go:85-88` | yes | no | no |
| non-retryable failure | `processor.go:63-88` | yes, after DLQ | yes | unless not-found |
| retryable failure, `ingested_at` < 12 h old | `processor.go:74-79` | **no** | no | yes |
| retryable failure, ≥ 12 h old or no `ingested_at` | `processor.go:74,82` | yes | yes | yes |
| enriched / in-advance produce fails | `event_producer_service.go:87-89` (result ignored at `processor.go:110-113`) | yes | yes (`error_code ""`) | yes |
| DLQ produce fails | `event_producer_service.go:66-73` | yes | — | yes (only copy) |
| non-context fetch error | `consumer.go:175-183` | — | — | no: process panics |

Where records are lost, plainly (fix plan: `event-accounting-campaign`; OPEN DECISION OD-2):
- **L1** a retryable failure (DB/Redis error, pool timeout, SQLSTATE 0A000) is skipped forever as soon as any later
  batch on that partition commits. VERIFIED 2026-10-01 with a scratch kfake probe on the real `kafka.NewConsumerGroup`
  (offsets 0-4, offset 2 not marked once, then 5 and 6 produced): `times each offset seen: map[0:1 1:1 2:1 3:1 4:1
  5:1 6:1]`, `committed offset … 7`. Reproduce with the `diagnostics-and-tooling` kfake harness (its wrap hook drops
  a record = the retryable path); setup and output in [reference/concurrency-and-commit.md](reference/concurrency-and-commit.md) §4.
- **L2** undecodable records are committed with no DLQ copy (verified: numeric `precise_total_amount_cents` →
  `json: cannot unmarshal number into Go struct field Event.precise_total_amount_cents of type string`).
- **L3/L4** a failed enriched/in-advance produce leaves only a DLQ copy; a failed DLQ produce leaves only Sentry.
- **L5** enriched is produced before the in-advance check and ZADD; their retryable failure falls under L1.
- **L6/L7** not lost but silently changed: `value` via `%v` (`1e+06`, `<nil>`), `ToTime` 496/1000 ms off by 1 ms
  (both verified 2026-10-01) → owned by `rails-go-parity`.
Full table with evidence: [reference/concurrency-and-commit.md](reference/concurrency-and-commit.md) §3-4.

## 5. DB mode vs memory-cache mode (OPEN DECISION OD-1)

OPEN DECISION OD-1 (owner): whether production runs `LAGO_USE_MEMORY_CACHE=true`, and with which Debezium column
list / SASL / TLS / brokers, is unknown. DB mode is the default path (dev runs it); cache findings are code-level
defects with UNVERIFIED production impact.

| | DB mode | Memory-cache mode |
|---|---|---|
| Per event | 1 BM query (gorm `First`), 1-2 subscription queries (Rails-copied SQL, ms `date_trunc`), 1 charges query if a subscription was found and not API-post-processed | badger lookups: `bm:<org>:<code>`, prefix scans `sub:<org>:<ext_id>:`, `ch:<org>:<plan>:<bm>:` |
| Warm-up | none | blocking PG snapshot of 6 tables (pool 10); **table errors swallowed** |
| Freshness | live | 6 CDC consumers, new `lago_evp_<model>_<uuid>` group per start (full replay), apply only if `updated_at` strictly newer |
| TTL | — | terminated subscriptions rewritten with 30-day TTL; snapshot keeps terminations < 1 month |
| Known traps | `SELECT *` on billable_metrics (I2) | Debezium list lacks `charges.pay_in_advance`, `billable_metrics.recurring` ⇒ a CDC update zeroes them; raw broker string, no SASL/TLS; `:` in external_id leaks (verified); µs vs ms boundary (verified); 3 filter tables loaded but unread |

Keys, CDC apply rules, column contract, failure table: [reference/memory-cache.md](reference/memory-cache.md)
(read before touching `cache/`, `models/*GetAll*` or `extra/debezium_config.json`).

## 6. Load-bearing design decisions and WHY

| # | Decision | Recorded why (or "not recorded") |
|---|---|---|
| D2 | fail-fast panics via `LogAndPanic` | `e58befb` "Capture startup errors and replace os.Exit with panic" (panic lets the deferred Sentry flush run — inference) |
| D3 | goroutine per partition + `BlockRebalanceOnPoll` + manual sync commit | **not recorded** (`4100da0`); matches franz-go's "manual commit" per-partition example (INFERENCE) |
| D4 | goroutine per record, unbounded | **not recorded** (`4100da0`, `a15bd3b`) |
| D5 | retryable ⇒ no commit; 12 h ⇒ DLQ | `cec0eb2` says what, not why; 12 h **not recorded** (OD-2) |
| D6 | commit longest prefix; skip if empty | `9acd83e`: nil record segfaulted franz-go (ING-15) |
| D7 | undecodable ⇒ commit, no DLQ | comment `processor.go:56` "it will failed forever"; no-DLQ **not recorded** |
| D8 | batch on `context.Background()`, stores take ctx | `02a4bc8`: in-flight Redis writes failed with `context canceled` on every rolling restart |
| D12 | expressions only for non-`http_ruby` | `d1c1629`: Rails already evaluated them |
| D13 | ZSET member with 10 s bucket, score = now | comment `models/stores.go:44-49`: no starvation; `42615c9`, `fb6401d` |
| D15 | explicit column lists | `9acd83e`: `SELECT *` + DDL ⇒ SQLSTATE 0A000 on every cached plan |
| D16 | badger + Debezium cache mode | **not recorded** (`fff5858`) |
| D17 | no per-event charge/filter resolution | `d9c32b6`: `flat_filters` was the main DB load; its only consumer's flag "is off everywhere" |

All 21 decisions with cost and evidence: [reference/design-decisions.md](reference/design-decisions.md) (read before
changing any mechanism; D3-D8 are change class C4 → change-control N7).

## 7. Invariants (status as of 2026-10-01; details, breakage and guards in [reference/invariants.md](reference/invariants.md))

| ID | Invariant | Enforced at (`events-processor/…`) | Guard test | Status |
|---|---|---|---|---|
| I1 | per-event reads filter `organization_id` | `models/billable_metrics.go:63`, `models/subscriptions.go:30`, `models/charges.go:54` | SQL pins (BM, subscriptions); charges none | HOLDS |
| I2 | explicit columns, no implicit `SELECT *` | `models/subscriptions.go:24,37`, `models/charges.go:52` | subscriptions pin | **VIOLATED** `models/billable_metrics.go:61` |
| I3 | `deleted_at IS NULL` on soft-deletable tables | `models/billable_metrics.go:63`, `models/charges.go:54`, snapshots | BM pin only | HOLDS |
| I4 | subscription SQL mirrors Rails `Events::Common#subscription` | `models/subscriptions.go:29-40` | subscriptions pin | HOLDS (DB) / PARTIAL (cache) |
| I5 | exactly one side post-processes (`NotAPIPostProcessed`) | `processors/events_processor/processor.go:115`, `models/event.go:86-92` | `TestNotAPIPostProcessed`, `processor_test.go:204` | HOLDS |
| I6 | expressions only for non-`http_ruby` | `processors/events_processor/enrichment_service.go:104` | none | HOLDS |
| I7 | side effects use batch/record ctx, never process ctx | `config/kafka/consumer.go:83`, `models/stores.go:50-54` | none | HOLDS |
| I8 | commit only a processed prefix, never nil | `config/kafka/consumer.go:92-104,278-308` | `TestFindMaxCommitableRecord` | HOLDS within a batch (not across: L1) |
| I9 | retryable > 12 h old (or no `ingested_at`) ⇒ DLQ | `processor.go:74` | none | HOLDS (OD-2) |
| I10 | refresh ZSET contract `subscription_refreshed_v2` / `<org>:<sub>\|<10s>` | `main_processor.go:152`, `models/stores.go:16,54-69` | `TestFlag` | HOLDS (change-control N6) |
| I11 | key `<org>-<transaction_id>`; DLQ unkeyed | `event_producer_service.go:30,41` | `event_producer_service_test.go:45-52` | HOLDS |
| I12 | duplicates safe only via downstream dedup on `transaction_id` | `$API` ReplacingMergeTree + `PayInAdvanceJob` unique | none here | HOLDS (external) |
| I13 | CDC apply monotonic per key; delete only on same id | `cache/consumer.go:107-156` | `cache/consumer_test.go` | HOLDS |
| I14 | fail-fast on missing config | `utils/error_tracker.go:30-34`, `main_processor.go:103-179` | `startup-contract.sh` only | PARTIAL |
| I15 | missing BM ⇒ DLQ; missing subscription ⇒ still enriched | `models/billable_metrics.go:75-83`, `enrichment_service.go:61-67` | enrichment/processor tests | HOLDS |

Static re-check: `.claude/skills/architecture-contract/scripts/invariants-grep.sh` (expected today: 1 FLAG = I2).

## 8. Known weak points (top of the register)

| Sev | Weak point | Owner skill |
|---|---|---|
| HIGH | L1: retryable failures silently skipped (no seek, prefix commit) | event-accounting-campaign (OD-2) |
| HIGH | L2-L4: undecodable ⇒ dropped; produce failure ⇒ DLQ+commit; DLQ failure ⇒ Sentry only | event-accounting-campaign |
| HIGH | `value` via `%v` ⇒ exponent strings / `<nil>` reach ClickHouse | rails-go-parity, campaign (OD-3) |
| HIGH (OD-1) | cache: Debezium list zeroes `pay_in_advance` / `recurring`; snapshot errors swallowed; `:` prefix leak | no owning skill for cache hardening (raise with the owner, OD-1); parity cases: rails-go-parity |
| MEDIUM | `SELECT *` in `FetchBillableMetric` (and its test pins it) | change-control N4 |
| MEDIUM | unbounded goroutines vs DB pool 200 / Redis pool 10; no deadlines; head-of-line blocking; fetch error ⇒ panic | event-accounting-campaign, debugging-playbook |
| MEDIUM | startup validation gaps (empty topic/group/prefix, `=1` ≠ cache mode, SCRAM SIGSEGV) | config-and-flags, debugging-playbook |
| LOW | no metrics/health/lag, spans not nested, PII in Sentry/DLQ, Redis `InsecureSkipVerify`, dead code | run-and-operate, security-and-supply-chain |

All 26 entries with evidence and status: [reference/weak-points.md](reference/weak-points.md) (read when triaging
risk or picking the next hardening item; it also lists the 0%-coverage delivery-path functions).

## 9. Error taxonomy and DLQ codes (short; triage lives in `debugging-playbook`)

| `error_code` | `error_message` | Cause | Retryable |
|---|---|---|---|
| `build_enriched_event` | Error while converting event to enriched event | unparsable/unsupported `timestamp` (`models/event.go:70-81`) | no |
| `fetch_billable_metric` | Error fetching billable metric | not found (`record not found` / `Key not found`): no, not captured; DB/badger error: yes | mixed |
| `evaluate_expression` | Error evaluating custom expression | lago-expression returned nil; message embeds the event JSON (`enrichment_service.go:121-142`) | no |
| `fetch_subscription` | Error fetching subscription | DB/badger error other than not-found (`enrichment_service.go:61-64`) | yes |
| `fetch_pay_in_advance_charge` | Error fetching pay in advance charge | DB/badger error (`processor.go:116-119`) | yes |
| `flag_subscription_refresh` | Error flagging subscription refresh | Redis error / pool timeout (`processor.go:128-131`) | yes |
| `""` | `""` | produce to enriched/in-advance failed; `initial_error_message` = `failed to push to <topic> topic` | n/a |

DLQ record = `{event, initial_error_message, error_message, error_code, failed_at}` (`models/event.go:50-56`), no key.

## 10. Observability as-is

- **Logs**: JSON (`log/slog`) to stdout, base attr `service=post_process`; per-event failure line `msg=<error_message>`
  with `error_code`, `error`. Component attrs: `component=kafka` / `kafka-producer` (forced ≥ INFO),
  `kafka-topic-consumer=<topic>`, `component=db` (slog-gorm SQL errors with `query`), `pkg=cache` + `model`.
  go-redis prints plain-text `redis: … pool.go:…` lines. DEBUG is the default when `ENV` is unset.
- **Sentry** (`SENTRY_DSN`, environment = `ENV`): startup panics raised via `LogAndPanic`, capturable per-event
  failures **with the full event as extra** (`processor.go:70-72`), unmarshal/produce/DLQ/commit/CDC errors. Not
  captured: `brokers not found` (plain `slog.Error` + `panic`, `main_processor.go:105-106`), SCRAM SIGSEGV,
  fetch-error panic, snapshot SQL errors.
- **Tracing**: provider `TRACING_PROVIDER` → `DD_TRACE_ENABLED` → `OTEL_EXPORTER_OTLP_ENDPOINT` → none; spans
  `Consumer.Consume`, `PostProcess.ProcessEvents`, `PostProcess.ProcessOneEvent`, `Producer.Produce`, **never nested**
  (`Span.GetContext()` is unused); Kafka client hooks only with `KAFKA_TRACING_ENABLED=true` (`config/kafka/kafka.go:40-46`).
- **Metrics / health**: none. No HTTP listener, no DLQ/skip/lag counters; OTel meter only carries kotel Kafka hooks.
  Consumer lag must be read from the broker for group `<group>_<raw topic>`.

## If you are about to change X

| You touch | Class / rule | Read first | Prove with |
|---|---|---|---|
| `config/kafka/consumer.go`, disposition in `processor.go`, producers | C4, change-control N7, OD-2 | §4, D3-D8, `failure-archaeology` | kfake test driving `processRecordsAndCommit` (`diagnostics-and-tooling`) |
| SQL in `models/*.go` | C3, change-control N4 | I1-I3 | exact sqlmock pin + `invariants-grep.sh` |
| topic names, keys, payload, Redis key/bucket | C4, change-control N6, OD-4 paired lago-api PR | §1, I10-I12 | `topic-map.sh`, `rails-go-parity` |
| `cache/`, `extra/debezium_config.json` | C3/C4, OD-1 | §5, `memory-cache.md` | parity harness in `rails-go-parity` |
| startup / new env var | C3 (+C6 for compose) | §2, `config-and-flags` checklist | `startup-contract.sh` (update expected steps) |
| value / time formatting | C3, OD-3 | `rails-go-parity` | its value/time probes |

## Scripts

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/topic-map.sh` | every topic/env var/group/key/Redis key with EP file:line, dev value, created-in-dev, lago-api readers; FLAGs drift | `.claude/skills/architecture-contract/scripts/topic-map.sh` (`--no-api` offline, `--strict` exit 1 on FLAG) | 4 EP topics all `yes`; group `lago_dev_events-raw`; CDC prefix `lago_proc_cdc`; `FLAG LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC …`, `FLAG … "unprocessed_events" …`; `SUMMARY flags=2` (`--no-api`: `flags=0`) |
| `scripts/startup-contract.sh` | builds the binary (temp dir, ~5 s warm) and runs it with env added step by step; PASS/FAIL per documented panic | `.claude/skills/architecture-contract/scripts/startup-contract.sh` (opt. `--bin`, `--broker`, `--redis`, `--pg`, `--out`) | S0-S7 `PASS` (S6 SKIP without Postgres; S0 SKIP if `libexpression_go.so` is installed system-wide), `SUMMARY steps=9 fails=0`, exit 0 (1 = some FAIL, 2 = setup error); with a disposable broker + Redis (e.g. kfake + miniredis) and Postgres: `steps=17 fails=0` |
| `scripts/invariants-grep.sh` | static checks of change-control N4/N5/N7 rules + Go-side contract snapshot | `.claude/skills/architecture-contract/scripts/invariants-grep.sh --quiet` | `FLAG N4-cols events-processor/models/billable_metrics.go:61 FetchBillableMetric …`, `WARN N4-pin … HasPayInAdvanceCharge …`, `SUMMARY flags=1 warns=1`, exit 1 |

All three are read-only on the repo (temp dirs only) and need no Docker; exit codes are documented in each header.

## Provenance and maintenance

- Sources: all non-test Go under `events-processor/` (main.go, processors/, config/{kafka,redis,database,tracing},
  cache/, models/, utils/) read in full; `extra/debezium_config.json`; `.env.development.default:77-90`;
  `docker-compose.dev.yml:318-406`; `$API` karafka.rb, clock.rb, `db/clickhouse_migrate/*`, consumers/jobs cited above;
  franz-go v1.20.5 sources and `examples/goroutine_per_partition_consuming/README.md`; commits `4100da0`, `e58befb`,
  `cec0eb2`, `9acd83e`, `02a4bc8`, `42615c9`, `fb6401d`, `731e18f`, `fff5858`, `d9c32b6`, `2fd8e8b`, `b4ad153`, `d1c1629`.
- Volatile facts and one-line re-verification (run from repo root):
  - code under study unchanged: `git log -1 --format=%h -- events-processor extra/debezium_config.json .env.development.default docker-compose.dev.yml` → `5308258` (as of 2026-10-01; anything newer means re-verify this skill)
  - group id format: `grep -n 'cgName := fmt.Sprintf' events-processor/config/kafka/consumer.go` → `237: … "%s_%s"`
  - poll size / rebalance mode: `grep -n 'PollRecords(ctx, 10000)\|BlockRebalanceOnPoll' events-processor/config/kafka/consumer.go` → 168, 245
  - retry horizon: `grep -n '12\*time.Hour' events-processor/processors/events_processor/processor.go` → 74
  - Redis key: `grep -n 'subscription_refreshed_v2' events-processor/processors/main_processor.go` → 152
  - I2 still violated: `.claude/skills/architecture-contract/scripts/invariants-grep.sh --quiet | tail -1` → `SUMMARY flags=1 warns=1`
  - startup contract: `.claude/skills/architecture-contract/scripts/startup-contract.sh | tail -1` → `SUMMARY steps=9 fails=0 …`
  - Debezium gap: `grep -o 'public.charges.([^)]*)' extra/debezium_config.json` → no `pay_in_advance`
  - franz-go pin: `grep -n 'twmb/franz-go v' events-processor/go.mod` → `v1.20.5`
  - coverage of the delivery path (after `source .claude/skills/build-and-env/scripts/ep-env.sh`, in `events-processor/`):
    `go test -count=1 -coverpkg=./... -coverprofile="${TMPDIR:-/tmp}/ac-cov.out" ./cache/... ./config/database/... ./config/kafka/... ./models/... ./processors/events_processor/... ./utils/... && go tool cover -func="${TMPDIR:-/tmp}/ac-cov.out" | grep -E 'ProcessEvents|processRecordsAndCommit|^total'`
    → both 0.0%, total 44.9% (as of 2026-10-01; needs Postgres; baselines in `validation-and-qa`)
- Update triggers: any commit under `events-processor/config/kafka/`, `processors/`, `cache/`, `models/`, `main.go`;
  a franz-go bump (defaults cited here); changes to `extra/debezium_config.json` or the Kafka/Redis vars in
  `.env.development.default`; an `api` submodule bump (downstream readers); owner answers to OD-1, OD-2, OD-3, OD-4.
