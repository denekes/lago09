---
name: architecture-contract
description: "As-is architecture contract of the Go events-processor: topology (raw topic -> enriched, in-advance and dead-letter topics + Redis ZSET), name sources, startup order (only partly fail-fast), concurrency, the Kafka commit algorithm and per-record disposition, DB vs memory-cache mode, design decisions, invariants I1-I15, weak points. Use when reading or changing consumer.go, processor.go, main_processor.go, cache/ or models SQL, or for \"how does the events-processor work\", \"what happens to a record when\". Not for live triage (use debugging-playbook) or fixes (use event-accounting-campaign)."
---
# Architecture contract: events-processor

What the Go `events-processor/` IS today: its edges, the decisions it rests on and why, the invariants that must
hold, and its weak points stated plainly. It describes; it does not prescribe fixes.
Code facts as of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only commits on
top. Verified 2026-10-01 unless marked; owner decisions OD-1..OD-5 of 2026-10-02 folded in (register:
`change-control` §9). Paths are repo-relative, except Go source paths in
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
- the plan to fix silent loss and memory-cache defects (W1-W6, ADR-001) and its gates → `event-accounting-campaign`;
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
  snapshot + Debezium CDC (`LAGO_USE_MEMORY_CACHE=true`). Dev runs DB mode; PRODUCTION runs memory-cache mode
  (DECIDED OD-1 (owner, 2026-10-02)).
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
 │ unmarshal → billable metric → expression → value → subscription   │◄── cache mode (PROD): badger ← PG
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

## 2. Startup contract (partially fail-fast: see I14)

This section owns the startup order and panic contract (symptom → fix: `debugging-playbook`). Order and failure of
each step. `#` is the step number of
[reference/startup-and-shutdown.md](reference/startup-and-shutdown.md) §1 (rows 5a-5c and 10 are folded here);
`Probe` is the step id printed by `scripts/startup-contract.sh`, which captures each failure from the real binary.

| # | Step | Failure → log `msg` / panic text | Probe |
|---|---|---|---|
| 0 | loader finds `libexpression_go.so` (the image copies it to `/usr/lib`, `events-processor/Dockerfile:14,22`) | `error while loading shared libraries: libexpression_go.so…` (exit 127, before `main`) | S0 |
| 1-4 | signal handler, logger (`service=post_process`; DEBUG unless `ENV` set and ≠ `development`), tracer, Sentry (`main.go:28-64,90-99`) | Sentry init error only printed | — |
| 5 | cache mode iff `LAGO_USE_MEMORY_CACHE` == `"true"` (`main.go:67`): badger → **blocking PG snapshot** → 6 CDC consumers | PG unreachable → `Error connecting to the database` (before any Kafka check); table errors **swallowed**; `=1` is DB mode | S5, S6, S7 |
| 6 | brokers (`main_processor.go:103-107`) | `brokers not found` / `panic: brokers not found` (no Sentry event) | S1 |
| 7 | producers enriched → in-advance → DLQ: env required + `Ping` (`main_processor.go:55-76,118-131`) | `failed to initialize enriched events producer` / `panic: LAGO_KAFKA_ENRICHED_EVENTS_TOPIC variable is required`; unreachable: `panic: unable to dial: …`; bad `LAGO_KAFKA_SCRAM_ALGORITHM` → **SIGSEGV, no log** | S2, S3, S4, SK1, SK2 |
| 8 | DB mode only: pool size int, connect (`main_processor.go:133-150`) | `Error converting max connections into integer`; `Error connecting to the database` | SK3, SK4 |
| 9 | Redis flag store + `Ping` (`main_processor.go:152-156`) | `Error connecting to the flag store` (bad DB int, unreachable, or `ENV=production` ⇒ TLS ⇒ `panic: EOF` on plaintext Redis) | SK5, SK6, SK7 |
| 11 | consumer group + `Ping` (`main_processor.go:168-179`) | `Error starting the event consumer`; empty topic/group accepted (group `_`, idles); missing topic not fatal (INFO `UNKNOWN_TOPIC_OR_PARTITION`, waits) | SK9, SK8 |
| 12 | `Starting event consumer` → `cg.Start` blocks (`main_processor.go:181-182`) | — (SIGTERM → graceful shutdown) | SK8 |

