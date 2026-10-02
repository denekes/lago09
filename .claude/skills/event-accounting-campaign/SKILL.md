---
name: event-accounting-campaign
description: "Decision-gated campaign (W1-W6) to FIX event accounting in the Go events-processor (DB and memory-cache mode): every raw-topic record ends with a faithful value, on the DLQ with a cause, or in a bounded retry. ADR-001 delivery contract, ClickHouse decimal migration, kfake fault-matrix ledger, value corpus, scoreboard.sh. Use when planning or reviewing a change to commit/retry/DLQ behaviour, value or time derivation, or the memory cache: \"fix lost events\", \"retry topic\", \"12 h horizon\", Debezium columns. Not for as-is behaviour (use architecture-contract) or triage (use debugging-playbook)."
---
# Event accounting campaign (W1-W6)

Make every record of the raw events topic **accountable** (it ends on `events_enriched`, on
`events_dead_letter` with a cause, or in a bounded retry) and **faithful** (the enriched `value` and time
are what Rails would compute), in the mode production runs. The plan: measure in both data-source modes, add
signals, fix value (including the ClickHouse column) and time, implement the delivery contract ADR-001, harden
the memory cache (W6), put the harness in CI, verify in production. Owner decisions (`change-control` §9):
production runs memory-cache mode (DECIDED OD-1 (owner, 2026-10-02)); ADR-001 is the delivery contract
(DECIDED OD-2 (owner, 2026-10-02), delegated); a ClickHouse schema change is allowed
(DECIDED OD-3 (owner, 2026-10-02)); paired PRs follow dependencies (DECIDED OD-4 (owner, 2026-10-02));
`ep-test.sh` is an accepted gate (DECIDED OD-5 (owner, 2026-10-02)). Every fix is a CANDIDATE until merged with evidence. Code facts as
of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only commits on top
(`git log --oneline 5308258..HEAD -- events-processor` prints nothing). lago-api at the pin `591ae90`
(2026-09-08). Verified 2026-10-01; decisions, cache-mode and ClickHouse measurements 2026-10-02.

## When to use / when NOT to use

Use it when:
- you are about to change commit, retry, DLQ or skip behaviour (`config/kafka/consumer.go`, the disposition
  block of `processors/events_processor/processor.go`, `event_producer_service.go`): implement ADR-001;
- you touch how `value` or time is derived (`enrichment_service.go`, `models/event.go`, `utils/time.go`) or
  the ClickHouse `decimal_value` column (lago-api);
- you change the memory cache (`events-processor/cache/*.go`, `extra/debezium_config.json`): W6;
- someone reports missing usage, events billed 0, unique counts too high, connector events vanishing,
  in-advance charges missing after a charge edit;
- you need today's numbers (LOST, corpus mismatches, ToTime, coverage) in DB and cache mode.

Do NOT use it for:
- how the pipeline works today, invariants, weak-point list (memory-cache WP6-WP10) -> `architecture-contract`;
- the Go vs Rails/ClickHouse contract table and its probes -> `rails-go-parity`;
- kfake/miniredis/scratch-PG building blocks, smoke runs, clickhouse-local -> `diagnostics-and-tooling`;
- triaging a live incident from logs or DLQ codes -> `debugging-playbook`;
- change classes, non-negotiables N1-N13, contracts K1-K10, the owner-decision register -> `change-control`;
- test conventions, baselines, CI shape -> `validation-and-qa`; CGO toolchain, Postgres -> `build-and-env`;
- incident history of the commit path -> `failure-archaeology`; release reliability -> `release-and-images`.

## Terms

| Term | Meaning here |
|---|---|
| raw record | one Kafka record on `LAGO_KAFKA_RAW_EVENTS_TOPIC` (dev `events-raw`) |
| accounted | the record is ENRICHED, DLQ, REDELIVERED (bounded retry) or PENDING (bounded); ADR-001 adds RETRIED and RETRY_PARKED |
| UNACCOUNTED | LOST + SKIPPED_RETRY + SENTRY_ONLY; definitions in `reference/ledger-and-matrix.md` s.2 |
| withheld | `ProcessEvents` left the record out of its return value, i.e. "retry me" (`processor.go:74-78`) |
| committed past | the group's committed offset is greater than the record's offset: it will never be re-polled |
| ledger / case | one `accounting-probe` row per raw offset / one fault scenario of the matrix |
| DB mode / cache mode | data source of enrichment: `models.ApiStore` on Postgres (dev runs this) / the badger memory cache fed by a snapshot + Debezium CDC (`LAGO_USE_MEMORY_CACHE=true`): PRODUCTION runs cache mode (DECIDED OD-1 (owner, 2026-10-02)); every gate runs in both |
| SYSTEMIC / TRANSIENT / PERMANENT | the ADR-001 failure classes: dependency down / one record's retryable error / non-retryable (`reference/delivery-options.md` s.0.3) |
| retry topic | `<raw>-retry` (name CANDIDATE): ADR-001's delayed retry for TRANSIENT failures, then DLQ |
| faithful value | the `value` string Rails' own enrichment would produce (`$API/app/services/events/enrich_service.rb:59-60`) |
| baseline / target | the Phase-0 measurement (2026-10-01; cache rows 2026-10-02) / the campaign goal; targets are NOT current state |
| OD-n | an owner decision in `change-control` §9: OD-1 to OD-5 are each `DECIDED OD-n (owner, 2026-10-02)`; OPEN DECISION OD-1b (owner) = the production CDC config; DEFAULT APPLIED OD-20 = W6 lives here; any other bare `OD-n` here (OD-6, OD-8) reads as OPEN DECISION OD-n (owner) |
| ADR-001 | the delivery contract, ACCEPTED (delegated by owner 2026-10-02): `reference/delivery-options.md` s.0 |
| `$API` | pinned lago-api checkout: `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)` |
| BM, subscription, pay-in-advance | see `domain-reference` |

## The problem in numbers (Phase-0 baseline)

