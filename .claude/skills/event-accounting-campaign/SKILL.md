---
name: event-accounting-campaign
description: Executable, decision-gated campaign for the hardest live problem - event accounting in the Go events-processor - every raw-topic record must end on events_enriched with a faithful value, on the DLQ with a cause, or in a bounded retry; never a silent skip, drop or zero. Numbered phases, exact commands, EXPECTED numbers, "if you see X, branch to Y" gates; a kfake fault-matrix ledger (accounting-probe), a golden value corpus vs Rails plus a utils.ToTime count (value-corpus), one scoreboard.sh; ranked delivery menu, fenced-off wrong paths. Use for "events lost", "LOST", "retryable failure skipped", "commit past failed offset", "No commitable record in batch", "Sentry only", "precise_total_amount_cents number", "1e+06", "<nil>", "Decimal(38,26) zero", "ToTime 1 ms early", "retry topic", "12 h horizon", OD-2. Not for as-is architecture (architecture-contract), parity rows (rails-go-parity), harness blocks (diagnostics-and-tooling), live triage (debugging-playbook), gates (change-control).
---
# Event accounting campaign (W1-W5)

Make every record of the raw events topic **accountable** (it ends on `events_enriched`, on
`events_dead_letter` with a cause, or in a bounded retry) and **faithful** (the enriched `value` and time
are what Rails would compute). This skill is the plan: measure, add signals, fix value and time, choose a
delivery contract with the owner, put the harness in CI, verify in production. Every fix named here is a
CANDIDATE until merged with evidence. Code facts as of 5308258 (events-processor tree 83e012866f29); the
working branch may carry skills-only commits on top (`git log --oneline 5308258..HEAD -- events-processor`
prints nothing). lago-api at the pin `591ae90` (2026-09-08). Verified 2026-10-01 unless marked.

## When to use / when NOT to use

Use it when:
- you are about to change commit, retry, DLQ or skip behaviour (`config/kafka/consumer.go`, the disposition
  block of `processors/events_processor/processor.go`, `event_producer_service.go`);
- you touch how `value` or time is derived (`enrichment_service.go`, `models/event.go`, `utils/time.go`);
- someone reports missing usage, events billed 0, unique counts too high, connector events vanishing;
- you need today's numbers (LOST, corpus mismatches, ToTime, coverage) or the owner needs a decision brief (OD-2, OD-3).

Do NOT use it for:
- how the pipeline works today, invariants, weak-point list -> `architecture-contract`;
- the Go vs Rails/ClickHouse contract table and its probes -> `rails-go-parity`;
- kfake/miniredis/scratch-PG building blocks, clickhouse-local -> `diagnostics-and-tooling`;
- triaging a live incident from logs or DLQ codes -> `debugging-playbook`;
- class definitions, the non-negotiables (change-control N1-N13), PR evidence format -> `change-control`;
- test conventions, baselines, CI shape -> `validation-and-qa`; CGO toolchain, Postgres -> `build-and-env`;
- incident history of the commit path -> `failure-archaeology`;
- memory-cache (badger + Debezium CDC) hardening beyond the shared ledger: unowned; owner question OPEN
  DECISION OD-20 (owner), next to OD-1; candidate future campaign; as-is defects `architecture-contract`
  WP6-WP10. Release reliability -> `release-and-images`.

## Terms

| Term | Meaning here |
|---|---|
| raw record | one Kafka record on `LAGO_KAFKA_RAW_EVENTS_TOPIC` (dev `events-raw`) |
| accounted | the record is ENRICHED, DLQ, REDELIVERED (bounded retry) or PENDING (bounded) |
| UNACCOUNTED | LOST + SKIPPED_RETRY + SENTRY_ONLY; definitions in `reference/ledger-and-matrix.md` s.2 |
| withheld | `ProcessEvents` left the record out of its return value, i.e. "retry me" (`processor.go:74-78`) |
| committed past | the group's committed offset is greater than the record's offset: it will never be re-polled |
| ledger / case | one `accounting-probe` row per raw offset / one fault scenario of the matrix |
| faithful value | the `value` string Rails' own enrichment would produce (`$API/app/services/events/enrich_service.rb:59-60`) |
| baseline / target | the 2026-10-01 measurement / the campaign goal; targets are NOT current state |
| OD-n | an owner OPEN DECISION: read every bare `OD-n` here as OPEN DECISION OD-n (owner), never settled; list and gate in `change-control` |
| `$API` | pinned lago-api checkout: `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)` |
| BM, subscription, pay-in-advance | see `domain-reference` |

## The problem in numbers (Phase-0 baseline, 2026-10-01)

