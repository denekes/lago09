# DB mode vs memory-cache mode (badger snapshot + Debezium CDC)

Verified 2026-10-01 at HEAD 5308258 by reading `events-processor/{main.go,cache/*.go,models/*.go}` and
`extra/debezium_config.json`, plus scratch probes against the real `cache` package and the binary
(`startup-contract.sh` S5-S7). Paths relative to `events-processor/` unless they start with `extra/`.

**OPEN DECISION OD-1 (owner): does production run `LAGO_USE_MEMORY_CACHE=true`, with which Debezium column list,
SASL/TLS and broker list?** Until answered: DB mode is the default path (dev runs it: neither
`LAGO_USE_MEMORY_CACHE` nor `LAGO_DEBEZIUM_TOPIC_PREFIX` is in `.env.development.default`). Every memory-cache finding
below is a real code-level defect whose **production impact is UNVERIFIED**.

## 1. Side by side

| Aspect | DB mode (default) | Memory-cache mode |
|---|---|---|
| Switch | `LAGO_USE_MEMORY_CACHE` anything but the exact string `true` (`main.go:67`) | `LAGO_USE_MEMORY_CACHE=true` |
| Postgres | pgx pool `MaxConns = LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` (default 200), gorm (`processors/main_processor.go:133-150`, `config/database/database.go:24-48`) | snapshot-only pool, `MaxConns 10`, closed after warm-up (`cache/cache.go:63-73`); **no** per-event DB access (`main_processor.go:133` skips the pool) |
| Billable metric | `FetchBillableMetric` gorm `First` (implicit `SELECT *`) `WHERE organization_id=? AND code=? AND deleted_at IS NULL ORDER BY id LIMIT 1` (`models/billable_metrics.go:59-73`) | `bm:<org>:<code>` point get (`cache/billable_metrics.go:18-30`) |
| Subscription | SQL copied from Rails `Events::Common#subscription`: `date_trunc('millisecond', started_at) <= ts AND (terminated_at IS NULL OR date_trunc('millisecond', terminated_at) >= ts) ORDER BY terminated_at DESC NULLS FIRST, started_at DESC LIMIT 1`, explicit columns (`models/subscriptions.go:24-52`) | prefix scan `sub:<org>:<external_id>:` + Go emulation of the ordering at **full (µs) precision** (`cache/subscriptions.go:45-117`) |
| Pay-in-advance check | `SELECT id FROM charges WHERE organization_id=? AND plan_id=? AND billable_metric_id=? AND pay_in_advance IS TRUE AND deleted_at IS NULL LIMIT 1` (`models/charges.go:47-66`) | prefix scan `ch:<org>:<plan>:<bm_id>:` and any `PayInAdvance` (`cache/charges.go:87-102`) |
| Freshness | read-your-writes from Postgres | snapshot at start + CDC lag |
| Startup | fails fast if PG unreachable | snapshot connect failure panics; **per-table load failures are swallowed** |
| Tests | sqlmock (`tests/mocked_store.go`) | real badger (`cache/*_test.go`); `processors/events_processor` tests run both modes (`processor_test.go:184`, `enrichment_service_test.go:63`) |

Per-event Postgres cost in DB mode: 1 BM query + 1 subscription query (2 for a recurring BM with no subscription
at the event time, `enrichment_service.go:57-59`) + 1 charges query (only when a subscription was found and the
event was not post-processed by the API, `processor.go:115-116`).

## 2. What is cached (badger v4 in-memory, default options, logger off: `cache/cache.go:36-53`)

| Prefix | Key | Read by | Snapshot filter (`models/*.go`) | CDC delete rule | TTL |
|---|---|---|---|---|---|
| `bm` | `bm:<org>:<code>` | `GetBillableMetric` (enrichment) | `deleted_at IS NULL` | `deleted_at` set and cached id == message id → delete | none |
| `sub` | `sub:<org>:<external_id>:<id>` | `SearchSubscriptions` | `terminated_at IS NULL OR terminated_at >= now() - 1 month` (`subscriptions.go:56-77`) | `terminated_at` set and cached id == message id → rewrite the message row with a **30-day TTL** (`cache/subscriptions.go:119-128`) | 30 d after a CDC termination; none for snapshot rows |
| `ch` | `ch:<org>:<plan>:<bm_id>:<id>` | `HasPayInAdvanceCharge` | `deleted_at IS NULL` | `deleted_at` set → delete | none |
| `bmf` | `bmf:<org>:<bm_id>:<id>` | **nobody** since `d9c32b6` | `deleted_at IS NULL` | delete | none |
| `cf` | `cf:<org>:<charge_id>:<id>` | **nobody** since `d9c32b6` | `deleted_at IS NULL` | delete | none |
| `cfv` | `cfv:<org>:<cf_id>:<bmf_id>:<id>` | **nobody** since `d9c32b6` | `deleted_at IS NULL` | delete | none |

Values are the model structs as JSON. Keys embed `code` / `external_id`: if those can change in place, the old key
lingers (UNVERIFIED whether Rails allows it).

## 3. Warm-up and CDC (`main.go:66-81`, `cache/cache.go:63-129`, `cache/consumer.go`)

1. `LoadInitialSnapshot` (blocking): six loaders in parallel, each streams its table into an in-memory slice first
   (`models/query_streaming.go:95-113`), then one badger transaction per row (`cache/cache.go:231-274`). Loader
   errors are ignored (each goroutine returns nil, `cache.go:78-106`); success logs `Completed snapshot load` with a
   count, failure logs only gorm's SQL error (`"component":"db"`). Verified: against an empty database the process
   logs six `relation … does not exist` errors, zero `Completed snapshot load`, and keeps starting (S6).