`LogAndPanic` (`utils/error_tracker.go:30-34`) logs `msg`=step, `error`=err, captures to Sentry, then panics with the
**error text**. Full captured outputs, the healthy-start log (`"At":-2` = earliest), and the SIGTERM sequence:
[reference/startup-and-shutdown.md](reference/startup-and-shutdown.md) (read when a pod does not start or stop cleanly).

## 3. Concurrency model

- 1 poll goroutine: `PollRecords(ctx, 10000)` (`config/kafka/consumer.go:168`); per partition, the batch is sent on an
  **unbuffered** channel (`:122,195`) — the loop blocks until that partition consumer is idle ⇒ head-of-line blocking.
- 1 goroutine per assigned partition (`consumer.go:111-130`), one batch in flight; `kgo.BlockRebalanceOnPoll()`
  (`consumer.go:245`) + `AllowRebalance()` after dispatch (`consumer.go:203`): rebalances happen between polls;
  revoke/lost (`consumer.go:132-150`) waits for the in-flight batch to finish and commit.
- 1 goroutine **per record**, unbounded `errgroup` (`processors/events_processor/processor.go:38-44`); per event up to
  2 more for `ProduceSync` to enriched / in-advance (`:110-126`), joined before the record is marked.
- Batch context = `context.Background()` (`consumer.go:83`), threaded unchanged to every record (one ctx for
  the whole batch): SIGTERM never cancels in-flight work, and there is **no context deadline** on the hot
  path (no gorm `WithContext`, unbounded produce retries). Only Redis calls are bounded, by go-redis client timeouts
  (dial 5 s, read/write 3 s, pool wait 4 s; `config/redis/redis.go:35-39`).
- Shutdown: cancel (`main.go:94-98`) → poll exits → close each `quit`, wait `done` → `client.Close()` (leave group)
  (`consumer.go:207-225,261-272`) → deferred closes.
- Details, goroutine tree, franz-go consumer defaults; producer defaults (acks, linger, retries) in §5: [reference/concurrency-and-commit.md](reference/concurrency-and-commit.md)
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
| enriched / in-advance produce fails (the other output and the ZADD still happen) | `event_producer_service.go:87-89` (result ignored at `processor.go:110-126`) | yes | yes (`error_code ""`) | yes |
| DLQ produce fails | `event_producer_service.go:66-73` | yes | — | yes (only copy) |
| non-context fetch error | `consumer.go:175-183` | — | — | no: process panics |

Where records are lost, plainly (target contract: ADR-001, DECIDED OD-2 (owner, 2026-10-02), in
`event-accounting-campaign` `reference/delivery-options.md`; fix plan: `event-accounting-campaign`):
- **L1** a retryable failure (DB/Redis error, pool timeout, SQLSTATE 0A000) is skipped forever as soon as any later
  batch on that partition commits. VERIFIED 2026-10-01 with a scratch kfake probe on the real `kafka.NewConsumerGroup`
  (offsets 0-4, offset 2 not marked once, then 5 and 6 produced): `times each offset seen: map[0:1 1:1 2:1 3:1 4:1
  5:1 6:1]`, `committed offset … 7`. Reproduce with the `diagnostics-and-tooling` kfake harness (its wrap hook drops
  a record = the retryable path); setup and output in [reference/concurrency-and-commit.md](reference/concurrency-and-commit.md) §4.
- **L2** undecodable records are committed with no DLQ copy (`processor.go:49-60`; verified: numeric
  `precise_total_amount_cents` → `json: cannot unmarshal number into Go struct field Event.precise_total_amount_cents of type string`).
- **L3/L4** a failed enriched produce leaves a DLQ copy (`error_code ""`) while the in-advance event (if any) is
  still produced, the refresh ZADD still runs and the record is committed (ledger case 6 in `event-accounting-campaign`);
  a failed in-advance produce leaves enriched + a DLQ copy; a failed DLQ produce leaves only Sentry
  (`event_producer_service.go:66-73,87-89`; the goroutines at `processor.go:110-126` ignore the result).
- **L5** enriched is produced before the in-advance check and ZADD (`processor.go:110-131`); their retryable
  failure falls under L1.
