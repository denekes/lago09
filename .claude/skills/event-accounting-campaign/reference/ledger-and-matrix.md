# Fault-matrix ledger: cases, outcomes, expected-today output

Read when you run `accounting-probe`, read a ledger row, add a fault case, or need to know which
code path a case exercises. Code facts as of 5308258 (events-processor tree 83e012866f29); the working
branch may carry skills-only commits on top. Verified 2026-10-01 with franz-go v1.20.5, kfake pseudo-version
`v0.0.0-20251123185109-2b5c574e9ddd`, Postgres 16; memory-cache mode (`-mode cache`) and the opt-in cases 15-16
added and verified 2026-10-02.

## 1. What the probe drives (and what it does not touch)

- Real code: `kafka.NewConsumerGroup` (`events-processor/config/kafka/consumer.go:227`), the poll loop
  (`:167`), `processRecordsAndCommit` (`:82`), `findMaxCommitableRecord` (`:278`),
  `EventProcessor.ProcessEvents` (`events-processor/processors/events_processor/processor.go:32`), real
  `kafka.Producer` clients, the real Redis flag store, and one of two data sources: DB mode (the probe's default
  `-mode db`: `models.ApiStore` over pgx/gorm, what dev runs) or `-mode cache`: a real `cache.Cache` (badger in
  memory, `events-processor/cache/cache.go:36-53`), the mode production runs (DECIDED OD-1 (owner, 2026-10-02)).
- Wiring: the `pipeline` package of the `diagnostics-and-tooling` kfake harness (it mirrors
  `StartProcessingEvents`, `events-processor/processors/main_processor.go:102`, minus env parsing, SASL/TLS
  and panics). Data: that harness's `fixture` tenant (org `11111111-…`, BM `api_calls` = sum of `amount`
  with a pay-in-advance charge, subscription `sub_ext_1`), loaded into a throwaway Postgres database
  `acct_probe_<pid>_<n>` that the probe creates and drops (also on SIGINT/SIGTERM); in cache mode the
  same tenant is written into a fresh cache per case by `fixture.SeedCache` (no Postgres; no Debezium
  snapshot or CDC traffic: `smoke-binary.sh cache-cdc` covers CDC, `memory-cache-w6.md` s.4).
- Faults are injected only at the edges: a gorm `Query` callback (DB), `miniredis.SetError` (Redis), a kfake
  `ControlKey(Produce)` answering `INVALID_RECORD` (Kafka produce), the payload itself, or (case 15) a
  throwaway Postgres role with `CONNECTION LIMIT 30` used with the binary's default pool of 200. No
  events-processor file is modified (change-control N10).
- Each case (`runCase`, `scripts/accounting-probe/main.go:504`): fresh kfake cluster, fresh miniredis, consumer group `acct_events-raw`.
  Session 1 produces the fault record alone and waits until `ProcessEvents` has seen it, disarms the
  fault (all faults are transient: they fire once), then (cases with neighbours) produces 2 good
  records and waits for them. Session 1 stops (real graceful shutdown). Session 2 restarts in the same
  group, produces a sentinel and waits until the committed offset passes it. Outputs are read back to
  the high watermark.
- Cases 1-3 inject at the Postgres edge and have no cache-mode counterpart; `-mode cache` runs cases 4-10
  (`run.sh accounting-probe -mode cache -case retryable-only-batch` exits 100: "unknown case(s) for -mode cache").
- Cases 15-16 are OPT-IN: they run only when named with `-case` (`-list` marks them `OPT-IN`), so the
  default TOTALS, the `scoreboard.sh` baselines and the numbers other skills quote (`UNACCOUNTED=5`, `rows=36`)
  do not move. Case 15 creates and drops its role (needs CREATEROLE) and exists in DB mode only; case 16 runs in
  both modes.
- Not modelled (UNVERIFIED by this probe): rebalance mid-batch, SIGKILL mid-batch, commit failure
  (`consumer.go:104-108` logs and captures, does not retry), multi-partition interleaving, CDC updates and
  snapshot failures in cache mode (smoke-level evidence only, `memory-cache-w6.md`), SASL/TLS. Add them as
  cases (section 5) before claiming them.

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