2. `ConsumeChanges`: six consumers, topic `$LAGO_DEBEZIUM_TOPIC_PREFIX.public.<table>`, group
   `lago_evp_<model>_<uuid>` (new every start ⇒ replay from the earliest retained offset), `kgo.SeedBrokers(<raw env
   string>)` with **no comma split, no SASL, no TLS, no logger** (`cache/consumer.go:26-35`; the main path splits the
   list with `utils.ParseBrokersEnv`, `utils/env.go:22-33`). Fetch errors are logged + captured and the loop
   `continue`s forever (`:66-74`); offsets are committed after every poll (`:83-85`).
3. Apply (`cache/consumer.go:92-175`): `UnmarshalNestedJSON` into a **fresh zero-valued struct** (only fields present
   in the message are set; supports `"properties.pricing_group_keys"`-style tags, `utils/json.go:12-57`) →
   if deleted: delete only when the cached id equals the message id (guards re-created codes) → else skip unless the
   message `updated_at` (ms) is strictly newer → `SetCache` overwrites the **whole** entry.
4. Debezium shape expected (`extra/debezium_config.json`): unwrap SMT (`ExtractNewRecordState`) with
   `delete.handling.mode: rewrite` (adds `__deleted`, lines 52-54), no tombstones emitted (`tombstones.on.delete:
   false`, line 43; the SMT's `drop.tombstones: false`, line 53, would only matter if some were), JSON without
   schemas (lines 16-18, 55-57), timestamps expected as int64 µs (Debezium default, not set in the file;
   `utils.NullTime.UnmarshalJSON` accepts µs ints or RFC3339 strings, `utils/time.go:140-172`). EP never reads
   `__deleted`: soft deletes (`deleted_at`, `terminated_at`) are honoured, a hard `DELETE` row is not
   (code-level observation, impact UNVERIFIED).

## 4. Column contract (the trap)

`extra/debezium_config.json:2` `column.include.list` (unchanged since `fff5858`, 2026-04-27):

| Table | Columns streamed | Model fields the cache needs but CDC does not carry |
|---|---|---|
| billable_metrics | id, organization_id, code, aggregation_type, field_name, expression, created_at, updated_at, deleted_at | **`recurring`** (`models/billable_metrics.go:51`, added by `b4ad153`) |
| charges | id, organization_id, plan_id, billable_metric_id, created_at, updated_at, deleted_at, properties | **`pay_in_advance`** (`models/charges.go:13`), `accepts_target_wallet` (no reader) |
| subscriptions | id, organization_id, external_id, plan_id, created_at, updated_at, started_at, terminated_at | — |

Because step 3 overwrites the whole entry from a zero-valued struct, **any CDC update of a charge sets
`PayInAdvance=false`** (in-advance events stop for that charge) and any CDC update of a BM sets `Recurring=false`
(recurring fallback stops). Code-level VERIFIED by reading; production impact depends on the real connector config
(OD-1). Re-check: `grep -o 'public.charges.([^)]*)' extra/debezium_config.json` → no `pay_in_advance`.

## 5. Failure behaviour summary (memory-cache mode)

| Situation | Behaviour | Evidence |
|---|---|---|
| Postgres unreachable at start | panic before any Kafka check | S5 |
| table missing / SQL error / timeout during snapshot | swallowed; empty cache; every event → DLQ `fetch_billable_metric` (`Key not found`, non-retryable) | S6; `cache/cache.go:78-106,189-191` |
| comma-separated `LAGO_KAFKA_BOOTSTRAP_SERVERS` | main consumer fine; CDC consumers get one bogus seed and log nothing (no logger) | `cache/consumer.go:28-35`; franz-go `parseBrokerAddr` turns `h1:9092,h2:9092` (SplitHostPort fails) into one "IPv6 literal" seed on port 9092 instead of erroring (`franz-go@v1.20.5/pkg/kgo/client.go:745-749`); 8 s run: no CDC error line |
| secured Kafka (SASL/TLS) | CDC consumers cannot authenticate | `cache/consumer.go:30-35` |
| subscription created just before its first event | event enriched with no subscription ⇒ no in-advance, no refresh flag | `enrichment_service.go:61-67` (inference) |
| `external_id` containing `:` | prefix scan leaks: lookup `acme` matches `acme:eu` (verified probe: `prefix leak: lookup external_id=acme matched id=sub-eu external_id=acme:eu`) | `cache/subscriptions.go:46` |
| event exactly on the start millisecond (`started_at …00.000500`, event `…00.000`) | cache: no match; DB mode `date_trunc(ms)` matches (verified probe: `cache matched=false`) | `cache/subscriptions.go:60-65` vs `models/subscriptions.go:32-33` |
| shutdown | `Cache.Wait()` never called; badger may close under a CDC goroutine (UNVERIFIED impact) | `main.go:75`, `cache/cache.go:59-61` |
| memory | whole tables held in Go slices during warm-up; badger in-memory unbounded; terminated subscriptions kept 1 month (snapshot) / 30 days (CDC); 3 dead filter tables still loaded | `models/query_streaming.go:96`, `cache/subscriptions.go:126` |

Hardening beyond the shared parity harness is not owned by any campaign (see `event-accounting-campaign` scope);
DB/cache/Rails parity cases are in `rails-go-parity`.