- **L6/L7** not lost but silently changed: `value` via `%v` (`1e+06`, `<nil>`), `ToTime` 496/1000 ms off by 1 ms
  (both verified 2026-10-01) → owned by `rails-go-parity`.
Full table with evidence: [reference/concurrency-and-commit.md](reference/concurrency-and-commit.md) §3-4.

## 5. DB mode vs memory-cache mode (production = memory-cache: DECIDED OD-1)

DECIDED OD-1 (owner, 2026-10-02): dev runs DB mode (`.env.development.default` and every compose file in
this repo set neither `LAGO_USE_MEMORY_CACHE` nor `LAGO_DEBEZIUM_TOPIC_PREFIX`); PRODUCTION runs memory-cache
mode. Every cache finding here and WP6-WP10 is production-relevant, and C3/C4 proof must cover cache mode,
not only DB mode (`diagnostics-and-tooling` `smoke-binary.sh cache` and `cache-cdc`). Hardening owner:
`event-accounting-campaign` W6 (DEFAULT APPLIED OD-20; the owner may reassign it).

**Verify first: OPEN DECISION OD-1b (owner).** Is the production Debezium `column.include.list` the one in
`extra/debezium_config.json:2`, and which Kafka auth (SASL/TLS) and bootstrap broker list do the CDC consumers
get? If production uses the repo's column list, every CDC update of a charge or billable metric rewrites the
cached row without `pay_in_advance` / `recurring` (`cache/consumer.go:93,158`): in-advance events and the
recurring fallback silently stop for each edited charge or metric. Code-level VERIFIED; binary smoke
`smoke-binary.sh cache-cdc` prints `tx_A ... in_advance=no` (re-run 2026-10-02, hand-shaped CDC row);
production impact UNVERIFIED. A restart hides it until the next edit: the snapshot reads the full rows
(`models/charges.go:29`, `models/billable_metrics.go:93`) and replayed older CDC rows are skipped
(`cache/consumer.go:143-156`; INFERRED, guard test `TestProcessRecord_SkipUpdate_OlderTimestamp`).

| | DB mode (dev) | Memory-cache mode (production) |
|---|---|---|
| Per event | 1 BM query (gorm `First`), 1-2 subscription queries (Rails-copied SQL, ms `date_trunc`), 1 charges query if a subscription was found and not API-post-processed (`models/billable_metrics.go:59-73`, `models/subscriptions.go:24-52`, `models/charges.go:47-66`) | badger lookups: `bm:<org>:<code>`, prefix scans `sub:<org>:<ext_id>:`, `ch:<org>:<plan>:<bm>:` (`cache/subscriptions.go:46`, `cache/charges.go:87-102`) |
| Warm-up | none | blocking PG snapshot of 6 tables (pool 10); **table errors swallowed** (`cache/cache.go:63-107`) |
| Freshness | live | 6 CDC consumers, new `lago_evp_<model>_<uuid>` group per start (full replay), apply only if `updated_at` strictly newer (`cache/consumer.go:26-35,143-156`) |
| TTL | — | terminated subscriptions rewritten with 30-day TTL (`cache/subscriptions.go:119-128`); snapshot keeps terminations < 1 month (`models/subscriptions.go:56-77`) |
| Known traps | `SELECT *` on billable_metrics (I2, `models/billable_metrics.go:61`) | (all production-relevant) Debezium list lacks `charges.pay_in_advance`, `charges.accepts_target_wallet`, `billable_metrics.recurring` (`extra/debezium_config.json:2`) ⇒ a CDC update zeroes them; raw broker string, no SASL/TLS; swallowed snapshot errors; new CDC groups per start; `:` in external_id leaks (verified); µs vs ms boundary (verified); ~0.8 GB RSS per 1M subscriptions (synthetic, `memory-cache.md` §5); 3 filter tables loaded but unread |

Keys, CDC apply rules, column contract, failure table: [reference/memory-cache.md](reference/memory-cache.md)
(read before touching `cache/`, `models/*GetAll*` or `extra/debezium_config.json`). Production operations
(snapshot check, CDC lag, orphan groups, sizing): `run-and-operate` `reference/memory-cache-ops.md`.

## 6. Load-bearing design decisions and WHY

