# Concurrency model, commit algorithm, disposition, and where records are lost

Code facts as of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only commits on
top. Verified 2026-10-01 by reading `events-processor/config/kafka/consumer.go`,
`processors/events_processor/{processor,event_producer_service}.go` and franz-go v1.20.5 (`go.mod:18`), and by
re-running a kfake probe that drives the repo's `kafka.NewConsumerGroup` (numbers in §4). Paths are relative to
`events-processor/`. Changing anything here is change class C4: change-control N7 (kfake test of
`processRecordsAndCommit` + conformance to ADR-001, the accepted delivery contract (DECIDED OD-2 (owner,
2026-10-02); `event-accounting-campaign` `reference/delivery-options.md`) + owner sign-off).

## 1. Goroutines

```text
main goroutine ── StartProcessingEvents ── cg.Start(ctx) ── blocks on <-ctx.Done()        consumer.go:261-272
  ├─ signal goroutine: SIGTERM → cancel(root ctx)                                         main.go:94-98
  ├─ poll goroutine: loop { PollRecords(ctx, 10000) → per partition: send batch on        consumer.go:152-205
  │                         UNBUFFERED chan (blocks until that partition is idle)
  │                         → AllowRebalance() }
  ├─ partition consumer goroutine × assigned partitions (created in OnPartitionsAssigned)  consumer.go:111-130
  │     loop { select quit | ctx.Done | batch := <-records → processRecordsAndCommit }    consumer.go:51-73
  │        └─ ProcessEvents: errgroup, ONE goroutine PER RECORD, no SetLimit             processor.go:38-95
  │              └─ processEvent: +1 goroutine ProduceSync(enriched)                       processor.go:110-113
  │                               +1 goroutine ProduceSync(in-advance) if applicable       processor.go:121-126
  │                               deferred errgroup.Wait() joins them                     processor.go:100-101
  ├─ cache mode: 6 CDC loops (PollFetches → apply → CommitUncommittedOffsets)              cache/consumer.go:47-88
  └─ libraries: franz-go group/heartbeat/fetch, pgxpool, go-redis pool, OTel/dd exporters
```

Properties that follow from the code:
- **One batch in flight per partition**; batches of different partitions run in parallel.
- **Head-of-line blocking across partitions**: the poll loop dispatches partition by partition over unbuffered
  channels (`consumer.go:122,195`); a partition still processing its previous batch blocks dispatch to the
  partitions after it in the same poll, and the next `PollRecords`.
- **Rebalances wait for dispatch**: `kgo.BlockRebalanceOnPoll()` (`:245`) holds rebalances from `PollRecords` until
  `AllowRebalance()` (`:203`). The revoke/lost handler (`:132-150`, used for both `OnPartitionsLost` and
  `OnPartitionsRevoked`, `:242-243`) closes the partition's `quit` and waits for its `done`, i.e. the in-flight batch
  finishes and commits before the partition is handed over. Slow batches therefore delay rebalances; franz-go's
  default rebalance timeout is 60 s (`franz-go@v1.20.5/pkg/kgo/config.go:595`).
- **No ordering inside a batch**: records of one partition run concurrently; output keys are
  `<org>-<transaction_id>`, so there is no per-subscription ordering downstream either (`731e18f`).
- **Unbounded fan-out**: up to 10 000 records per poll (`:168`), each a goroutine hitting the DB pool (200, DB mode =
  dev, `main_processor.go:134`; in memory-cache mode, which production runs (DECIDED OD-1), badger instead) and the
  Redis pool (`PoolSize 10`, `PoolTimeout 4s`, `config/redis/redis.go:38-39`, both modes).
  Pool timeouts surface as **retryable** failures → loss L1 below.
- **No context deadlines**: batch ctx is `context.Background()` (`consumer.go:83`), passed unchanged to every
  record (one ctx for the whole batch); gorm calls have no `WithContext`;
  `ProduceSync` (`config/kafka/producer.go:62`) inherits that ctx and franz-go's defaults retry records
  `math.MaxInt64` times with no delivery timeout (`config.go:563`, `RecordDeliveryTimeout` unset), so a broker
  outage stalls the partition (and shutdown) instead of failing records (code-level reading, not probed).
  Exception: Redis calls are bounded by go-redis client options (`DialTimeout 5s`, `Read/WriteTimeout 3s`,
  `PoolTimeout 4s`, `config/redis/redis.go:35-39`), so a Redis stall becomes a retryable failure (→ L1), not a hang.
- **Fetch errors kill the process**: any non-context fetch error → `panic(err)` in the poll goroutine
  (`consumer.go:175-183`), not captured by Sentry.
