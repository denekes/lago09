# DB mode vs memory-cache mode (badger snapshot + Debezium CDC)

Code facts as of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only commits on
top. Verified 2026-10-01 by reading `events-processor/{main.go,cache/*.go,models/*.go}` and
`extra/debezium_config.json`, plus scratch probes against the real `cache` package and the binary
(`startup-contract.sh` S5-S7). Mode deltas in §1a were executed on 2026-10-02 by the re-implementation kit
(`events-processor-spec` unit vectors, cited by id). Paths relative to `events-processor/` unless they start with
`extra/`.

**DECIDED OD-1 (owner, 2026-10-02): production runs `LAGO_USE_MEMORY_CACHE=true`.** Dev runs DB mode (neither
`LAGO_USE_MEMORY_CACHE` nor `LAGO_DEBEZIUM_TOPIC_PREFIX` is in `.env.development.default` or any compose file
here). Every memory-cache finding below is therefore a **production-relevant** defect (`weak-points.md` WP6-WP10,
WP27). Hardening owner: `event-accounting-campaign` W6 (DEFAULT APPLIED OD-20; the owner may reassign it).

**Verify first: OPEN DECISION OD-1b (owner).** The production Debezium connector config (is its
`column.include.list` the one in `extra/debezium_config.json:2`?), the Kafka auth (SASL/TLS) and the bootstrap
broker list the CDC consumers get are not visible from any repo here. If production uses the repo's column list,
in-advance charges and the recurring fallback are silently broken for every edited charge or metric (§4:
code-level and binary-smoke VERIFIED, production impact UNVERIFIED). Operator checks: `run-and-operate`
`reference/memory-cache-ops.md`.

## 1. Side by side

| Aspect | DB mode (dev) | Memory-cache mode (production, DECIDED OD-1) |
|---|---|---|
| Switch | `LAGO_USE_MEMORY_CACHE` anything but the exact string `true` (`main.go:67`) | `LAGO_USE_MEMORY_CACHE=true` |
| Postgres | pgx pool `MaxConns = LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` (default 200), gorm (`processors/main_processor.go:133-150`, `config/database/database.go:24-48`) | snapshot-only pool, `MaxConns 10`, closed after warm-up (`cache/cache.go:63-73`); **no** per-event DB access (`main_processor.go:133` skips the pool) |
| Billable metric | `FetchBillableMetric` gorm `First` (implicit `SELECT *`) `WHERE organization_id=? AND code=? AND deleted_at IS NULL ORDER BY id LIMIT 1` (`models/billable_metrics.go:59-73`) | `bm:<org>:<code>` point get (`cache/billable_metrics.go:18-30`) |
| Subscription | SQL copied from Rails `Events::Common#subscription`: `date_trunc('millisecond', started_at) <= ts AND (terminated_at IS NULL OR date_trunc('millisecond', terminated_at) >= ts) ORDER BY terminated_at DESC NULLS FIRST, started_at DESC LIMIT 1`, explicit columns (`models/subscriptions.go:24-52`) | prefix scan `sub:<org>:<external_id>:` + Go emulation of the ordering at **full (µs) precision** (`cache/subscriptions.go:45-117`) |
| Event time with an RFC 3339 offset | kept with its offset by `ToTime` (`utils/time.go:25-29`) and compared against `timestamp` (no time zone) columns, i.e. as the **wall clock** of that offset (`models/subscriptions.go:32-33`) | compared as an **instant** (Go `time.Time` comparisons, `cache/subscriptions.go:60-65`) |
| Pay-in-advance check | `SELECT id FROM charges WHERE organization_id=? AND plan_id=? AND billable_metric_id=? AND pay_in_advance IS TRUE AND deleted_at IS NULL LIMIT 1` (`models/charges.go:47-66`) | prefix scan `ch:<org>:<plan>:<bm_id>:` and any `PayInAdvance` (`cache/charges.go:87-102`) |
| Freshness | read-your-writes from Postgres | snapshot at start + CDC lag |
| Startup | panics if PG unreachable (`processors/main_processor.go:144-147`) | snapshot connect failure panics (`cache/cache.go:69-72`); **per-table load failures are swallowed** |
| Tests | sqlmock (`tests/mocked_store.go`) | real badger (`cache/*_test.go`); `processors/events_processor` tests run both modes (`processor_test.go:184`, `enrichment_service_test.go:63`) |

Per-event Postgres cost in DB mode: 1 BM query + 1 subscription query (2 for a recurring BM with no subscription
at the event time, `enrichment_service.go:57-59`) + 1 charges query (only when a subscription was found and the
event was not post-processed by the API, `processor.go:115-116`).

## 1a. Behaviour deltas executed by the kit (both modes, 2026-10-02)