| # | Decision | Recorded why (or "not recorded") |
|---|---|---|
| D2 | startup panics via `LogAndPanic` (only partially fail-fast: I14) | `e58befb` "Capture startup errors and replace os.Exit with panic" (panic lets the deferred Sentry flush run — inference) |
| D3 | goroutine per partition + `BlockRebalanceOnPoll` + manual sync commit | **not recorded** (`4100da0`); matches franz-go's "manual commit" per-partition example (INFERENCE) |
| D4 | goroutine per record, unbounded | **not recorded** (`4100da0`, `a15bd3b`) |
| D5 | retryable ⇒ no commit; 12 h ⇒ DLQ | `cec0eb2` says what, not why; 12 h **not recorded**. Target: ADR-001 (DECIDED OD-2) replaces the mechanism and keeps 12 h as the default retry max age |
| D6 | commit longest prefix; skip if empty | `9acd83e`: nil record segfaulted franz-go (ING-15); chain `cec0eb2` → … → `9acd83e` in `failure-archaeology` chain A |
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
| I4 | subscription SQL mirrors Rails `Events::Common#subscription` | `models/subscriptions.go:29-40` | subscriptions pin | HOLDS (DB, dev) / PARTIAL (cache = production, WP9) |
| I5 | exactly one side post-processes (`NotAPIPostProcessed`) | `processors/events_processor/processor.go:115`, `models/event.go:86-92` | `TestNotAPIPostProcessed`, `processor_test.go:204` | HOLDS |
| I6 | expressions only for non-`http_ruby` | `processors/events_processor/enrichment_service.go:104` | none | HOLDS |
| I7 | side effects use the batch ctx (`context.Background()`), never the process/signal ctx | `config/kafka/consumer.go:83`, `models/stores.go:50-54` | none | HOLDS |
| I8 | commit only a processed prefix, never nil | `config/kafka/consumer.go:92-104,278-308` | `TestFindMaxCommitableRecord` | HOLDS within a batch (not across: L1) |
| I9 | retryable > 12 h old (or no `ingested_at`) ⇒ DLQ | `processor.go:74` | none | HOLDS (12 h stays ADR-001's default max age, DECIDED OD-2) |
| I10 | refresh ZSET contract `subscription_refreshed_v2` / `<org>:<sub>\|<10s>` | `main_processor.go:152`, `models/stores.go:16,54-69` | `TestFlag` | HOLDS (change-control N6) |
| I11 | key `<org>-<transaction_id>`; DLQ unkeyed | `event_producer_service.go:30,41` | `event_producer_service_test.go:45-52` | HOLDS |
| I12 | duplicates safe only via downstream dedup on `transaction_id` | `$API/app/services/billable_metrics/aggregations/base_service.rb:161-169` (`FINAL` only if the org has `clickhouse_deduplication_enabled`, default false); `PayInAdvanceService#already_processed?` | none here | **CONDITIONAL** (external) |
| I13 | CDC apply monotonic per key; delete only on same id | `cache/consumer.go:107-156` | `cache/consumer_test.go` | HOLDS |
| I14 | startup fails fast on missing config (partially: empty topic/group/prefix, swallowed snapshot errors, SCRAM SIGSEGV) | `utils/error_tracker.go:30-34`, `main_processor.go:103-179` | `startup-contract.sh` only | PARTIAL |
| I15 | missing BM ⇒ DLQ; missing subscription ⇒ still enriched | `models/billable_metrics.go:75-83`, `enrichment_service.go:61-67` | enrichment/processor tests | HOLDS |

Static re-check: `.claude/skills/architecture-contract/scripts/invariants-grep.sh` (expected today: 1 FLAG = I2).

## 8. Known weak points (top of the register)

| Sev | Weak point | Owner skill |
|---|---|---|
| HIGH | L1: retryable failures silently skipped (no seek, prefix commit; `processor.go:74-79`, `consumer.go:92-104`) | event-accounting-campaign W1, target ADR-001 (DECIDED OD-2) |
| HIGH | L2-L4: undecodable ⇒ dropped; produce failure ⇒ DLQ (+ in-advance still emitted) + commit; DLQ failure ⇒ Sentry only (`processor.go:49-60`, `event_producer_service.go:66-73,87-89`) | event-accounting-campaign |
| HIGH | `value` via `%v` ⇒ exponent strings / `<nil>` reach ClickHouse | rails-go-parity, campaign W2 (a ClickHouse schema change is allowed: DECIDED OD-3) |
| CRITICAL (PROD) | cache, which production runs (DECIDED OD-1): Debezium list zeroes `pay_in_advance` / `recurring` on every edit (if production uses the repo list: OPEN DECISION OD-1b (owner), verify first); snapshot errors swallowed ⇒ everything DLQs; CDC consumers without SASL/TLS or broker split; `:` prefix leak (WP6-WP10, WP27) | `event-accounting-campaign` W6 (DEFAULT APPLIED OD-20); ops: `run-and-operate`; parity cases: rails-go-parity |
| MEDIUM | `SELECT *` in `FetchBillableMetric` (and its test pins it) | change-control N4 |
| MEDIUM | unbounded goroutines vs DB pool 200 / Redis pool 10 (`processor.go:38-44`); no deadlines; head-of-line blocking; fetch error ⇒ panic (`consumer.go:175-183`) | event-accounting-campaign, debugging-playbook |
| MEDIUM | startup validation gaps (empty topic/group/prefix, `=1` ≠ cache mode, SCRAM SIGSEGV; `main.go:67`, `config/kafka/kafka.go:48-64`) | config-and-flags, debugging-playbook |
| LOW | no metrics/health/lag, spans not nested, PII in Sentry/DLQ (`processor.go:70-72`), Redis `InsecureSkipVerify` (`config/redis/redis.go:42-48`), dead code | run-and-operate, security-and-supply-chain |

All 27 entries with evidence and status: [reference/weak-points.md](reference/weak-points.md) (read when triaging
risk or picking the next hardening item; it also lists the 0%-coverage delivery-path functions).

## 9. Error taxonomy and DLQ codes (owner of code → cause → retryable; symptom triage: `debugging-playbook`)

Retryable is a property of the FAILURE, not of the code: every `FailedResult` defaults to retryable + capturable
(`utils/result.go:113-129`) unless the call site marks it otherwise. A retryable failure reaches the DLQ only once
its `ingested_at` is ≥ 12 h old (or missing); younger ones are not marked and fall under L1 (`processor.go:74-82`).

| `error_code` | `error_message` | Cause | Retryable |
|---|---|---|---|
| `build_enriched_event` | Error while converting event to enriched event | unparsable/unsupported `timestamp` (`models/event.go:70-81`) | no |
| `fetch_billable_metric` | Error fetching billable metric | not found (`record not found` / `Key not found`): no, not captured (`models/billable_metrics.go:75-83`, `cache/cache.go:189-191`); DB/badger error: yes (`enrichment_service.go:41-43`) | per failure |
| `evaluate_expression` | Error evaluating custom expression | lago-expression returned nil; message embeds the event JSON (`enrichment_service.go:121-142`) | no |
| `fetch_subscription` | Error fetching subscription | DB/badger error other than not-found (`enrichment_service.go:61-64`) | yes |
| `fetch_pay_in_advance_charge` | Error fetching pay in advance charge | DB/badger error (`processor.go:116-119`) | yes |
| `flag_subscription_refresh` | Error flagging subscription refresh | Redis error / pool timeout (`processor.go:128-131`) | yes |
| `""` | `""` | produce to enriched/in-advance failed; `initial_error_message` = `failed to push to <topic> topic` (`event_producer_service.go:87-89`) | n/a |

DLQ record = `{event, initial_error_message, error_message, error_code, failed_at}` (`models/event.go:50-56`), no key.

## 10. Observability as-is

- **Logs**: JSON (`log/slog`, `main.go:31-41`) to stdout, base attr `service=post_process`; per-event failure line `msg=<error_message>`
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
- **Metrics / health**: none (`grep -rl '"net/http"' events-processor --include='*.go'` → no output). No HTTP listener,
  no DLQ/skip/lag counters; OTel meter only carries kotel Kafka hooks.
  Consumer lag must be read from the broker for group `<group>_<raw topic>`.

## If you are about to change X

| You touch | Class / rule | Read first | Prove with |
|---|---|---|---|
| `config/kafka/consumer.go`, disposition in `processor.go`, producers | C4, change-control N7: conform to ADR-001 (DECIDED OD-2) or get an owner amendment first (a log/span/counter-only edit is C3 only if it passes change-control's behaviour test, §2) | §4, D3-D8, `failure-archaeology` | kfake test driving `processRecordsAndCommit` (`diagnostics-and-tooling`) |
| SQL in `models/*.go` | C3, change-control N4 | I1-I3 | exact sqlmock pin + `invariants-grep.sh` |
| topic names, keys, payload, Redis key/bucket | C4, change-control N6; a paired PR in every repo that depends on the changed part (DECIDED OD-4; the enriched, in-advance and DLQ topics and the ZSET all have lago-api readers, dependents per K row in change-control) | §1, I10-I12 | `topic-map.sh`, `rails-go-parity` |
| `cache/`, `extra/debezium_config.json` | C3/C4; production path (DECIDED OD-1); `event-accounting-campaign` W6; the production connector config is OPEN DECISION OD-1b (owner) | §5, `memory-cache.md` | `smoke-binary.sh cache-cdc` (`diagnostics-and-tooling`) + parity harness in `rails-go-parity` |
| startup / new env var | optional knob whose default preserves behaviour: C3 + C6 ("C4 by path, C3 by behaviour", change-control `reference/change-classes.md` worked case); C4 if it alters commit/retry/DLQ/skip or a topic/group/key/payload name | §2, `config-and-flags` checklist | `startup-contract.sh` (update expected steps) |
| `value` string formatting (`processors/events_processor/enrichment_service.go:114`) | C3 + C4 (cross-repo contract, change-control N6); paired lago-api PR, because lago-api ClickHouse reads `value` (DECIDED OD-4); a ClickHouse schema change is allowed (DECIDED OD-3) and its DDL lives in lago-api (paired PR + deploy order) | `rails-go-parity`, `event-accounting-campaign` W2 | value probe + corpus before/after |
| time parsing (`utils/time.go`: `ToTime`, `ToFloat64Timestamp`) | C3 (C4 if the enriched `timestamp` payload format changes) | `rails-go-parity` | time + subscription probes |
| a new DLQ `error_code` or DLQ cause (§9) | C4 (changes disposition): must fit ADR-001 PERMANENT (DLQ at once, with a cause; DECIDED OD-2) + owner acceptance; a CH-overflow fix may change the schema (DECIDED OD-3); no DLQ replay tool exists today (ADR-001 plans an operator-gated one) | §4, §9 | accounting-probe ledger + value corpus before/after (`event-accounting-campaign`); kfake test only if commit logic changes |

## Scripts

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/topic-map.sh` | every topic/env var/group/key/Redis key with EP file:line, dev value, created-in-dev, lago-api readers; FLAGs drift | `.claude/skills/architecture-contract/scripts/topic-map.sh` (`--no-api` offline, `--strict` exit 1 on FLAG) | 4 EP topics all `yes`; group `lago_dev_events-raw`; CDC prefix `lago_proc_cdc`; `FLAG LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC …`, `FLAG … "unprocessed_events" …`; `SUMMARY flags=2` (`--no-api`: `flags=0`) |
| `scripts/startup-contract.sh` | builds the binary (temp dir, ~5 s warm) and runs it with env added step by step; PASS/FAIL per documented panic | `.claude/skills/architecture-contract/scripts/startup-contract.sh` (opt. `--bin`, `--broker`, `--redis`, `--pg`, `--out`) | S0-S7 `PASS` (S6 SKIP without Postgres; S0 SKIP if `libexpression_go.so` is installed system-wide), `SKIP SK1-SK9`, `SUMMARY steps=9 fails=0`, exit 0 (1 = some FAIL, 2 = setup error); with a disposable broker + Redis (e.g. kfake + miniredis) and Postgres: `steps=17 fails=0` |
| `scripts/invariants-grep.sh` | static checks of change-control N4/N5/N7 rules + Go-side contract snapshot | `.claude/skills/architecture-contract/scripts/invariants-grep.sh --quiet` | `FLAG N4-cols events-processor/models/billable_metrics.go:61 FetchBillableMetric …`, `WARN N4-pin … HasPayInAdvanceCharge …`, `SUMMARY flags=1 warns=1`, exit 1 |

All three are read-only on the repo (temp dirs only) and need no Docker; exit codes are documented in each header.

## Provenance and maintenance

- Sources: all non-test Go under `events-processor/` (main.go, processors/, config/{kafka,redis,database,tracing},
  cache/, models/, utils/) read in full; `extra/debezium_config.json`; `.env.development.default:77-90`;
  `docker-compose.dev.yml:318-406`; `$API` karafka.rb, clock.rb, `db/clickhouse_migrate/*`, consumers/jobs, `billable_metrics/aggregations/base_service.rb`,
  `organizations/create_service.rb`, `events/pay_in_advance_service.rb` (I12);
  franz-go v1.20.5 and pgx v5.9.2 sources, `examples/goroutine_per_partition_consuming/README.md`; commits `4100da0`,
  `e58befb`, `cec0eb2`, `656c829`, `600e195`, `b604769`, `b6d3616`, `9acd83e`, `02a4bc8`, `42615c9`, `fb6401d`, `731e18f`, `fff5858`, `d9c32b6`, `2fd8e8b`, `b4ad153`, `d1c1629`.
- Volatile facts and one-line re-verification (run from repo root):
  - code under study unchanged: `git log -1 --format=%h -- events-processor extra/debezium_config.json .env.development.default docker-compose.dev.yml` → `5308258` (as of 2026-10-01; anything newer means re-verify this skill)
  - group id format: `grep -n 'cgName := fmt.Sprintf' events-processor/config/kafka/consumer.go` → `237: … "%s_%s"`
  - poll size / rebalance mode: `grep -n 'PollRecords(ctx, 10000)\|BlockRebalanceOnPoll' events-processor/config/kafka/consumer.go` → 168, 245
  - retry horizon: `grep -n '12\*time.Hour' events-processor/processors/events_processor/processor.go` → 74
  - Redis key: `grep -n 'subscription_refreshed_v2' events-processor/processors/main_processor.go` → 152
  - I2 still violated: `.claude/skills/architecture-contract/scripts/invariants-grep.sh --quiet | tail -1` → `SUMMARY flags=1 warns=1`
  - startup contract: `.claude/skills/architecture-contract/scripts/startup-contract.sh | tail -1` → `SUMMARY steps=9 fails=0 …`
  - I12 condition: `grep -n 'clickhouse_deduplication_enabled?' "$API/app/services/billable_metrics/aggregations/base_service.rb"` → `168`
  - Debezium gap: `grep -o 'public.charges.([^)]*)' extra/debezium_config.json` → no `pay_in_advance`
  - WP6 in the binary: `.claude/skills/diagnostics-and-tooling/scripts/smoke-binary.sh cache-cdc | grep '^tx_A'` → `… in_advance=no` (as of 2026-10-02; needs Postgres)
  - franz-go pin: `grep -n 'twmb/franz-go v' events-processor/go.mod` → `v1.20.5`
  - coverage of the delivery path (after `source .claude/skills/build-and-env/scripts/ep-env.sh`, in `events-processor/`):
    `go test -count=1 -coverpkg=./... -coverprofile="${TMPDIR:-/tmp}/ac-cov.out" ./cache/... ./config/database/... ./config/kafka/... ./models/... ./processors/events_processor/... ./utils/... && go tool cover -func="${TMPDIR:-/tmp}/ac-cov.out" | grep -E 'ProcessEvents|processRecordsAndCommit|^total'`
    → both 0.0%, total 44.9% (the informational `-coverpkg` figure; the gated baseline is 47.4% own-package coverage,
    `validation-and-qa`; as of 2026-10-01; needs Postgres)
- Update triggers: any commit under `events-processor/config/kafka/`, `processors/`, `cache/`, `models/`, `main.go`;
  a franz-go bump (defaults cited here); changes to `extra/debezium_config.json` or the Kafka/Redis vars in
  `.env.development.default`; an `api` submodule bump (downstream readers); the owner's answer to OPEN DECISION
  OD-1b (production CDC config), an ADR-001 amendment, or a reassignment of W6 (OD-20).