- **Group id** `<LAGO_KAFKA_CONSUMER_GROUP>_<topic>` (`:237`); balancer = franz-go default cooperative-sticky
  (`config.go:589-591`; observed `"balance_protocol":"cooperative-sticky"`).

## 2. Commit algorithm (`processRecordsAndCommit`, `consumer.go:82-109`)

1. `processed := ProcessEvents(ctx=Background, batch)` — returns the records that were *marked processed*.
2. If `len(processed) == len(batch)`: `CommitRecords(batch...)` → franz-go commits `max offset + 1` for the
   partition (`franz-go@v1.20.5/pkg/kgo/consumer_group.go:2392-2412`).
3. Else `findMaxCommitableRecord(processed, batch)` (`:278-308`): find the lowest unprocessed offset `m`; commit
   the highest processed offset `< m`. If none exists (the first record was not processed), log
   `WARN "No commitable record in batch, skipping commit…"` and return without committing (`:95-99`; the `ok`
   flag was added by `9acd83e` after a nil record segfaulted franz-go, ING-15).
4. `CommitRecords` is synchronous on `Background`; an error is logged + captured, **not retried** (`:104-108`).

What the algorithm does NOT do: it never rewinds the fetch position. franz-go keeps fetching after the end of the
batch regardless of what was committed. An unprocessed record is fetched again only if the partition is
re-assigned (revoked/lost then re-fetched from the committed offset) or the process restarts **before** a later
commit on that partition moves past it. The code comment "records will be re-polled after the next rebalance"
(`:96-97`) is true only in that case; with cooperative-sticky a rebalance usually keeps the partition where it is.

## 3. Disposition table (one row per way a raw record can end)

| Case | Where decided | Marked processed (committable)? | DLQ record | Sentry | Log line |
|---|---|---|---|---|---|
| JSON unmarshal error (invalid JSON; numeric `precise_total_amount_cents`; `ingested_at` none of `2006-01-02T15:04:05[.fff]`, unix number/string, RFC3339) | `processor.go:49-60` | **yes** | **no** | yes (`CaptureError`) | ERROR `Error unmarshalling message` |
| success (enriched produced; in-advance / ZADD if applicable) | `processor.go:85-88` | yes | no | no | none (DEBUG only in cache mode) |
| non-retryable failure: `build_enriched_event`, `evaluate_expression`, `fetch_billable_metric` (not found) | `processor.go:63-88` | yes, after the DLQ attempt | yes | if capturable (not-found: no) | ERROR `<error_message>` + `error_code` |
| retryable failure and `time.Since(ingested_at) < 12h` | `processor.go:74-79` | **no** | no | yes | ERROR … — then see loss L1 |
| retryable failure and `ingested_at` ≥ 12 h old **or missing** (zero time) | `processor.go:74,82` | yes | yes | yes | ERROR |
| enriched or in-advance produce fails (after franz-go retries); the other output and the ZADD still happen | `event_producer_service.go:76-92`; result dropped at `processor.go:110-126` | yes (`processEvent` still returns success) | yes, `error_code ""`, `initial_error_message "failed to push to <topic> topic"` | yes (`producer.go:65`) | ERROR `record had a produce error while synchronously producing` |
| DLQ produce fails | `event_producer_service.go:66-73` | yes | — | yes (only remaining copy) | ERROR `error while pushing to dead letter topic` |
| commit fails | `consumer.go:104-108` | n/a | no | yes | ERROR `Error when committing offets…` → redelivery on restart (duplicates) |
| non-context fetch error | `consumer.go:175-183` | n/a | no | **no** | ERROR `Fetch error`, then process panic |

Retryable sources: any `FailedResult` keeps the defaults `Retryable=true, Capture=true` (`utils/result.go:113-129`)
unless marked otherwise: DB/badger errors on BM / subscription / charge lookups, Redis errors and pool timeouts on
the ZADD. Not-found results are `NonCapturable().NonRetryable()` (`models/billable_metrics.go:75-83`,
`models/subscriptions.go:79-87`, `cache/cache.go:189-191`); a missing subscription is not even a failure
(`enrichment_service.go:61-67`).

## 4. Where records are lost or silently changed (stated plainly)