```
$ .claude/skills/event-accounting-campaign/scripts/scoreboard.sh
metric                                   today      baseline   target     status
---------------------------------------- ---------- ---------- ---------- ------
unaccounted_records                      5          5          le 0       baseline
lost                                     1          1          le 0       baseline
skipped_retry                            1          1          le 0       baseline
sentry_only                              3          3          le 0       baseline
ledger_rows                              36         36         eq 36      baseline, TARGET MET
cache_unaccounted_records                4          4          le 0       baseline
cache_ledger_rows                        26         26         eq 26      baseline, TARGET MET
corpus_value_mismatches                  13         13         le 0       baseline
corpus_go_decimal_mismatches             2          2          le 0       baseline
corpus_end_to_end_decimal_mismatches     6          6          le 0       baseline
totime_mismatches_per_1000               496        496        le 0       baseline
rfc3339_normalised_utc_ms                false      false      eq true    baseline
cov_ProcessEvents_pct                    0.0        0.0        gt 0.0     baseline
cov_processRecordsAndCommit_pct          0.0        0.0        gt 0.0     baseline
cov_total_tested_pkgs_pct                47.4       47.4       gt 47.4    baseline
scoreboard: moved=0 unmeasured=0 targets_missed=13 (baseline 2026-10-01, cache_* 2026-10-02; targets are campaign TARGETS, not current state)
```
(~20-25 s warm, depending on host load; exit 0. `cache_*` rows = the ledger in memory-cache mode, added
2026-10-02.) What the unaccounted records are (fault rows of the ledger, DB mode / cache mode):

| # | Case (`-case` name) | What happens today (DB / cache) | Code |
|---|---|---|---|
| 1 | transient DB error, then more traffic (`retryable-then-later-batch`) | **LOST** / no cache counterpart: withheld, a later batch commits past it | `processor.go:74-78`, `consumer.go:89-104` |
| 8 | transient Redis error, then more traffic (`redis-flag-then-later-batch`) | **SKIPPED_RETRY** / same: enriched + in-advance produced, refresh flag never retried | `processor.go:110-131` |
| 4 | invalid JSON (`unmarshal-bad-json`) | **SENTRY_ONLY** / same: committed, no DLQ | `processor.go:50-59` |
| 5 | connector event with numeric `precise_total_amount_cents` (`numeric-precise-total-amount-cents`) | **SENTRY_ONLY** / same: unmarshal error (Go declares a string) | `models/event.go:18`, `connectors/http.yml:32-36` |
| 7 | non-retryable failure while the DLQ topic rejects (`dlq-produce-failure`) | **SENTRY_ONLY** / same: committed after a failed DLQ produce | `event_producer_service.go:70-73` |

Accounted today (controls and DLQ paths): 2 `retryable-only-batch`, 3 `retryable-stale-12h`,
6 `enriched-produce-failure`, 9 `redis-flag-only-batch`, 10 `missing-bm-nonretryable`. Case numbers are the
rows of `reference/ledger-and-matrix.md` s.3; names as printed by `run.sh accounting-probe -list`.
Paths are under `events-processor/` (processor files in `processors/events_processor/`) unless they start
with `connectors/`. Cache-mode defects the ledger does not see (Debezium update zeroes `pay_in_advance`,
boundary millisecond, empty snapshot DLQs everything; `smoke-binary.sh`, 2026-10-02): `reference/memory-cache-w6.md` s.1.

## Phase map

<!-- evidence-check: off phase routing table; evidence sits in each phase section below -->

| Phase | Workstream | Class (change-control) | Blocks on | Exit gate (scoreboard unless stated) |
|---|---|---|---|---|
| 0 Measure | all | C1 (read-only) | nothing | table == baseline in both modes, or every moved metric explained |
| 1 Signals | W5 | C3 (change-control C3/C4 precedence rule; C4 if control flow changes) | Phase 0 | `--check-baseline` exit 0 (`moved=0 unmeasured=0`) + disposition lines in every case, both modes |
| 2 Value fidelity | W2 | C3 + C4 (`value` is a cross-repo contract, change-control N6; a new DLQ cause is C4) | Phase 1; paired lago-api PR for the CH column (DECIDED OD-3 (owner, 2026-10-02), DECIDED OD-4 (owner, 2026-10-02)) | value metrics at target; `ch-schema-candidate.sh` `cand_mismatches=0` |
| 3 Time semantics | W3 | C3 (C4 if the enriched `timestamp` payload format changes) | Phase 0 (coordinate with Phase 2: see Phase 3 entry) | `totime 0`, `rfc3339 true`, nothing else moved |
| 4 Delivery semantics | W1 | C4 (+ C6 topic list) + change-control N7 | Phase 1; Phase 5a; ADR-001 (DECIDED OD-2 (owner, 2026-10-02)) | 0 LOST/UNACCOUNTED in both ledgers (steps 4c + 4d) |
| 5 Parity harness + CI | W4 | C1 + C5 (go.mod, workflow) | Phase 0 | coverage targets; ledger runs on PRs in both modes |
| 6 Rollout + prod verification | all | per change | each merge; OPEN DECISION OD-1b (owner), OPEN DECISION OD-8 (owner) | reconciliation query does not grow |
| 7 Memory-cache correctness | W6 (DEFAULT APPLIED OD-20) | C1 / C3 / C4 per sub-phase | Phase 0; OD-1b sets the urgency | per sub-phase (W6-0..W6-5) |

<!-- evidence-check: on -->

Phase 3 needs only Phase 0 and Phase 2 needs Phase 1, so they can run in parallel; Phase 7 runs in
parallel with all of them (it does not change delivery). Phase 5a (the in-repo kfake test) must land
before or inside the Phase 4 step 4c PR (change-control N7).

## Phase 0 - Measure (C1, safe, read-only)

Entry: repo root (`cd "$(git rev-parse --show-toplevel)"`), Go, cargo for the first `ep-env.sh` run,
Ruby >= 3.3 on PATH only for `-ruby` (3.3.6 verified), and Postgres with a login role that has CREATEDB
(if not: `build-and-env`):
```bash
pg_isready -d "${DATABASE_URL:-postgres://lago:lago@localhost:5432/lago}"    # accepting connections
psql "${DATABASE_URL:-postgres://lago:lago@localhost:5432/lago}" -XAtc \
  'select current_user, rolcreatedb or rolsuper from pg_roles where rolname=current_user'   # <role>|t (pg_isready does not check login)
```