```
$ .claude/skills/event-accounting-campaign/scripts/scoreboard.sh
metric                                   today      baseline   target     status
---------------------------------------- ---------- ---------- ---------- ------
unaccounted_records                      5          5          le 0       baseline
lost                                     1          1          le 0       baseline
skipped_retry                            1          1          le 0       baseline
sentry_only                              3          3          le 0       baseline
ledger_rows                              36         36         eq 36      baseline, TARGET MET
corpus_value_mismatches                  13         13         le 0       baseline
corpus_go_decimal_mismatches             2          2          le 0       baseline
corpus_end_to_end_decimal_mismatches     6          6          le 0       baseline
totime_mismatches_per_1000               496        496        le 0       baseline
rfc3339_normalised_utc_ms                false      false      eq true    baseline
cov_ProcessEvents_pct                    0.0        0.0        gt 0.0     baseline
cov_processRecordsAndCommit_pct          0.0        0.0        gt 0.0     baseline
cov_total_tested_pkgs_pct                47.4       47.4       gt 47.4    baseline
scoreboard: moved=0 unmeasured=0 targets_missed=12 (baseline 2026-10-01; targets are campaign TARGETS, not current state)
```
(~15-25 s warm, depending on host load; exit 0.) What the 5 unaccounted records are (fault rows of the ledger):

| # | Case (`-case` name) | What happens today | Code |
|---|---|---|---|
| 1 | transient DB error, then more traffic (`retryable-then-later-batch`) | **LOST**: withheld, a later batch commits past it | `processor.go:74-78`, `consumer.go:89-104` |
| 8 | transient Redis error, then more traffic (`redis-flag-then-later-batch`) | **SKIPPED_RETRY**: enriched + in-advance produced, refresh flag never retried | `processor.go:110-131` |
| 4 | invalid JSON (`unmarshal-bad-json`) | **SENTRY_ONLY**: committed, no DLQ | `processor.go:50-59` |
| 5 | connector event with numeric `precise_total_amount_cents` (`numeric-precise-total-amount-cents`) | **SENTRY_ONLY**: unmarshal error (Go declares a string) | `models/event.go:18`, `connectors/http.yml:32-36` |
| 7 | non-retryable failure while the DLQ topic rejects (`dlq-produce-failure`) | **SENTRY_ONLY**: committed after a failed DLQ produce | `event_producer_service.go:70-73` |

Accounted today (controls and DLQ paths): 2 `retryable-only-batch`, 3 `retryable-stale-12h`,
6 `enriched-produce-failure`, 9 `redis-flag-only-batch`, 10 `missing-bm-nonretryable`. Case numbers are the
rows of `reference/ledger-and-matrix.md` s.3; names as printed by `run.sh accounting-probe -list`.
Paths above are under `events-processor/` (processor files in `processors/events_processor/`) unless they
start with `connectors/`. Value and time: `reference/value-and-time.md`.

## Phase map

<!-- evidence-check: off phase routing table; evidence sits in each phase section below -->

| Phase | Workstream | Class (change-control) | Blocks on | Exit gate (scoreboard unless stated) |
|---|---|---|---|---|
| 0 Measure | all | C1 (read-only) | nothing | table == baseline, or every moved metric explained |
| 1 Signals | W5 | C3 (change-control C3/C4 precedence rule; C4 if control flow changes) | Phase 0 | `--check-baseline` exit 0 (`moved=0 unmeasured=0`) + disposition lines in every case |
| 2 Value fidelity | W2 | C3 + C4 (`value` is a cross-repo contract, change-control N6; a new DLQ cause is C4) | Phase 1; OD-4; OD-3 for the CH part | value metrics at target or owner-approved exceptions |
| 3 Time semantics | W3 | C3 (C4 if the enriched `timestamp` payload format changes) | Phase 0 (coordinate with Phase 2: see Phase 3 entry) | `totime 0`, `rfc3339 true`, nothing else moved |
| 4 Delivery semantics | W1 | C4 + ADR + change-control N7 | Phase 1; **OD-2**; in-repo kfake test (Phase 5a) | lost 0, skipped_retry 0, then unaccounted 0 |
| 5 Parity harness + CI | W4 | C1 + C5 (go.mod, workflow) | Phase 0 | coverage targets; ledger runs on PRs |
| 6 Rollout + prod verification | all | per change | each merge; OD-1, OD-8 | reconciliation query does not grow |

<!-- evidence-check: on -->

Phase 3 needs only Phase 0 and Phase 2 needs Phase 1, so they can run in parallel. Phase 5a (the in-repo kfake test) must land before or
inside the Phase 4 PR (change-control N7).

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
S=.claude/skills/event-accounting-campaign/scripts
# Do not run this block under `set -e`: accounting-probe exits 5 ON PURPOSE (exit = UNACCOUNTED rows; 100 = setup error).
$S/run.sh --check                   # expect: franz-go: events-processor=v1.20.5 probe-module=v1.20.5 / run.sh: check OK
$S/scoreboard.sh                    # expect: the baseline table above, exit 0
$S/run.sh accounting-probe          # full ledger; expect last lines TOTALS ... UNACCOUNTED=5, elapsed ~2.3s, exit 5 (= expected)
$S/run.sh value-corpus -ruby -ch-bin "$(.claude/skills/diagnostics-and-tooling/scripts/ch-local.sh --path)"
                                    # expect: ruby 27/27, ch cross-check 27/27, SUMMARY ... value_mismatches=13 ...