ADR-001 step 4a adds two outcomes: RETRIED (finally ENRICHED or DLQ after a hop through the retry topic;
accounted) and RETRY_PARKED (on the retry topic at the end of the case, inside the max age; accounted,
bounded): `delivery-options.md` s.6.

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
| 9 | `redis-flag-only-batch` (control) | same, no neighbours | as case 2; the retry re-produces (`processor.go:110-126` runs again) | REDELIVERED, **enriched=2, in_adv=2** | REDELIVERED (duplicates absorbed downstream, see `delivery-options.md` s.4) |
| 10 | `missing-bm-nonretryable` | unknown metric code | `models/billable_metrics.go:75-83` NonRetryable+NonCapturable -> DLQ | DLQ `fetch_billable_metric(record not found)` | DLQ |
| 15 | `db-connection-exhaustion` (OPT-IN, DB mode) | 200 good records produced before the consumer starts (one poll), role `CONNECTION LIMIT 30`, pool 200 (`processors/main_processor.go:134` default); 2 good records follow | Postgres refuses connections (`too many connections for role`) -> retryable lookup failures -> `processor.go:74-78` withheld -> the neighbours' batch commits past them (case 1 at burst scale) | **164-170 of 200 LOST** (timing-dependent) | ADR-001 SYSTEMIC: pause, 0 LOST (kit `events-processor-spec` EPC-30, `reimplementation-kit` RBD-10) |
| 16 | `non-finite-timestamp` (OPT-IN) | `"timestamp": "NaN"` | `utils/time.go:56-58` accepts it; `event_producer_service.go:77-79` marshal error, logged + captured, no produce, no DLQ; `processor.go:134` success | **SENTRY_ONLY** (both modes) | DLQ with a cause (ADR-001 PERMANENT; kit EPC-08, RBD-4) |

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

Memory-cache mode (2026-10-02; identical on 3 runs, one of them under `GOFLAGS=-race`):
```
$ .claude/skills/event-accounting-campaign/scripts/run.sh accounting-probe -mode cache
== mode: cache (memory-cache data source, fixture.SeedCache; no Postgres, no CDC; 7 of 10 cases have a cache-mode counterpart)
...per-case tables...
== fault-record outcome per case
unmarshal-bad-json                   SENTRY_ONLY    (expected today: fault=SENTRY_ONLY)
numeric-precise-total-amount-cents   SENTRY_ONLY    (expected today: fault=SENTRY_ONLY)
enriched-produce-failure             DLQ            (expected today: fault=DLQ(push events_enriched))
dlq-produce-failure                  SENTRY_ONLY    (expected today: fault=SENTRY_ONLY)
redis-flag-then-later-batch          SKIPPED_RETRY  (expected today: fault=SKIPPED_RETRY)
redis-flag-only-batch                REDELIVERED    (expected today: fault=REDELIVERED (enriched x2))
missing-bm-nonretryable              DLQ            (expected today: fault=DLQ(fetch_billable_metric: Key not found))
TOTALS rows=26 ENRICHED=19 DLQ=2 REDELIVERED=1 LOST=0 SKIPPED_RETRY=1 SENTRY_ONLY=3 PENDING=0 ENRICHED+DLQ=0 UNACCOUNTED=4
elapsed: 1.7s
$ echo $?
4
```
Per-case footers match DB mode for the shared cases (committed `3 -> 4`, case 9 `-1 -> 2`; Sentry 1,
case 7: 2, case 10: 0); the only text difference is the case-10 DLQ cause `fetch_billable_metric(Key not found)`
(badger) instead of `(record not found)` (gorm).

Opt-in cases (2026-10-02; case 15: 4 runs, one under `GOFLAGS=-race`; case 16: 2 runs per mode, one under
`-race`):
```
$ .claude/skills/event-accounting-campaign/scripts/run.sh accounting-probe -case db-connection-exhaustion
...
burst rows (offsets 0-199, -v prints each): burst=200 ENRICHED=31 LOST=169
committed offset: after session 1 = 202, after restart = 203 | sentry captures = 169 | zset members = 1
== fault-record outcome per case
db-connection-exhaustion             burst=200 ENRICHED=31 LOST=169 (expected today: burst: LOST > 0 (timing-dependent))
TOTALS rows=203 ENRICHED=34 DLQ=0 REDELIVERED=0 LOST=169 SKIPPED_RETRY=0 SENTRY_ONLY=0 PENDING=0 ENRICHED+DLQ=0 UNACCOUNTED=169
$ echo $?
99
$ .claude/skills/event-accounting-campaign/scripts/run.sh accounting-probe -case non-finite-timestamp      # and -mode cache
...
non-finite-timestamp                 SENTRY_ONLY    (expected today: fault=SENTRY_ONLY)
TOTALS rows=4 ENRICHED=3 DLQ=0 REDELIVERED=0 LOST=0 SKIPPED_RETRY=0 SENTRY_ONLY=1 PENDING=0 ENRICHED+DLQ=0 UNACCOUNTED=1
```
Case 15: LOST was 169, 170, 170 and 164 (`-race`); exit 99 is the cap (`min(UNACCOUNTED, 99)`); `-v` prints
every burst row and shows the Postgres refusals. The kit measured the same mechanism on the reference binary
(`events-processor-spec` EPC-30: 85-170 of 201 records lost in nine runs). Case 16 committed `3 -> 4` with one
Sentry capture in both modes.