```bash
S=.claude/skills/event-accounting-campaign/scripts; D=.claude/skills/diagnostics-and-tooling/scripts
# Do not run this block under `set -e`: accounting-probe exits 5 / 4 ON PURPOSE (exit = UNACCOUNTED rows; 100 = setup error).
$S/run.sh --check                   # expect: franz-go: events-processor=v1.20.5 probe-module=v1.20.5 / run.sh: check OK
$S/scoreboard.sh                    # expect: the baseline table above, exit 0
$S/run.sh accounting-probe          # DB mode; last lines TOTALS ... UNACCOUNTED=5, elapsed ~2.5s, exit 5 (= expected)
$S/run.sh accounting-probe -mode cache   # production's mode; TOTALS rows=26 ... UNACCOUNTED=4, elapsed ~1.7s, exit 4
$D/smoke-binary.sh cache cache-cdc  # real binary in cache mode; both "EXPECTED-TODAY: MATCH", exit 0, ~10 s
$S/run.sh value-corpus -ruby -ch-bin "$($D/ch-local.sh --path)"
                                    # expect: ruby 27/27, ch cross-check 27/27, SUMMARY ... value_mismatches=13 ...
$S/ch-schema-candidate.sh -q        # SUMMARY ... today_corpus_mismatches=6 cand_mismatches=0 cand_policy_null=3 ...
```
`ch-local.sh --path` (`diagnostics-and-tooling`) prints the cached ClickHouse binary and downloads it once
into `$LAGO_SKILLS_CACHE/clickhouse/<version>/`; the cross-check line names the version it resolved
(26.2.19.43 on 2026-10-02). Offline or without Ruby, drop `-ch-bin` / `-ruby`: the SUMMARY numbers and
`scoreboard.sh` need neither, you only lose the two cross-checks. Expected full outputs:
`reference/ledger-and-matrix.md` s.4 (both modes), `reference/value-and-time.md` s.2-3 and s.6.2,
`reference/memory-cache-w6.md` s.4 (cache smoke, CDC brokers, memory, empty snapshot). The command blocks of
later phases reuse `S` and `D`.

Prove one symptom instead of the whole baseline (a support case, a review):
```bash
$S/run.sh accounting-probe -list                                         # the 10 case names (-mode cache -list: the 7 with a cache counterpart)
$S/run.sh accounting-probe -case numeric-precise-total-amount-cents      # one SENTRY_ONLY row, UNACCOUNTED=1, exit 1 (= expected)
$S/run.sh value-corpus -mode value -value 2000000000000                  # one customer value: go_value 2e+12, ch 0, FORMAT+CH_ZERO
```
The probe's exit code is the UNACCOUNTED count, so 1 is the expected result for one fault row. `-value`
(repeatable; JSON text, `MISSING` = absent property) derives its want columns with Ruby, so it needs Ruby.

If you see X instead, branch to Y (build, pin, coverage and leftover-database cases: `reference/ledger-and-matrix.md` s.6):

| You see | It means | Do |
|---|---|---|
| probe exit 100 + `postgres unreachable` (or `CREATE DATABASE … role needs CREATEDB`); scoreboard exit 2 + `NOT MEASURED` rows | Postgres down or no CREATEDB (DB mode only; `-mode cache` needs no Postgres) | `build-and-env` (start PG), re-run; `--no-accounting --no-coverage` gives the corpus and cache-ledger metrics alone (not a gate: with `--check-baseline` it exits 5, `unmeasured=8`) |
| probe exit 100 + `unknown case(s) for -mode cache` (`scripts/accounting-probe/main.go:737`) | cases 1-3 inject at the Postgres edge: DB mode only | drop `-mode cache` for them |
| value-corpus exit 2 + `setup error: ruby: exec: "ruby": executable file not found` or `clickhouse local: fork/exec …: no such file or directory` | no Ruby on PATH / wrong `-ch-bin` path | install Ruby >= 3.3 or drop `-ruby`; use `ch-local.sh --path` or drop `-ch-bin` (`scoreboard.sh` uses neither) |
| UNACCOUNTED or a fault row differs on unchanged code | flake or a behaviour change you did not expect | run 3 times; if stable, `git log --oneline 5308258..HEAD -- events-processor`, compare per case with `reference/ledger-and-matrix.md` s.3-4 |
| `smoke-binary.sh cache-cdc` differs on `tx_A` | the Debezium column list or the CDC row shape changed | expected only with W6-1; otherwise a regression (`reference/memory-cache-w6.md`) |
| `NOTE: sentinel not committed within timeout` (`scripts/accounting-probe/main.go:553`) | the partition is blocked (PENDING) | never expected: today nothing blocks; after step 4c it means a SYSTEMIC pause that did not resume (a bug) |
| `corpus_value_mismatches` != 13 or `totime` != 496 | value/time code changed | the PR must carry Phase 2/3 evidence and update `rails-go-parity` rows |

Exit gate: the table equals the baseline, or each moved metric is tied to a commit. Evidence: the
scoreboard table and both ledger `TOTALS` lines go into the evidence block of the first campaign PR
(change-control N13). Rollback: none (writes only to mktemp dirs and scratch databases it drops;
`git status --porcelain --ignored -- events-processor` stays empty).

Next (decision status per phase: the Phase map "Blocks on" column; register `change-control` §9): Phases 1,
3 and 5a/5c need no decision; 2, 4 and 7 have theirs (DECIDED OD-3 (owner, 2026-10-02) and
DECIDED OD-4 (owner, 2026-10-02); DECIDED OD-2 (owner, 2026-10-02); DEFAULT APPLIED OD-20).
Optional, owner only: the production reconciliation query (`reference/observability-and-production.md` s.3)
turns the ledger into a production number: the baseline that ADR-001 must drive to 0. Use its
connector-aware WHERE clause: ClickHouse stores a connector's integer `ingested_at` as a 1970 date
(VERIFIED on `clickhouse local`), so the plain `ingested_at` window misses every connector event, case 5 included.

## Phase 1 - Signals for every disposition (W5, C3)

Entry: Phase 0 done. Today a withheld record and a DLQ'd record log the same line (`processor.go:64-68`), and
a later commit that skips a withheld record logs nothing (`consumer.go:98` only fires when the first record
fails). There is no metrics endpoint (`grep -rn ListenAndServe --include=*.go events-processor` = 0 hits).

