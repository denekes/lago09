# Fault-matrix ledger: cases, outcomes, expected-today output

Read when you run `accounting-probe`, read a ledger row, add a fault case, or need to know which
code path a case exercises. Code facts as of 5308258 (events-processor tree 83e012866f29); the working
branch may carry skills-only commits on top. Verified 2026-10-01 with franz-go v1.20.5, kfake pseudo-version
`v0.0.0-20251123185109-2b5c574e9ddd`, Postgres 16.

## 1. What the probe drives (and what it does not touch)

- Real code: `kafka.NewConsumerGroup` (`events-processor/config/kafka/consumer.go:227`), the poll loop
  (`:167`), `processRecordsAndCommit` (`:82`), `findMaxCommitableRecord` (`:278`),
  `EventProcessor.ProcessEvents` (`events-processor/processors/events_processor/processor.go:32`), real
  `kafka.Producer` clients, the real Redis flag store, DB mode (`models.ApiStore` over pgx/gorm).
- Wiring: the `pipeline` package of the `diagnostics-and-tooling` kfake harness (it mirrors
  `StartProcessingEvents`, `events-processor/processors/main_processor.go:102`, minus env parsing, SASL/TLS
  and panics). Data: that harness's `fixture` tenant (org `11111111-…`, BM `api_calls` = sum of `amount`
  with a pay-in-advance charge, subscription `sub_ext_1`), loaded into a throwaway Postgres database
  `acct_probe_<pid>_<n>` that the probe creates and drops (also on SIGINT/SIGTERM).
- Faults are injected only at the edges: a gorm `Query` callback (DB), `miniredis.SetError` (Redis), a kfake
  `ControlKey(Produce)` answering `INVALID_RECORD` (Kafka produce), or the payload itself. No
  events-processor file is modified (change-control N10).
- Each case: fresh kfake cluster, fresh miniredis, consumer group `acct_events-raw`.
  Session 1 produces the fault record alone and waits until `ProcessEvents` has seen it, disarms the
  fault (all faults are transient: they fire once), then (cases with neighbours) produces 2 good
  records and waits for them. Session 1 stops (real graceful shutdown). Session 2 restarts in the same
  group, produces a sentinel and waits until the committed offset passes it. Outputs are read back to
  the high watermark.
- Not modelled (UNVERIFIED by this probe): rebalance mid-batch, SIGKILL mid-batch, commit failure
  (`consumer.go:104-108` logs and captures, does not retry), multi-partition interleaving, memory-cache
  mode (OPEN DECISION OD-1 (owner)), SASL/TLS. Add them as cases (section 5) before claiming them.

## 2. Outcome definitions (one per raw offset)

<!-- evidence-check: off definitions implemented by scripts/accounting-probe/main.go, not claims -->

| Outcome | Rule (deliveries = times handed to `ProcessEvents`; decision = on the last delivery) | Accounted? |
|---|---|---|
| ENRICHED | on `events_enriched`, not on the DLQ, decision processed, 1 delivery | yes |
| DLQ | on `events_dead_letter` (cause = `error_code(initial_error_message)`), not enriched | yes |
| REDELIVERED | more than 1 delivery, finally ENRICHED or DLQ: a bounded retry happened | yes |
| PENDING | withheld and the committed offset is not past it (would come back after a restart) | yes, if bounded |
| LOST | withheld (retry intended), committed offset moved past it, never redelivered, on no topic | **no** |
| SKIPPED_RETRY | as LOST, but part of its output was produced before the failure | **no** |
| SENTRY_ONLY | decision processed (so committed) but on no output topic: only log/Sentry saw it | **no** |
| ENRICHED+DLQ | on both topics | flag it (double accounting) |

<!-- evidence-check: on -->

`UNACCOUNTED = LOST + SKIPPED_RETRY + SENTRY_ONLY` is the gate metric. The probe's exit code is
`min(UNACCOUNTED, 99)`; 100 = setup error. So `-case <one fault case>` exits 1 on today's code: that is the
expected result, not a failure.

## 3. The matrix: code path, today, target

| # | Case | Injection | Code path exercised | Fault row today | Target (any of) |
|---|---|---|---|---|---|
| 1 | `retryable-then-later-batch` | next `subscriptions` query fails once (transient DB error) | `enrichment_service.go:61-63` retryable `fetch_subscription` -> `processor.go:74-78` withheld -> next batch committed by `consumer.go:104` past it | **LOST** | REDELIVERED, or DLQ with a retry-exhausted cause |
| 2 | `retryable-only-batch` (control) | same, no neighbours | `consumer.go:94-99` skips the commit; restart re-polls from the last commit | REDELIVERED | REDELIVERED |
| 3 | `retryable-stale-12h` | same, `ingested_at` 13 h ago | `processor.go:74` horizon -> `:82` DLQ | DLQ `fetch_subscription` | DLQ |
| 4 | `unmarshal-bad-json` | truncated JSON | `processor.go:50-59` "commit it as it will failed forever", Sentry only | **SENTRY_ONLY** | DLQ with the raw bytes and a cause |
| 5 | `numeric-precise-total-amount-cents` | `"precise_total_amount_cents": 100` (connector shape, `connectors/http.yml:32-36`) | `models/event.go:18` declares a `string` -> unmarshal error -> as case 4 | **SENTRY_ONLY** | ENRICHED (accept number and string) |
| 6 | `enriched-produce-failure` | kfake rejects produce to `events_enriched` | `event_producer_service.go:87-89` -> DLQ, record still processed | DLQ `''(failed to push to events_enriched topic)`, **in_adv=1** | DLQ (and decide whether an in-advance event without an enriched one is acceptable) |
| 7 | `dlq-produce-failure` | unknown code + kfake rejects produce to `events_dead_letter` | `processor.go:82` -> `event_producer_service.go:70-73` Sentry only, record processed | **SENTRY_ONLY** | PENDING/REDELIVERED (never commit what reached no topic) |
| 8 | `redis-flag-then-later-batch` | Redis error while the fault record is in flight | `processor.go:110-113` enriched produced first, `:128-131` retryable flag failure, then as case 1 | **SKIPPED_RETRY** (enriched=1, in_adv=1, refresh never retried) | REDELIVERED |
| 9 | `redis-flag-only-batch` (control) | same, no neighbours | as case 2; the retry re-produces | REDELIVERED, **enriched=2, in_adv=2** | REDELIVERED (duplicates absorbed downstream, see `delivery-options.md` s.4) |
| 10 | `missing-bm-nonretryable` | unknown metric code | `models/billable_metrics.go:75-83` NonRetryable+NonCapturable -> DLQ | DLQ `fetch_billable_metric(record not found)` | DLQ |