| # | Loss | Mechanism | Evidence | Fix plan |
|---|---|---|---|---|
| L1 | **retryable failure skipped forever** | record not marked → prefix commit stops before it → fetch position already past it → next fully processed batch on the partition commits past it; no DLQ, no metric, only Sentry | code §2; scratch kfake probe re-run 2026-10-01 (1 partition, group `probe`, the repo's `kafka.NewConsumerGroup` with a `ProcessRecords` that leaves offset 2 unmarked once; offsets 0-4 pre-produced, then 5 and 6 produced 3 s / 5 s later) → `batch offsets=[0 1 2 3 4] processed=4`, `batch offsets=[5] processed=1`, `batch offsets=[6] processed=1`, `times each offset seen: map[0:1 1:1 2:1 3:1 4:1 5:1 6:1]`, `committed offset for group probe_raw p0: 7`. The probe is not shipped here; rebuild it with the `diagnostics-and-tooling` kfake harness | `event-accounting-campaign` W1, target ADR-001 (DECIDED OD-2) |
| L2 | undecodable record dropped | committed with no DLQ; connectors that send numeric `precise_total_amount_cents` hit it (`connectors/http.yml:32-33` vs `models/event.go:18`; verified `json: cannot unmarshal number into Go struct field Event.precise_total_amount_cents of type string`) | `processor.go:49-60` | `event-accounting-campaign` |
| L3 | produce failure ⇒ DLQ + commit | the failed output (enriched or in-advance) is lost and a DLQ copy (`error_code ""`) is written; the other output and the refresh ZADD still happen, so an enriched failure still produces the in-advance event (pay-in-advance without an enriched row; accounting-probe case 6 in `event-accounting-campaign`: `enriched 0 in_adv 1 dlq 1`) | `event_producer_service.go:87-89`; independent goroutines `processor.go:110-126` | `event-accounting-campaign` |
| L4 | DLQ produce failure ⇒ commit | Sentry is the only copy (marshal error of the DLQ payload is also ignored, `:60-64`) | `event_producer_service.go:66-73` | `event-accounting-campaign` |
| L5 | partial side effects | enriched is produced before the in-advance check and the ZADD; if those fail retryably the enriched copy exists, the in-advance/refresh are lost under L1, or duplicated on redelivery | `processor.go:110-131` | `event-accounting-campaign` |
| L6 | value silently changed | `fmt.Sprintf("%v")` on float64: `1000000`→`"1e+06"`, `1e-7`→`"1e-07"`, `12345678901234567890`→`"1.2345678901234567e+19"`, null/missing→`"<nil>"` (verified 2026-10-01); downstream `decimal_value Decimal(38,26) DEFAULT toDecimal128OrZero(value, 26)` (`$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32`, 12 integer digits) then yields 0 for `"<nil>"` and for values ≥ 1e12 (not re-run here: UNVERIFIED in this skill; the ClickHouse probe belongs to `rails-go-parity`) | `enrichment_service.go:114` | `rails-go-parity` (divergence), `event-accounting-campaign` W2 (schema change allowed: DECIDED OD-3) |
| L7 | time silently shifted | `utils.ToTime` float math: 496/1000 ms-precision strings land 1 ms early (verified 2026-10-01: `ToTime wrong ms: 496/1000 ; ToFloat64Timestamp wrong ms: 0/1000`); RFC3339 branch returns un-normalised time | `utils/time.go:20-23,25-29,48` | `rails-go-parity`, campaign W3 |

Duplicates (not losses): commit failure, SIGKILL mid-batch, rebalance before commit, group rename (new group starts
at the earliest offset). They are absorbed only if downstream dedup on `transaction_id` holds (invariant I12, CONDITIONAL: `FINAL` only for
orgs with `clickhouse_deduplication_enabled`).

## 5. Producer settings in force (franz-go v1.20.5 defaults; EP passes no producer options)

`NewProducer` builds its client with an empty option list (`events-processor/config/kafka/producer.go:33-35`), so
every produce to `events_enriched`, `events_charged_in_advance` and `events_dead_letter` runs on the library
defaults (`$(go env GOMODCACHE)/github.com/twmb/franz-go@v1.20.5/pkg/kgo/config.go`, verified 2026-10-02):

| Setting | Default | `config.go` line |
|---|---|---|
| acks | all in-sync replicas | 557 |
| idempotent producer | on (only `DisableIdempotentWrite()` turns it off; not called) | 221 |
| max produce requests in flight per broker | 1 | 558 |
| linger | 10 ms (max allowed 1 min) | 565 |
| produce request timeout | 10 s | 562 |
| record retries | `math.MaxInt64` (effectively unbounded; `Produce` calls `ProduceSync` with the batch `context.Background()`, `producer.go:62`, so no deadline bounds it: a non-retriable error or the 4-unknown-failures cap ends it) | 563-564 |
| buffered records before `Produce` blocks | 10000 | 561 |
| compression | snappy, fallback none | 559 |
| max record batch bytes | 1000012 | 560 |

Env knobs that would tune these do not exist today; adding one follows `config-and-flags` (add-a-variable
checklist, "knob that tunes a library") and is C3 + C6 when its default equals the library default.