CANDIDATE change: one disposition per record (`enriched`, `dlq`, `withheld`, `undecodable`,
`dlq_push_failed`, `enriched_push_failed`) and one batch line per commit decision; fields and rules in
`reference/observability-and-production.md` s.2 (ADR-001's later signals: s.5). No event JSON in logs
(`security-and-supply-chain`).

Class: C3 under change-control's C3/C4 precedence rule (`change-control` change-classes.md §1 step 6): the
touched paths (`processor.go:50-88`, `consumer.go`, `event_producer_service.go`) are on its C4 path row, but
an observability-only edit is C3 when (a) the diff changes no control flow, return value,
`CommitRecords`/DLQ/produce call or payload field, and (b) `scoreboard.sh --check-baseline` prints
`moved=0 unmeasured=0` (both ledgers). Paste both and say which rule applied; otherwise C4 (Phase 5a first).

Commands and expected after the change:
```bash
.claude/skills/build-and-env/scripts/ep-test.sh                    # ok x6 (accepted gate: DECIDED OD-5 (owner, 2026-10-02)); full N9 pre-PR gate: change-control
$S/scoreboard.sh --check-baseline                                  # exit 0, "moved=0 unmeasured=0": nothing but signals changed
$S/run.sh accounting-probe -v 2>&1 | grep -c disposition           # today 0; after: > 0, case 1 shows "withheld" for offset 0
$S/run.sh accounting-probe -mode cache -v 2>&1 | grep -c disposition   # today 0; after: > 0
```
Exit gate: moved=0; every ledger case shows its disposition in both modes (table in the reference); a unit
test per disposition (`validation-and-qa` for conventions). Rollback: revert the PR (no data effect).

## Phase 2 - Value fidelity (W2, C3 + C4) including the ClickHouse column

Entry: Phase 1 merged; run `rails-go-parity`'s parity check on the base branch first. The `value` string is
read by ClickHouse and lago-api, and the ClickHouse DDL lives in lago-api, so this is a cross-repo change
with a paired lago-api PR (change-control N6; DECIDED OD-4 (owner, 2026-10-02): lago-api depends on it).

Problem (corpus, 27 rows): 13 string mismatches (`1e+06`, `<nil>`, `1e-07`…), 2 decimal mismatches in Go
itself (integers > 2^53 through `float64`), 6 rows billed 0 end to end: all have |x| >= 1e12, which
`decimal_value Decimal(38,26)` cannot hold (`$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32`).
4 of those 6 (`ch_zeroed=4`) are numerically exact in Go (`1e+12` equals 1000000000000) and are zeroed by
the column alone; the other 2 are also wrong in Go (float64 precision).

CANDIDATE change (details, trap and rollout note: `reference/value-and-time.md` s.4-6):
1. exact numbers inside `properties` only (NOT a global `UseNumber`: it breaks numeric timestamps, VERIFIED in `reference/value-and-time.md` s.4);
2. `value` = plain decimal, Ruby-equivalent: integers exact, floats shortest round-trip, missing/null -> `"0"` (CANDIDATE design: `reference/value-and-time.md` s.5);
3. accept number or string for `precise_total_amount_cents` (`models/event.go:18`; ledger case 5); there is no
   value-preserving workaround through the connectors (they turn any non-number into `"0"`, `connectors/http.yml:32-36`);
4. ClickHouse migration track (DECIDED OD-3 (owner, 2026-10-02); design CANDIDATE, `reference/value-and-time.md`
   s.6): column `Nullable(Decimal(40, 15))` = Postgres `numeric(40,15)` (`$API/db/structure.sql:3059`) with
   DEFAULT `if(abs(toDecimal256OrNull(value, 18)) < 1e25, round(toDecimal256OrNull(value, 18), 15), NULL)`
   (ClickHouse does not enforce the 40 digits; the guard digits make rounding match Postgres); NULL or a DLQ
   instead of 0 (Go DLQs |x| >= 1e25 as `value_out_of_range`, a new DLQ cause = C4; NULL vs `ifNull(…, 0)` for
   the 3 non-numeric corpus rows is settled in the paired PR); both tables (`events_enriched`,
   `events_enriched_expanded`) and the Cloud DDL, a second schema edited in place (`$API/AGENTS.md:176`);
   history re-derived from the stored `value` by mutation, except the integers > 2^53 Go already rounded
   (re-enrich, or read `events_raw.properties`); additive first: new column, backfill, reader switch, drop in
   cleanup (change-control §6).

```bash
$S/run.sh value-corpus -ruby          # target: value_mismatches=0 go_decimal_mismatches=0; unique_count pair "same unique: true"
$S/ch-schema-candidate.sh -q          # today and target: cand_mismatches=0 pg_reference=postgres (the proof the column is right)
$S/run.sh accounting-probe -case numeric-precise-total-amount-cents   # target fault row ENRICHED (item 3); same with -mode cache
$S/scoreboard.sh                      # only corpus metrics (and sentry_only/unaccounted in both modes if item 3) moved
```
Expected today from `ch-schema-candidate.sh` (2026-10-02, ClickHouse 26.2.19.43, PostgreSQL 16.14):
`SUMMARY corpus_rows=27 edge_rows=6 today_corpus_mismatches=6 cand_mismatches=0 cand_policy_null=3
rederive_needs_re_enrichment=2 rederive_policy_null=3 pg_reference=postgres`.
Branch: `end_to_end_decimal_mismatches` stays 6 after items 1-2 -> expected until the lago-api column lands
and this skill's CH emulation follows it (`scripts/value-corpus/main.go:117`, `reference/value-and-time.md`
s.6.5); then 0, or the 3 policy rows if NULL is chosen (they need an exception marker that both
`value-corpus/main.go` and `rails_semantics.rb` honour: not built, CANDIDATE, C1 change to this skill). Any
other row moved -> stop, explain it.
Exit gate: value metrics at target or approved exceptions; `rails-go-parity` value rows (P10-P13: closing
a DIVERGE row triggers change-control's cross-repo protocol) and its EXPECTED block updated in the same PR;
change-control N9 gate; before/after corpus in the PR (change-control C3). Rollback: revert; rows written
meanwhile keep the new format (unique_count transition: write it in the PR); the ClickHouse column is
additive until cleanup.

## Phase 3 - Time semantics (W3, C3; C4 if the enriched `timestamp` payload format changes)

Entry: Phase 0. Coordinate with Phase 2: if `json.Number` reaches `Timestamp`, both time functions need a
`json.Number` case in the same change.

Problem: `utils.ToTime` float math puts 496/1000 ms-precision strings 1 ms early (`utils/time.go:20-23,48`);
the RFC3339 branch returns un-normalised times (`:25-29`). Rails sends `to_f.to_s` timestamps
(`$API/app/services/events/kafka_producer_service.rb:43`) and matches with `date_trunc('millisecond', …)`
(`$API/app/services/events/post_process_service.rb:50-53`). Parsing is a MATCH, but on Ruby 3.3.6
`to_f.to_s` itself puts 129/1000 ms values 1 ms early after millisecond truncation (CANDIDATE drift,
`rails-go-parity` P22, `domain-reference` MC17; lago-api pins Ruby 4.0.6, UNVERIFIED there).
`utils/time_test.go:31-35` uses `.344`, a value that round-trips, so the unit tests pass today. Cache mode
compares subscription bounds at full precision (W6-4), so fix both together when the boundary moves.

CANDIDATE change: string fraction parsed without floats; RFC3339 -> `.UTC().Truncate(time.Millisecond)`
(`reference/value-and-time.md` s.5).
```bash
$S/run.sh value-corpus -mode time     # target: "0/1000 land on a different millisecond", "normalised to UTC+ms: true"
$S/scoreboard.sh --check-baseline     # exit 3, moved=2 (the two time metrics) and nothing else
```
Then run `rails-go-parity`'s time and subscription probes: its scenarios B (float ms rounding) and C (RFC3339
offset) are the rows that should move. Exit gate: time metrics at target, no other metric moved, parity rows
updated. Rollback: revert (subscription attribution of offset/boundary events reverts too).