Line references are under `events-processor/`; `processor.go`, `enrichment_service.go` and
`event_producer_service.go` are in `processors/events_processor/`.

## 4. Expected-today output (2026-10-01; identical on 6 runs, one of them under `GOFLAGS=-race`)

```
$ .claude/skills/event-accounting-campaign/scripts/run.sh accounting-probe
...per-case tables...
== fault-record outcome per case
retryable-then-later-batch           LOST           (expected today: fault=LOST)
retryable-only-batch                 REDELIVERED    (expected today: fault=REDELIVERED)
retryable-stale-12h                  DLQ            (expected today: fault=DLQ(fetch_subscription))
unmarshal-bad-json                   SENTRY_ONLY    (expected today: fault=SENTRY_ONLY)
numeric-precise-total-amount-cents   SENTRY_ONLY    (expected today: fault=SENTRY_ONLY)
enriched-produce-failure             DLQ            (expected today: fault=DLQ(push events_enriched))
dlq-produce-failure                  SENTRY_ONLY    (expected today: fault=SENTRY_ONLY)
redis-flag-then-later-batch          SKIPPED_RETRY  (expected today: fault=SKIPPED_RETRY)
redis-flag-only-batch                REDELIVERED    (expected today: fault=REDELIVERED (enriched x2))
missing-bm-nonretryable              DLQ            (expected today: fault=DLQ(fetch_billable_metric))
TOTALS rows=36 ENRICHED=26 DLQ=3 REDELIVERED=2 LOST=1 SKIPPED_RETRY=1 SENTRY_ONLY=3 PENDING=0 ENRICHED+DLQ=0 UNACCOUNTED=5
elapsed: 2.3s
$ echo $?
5
```

Per-case footer lines (committed offset after session 1 / after restart, Sentry captures counted with a
`BeforeSend` hook, ZSET members):
<!-- evidence-check: off probe output; re-run the section 4 command to re-verify -->

| Case | committed s1 -> s2 | Sentry | Reading |
|---|---|---|---|
| 1 | 3 -> 4 | 1 | offset 0 was withheld, but the batch `[1,2]` committed 3: offset 0 can never come back |
| 2 | -1 -> 2 | 1 | nothing committed in s1; s2 re-read from the start and succeeded |
| 4, 5 | 3 -> 4 | 1 | committed; the only trace is one Sentry event |
| 7 | 3 -> 4 | 2 | producer capture + `ProduceToDeadLetterQueue` capture; committed |
| 9 | -1 -> 2 | 1 | redelivered and re-produced (duplicates) |
| 10 | 3 -> 4 | 0 | not-found is NonCapturable (`events-processor/models/billable_metrics.go:79`): no Sentry event, DLQ only |
<!-- evidence-check: on -->

The first record of every case is offset 0; the full per-case tables print transaction ids
`<case>-fault`, `<case>-n1`, `<case>-n2`, `<case>-sentinel`.

## 5. Adding a case

<!-- evidence-check: off procedure, not claims -->

1. Write the hypothesis first (research-methodology): "case X: fault row = OUTCOME, TOTALS change by …".
2. Add a payload function and/or a `faultKind` in `scripts/accounting-probe/main.go`; inject only at an
   edge (DB callback, Redis, kfake `Control`, payload). Never edit events-processor to make a case work.
3. Append a `scenario{...}` with `expected` = today's outcome; keep the fault transient (fires once) unless
   the case is about permanent faults (then expect PENDING growth and say so).
4. `run.sh --check` (vet, gofmt, franz-go pin), run the case 3 times plus once with `GOFLAGS=-race`.
5. Update section 3 and 4 here, the `ledger_rows` and UNACCOUNTED baselines in `scripts/scoreboard.sh`,
   and SKILL.md Phase 0. This is a C1 change (change-control).

<!-- evidence-check: on -->

Ideas not built yet (each is a hypothesis to test, UNVERIFIED): commit failure via
`ControlKey(OffsetCommit)`; crash after produce before commit (cancel inside a `Wrap`); 2 partitions with the
fault on one; in-advance produce failure (expect ENRICHED+DLQ); memory-cache mode (`fixture.SeedCache`).