Each row ran through this repo's events-processor packages (tree 83e012866f29) behind the kit's `ep-oracle`
adapter: `events-processor-spec` unit vectors, ids in the table; "Kit corrected" cites `reimplementation-kit` RBD
ids and is the kit's rebuild target, not a decision for this code. Re-run (maintainer scripts; builds the oracle into
`$LAGO_SKILLS_CACHE/ep-reference/` on first use):
```bash
eval "$(.claude/skills/events-processor-spec/scripts/maintainer/build-go-reference.sh --print-env)"
python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --areas ep --profile compat \
  --only 'ep\.match_subscription\.(00[2349]|010|016|017|028|029|032|033)$|ep\.decode\.021$' \
  --impl-cmd "env LD_LIBRARY_PATH=$EP_REF_LD_LIBRARY_PATH $EP_ORACLE_BIN"
# expect: 12 PASS lines, SUMMARY kitrun: ... vectors=12 passed=12 ... exit=0   (re-run 2026-10-02)
```

<!-- evidence-check: off kit-executed rows; each row names its vector ids, re-run with the kitrun block above -->
| Input | DB mode (dev, self-host) | Memory-cache mode (production) | Kit vectors (DB / cache) | Kit corrected |
|---|---|---|---|---|
| event in the `started_at` millisecond, `started_at` = `…00.0005` | matched (ms-truncated bound) | **no subscription** (µs bound) | ep.match_subscription.009 / .010 | ms in both (RBD-17, decided) |
| `"2025-03-01T00:30:00+01:00"`, subscriptions switching at `2025-03-01T00:00Z` | the NEW one (wall clock 00:30) | the OLD one (instant 23:30Z) | ep.match_subscription.016 / .017 | UTC instant (RBD-16, decided) |
| decimal string `"…00.001"`, `terminated_at` = `…00.0007` (1 ms after its millisecond) | still attached (`ToTime` lands 1 ms early) | still attached | ep.match_subscription.003 / .004 | not attached (RBD-15, RBD-17) |
| RFC 3339 `"…00.0008Z"`, `terminated_at` = `…00.0007` | not attached | not attached | ep.match_subscription.028 / .029 | attached (both truncated to ms) |
| external id `acme` while `acme:eu` (started later) exists | `acme` | **`acme:eu`** (prefix leak, WP8) | ep.match_subscription.032 / .033 | exact equality (RBD-99, proposed) |
| unknown metric code | DLQ `fetch_billable_metric`, `record not found` | same code, `Key not found` | EPC-03 goldens per mode | text is not a contract (RBD-24) |
| CDC row whose `updated_at` falls in the same millisecond as the cached row | n/a | row skipped (§3 step 3) | none: code-level (`cache/consumer.go:146`), kit rule EP-N3 | — |
<!-- evidence-check: on -->

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
   Two properties of this design are load-bearing (INFERRED from the code; a hardening change must keep them):
   - the group is per PROCESS so that every replica receives every CDC record (each pod has its own cache).
     A fixed group shared by replicas would split the partitions: with the reference config's single
     partition per CDC topic (`extra/debezium_config.json:44`), all but one replica would get no updates;
   - consuming from the earliest retained offset closes the gap between the snapshot read and the consumer
     start (`main.go:77-78`: snapshot first, then `ConsumeChanges`); starting at the latest offset would lose
     the changes made in between. Replayed rows older than the snapshot are skipped by the `updated_at` rule
     (step 3), but a row deleted before the snapshot can reappear until its delete message is replayed
     (the snapshot skips deleted rows, so the older non-deleted message re-creates the key; transient).
3. Apply (`cache/consumer.go:92-175`): `UnmarshalNestedJSON` into a **fresh zero-valued struct** (only fields present
   in the message are set; supports `"properties.pricing_group_keys"`-style tags, `utils/json.go:12-57`) →
   if deleted: delete only when the cached id equals the message id (guards re-created codes) → else skip unless the
   message `updated_at` is strictly newer **at millisecond precision** → `SetCache` overwrites the **whole** entry.
   The comparison uses `UnixMilli()` (`cache/billable_metrics.go:68`, `cache/charges.go:73`,
   `cache/subscriptions.go:168`) and skips on `>=` (`cache/consumer.go:146`), while Postgres and Debezium carry
   microseconds: a second change of the same row inside one millisecond is skipped, and the cache keeps the first
   version until the next change or restart (code-level, kit rule EP-N3; no vector exercises it; impact UNVERIFIED).
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
(recurring fallback stops). Code-level VERIFIED by reading; binary-level VERIFIED 2026-10-02 with
`.claude/skills/diagnostics-and-tooling/scripts/smoke-binary.sh cache-cdc` (one hand-shaped CDC `charges` row
without `pay_in_advance` → `tx_A … in_advance=no`, while `cache` mode without the CDC row emits the in-advance
event). Production runs cache mode (DECIDED OD-1), so the impact depends only on whether the production connector
uses this column list: OPEN DECISION OD-1b (owner), the first thing to verify. A restart masks the defect until
the next edit: the snapshot selects `pay_in_advance` and `recurring` (`models/charges.go:29`,
`models/billable_metrics.go:93`) and the replayed CDC rows are not newer, so they are skipped
(`cache/consumer.go:143-156`; INFERRED). Tell-tale: in-advance volume for a plan drops after a charge edit and
returns after a deploy. Re-check: `grep -o 'public.charges.([^)]*)' extra/debezium_config.json` → no `pay_in_advance`.