## Phase 4 - Delivery semantics (W1, C4): implement ADR-001

The choice is made: ADR-001 (DECIDED OD-2 (owner, 2026-10-02), delegated; `reference/delivery-options.md`
s.0, with context, industry practice, decision points 1-6, rejected options, consequences and topic impact).
In short: SYSTEMIC failures pause the partition and back off; TRANSIENT failures get a small in-place retry,
then a retry topic, then the DLQ after 5 attempts or 12 h; PERMANENT failures go to the DLQ at once (unmarshal
errors with the raw bytes); commit offset N only when every record <= N has a durable disposition; enriched
first, then in-advance and the Redis flag; downstream idempotency required. The 2026-10-01 ranked menu is kept
as history with the chosen parts marked (`reference/delivery-options.md` s.3). An implementation that
deviates from ADR-001 needs the owner before review.

Entry: Phase 1 merged; the in-repo kfake test (Phase 5a) exists or is in the step 4c PR (change-control N7).

<!-- evidence-check: off step table (plan); details, gates and constraints in reference/delivery-options.md s.6 -->
| Step | Change | Class | Gate (expected) |
|---|---|---|---|
| 4a | probe sees ADR-001: retry topic in kfake, outcomes RETRIED / RETRY_PARKED, repeatable faults, cases 11-14 with today's outcome | C1 (this skill + `diagnostics-and-tooling` harness) | `--check-baseline`: only the ledger rows the new cases add moved, explained; baselines updated in the PR |
| 4b | retry topic `events-raw-retry` (name CANDIDATE) in `docker-compose.dev.yml:398-405` + env var in `.env.development.default:78-86`; paired lago-helm-charts PR; production topic by owner/ops; no lago-api PR (no lago-api reader) | C4 + C6 | no behaviour change: `--check-baseline` exit 0 |
| 4c | the Go contract: classes, in-place budget, retry producer + consumer, DLQ after N / 12 h, SYSTEMIC pause + backoff, commit rule, failed DLQ/retry produce = SYSTEMIC, side-effect order, counters | C4 + N7 | table below |
| 4d | unmarshal failures -> DLQ with raw bytes + parse error (K6 payload: paired lago-api PR, lago-api ships first) | C4 | case 4 (and 5 unless Phase 2 item 3 merged) DLQ; `unaccounted_records=0`, `cache_unaccounted_records=0` |
| 4e | operator-gated DLQ -> raw replay tool with a replay header, after downstream dedup is confirmed | C4 | a replayed DLQ record ends ENRICHED once downstream of dedup |
<!-- evidence-check: on -->

Step 4c gates (commands from the repo root; full list and implementation constraints:
`reference/delivery-options.md` s.6):
```bash
$S/run.sh accounting-probe                  # x3 + once with GOFLAGS=-race: LOST=0 SKIPPED_RETRY=0 PENDING=0 SENTRY_ONLY=2 (cases 4, 5; 1 if Phase 2 item 3 is in), exit 2
$S/run.sh accounting-probe -mode cache      # x3 + race: same rows, SENTRY_ONLY=2, exit 2
$S/scoreboard.sh --check-baseline           # exit 3; moved exactly: unaccounted 5->2, lost 1->0, skipped_retry 1->0, sentry_only 3->2, cache_unaccounted 4->2
.claude/skills/build-and-env/scripts/ep-test.sh -race -count=1 ./config/kafka/... ./processors/...   # in-repo kfake test ok, incl. revoke during a pause
$D/kfake-run.sh happy-path -n 50000 -partitions 4    # cache mode (default) and -store db, before/after: PASS; >10 % slower needs an explanation (CANDIDATE threshold)
```
Expected ledger outcome after step 4d, both modes (per-case table: `reference/delivery-options.md` s.0.6):
every fault row ENRICHED, RETRIED -> ENRICHED, or DLQ with a cause; case 6 DLQ with `in_adv=0`; cases 8 and
9 ENRICHED with `enriched=1 in_adv=1`; `LOST=0 SKIPPED_RETRY=0 SENTRY_ONLY=0 PENDING=0 UNACCOUNTED=0`.

Test design (the N7 test, Phase 5a): kfake with raw + retry topics, the REAL consumer group with a scripted
`ProcessRecords` (commit rule, pause/resume, revoke during a pause) and real producers with DB, Redis and
produce faults over the failure matrix in both modes; injected clock, no sleeps. Implementation constraints
(`BlockRebalanceOnPoll` `consumer.go:245`, unbuffered dispatch `:122,195`, revokes waiting on the partition
goroutine `:132-150`): `reference/delivery-options.md` s.2 and s.6. Observability counters:
`reference/observability-and-production.md` s.5.

Review a candidate (yours or someone else's PR) without editing the repo (change-control N10): build it
through a `go build -overlay` map; `git status --porcelain -- events-processor` stays empty.
```bash
d=$(mktemp -d); cp events-processor/config/kafka/consumer.go "$d/"      # then edit "$d/consumer.go"
printf '{"Replace":{"%s":"%s"}}\n' "$PWD/events-processor/config/kafka/consumer.go" "$d/consumer.go" >"$d/overlay.json"
GOFLAGS=-overlay="$d/overlay.json" $S/run.sh accounting-probe   # "commit every record": UNACCOUNTED=7, exit 7
```
Verified 2026-10-01 for "commit every record" (the `findMaxCommitableRecord` branch made unreachable):
`REDELIVERED=0 LOST=2 SKIPPED_RETRY=2 UNACCOUNTED=7`; the controls (cases 2, 9) turn LOST / SKIPPED_RETRY.
Run the same overlay with `-mode cache` too.

Exit gate: ADR-001 referenced in the PR, both ledgers and the kfake test output in the PR, change-control N9
gate. Rollback: redeploy the previous image (offsets stay compatible); drain the retry topic first (the old
binary does not read it).

## Phase 5 - Parity harness and CI (W4, C1 + C5)

1. 5a: port the ledger into an events-processor Go test (kfake as a test dependency in
   `events-processor/go.mod`: C5, pin rules change-control N3 and the kfake version trap) asserting per-case
   outcomes in DB and cache mode; this is the test change-control N7 asks for (design: Phase 4).
2. 5b: memory-cache mode ledger: built in this skill's probe (`run.sh accounting-probe -mode cache`,
   2026-10-02); 5a must carry it into the repo, plus a DB-vs-cache comparison per case.