```
`ch-local.sh --path` (`diagnostics-and-tooling`) prints the cached ClickHouse binary and downloads it once
into `$LAGO_SKILLS_CACHE/clickhouse/<version>/`; the cross-check line names the version it resolved
(26.2.19.43 on 2026-10-01). Offline or without Ruby, drop `-ch-bin` / `-ruby`: the SUMMARY numbers and
`scoreboard.sh` need neither, you only lose the two cross-checks. Expected full outputs:
`reference/ledger-and-matrix.md` s.4 and `reference/value-and-time.md` s.2-3. The command blocks of later
phases reuse `S`.

Prove one symptom instead of the whole baseline (a support case, a review):
```bash
$S/run.sh accounting-probe -list                                         # the 10 case names
$S/run.sh accounting-probe -case numeric-precise-total-amount-cents      # one SENTRY_ONLY row, UNACCOUNTED=1, exit 1 (= expected)
$S/run.sh value-corpus -mode value -value 2000000000000                  # one customer value: go_value 2e+12, ch 0, FORMAT+CH_ZERO
```
The probe's exit code is the UNACCOUNTED count, so 1 is the expected result for one fault row. `-value`
(repeatable; JSON text, `MISSING` = absent property) derives its want columns with Ruby, so it needs Ruby.

If you see X instead, branch to Y:

| You see | It means | Do |
|---|---|---|
| probe exit 100 + `postgres unreachable` (or `CREATE DATABASE … role needs CREATEDB`); scoreboard exit 2 + `NOT MEASURED` rows | Postgres down or no CREATEDB | `build-and-env` (start PG), re-run; `--no-accounting --no-coverage` gives the corpus metrics alone (not a gate: with `--check-baseline` it exits 5, `unmeasured=8`) |
| value-corpus exit 2 + `setup error: ruby: exec: "ruby": executable file not found` or `clickhouse local: fork/exec …: no such file or directory` | no Ruby on PATH / wrong `-ch-bin` path | install Ruby >= 3.3 or drop `-ruby`; use `ch-local.sh --path` or drop `-ch-bin` (`scoreboard.sh` uses neither) |
| exit 2, `building accounting-probe failed` | your events-processor tree does not compile, or no CGO env | fix the build; `build-and-env` for `-lexpression_go` |
| exit 2, `missing diagnostics-and-tooling/scripts/kfake-harness` | the sibling harness moved (this module depends on it by relative path) | `diagnostics-and-tooling`; fix the `replace` in `scripts/go.mod` |
| `--check` prints different franz-go versions | events-processor bumped franz-go | re-pin kfake per `diagnostics-and-tooling` (kfake technique, version trap), then `go mod tidy` in `scripts/` |
| UNACCOUNTED or a fault row differs on unchanged code | flake or a behaviour change you did not expect | run 3 times; if stable, `git log --oneline 5308258..HEAD -- events-processor`, compare per case with `reference/ledger-and-matrix.md` s.3 |
| `NOTE: sentinel not committed within timeout` (`scripts/accounting-probe/main.go:529`) | the partition is blocked (PENDING) | expected only under Phase 4 option 3; otherwise a regression |
| `corpus_value_mismatches` != 13 or `totime` != 496 | value/time code changed | the PR must carry Phase 2/3 evidence and update `rails-go-parity` rows |
| coverage of `ProcessEvents` > 0 | someone added a test | good: update the baseline in `scripts/scoreboard.sh` (same PR) |
| leftover `acct_probe_*` databases | the probe was killed hard | `psql "${DATABASE_URL:-postgres://lago:lago@localhost:5432/lago}" -Atc "select datname from pg_database where datname like 'acct_probe%'"`, drop them |

Exit gate: the table equals the baseline, or each moved metric is tied to a commit. Evidence: the
scoreboard table and the ledger `TOTALS` line go into the evidence block of the first campaign PR
(change-control N13) or, before any PR exists, into the owner brief: a GitHub issue titled
"OD-2: delivery contract" (change-control §9 says how to raise an OD). Rollback: none (writes only to mktemp
dirs and a scratch database it drops; `git status --porcelain --ignored -- events-processor` stays empty).

After Phase 0, what is next, and who decides (OD defaults: change-control §9):
<!-- evidence-check: off routing table; each row is detailed in its phase section -->

| Next | Unlocked by | Decision needed | Decider | Default until decided | Deliverable |
|---|---|---|---|---|---|
| Phase 1 signals | Phase 0 | none: class by change-control's C3/C4 precedence rule | — | C3 when `moved=0 unmeasured=0` and no control-flow change | PR: signals + a unit test per disposition |
| Phase 3 time | Phase 0 | none | — | C3 | PR: `utils/time.go` + parity probe before/after |
| Phase 5a/5c tests | Phase 0 | none (kfake in `go.mod` is C5, change-control N3) | — | — | PR: ledger and corpus as Go tests |
| Phase 2 value | Phase 1 merged | OD-4 paired lago-api PR; OD-3 CH schema / overflow policy | owner (+ lago-api maintainers for OD-3) | OD-4 YES; OD-3 not approved (prefer detect-and-DLQ, itself C4) | paired PRs, corpus before/after |
| Phase 4 delivery | Phase 1 merged + Phase 5a | OD-2 delivery contract and the 12 h rule | owner (product + engineering) | none chosen: nothing merges | ADR + kfake test + ledger |
| Phase 6 rollout | each merge | OD-1 (mode), OD-8 (flags) | owner, prod deploy owner | UNKNOWN: verify both modes / flag states | canary data, reconciliation query |

<!-- evidence-check: on -->

Optional, owner only: the production reconciliation query (`reference/observability-and-production.md` s.3)
turns the ledger into a production number. Its result is the best input for OD-2. Use its connector-aware
WHERE clause: ClickHouse stores a connector's integer `ingested_at` as a 1970 date (VERIFIED on
`clickhouse local`), so the plain `ingested_at` window misses every connector event, case 5 included.

## Phase 1 - Signals for every disposition (W5, C3)

Entry: Phase 0 done. Today a withheld record and a DLQ'd record log the same line (`processor.go:64-68`), and
a later commit that skips a withheld record logs nothing (`consumer.go:98` only fires when the first record
fails). There is no metrics endpoint (`grep -rn ListenAndServe --include=*.go events-processor` = 0 hits).

CANDIDATE change: one disposition per record (`enriched`, `dlq`, `withheld`, `undecodable`,
`dlq_push_failed`, `enriched_push_failed`) and one batch line per commit decision; fields and rules in
`reference/observability-and-production.md` s.2. No event JSON in logs (`security-and-supply-chain`).

Class: C3 under change-control's C3/C4 precedence rule (`change-control` change-classes.md §1 step 6: the
behaviour test wins over the path row). The touched paths (`processor.go:50-88`, `consumer.go`,
`event_producer_service.go`) are on its C4 path row, but an observability-only edit is C3 when (a) the diff
changes no control flow, return value, `CommitRecords`/DLQ/produce call or payload field, and (b)
`scoreboard.sh --check-baseline` prints `moved=0 unmeasured=0`. Paste both in the PR and say which rule
applied. If any commit, retry, DLQ or skip behaviour changes, it is C4: the N7 kfake test (Phase 5a) comes first.

Commands and expected after the change:
```bash
.claude/skills/build-and-env/scripts/ep-test.sh                    # ok x6; full N9 pre-PR gate (-race, vet, gofmt, lint): change-control
$S/scoreboard.sh --check-baseline                                  # exit 0, "moved=0 unmeasured=0": nothing but signals changed
$S/run.sh accounting-probe -v 2>&1 | grep -c disposition           # today 0; after: > 0, case 1 shows "withheld" for offset 0
```
Exit gate: moved=0; every ledger case shows its disposition (table in the reference); a unit test per
disposition (`validation-and-qa` for conventions). Rollback: revert the PR (no data effect).

## Phase 2 - Value fidelity (W2, C3 + C4)

Entry: Phase 1 merged; run `rails-go-parity`'s parity check on the base branch first. The `value` string is
read by ClickHouse and lago-api, so this is a cross-repo contract (change-control N6): paired lago-api PR
per OPEN DECISION OD-4 (owner), default YES.

Problem (corpus, 27 rows): 13 string mismatches (`1e+06`, `<nil>`, `1e-07`…), 2 decimal mismatches in Go
itself (integers > 2^53 through `float64`), 6 rows billed 0 end to end: all have |x| >= 1e12, which
`decimal_value Decimal(38,26)` cannot hold (`$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32`).
4 of those 6 (`ch_zeroed=4`) are numerically exact in Go (`1e+12` equals 1000000000000) and are zeroed by
the column alone; the other 2 are also wrong in Go (float64 precision).

CANDIDATE change (details, trap and rollout note: `reference/value-and-time.md` s.4-5):
1. exact numbers inside `properties` only (NOT a global `UseNumber`: it breaks numeric timestamps, VERIFIED in `reference/value-and-time.md` s.4);
2. `value` = plain decimal, Ruby-equivalent: integers exact, floats shortest round-trip, missing/null -> `"0"` (CANDIDATE design: `reference/value-and-time.md` s.5);
3. accept number or string for `precise_total_amount_cents` (`models/event.go:18`; ledger case 5); there is no
   value-preserving workaround through the connectors (they turn any non-number into `"0"`, `connectors/http.yml:32-36`);
4. overflow policy for |x| >= 1e12: DLQ with a cause, accept, or CH schema change. OPEN DECISION OD-3 (owner);
   the schema option is fenced off below.

A new DLQ cause (e.g. detect-and-DLQ `value_out_of_range`) changes the disposition of those records, so it
is C4 under change-control's precedence rule: ADR + owner acceptance under OD-3. The N7 kfake test is
required only if `consumer.go` or the commit logic changes; the ledger and the value corpus before/after are
required either way. DLQ'd rows are not replayable today (no DLQ replay tool exists; a manual re-feed is
CANDIDATE and needs OPEN DECISION OD-2 (owner)), so the owner accepts visibility, not recovery.

```bash
$S/run.sh value-corpus -ruby          # target: value_mismatches=0 go_decimal_mismatches=0; unique_count pair "same unique: true"
$S/run.sh accounting-probe -case numeric-precise-total-amount-cents   # target fault row ENRICHED (item 3)
$S/scoreboard.sh                      # only corpus metrics (and sentry_only/unaccounted if item 3) moved
```
Branch: `end_to_end_decimal_mismatches` stays 6 after items 1-2 -> expected (CH rows): either OD-3 answered
and implemented, or those rows get an owner-approved exception in `corpus.tsv` (`want_value` = the new DLQ
cause, owner answer quoted in the PR). Caveat: `-ruby` exits 2 on any row whose want columns differ from
what Ruby derives, so an exception row first needs an exception marker that both `value-corpus/main.go`
and `rails_semantics.rb` honour (not built; CANDIDATE, C1 change to this skill). Any other row moved ->
stop, explain it.
Exit gate: value metrics at target or approved exceptions; `rails-go-parity` value rows (P10-P13: closing
a DIVERGE row triggers change-control's cross-repo protocol) and its EXPECTED block updated in the same PR;
change-control N9 gate; before/after corpus in the PR (change-control C3). Rollback: revert; rows written
meanwhile keep the new format (unique_count transition: write it in the PR).

## Phase 3 - Time semantics (W3, C3; C4 if the enriched `timestamp` payload format changes)

Entry: Phase 0. Coordinate with Phase 2: if `json.Number` reaches `Timestamp`, both time functions need a
`json.Number` case in the same change.

Problem: `utils.ToTime` float math puts 496/1000 ms-precision strings 1 ms early (`utils/time.go:20-23,48`);
the RFC3339 branch returns un-normalised times (`:25-29`). Rails sends `to_f.to_s` timestamps
(`$API/app/services/events/kafka_producer_service.rb:43`) and matches with `date_trunc('millisecond', …)`
(`$API/app/services/events/post_process_service.rb:50-53`). Parsing is a MATCH, but on Ruby 3.3.6
`to_f.to_s` itself puts 129/1000 ms values 1 ms early after millisecond truncation (CANDIDATE drift,
`rails-go-parity` P22, `domain-reference` MC17; lago-api pins Ruby 4.0.6, UNVERIFIED there).
`utils/time_test.go:31-35` uses `.344`, a value that round-trips, so the unit tests pass today.

CANDIDATE change: string fraction parsed without floats; RFC3339 -> `.UTC().Truncate(time.Millisecond)`
(`reference/value-and-time.md` s.5).
```bash
$S/run.sh value-corpus -mode time     # target: "0/1000 land on a different millisecond", "normalised to UTC+ms: true"
$S/scoreboard.sh --check-baseline     # exit 3, moved=2 (the two time metrics) and nothing else
```
Then run `rails-go-parity`'s time and subscription probes: its scenarios B (float ms rounding) and C (RFC3339
offset) are the rows that should move. Exit gate: time metrics at target, no other metric moved, parity rows
updated. Rollback: revert (subscription attribution of offset/boundary events reverts too).

## Phase 4 - Delivery semantics (W1, C4)

Entry (all required): Phase 1 merged; OPEN DECISION OD-2 (owner) answered in writing (block, retry topic,
bounded in-process retry, or DLQ-now; and whether 12 h is a product rule); ADR drafted
(`reference/delivery-options.md` s.5); an in-repo kfake test exists or is in this PR (change-control N7,
Phase 5a). Never merge without owner sign-off.

Ranked menu (CANDIDATE; full pros/cons, constraints and decision guide in `reference/delivery-options.md`):
<!-- evidence-check: off option summary; evidence per option in reference/delivery-options.md -->

| Rank | Option | One-line trade-off |
|---|---|---|
| 1 | in-process bounded retry of the failed step, then DLQ (`retry_exhausted:<code>`) | smallest diff, `processRecordsAndCommit` untouched; long outages become DLQ volume (no DLQ replay tool exists) |
| 2 | retry topic with bounded attempts, then DLQ | never blocks, keeps a 12 h horizon; new topic = provisioning + deploy order (C4 + C6) |
| 3 | seek back / pause the partition until success or 12 h | keeps order and intent; head-of-line blocking, franz-go `SetOffsets` caveats, chain-A code |
| 4 | commit and DLQ immediately | trivial; every blip becomes DLQ volume |
<!-- evidence-check: on -->

Constraints every option must answer in the ADR: `BlockRebalanceOnPoll` (`consumer.go:245`) with the
unbuffered dispatch (`:122`, `:195`) and the 60 s rebalance timeout; 10 000 records per poll (`:168`), one
goroutine each (`processor.go:38-44`); the 12 h horizon (`processor.go:74`); duplicates from re-production
(case 9: enriched=2, in_adv=2) and what absorbs them (`reference/delivery-options.md` s.4).

```bash
$S/run.sh accounting-probe                       # 3 runs + once with GOFLAGS=-race
$S/scoreboard.sh --check-baseline                # moved: lost/skipped_retry (and sentry_only if cases 4/5/7 are in scope)
```
Review a candidate (yours or someone else's PR) without editing the repo (change-control N10): build it
through a `go build -overlay` map; `git status --porcelain -- events-processor` stays empty.
```bash
d=$(mktemp -d); cp events-processor/config/kafka/consumer.go "$d/"      # then edit "$d/consumer.go"
printf '{"Replace":{"%s":"%s"}}\n' "$PWD/events-processor/config/kafka/consumer.go" "$d/consumer.go" >"$d/overlay.json"
GOFLAGS=-overlay="$d/overlay.json" $S/run.sh accounting-probe   # "commit every record": UNACCOUNTED=7, exit 7
```
Verified 2026-10-01 for "commit every record" (the `findMaxCommitableRecord` branch made unreachable):
`REDELIVERED=0 LOST=2 SKIPPED_RETRY=2 UNACCOUNTED=7`; the controls (cases 2, 9) turn LOST / SKIPPED_RETRY.

Expected after (target): case 1 and case 8 fault rows REDELIVERED, ENRICHED or DLQ with a retry cause;
`lost=0 skipped_retry=0`; cases 2, 3, 6, 9, 10 unchanged unless the ADR says why; no `NOTE: sentinel not
committed` unless option 3 was chosen and bounded. Then (cases 4, 5, 7) `unaccounted_records=0`. Branch: if
case 7 becomes LOST, you made DLQ failures "withhold" before fixing W1: reorder. Throughput: compare the
`diagnostics-and-tooling` happy-path scenario (50 000 records, 4 partitions) before and after; relative only.
Exit gate: owner sign-off, ADR, ledger and kfake test output in the PR, change-control N9 gate. Rollback: redeploy the
previous image (offsets stay compatible); option 2 also needs the retry topic drained first.

## Phase 5 - Parity harness and CI (W4, C1 + C5)

1. 5a: port the ledger into an events-processor Go test (kfake as a test dependency in
   `events-processor/go.mod`: C5, pin rules change-control N3 and the kfake version trap) asserting per-case outcomes; this is
   the test change-control N7 asks for.
2. 5b: memory-cache mode ledger (seed with the harness fixture) and a DB-vs-cache comparison per case. Only
   matters if OPEN DECISION OD-1 (owner) says production uses memory-cache mode.
3. 5c: corpus and `ToTime` rows as unit tests next to `enrichment_service_test.go` and `utils/time_test.go`
   (assert the targets once Phases 2/3 merged).
4. 5d: run 5a/5c in `.github/workflows/events-processor-tests.yml` (C5; actionlint via `release-and-images`).

Expected after: `cov_ProcessEvents_pct` and `cov_processRecordsAndCommit_pct` > 0,
`cov_total_tested_pkgs_pct` > 47.4 (the gated definition: own-package coverage over tested packages, same as
`validation-and-qa` baseline.sh `cover.total`); the CI job fails when a ledger case regresses (prove it once on a
throwaway branch). Rollback: revert the workflow/test change.

## Phase 6 - Rollout and production verification

For every merged campaign change: canary, watch the Phase 1 signals, Warn lines from `consumer.go:98`, DLQ
rate, broker-side lag, Sentry volume, and the reconciliation query over the canary window. Mode and flags
change what you must check: OPEN DECISION OD-1 (owner) (memory-cache mode) and OPEN DECISION OD-8 (owner)
(`pre_filter_events`, `lazy_charge_usage_cache`, `enriched_events_aggregation`). Checklist and query:
`reference/observability-and-production.md` s.3-4. A fix becomes VERIFIED-IN-PROD only with that data.

## Wrong paths - fenced off

| Wrong path | Why it is wrong | Evidence | Do instead |
|---|---|---|---|
| "Just commit everything" (drop the withhold branch) | it is the `4100da0` origin design (every failure DLQ'd), which `cec0eb2` replaced on purpose; today it turns REDELIVERED into LOST: UNACCOUNTED 5 -> 7 | `cec0eb2` (#502) "avoid commit"; `processor.go:74-78`; the Phase 4 overlay run | Phase 4 with OD-2 |
| Raise or remove the 12 h horizon | the horizon only applies to a record that is re-polled; case 1 is never re-polled | ledger case 1 vs 3; `processor.go:74` | Phase 4; the horizon itself is OD-2 |
| Sleep/retry inside `processRecordsAndCommit`, or `SetOffsets` from the partition goroutine | blocks rebalances (`BlockRebalanceOnPoll`, 60 s timeout); franz-go warns against `SetOffsets` inside the poll loop | `consumer.go:203,245`; `franz-go@v1.20.5/pkg/kgo/consumer.go:665-681`; chain A (`failure-archaeology`): `cec0eb2` -> `600e195` (infinite poll loop, hotfix `b604769`) -> `9acd83e` (ING-15 segfault) | `reference/delivery-options.md` option 1 or 2 |
| Change commit/disposition code without a ledger + kfake test | 13 months of fix-after-fix ended in a production segfault | change-control N7; `9acd83e` | Phase 5a first |
| "Fix" `go.mod` `expression-go v0.1.4` -> v0.2.0 | no `expression-go/v0.2.0` tag exists; ABI identical; unrelated to accounting | change-control N3; `git ls-remote --tags https://github.com/getlago/lago-expression \| grep expression-go/` -> only `expression-go/v0.1.0` and `expression-go/v0.1.4` (plain `v0.1.0`..`v0.2.0` tags are the Rust crate; as of 2026-10-01) | leave it |
| Re-implement charge/filter resolution in Go to make enrichment "complete" | per-event Rails resolution was removed as the main DB load | change-control N8; `d9c32b6` (#797), `2fd8e8b` (#766) | Rails stays authoritative |
| Make ClickHouse parse `<nil>` | CH already turns it into 0; the defects are the Go string and unique_count; a CH change is lago-api work | corpus rows `null`, `missing`; `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32` | Phase 2 item 2 |
| Change `Decimal(38,26)` without OD-3 | huge tables, cloud DDL edited in place, PG side is `numeric(40,15)` | `$API/AGENTS.md:176`; `$API/db/structure.sql:3059` | OD-3; meanwhile detect-and-DLQ (CANDIDATE; a new DLQ cause is C4) |
| Global `json.Decoder.UseNumber()` | every numeric timestamp fails: `Unsupported timestamp type: json.Number` -> DLQ | `reference/value-and-time.md` s.4 (VERIFIED) | exact numbers in `properties` only |
| Change the `value` format in Go alone | cross-repo contract; unique_count splits old/new strings mid-period | change-control N6; `$API/app/services/events/stores/clickhouse/unique_count_query.rb:311` | paired lago-api PR (OD-4), period-boundary rollout |
| Count on `CleanDuplicatedService` to clean retry duplicates | no caller in `app/`, `lib/`, `config/`, `clock.rb` at `591ae90` (only its spec) | `grep -rn 'CleanDuplicatedService' "$API/app" "$API/lib" "$API/config" "$API/clock.rb" \| grep -v 'class CleanDuplicatedService'` -> no output | rely on `FINAL` (only for orgs with `clickhouse_deduplication_enabled`, default false) and `already_processed?`; say so in the ADR |
| `go test -coverprofile=… ./...` for the coverage gate | fails with `no such tool "covdata"` on packages without tests | `build-and-env`, `validation-and-qa` | `scoreboard.sh` (lists packages with tests) |
| Make a case pass by editing events-processor inside a probe, or by sleeping | the ledger must measure the real code; sleeps hide races | change-control N10; `reference/ledger-and-matrix.md` s.5 | inject only at edges; wait on observable conditions |

## Validation protocol (every campaign change routes through change-control)

1. Classify with `change-control` (path rows, then its behaviour test; union of the matching rows' gates).
   Campaign default: Phase 0/5 tests C1; Phase 1 C3 (change-control C3/C4 precedence rule; C4 if control
   flow changes); Phase 2 C3 + C4 (a new DLQ cause is C4); Phase 3 C3 (C4 if the enriched `timestamp` format
   changes); Phase 4 C4; workflow and `go.mod` edits C5; topic lists C4 + C6 (the dev topic list is in both
   change-control rows).
2. Before coding, write the predicted scoreboard after the change (which metrics move, to what), as
   `research-methodology` asks.
3. Gates: change-control N9, run as its one "Pre-PR gate for events-processor code" block (`ep-test.sh` ok x6
   with PASS not below baseline, `ep-test.sh -race -count=1 ./...`, `go vet`, `gofmt -l` empty on changed
   files, golangci-lint `--new-from-rev=$BASE` 0 new issues per OPEN DECISION OD-6 (owner), the change-control
   guards); C3 parity evidence (`rails-go-parity`); C4: ADR + the ledger and corpus before/after + the kfake
   test when `consumer.go`/commit logic changes (change-control N7) + one `GOFLAGS=-race` ledger run (the
   unit suite's race-clean result never runs `processRecordsAndCommit`) + owner sign-off (OD-2, OD-3 for a new
   DLQ cause) + paired lago-api PR and deploy order (change-control N6, OPEN DECISION OD-4 (owner)).
4. Evidence block in the PR (change-control N13): scoreboard before/after, `--check-baseline` showing exactly
   the predicted metrics moved and `unmeasured=0`, ledger fault rows before/after, parity probe output, gate output.
5. Update the baseline line in `scripts/scoreboard.sh` (and the expected blocks in `reference/`) in the SAME
   PR that moves a metric (C1 change to this skill).
6. Status words: CANDIDATE (proposed) -> IN-PR (#NNN, evidence attached) -> MERGED (sha) -> VERIFIED-IN-PROD
   (Phase 6 data). Never write "fixed" before MERGED with evidence.

## Scripts

| Script | Purpose | Example | Expected (2026-10-01) |
|---|---|---|---|
| `scripts/run.sh` | builds a probe with a temp `-modfile` into a temp dir (CGO env from `ep-env.sh`), runs it, passes its exit code; `--check` = vet + gofmt + franz-go pin | `run.sh --check` | `run.sh: check OK`, exit 0 |
| `scripts/accounting-probe/` | fault-matrix ledger: 10 cases, real consumer group + processor, DB mode, kfake + miniredis + scratch Postgres; a candidate change runs through `GOFLAGS=-overlay=<json>` (Phase 4) | `run.sh accounting-probe [-case A,B] [-list] [-v]` | `TOTALS rows=36 … LOST=1 SKIPPED_RETRY=1 SENTRY_ONLY=3 … UNACCOUNTED=5`, exit 5 (exit = UNACCOUNTED, 100 = setup error) |
| `scripts/value-corpus/` | `corpus.tsv` through real unmarshal + `EnrichEvent`; Rails-derived expectations; CH emulation; `ToTime` count; `-value` triages ad hoc values (needs Ruby) | `run.sh value-corpus [-mode value\|time] [-ruby] [-ch-bin PATH] [-value JSON]… [-fail-on-mismatch]` | `SUMMARY corpus_rows=27 value_mismatches=13 go_decimal_mismatches=2 ch_zeroed=4 end_to_end_decimal_mismatches=6 totime_mismatches=496/1000 rfc3339_utc_ms=false`, exit 0 (1 with `-fail-on-mismatch`; 2 setup error: Ruby, ClickHouse, bad `-value`) |
| `scripts/scoreboard.sh` | all gate metrics in one table | `scoreboard.sh [--no-accounting] [--no-coverage] [--check-baseline] [--check-targets]` | table above, exit 0 (~15-25 s warm); `--check-baseline` exit 0 today (3 when a metric moved); `--check-targets` exit 4 today; 5 = a `--check-*` run with `NOT MEASURED` rows (skipped by `--no-*`, `unmeasured=N`); 2 = a measurement could not run or bad flag |
| `scripts/go.mod`, `go.sum` | probe module: `replace` onto `../../../../events-processor` and `../../diagnostics-and-tooling/scripts/kfake-harness`; kfake pinned at `v0.0.0-20251123185109-2b5c574e9ddd` so franz-go stays v1.20.5 | — | never `go get -u` here |

All scripts are read-only on the repo; outputs go to `mktemp -d` dirs and a scratch database the probe drops.

## Provenance and maintenance

- Sources: `events-processor/config/kafka/consumer.go`, `config/kafka/producer.go`,
  `processors/events_processor/{processor,enrichment_service,event_producer_service}.go`, `models/event.go`,
  `models/{subscriptions,billable_metrics}.go`, `utils/{time,result}.go`, `main.go`, `connectors/*.yml`;
  `$API/app/services/events/{enrich_service,kafka_producer_service,post_process_service,pay_in_advance_service}.rb`,
  `$API/app/services/events/stores/{clickhouse_store,postgres_store}.rb`,
  `$API/db/clickhouse_migrate/{20231024084411,20240705080709,20251110100317}_*.rb`, `$API/AGENTS.md`;
  franz-go v1.20.5 and kfake sources in the Go module cache; history commits `4100da0`, `cec0eb2`, `656c829`,
  `600e195`, `b604769`, `b6d3616`, `9acd83e`, `190aa81`, `76c1b3b`, `d9c32b6`, `2fd8e8b`; the
  `diagnostics-and-tooling` kfake harness (structural dependency: `scripts/go.mod` replaces
  `lagoskills/kfakeharness` by relative path) and its `ch-local.sh`.
- Volatile facts, one-line re-verification each (from repo root, `S=.claude/skills/event-accounting-campaign/scripts`), as of 2026-10-01:
  - all metrics: `$S/scoreboard.sh | tail -1` -> `scoreboard: moved=0 unmeasured=0 targets_missed=12 …`
  - ledger: `$S/run.sh accounting-probe 2>/dev/null | grep ^TOTALS` -> `TOTALS rows=36 ENRICHED=26 DLQ=3 REDELIVERED=2 LOST=1 SKIPPED_RETRY=1 SENTRY_ONLY=3 PENDING=0 ENRICHED+DLQ=0 UNACCOUNTED=5`
  - corpus + time: `$S/run.sh value-corpus 2>/dev/null | tail -1` -> `SUMMARY corpus_rows=27 value_mismatches=13 …`
  - retry branch: `grep -n '12\*time.Hour' events-processor/processors/events_processor/processor.go` -> `74:`
  - commit call: `grep -n 'CommitRecords(ctx' events-processor/config/kafka/consumer.go` -> `104:`
  - value format: `grep -n 'Sprintf("%v"' events-processor/processors/events_processor/enrichment_service.go` -> `114:`
  - amount type: `grep -n 'PreciseTotalAmountCents string' events-processor/models/event.go` -> `18:` and `42:`
  - CH decimal: `grep -n toDecimal128OrZero "$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb"` -> `32:`
  - Rails value: `grep -n '|| 0' "$API/app/services/events/enrich_service.rb"` -> `59:`
  - pins in sync: `$S/run.sh --check` -> `run.sh: check OK`
- Update triggers: any change to the files listed in Sources; a franz-go or Go bump in
  `events-processor/go.mod`; a change to the `diagnostics-and-tooling` harness API (`kfx`, `fixture`,
  `pipeline`) or to `ch-local.sh --path`; an `api` gitlink bump; an owner answer to OD-1, OD-2, OD-3, OD-4,
  OD-8 or OD-20; any scoreboard metric that moves.