## 5. Adding a case

<!-- evidence-check: off procedure, not claims -->

1. Write the hypothesis first (research-methodology): "case X: fault row = OUTCOME, TOTALS change by …".
2. Add a payload function and/or a `faultKind` in `scripts/accounting-probe/main.go`; inject only at an
   edge (DB callback, Redis, kfake `Control`, payload). Never edit events-processor to make a case work.
3. Append a `scenario{...}` with `expected` = today's outcome; keep the fault transient (fires once) unless
   the case is about permanent faults (then expect PENDING growth and say so).
4. `run.sh --check` (vet, gofmt, franz-go pin), run the case 3 times plus once with `GOFLAGS=-race`.
5. Update section 3 and 4 here, the `ledger_rows` / `cache_ledger_rows` and UNACCOUNTED baselines in
   `scripts/scoreboard.sh`, and SKILL.md Phase 0. Give the case a `cacheExp` (or "" when its fault needs the
   Postgres edge) and run it in both modes. This is a C1 change (change-control).

<!-- evidence-check: on -->

Planned for ADR-001 (step 4a, `delivery-options.md` s.6): the retry topic in the kfake topic list, the
RETRIED / RETRY_PARKED outcomes, repeatable DB/Redis faults, cases 11-14 (`delivery-options.md` s.0.6).
Folding cases 15-16 into the default run is a baseline change (rows, UNACCOUNTED and the "commit every
record" overlay number move) that other skills quote: do it in one coordinated C1 PR with those skills.
Ideas not built yet (each is a hypothesis to test, UNVERIFIED): commit failure via
`ControlKey(OffsetCommit)`; crash after produce before commit (cancel inside a `Wrap`); 2 partitions with the
fault on one; in-advance produce failure (expect ENRICHED+DLQ); a CDC update or a failed snapshot table in
cache mode (needs the CDC consumers on kfake, as `kfake-run.sh cdc-brokers` does).

## 6. Troubleshooting the probes (rare cases; the common ones are in SKILL.md Phase 0)

| You see | It means | Do |
|---|---|---|
| exit 2, `building accounting-probe failed` | your events-processor tree does not compile, or no CGO env | fix the build; `build-and-env` for `-lexpression_go` |
| exit 2, `missing diagnostics-and-tooling/scripts/kfake-harness` | the sibling harness moved (this module depends on it by relative path) | `diagnostics-and-tooling`; fix the `replace` in `scripts/go.mod` |
| `--check` prints different franz-go versions | events-processor bumped franz-go | re-pin kfake per `diagnostics-and-tooling` (kfake technique, version trap), then `go mod tidy` in `scripts/` |
| coverage of `ProcessEvents` > 0 | someone added a test | good: update the baseline in `scripts/scoreboard.sh` (same PR) |
| leftover `acct_probe_*` databases | the probe was killed hard | `psql "${DATABASE_URL:-postgres://lago:lago@localhost:5432/lago}" -Atc "select datname from pg_database where datname like 'acct_probe%'"`, drop them |

## 7. Second gate: the kit's corrected profile (runs next to `scoreboard.sh`)

The re-implementation kit grades any events-processor BINARY black-box against ADR-001 and the decided rebuild
decisions: `events-processor-spec` conformance suite, assertions tagged with `reimplementation-kit` RBD ids. It
sees what this probe cannot (the real binary's start-up, a 200-record burst against a connection limit, CDC rows,
25 value literals) and this probe sees what it cannot (per-offset outcome classes, `-overlay` candidates, the
cache-mode ledger). Every W1-W3 and W6 PR runs both; a Phase 1 (signals) or W6-0 PR leaves both lists unchanged.

Commands (repo root; needs Go >= 1.25 for the runner build, `psql`, a Postgres role with CREATEDB and CREATEROLE;
the runner creates the cluster role `epconf_iut` and one scratch database per scenario, and writes only under
`$LAGO_SKILLS_CACHE` or `--keep`):
```bash
source .claude/skills/build-and-env/scripts/ep-env.sh                      # CGO env; LD_LIBRARY_PATH for the binary
b=$(mktemp -d) && (cd events-processor && go build -o "$b/ep" .)           # the candidate = your working tree
K=.claude/skills/events-processor-spec/scripts/run-suite.sh
bash "$K" --impl-cmd "$b/ep" --impl-env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" --mode db --profile corrected
bash "$K" --impl-cmd "$b/ep" --impl-env LD_LIBRARY_PATH="$LD_LIBRARY_PATH" --mode cache --profile corrected
# today (tree 83e012866f29, re-run 2026-10-02, ~90 s per mode), last lines:
#   run-suite: scenarios=31 failing=12 unruled=1 skipped=4 mode=db profile=corrected ... exit=3
#   run-suite: scenarios=27 failing=7 unruled=2 skipped=8 mode=cache profile=corrected ... exit=3
```
`--only 'EPC-(07|08)'` narrows a run; `--keep DIR` keeps each scenario's `.out` file with the failed assertions
(`FAIL <kind> <tx>: ... RBD-n decided`). Exit 3 = some decided assertion failed; UNRULED (only `proposed`
assertions failed) never fails a run.

Corrected pass list per phase (today = the reference, 2026-10-02; "DB only" scenarios are skipped in cache mode):

<!-- evidence-check: off gate table (TARGET per phase); "today" column = the two run-suite runs above -->
| Phase (workstream) | Must turn PASS (`reimplementation-kit` RBD) | Today DB / cache | Ledger twin |
|---|---|---|---|
| 2 value (W2) | EPC-07: 25 `value` literals (RBD-13) | FAIL / FAIL | value corpus (`value-and-time.md` s.2) |
| 3 time (W3) | EPC-04 assertions `sm_ms_exact_str`, `sm_ms_exact_num`, `sm_term_after` (RBD-15) and `sm_ts_offset` (RBD-16) | FAIL / FAIL | `value-corpus -mode time` |
| 4 delivery (W1), step 4c | EPC-10, EPC-14, EPC-15 (RBD-1), EPC-16 (RBD-8), EPC-17 (RBD-9), EPC-18 (RBD-6), EPC-19 (RBD-5), EPC-30 (RBD-10) | all FAIL / EPC-17, 18, 19 FAIL (the rest DB only) | cases 1, 8, 6, 7, 15 |
| 4 delivery (W1), steps 4c-4d | EPC-08: `NaN` / `Inf` on the DLQ with a cause; EPC-09: undecodable records with a cause (RBD-4) | FAIL / FAIL | cases 16, 4, 5 |
| 7 cache (W6-4) | EPC-04 assertion `sm_started_ms` (RBD-17) | PASS / FAIL | smoke `tx_H` (`memory-cache-w6.md` s.4) |
| 7 cache (W6-1) | EPC-31 (RBD-21, proposed) | n/a / UNRULED | smoke `cache-cdc` `tx_A`; a gate once OPEN DECISION OD-1b and RBD-21 are ruled |
| every PR: stay PASS | EPC-11, 12, 13 (RBD-1..3, DB only), EPC-21 (RBD-12), EPC-26..29 (RBD-23) | PASS / PASS | cases 2, 3 |
| advisory | EPC-20 (RBD-7, proposed) | UNRULED / UNRULED | none (in-advance produce failure: not built) |
<!-- evidence-check: on -->

Campaign TARGET for this gate: `failing=0` in both modes, UNRULED only for proposed rulings. Known blocker
(kit issue, reported 2026-10-02): in cache mode `sm_ts_offset` fails for a different reason, the subscription it
expects (terminated 2025-03-01) is outside the cache's one-month snapshot window (`events-processor-spec` rule
EP-H7, RBD-20 proposed), so EPC-04 cannot pass in cache mode on W3 + W6-4 alone; the per-mode offset rule
itself is executed by unit vectors ep.match_subscription.016 / .017 (`architecture-contract` memory-cache.md
§1a). The EPC-30 count is timing-dependent (164 of 201 lost in this run; the kit saw 85-170 in nine runs).