## 5. Failure behaviour summary (memory-cache mode = production)

| Situation | Behaviour | Evidence |
|---|---|---|
| Postgres unreachable at start | panic before any Kafka check | S5 |
| table missing / SQL error / timeout during snapshot | swallowed; empty cache; every event → DLQ `fetch_billable_metric` (`Key not found`, non-retryable) | S6; `cache/cache.go:78-106,189-191` |
| comma-separated `LAGO_KAFKA_BOOTSTRAP_SERVERS` | main consumer fine; CDC consumers get one bogus seed and log nothing (no logger) | `cache/consumer.go:28-35`; franz-go `parseBrokerAddr` turns `h1:9092,h2:9092` (SplitHostPort fails) into one "IPv6 literal" seed on port 9092 instead of erroring (`franz-go@v1.20.5/pkg/kgo/client.go:745-749`); 8 s run: no CDC error line |
| secured Kafka (SASL/TLS) | CDC consumers cannot authenticate | `cache/consumer.go:30-35` |
| subscription created just before its first event | event enriched with no subscription ⇒ no in-advance, no refresh flag | `enrichment_service.go:61-67` (inference) |
| `external_id` containing `:` | prefix scan leaks: lookup `acme` matches `acme:eu` (verified probe: `prefix leak: lookup external_id=acme matched id=sub-eu external_id=acme:eu`); EXECUTED by the kit: ep.match_subscription.033 returns the `acme:eu` subscription in cache mode, .032 the `acme` one in DB mode | `cache/subscriptions.go:46` |
| event exactly on the start millisecond (`started_at …00.000500`, event `…00.000`) | cache: no match; DB mode `date_trunc(ms)` matches (verified probe: `cache matched=false`; EXECUTED by the kit: ep.match_subscription.010 / .009) | `cache/subscriptions.go:60-65` vs `models/subscriptions.go:32-33` |
| shutdown | `Cache.Wait()` never called; badger may close under a CDC goroutine (UNVERIFIED impact) | `main.go:75`, `cache/cache.go:59-61` |
| restart | 6 NEW `lago_evp_<model>_<uuid>` groups per process start ⇒ full re-read of every retained CDC topic and 6 orphan groups left per restart per replica | `cache/consumer.go:27`; smoke `consumer_groups: … + 6 lago_evp_<model>_<uuid>` (re-run 2026-10-02); kit cache goldens `other_groups=6` after one start (EPC-00), `other_groups=12` after one restart (EPC-21) |
| failed start (broker, producer or Redis check fails after the CDC consumers started) | 0-6 orphan `lago_evp_*` groups (timing-dependent: the consumers may or may not have joined before the panic) | `main.go:77-84` (CDC first, then `processors.StartProcessingEvents`); kit rule EP-A3 (not compared by the suite) |
| memory | whole tables held in Go slices during warm-up; badger in-memory unbounded; terminated subscriptions kept 1 month (snapshot) / 30 days (CDC); 3 dead filter tables still loaded. Measured (synthetic, see caveat): 1M subscriptions ⇒ RSS ~801-823 MB, Go heap in use 426 MB, 13.4-20.8 s to insert | `models/query_streaming.go:96`, `cache/subscriptions.go:126`; scratch benchmark (below) |

Memory measurement caveat: a scratch program called the real `cache.SetSubscription` 1,000,000 times with
synthetic rows (short ids, one org, one plan, no `terminated_at`) on 4 vCPU, then forced a GC: RSS 823 MB
(2026-10-01) and 801 MB (`VmRSS 800900 kB`, 2026-10-02), heap in use 426 MB both times, lookup OK. It does NOT
include the snapshot path (the whole table is first held as a Go slice, `models/query_streaming.go:96`, so the
warm-up peak is higher), the other 5 tables, real row sizes or production `GOGC`/limits. Treat ~0.8 GB per 1M
subscriptions as a lower bound and measure on a production-sized snapshot before sizing; the documented pod
size is 2 Gi (`docs/architecture.md:262`).

Memory-cache hardening (WP6-WP10, WP27) is owned by `event-accounting-campaign` W6 "memory-cache correctness"
(DEFAULT APPLIED OD-20, 2026-10-02; the owner may reassign it). DB/cache/Rails parity cases are in `rails-go-parity`;
production operations (snapshot check, CDC lag, orphan groups, sizing) are in `run-and-operate`.