3. 5c: corpus and `ToTime` rows as unit tests next to `enrichment_service_test.go` and `utils/time_test.go`
   (assert the targets once Phases 2/3 merged).
4. 5d: run 5a/5c in `.github/workflows/events-processor-tests.yml` (C5; actionlint via `release-and-images`).

Expected after: `cov_ProcessEvents_pct` and `cov_processRecordsAndCommit_pct` above 0,
`cov_total_tested_pkgs_pct` above 47.4 (gated definition: `validation-and-qa` baseline.sh `cover.total`); CI
fails when a ledger case regresses in either mode (prove it once on a throwaway branch). Rollback: revert.

## Phase 6 - Rollout and production verification

For every merged campaign change: canary, watch the Phase 1 signals (ADR-001 counters once step 4c is in),
Warn lines from `consumer.go:98`, DLQ rate, broker-side lag, Sentry volume, and the reconciliation query over
the canary window. Production runs memory-cache mode (DECIDED OD-1 (owner, 2026-10-02)): the cache-mode
evidence is the one that counts. Still open: the production CDC config (OPEN DECISION OD-1b (owner)) and
OPEN DECISION OD-8 (owner) (`pre_filter_events`, `lazy_charge_usage_cache`, `enriched_events_aggregation`).
Checklist and query: `reference/observability-and-production.md` s.3-5. A fix becomes VERIFIED-IN-PROD only
with that data.

## Phase 7 - Memory-cache correctness (W6; DEFAULT APPLIED OD-20)

Production runs this mode, so its defects are production defects (code-level VERIFIED; production impact
depends on OPEN DECISION OD-1b (owner): is the live Debezium column list the repo's?). Scope, measurements and
gates: `reference/memory-cache-w6.md`. As-is defects: `architecture-contract` WP6-WP10.

<!-- evidence-check: off sub-phase table (plan); measurements and evidence in reference/memory-cache-w6.md s.1 and s.4 -->
| Sub-phase | Scope | Class | Exit gate (measured today -> target) |
|---|---|---|---|
| W6-0 | measure (Phase 0 cache block, `run.sh cache-bench`, `kfake-run.sh cdc-brokers`, empty-snapshot smoke); OD-1b to the owner | C1 | outputs as `reference/memory-cache-w6.md` s.4 |
| W6-1 | Debezium `column.include.list` + `pay_in_advance`, `accepts_target_wallet`, `recurring`; guard test against every `SelectFields` | C4 (K9) | `smoke-binary.sh cache-cdc` `tx_A in_advance=no` -> `yes` |
| W6-2 | CDC clients via `kafka.NewKafkaClient` (broker split, SASL/TLS, logger); no per-start UUID groups | C4 | `cdc-brokers` `brokers=2 visible=false` -> `true`; smoke `+ 6 lago_evp_…` -> `+ 0` |
| W6-3 | snapshot errors fail start-up | C3 | empty-snapshot smoke: 7/9 DLQ `fetch_billable_metric(Key not found)` -> exit before consuming |
| W6-4 | cache subscription bounds at ms (and exact external-id match) | C3 | smoke cache `tx_H subscription_id=""` -> the DB-mode id |
| W6-5 | memory budget | C1 / C3 | `cache-bench -n 1000000` `rss_mb=792` -> not above (+10 %) unless the owner budget allows |
<!-- evidence-check: on -->

Every W6 PR runs both ledgers (`scoreboard.sh --check-baseline` `moved=0`: W6 does not change delivery) and
updates the `diagnostics-and-tooling` smoke expected files it moves, in the same PR.

## Wrong paths - fenced off

| Wrong path | Why it is wrong | Evidence | Do instead |
|---|---|---|---|
| "Just commit everything" (drop the withhold branch) | it is the `4100da0` origin design (every failure DLQ'd), which `cec0eb2` replaced on purpose; today it turns REDELIVERED into LOST: UNACCOUNTED 5 -> 7 | `cec0eb2` (#502) "avoid commit"; `processor.go:74-78`; the Phase 4 overlay run | ADR-001 (Phase 4) |
| Raise or remove the 12 h horizon | the horizon only applies to a record that is re-polled; case 1 is never re-polled. ADR-001 keeps 12 h as the retry-topic max age | ledger case 1 vs 3; `processor.go:74` | Phase 4 step 4c |
| Sleep/retry inside `processRecordsAndCommit` without a bound, or `SetOffsets` from the partition goroutine | blocks rebalances (`BlockRebalanceOnPoll`, 60 s timeout); franz-go warns against `SetOffsets` inside the poll loop | `consumer.go:203,245`; `franz-go@v1.20.5/pkg/kgo/consumer.go:665-681`; chain A (`failure-archaeology`): `cec0eb2` -> `600e195` (infinite poll loop, hotfix `b604769`) -> `9acd83e` (ING-15 segfault) | ADR-001: bounded in-place budget, retry topic, SYSTEMIC pause via `PauseFetchPartitions` (`reference/delivery-options.md` s.6 constraints) |
| Change commit/disposition code without a ledger + kfake test | 13 months of fix-after-fix ended in a production segfault | change-control N7; `9acd83e` | Phase 5a first |
| Validate a delivery, value or cache change in DB mode only | production runs memory-cache mode (DECIDED OD-1 (owner, 2026-10-02)); the CDC zeroing, the boundary millisecond and the empty-snapshot DLQ flood exist only there | `smoke-binary.sh cache-cdc` (`tx_A in_advance=no`); `events-processor/cache/subscriptions.go:60-65` | both ledgers + the cache smoke runs (Phase 0) |
| "Fix" `go.mod` `expression-go v0.1.4` -> v0.2.0 | no `expression-go/v0.2.0` tag exists; ABI identical; unrelated to accounting | change-control N3; `git ls-remote --tags https://github.com/getlago/lago-expression \| grep expression-go/` -> only `expression-go/v0.1.0` and `expression-go/v0.1.4` (plain `v0.1.0`..`v0.2.0` tags are the Rust crate; as of 2026-10-01) | leave it |
| Re-implement charge/filter resolution in Go to make enrichment "complete" | per-event Rails resolution was removed as the main DB load | change-control N8; `d9c32b6` (#797), `2fd8e8b` (#766) | Rails stays authoritative |
| Make ClickHouse parse `<nil>` | CH already turns it into 0; the defects are the Go string and unique_count | corpus rows `null`, `missing`; `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32` | Phase 2 item 2 |
| Change ClickHouse decimal precision without the corpus proof | ClickHouse does not enforce `Decimal(40,15)`'s 40 digits (it stored `1e30`), truncates where Postgres rounds, and the Cloud DDL is a second schema edited in place | `ch-schema-candidate.sh` (s.6.2 of `reference/value-and-time.md`); `$API/AGENTS.md:176`; `$API/db/structure.sql:3059` | Phase 2 item 4 with `cand_mismatches=0` (DECIDED OD-3 (owner, 2026-10-02) allows a change, not any change) |
| Global `json.Decoder.UseNumber()` | every numeric timestamp fails: `Unsupported timestamp type: json.Number` -> DLQ | `reference/value-and-time.md` s.4 (VERIFIED) | exact numbers in `properties` only |
| Change the `value` format in Go alone | cross-repo contract; unique_count splits old/new strings mid-period | change-control N6; `$API/app/services/events/stores/clickhouse/unique_count_query.rb:311` | paired lago-api PR (DECIDED OD-4 (owner, 2026-10-02): lago-api depends), period-boundary rollout |
| Count on `CleanDuplicatedService` to clean retry duplicates | no caller in `app/`, `lib/`, `config/`, `clock.rb` at `591ae90` (only its spec) | `grep -rn 'CleanDuplicatedService' "$API/app" "$API/lib" "$API/config" "$API/clock.rb" \| grep -v 'class CleanDuplicatedService'` -> no output | ADR-001 point 3: `FINAL` dedup (`clickhouse_deduplication_enabled`, default false) for CH-store orgs + `already_processed?` |
| `go test -coverprofile=… ./...` for the coverage gate | fails with `no such tool "covdata"` on packages without tests | `build-and-env`, `validation-and-qa` | `scoreboard.sh` (lists packages with tests) |
| Make a case pass by editing events-processor inside a probe, or by sleeping | the ledger must measure the real code; sleeps hide races | change-control N10; `reference/ledger-and-matrix.md` s.5 | inject only at edges; wait on observable conditions |

## Validation protocol (every campaign change routes through change-control)

1. Classify with `change-control` (path rows, then its behaviour test; union of the matching rows' gates).
   Campaign default: Phase 0/5 tests C1; Phase 1 C3 (change-control C3/C4 precedence rule; C4 if control
   flow changes); Phase 2 C3 + C4 (a new DLQ cause is C4); Phase 3 C3 (C4 if the enriched `timestamp` format
   changes); Phase 4 C4; W6 per sub-phase (Phase 7); workflow and `go.mod` edits C5; topic lists C4 + C6 (the
   dev topic list is in both change-control rows).
2. Before coding, write the predicted scoreboard after the change (which metrics move, to what), as
   `research-methodology` asks.
3. Gates: change-control N9, its one "Pre-PR gate for events-processor code" block (`ep-test.sh`, `-race`,
   `go vet`, `gofmt -l`, golangci-lint `--new-from-rev=$BASE` per OPEN DECISION OD-6 (owner), the guards); C3
   parity evidence (`rails-go-parity`); C4: ADR-001 referenced (or the contract change's ADR) + both ledgers
   and the corpus before/after + the kfake test when commit logic changes (change-control N7) + one
   `GOFLAGS=-race` ledger run per mode (the unit suite never runs `processRecordsAndCommit`) + a paired PR in
   each repo that depends on the changed contract, with the deploy order (change-control N6,
   DECIDED OD-4 (owner, 2026-10-02)); the owner only for a deviation from ADR-001.
4. Evidence block in the PR (change-control N13): scoreboard before/after, `--check-baseline` showing exactly
   the predicted metrics moved and `unmeasured=0`, ledger fault rows before/after in both modes, parity probe
   output, gate output.
5. Update the baseline line in `scripts/scoreboard.sh` (and the expected blocks in `reference/`) in the SAME
   PR that moves a metric (C1 change to this skill).
6. Status words: CANDIDATE (proposed) -> IN-PR (#NNN, evidence attached) -> MERGED (sha) -> VERIFIED-IN-PROD
   (Phase 6 data). Never write "fixed" before MERGED with evidence.

## Scripts

| Script | Purpose | Example | Expected (2026-10-02) |
|---|---|---|---|
| `scripts/run.sh` | builds a probe with a temp `-modfile` into a temp dir (CGO env from `ep-env.sh`), runs it, passes its exit code; `--check` = vet + gofmt + franz-go pin | `run.sh --check` | `run.sh: check OK`, exit 0 |
| `scripts/accounting-probe/` | fault-matrix ledger: 10 cases, real consumer group + processor, kfake + miniredis; `-mode db` (default, scratch Postgres) or `-mode cache` (seeded memory cache, cases 4-10, no Postgres); a candidate change runs through `GOFLAGS=-overlay=<json>` (Phase 4) | `run.sh accounting-probe [-mode db\|cache] [-case A,B] [-list] [-v]` | DB: `TOTALS rows=36 … LOST=1 SKIPPED_RETRY=1 SENTRY_ONLY=3 … UNACCOUNTED=5`, exit 5; cache: `TOTALS rows=26 … SKIPPED_RETRY=1 SENTRY_ONLY=3 … UNACCOUNTED=4`, exit 4 (exit = UNACCOUNTED, 100 = setup error) |
| `scripts/value-corpus/` | `corpus.tsv` through real unmarshal + `EnrichEvent`; Rails-derived expectations; CH emulation; `ToTime` count; `-value` triages ad hoc values (needs Ruby) | `run.sh value-corpus [-mode value\|time] [-ruby] [-ch-bin PATH] [-value JSON]… [-fail-on-mismatch]` | `SUMMARY corpus_rows=27 value_mismatches=13 go_decimal_mismatches=2 ch_zeroed=4 end_to_end_decimal_mismatches=6 totime_mismatches=496/1000 rfc3339_utc_ms=false`, exit 0 (1 with `-fail-on-mismatch`; 2 setup error: Ruby, ClickHouse, bad `-value`) |
| `scripts/ch-schema-candidate.sh` | the Phase 2 ClickHouse column CANDIDATE on the corpus + 6 edge values with `clickhouse local`, against Postgres `numeric(40,15)`; today's column, candidate, re-derivation from stored strings | `ch-schema-candidate.sh [--no-pg] [--ch-bin PATH] [-q]` | `SUMMARY corpus_rows=27 edge_rows=6 today_corpus_mismatches=6 cand_mismatches=0 cand_policy_null=3 rederive_needs_re_enrichment=2 rederive_policy_null=3 pg_reference=postgres`, exit 0 (~7 s; 2 = setup error) |
| `scripts/cache-bench/` | memory-cache warm-up time, Go heap and RSS for N subscriptions (W6-5) | `run.sh cache-bench [-n 1000000]` | `n=1000000 insert=13.66s (73208/s) heap_inuse_mb=406 rss_mb=792 lookup_ok=true …`, exit 0 (insert time varies with host load: 13-19 s) |
| `scripts/scoreboard.sh` | all gate metrics in one table, both ledger modes | `scoreboard.sh [--no-accounting] [--no-coverage] [--check-baseline] [--check-targets]` | table above, exit 0 (~20-25 s warm); `--check-baseline` exit 0 today (3 when a metric moved); `--check-targets` exit 4 today; 5 = a `--check-*` run with `NOT MEASURED` rows (`--no-accounting` skips the DB-mode ledger only; `unmeasured=N`); 2 = a measurement could not run or bad flag |
| `scripts/go.mod`, `go.sum` | probe module: `replace` onto `../../../../events-processor` and `../../diagnostics-and-tooling/scripts/kfake-harness`; kfake pinned at `v0.0.0-20251123185109-2b5c574e9ddd` so franz-go stays v1.20.5 | — | never `go get -u` here |

All scripts are read-only on the repo; outputs go to `mktemp -d` dirs and scratch databases they drop.

## Provenance and maintenance

- Sources: `events-processor/` `config/kafka/{consumer,producer,kafka}.go`,
  `processors/events_processor/{processor,enrichment_service,event_producer_service}.go`,
  `models/{event,subscriptions,billable_metrics,charges}.go`, `cache/*.go`, `utils/{time,result}.go`, `main.go`;
  `connectors/*.yml`, `extra/debezium_config.json`, `docker-compose.dev.yml`, `.env.development.default`;
  `$API/app/services/events/{enrich_service,kafka_producer_service,post_process_service,pay_in_advance_service}.rb`,
  `$API/app/services/events/stores/{clickhouse_store,postgres_store}.rb`, `$API/db/structure.sql`,
  `$API/db/clickhouse_migrate/{20231024084411,20231030163703,20240705080709,20250814090557,20251110100317,20260430075848}_*.rb`,
  `$API/db/clickhouse_migrate/cloud/{02,05}_*.sql`, `$API/AGENTS.md`;
  franz-go v1.20.5 and kfake sources in the Go module cache; history commits `4100da0`, `cec0eb2`, `656c829`,
  `600e195`, `b604769`, `b6d3616`, `9acd83e`, `190aa81`, `76c1b3b`, `d9c32b6`, `2fd8e8b`; the
  `diagnostics-and-tooling` kfake harness (structural dependency: `scripts/go.mod` replaces
  `lagoskills/kfakeharness` by relative path), its `ch-local.sh`, `smoke-binary.sh`, `kfake-run.sh`,
  `scratch-pg.sh`; the owner decisions of 2026-10-02 as recorded in `change-control` §9.
- Volatile facts, one-line re-verification each (from repo root, `S=.claude/skills/event-accounting-campaign/scripts`), as of 2026-10-02:
  - all metrics: `$S/scoreboard.sh | tail -1` -> `scoreboard: moved=0 unmeasured=0 targets_missed=13 …`
  - ledger DB: `$S/run.sh accounting-probe 2>/dev/null | grep ^TOTALS` -> `TOTALS rows=36 ENRICHED=26 DLQ=3 REDELIVERED=2 LOST=1 SKIPPED_RETRY=1 SENTRY_ONLY=3 PENDING=0 ENRICHED+DLQ=0 UNACCOUNTED=5`
  - ledger cache: `$S/run.sh accounting-probe -mode cache 2>/dev/null | grep ^TOTALS` -> `TOTALS rows=26 ENRICHED=19 DLQ=2 REDELIVERED=1 LOST=0 SKIPPED_RETRY=1 SENTRY_ONLY=3 PENDING=0 ENRICHED+DLQ=0 UNACCOUNTED=4`
  - corpus + time: `$S/run.sh value-corpus 2>/dev/null | tail -1` -> `SUMMARY corpus_rows=27 value_mismatches=13 …`
  - CH candidate: `$S/ch-schema-candidate.sh -q 2>/dev/null` -> `SUMMARY … cand_mismatches=0 … pg_reference=postgres`
  - cache smoke: `.claude/skills/diagnostics-and-tooling/scripts/smoke-binary.sh cache cache-cdc 2>&1 | grep -c 'EXPECTED-TODAY: MATCH'` -> `2`
  - retry branch: `grep -n '12\*time.Hour' events-processor/processors/events_processor/processor.go` -> `74:`
  - commit call: `grep -n 'CommitRecords(ctx' events-processor/config/kafka/consumer.go` -> `104:`
  - value format: `grep -n 'Sprintf("%v"' events-processor/processors/events_processor/enrichment_service.go` -> `114:`
  - amount type: `grep -n 'PreciseTotalAmountCents string' events-processor/models/event.go` -> `18:` and `42:`
  - CH decimal: `grep -n toDecimal128OrZero "$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb"` -> `32:`
  - PG decimal: `grep -n 'decimal_value numeric(40,15)' "$API/db/structure.sql"` -> includes `3059:`
  - Debezium gap: `grep -c 'pay_in_advance' extra/debezium_config.json` -> `0`
  - Rails value: `grep -n '|| 0' "$API/app/services/events/enrich_service.rb"` -> `59:`
  - pins in sync: `$S/run.sh --check` -> `run.sh: check OK`
- Update triggers: any change to the files listed in Sources; a franz-go or Go bump in
  `events-processor/go.mod`; a change to the `diagnostics-and-tooling` harness API (`kfx`, `fixture`,
  `pipeline`), its smoke expected files, or `ch-local.sh --path`; an `api` gitlink bump; a lago-api
  ClickHouse migration touching `decimal_value`; an owner answer to OD-1b, OD-8 or OD-20, or an amendment of
  ADR-001; any scoreboard metric that moves.
