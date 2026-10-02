---
name: validation-and-qa
description: "Evidence and test discipline for the Go events-processor: proof per change class, the baseline (235 PASS, 47.4% gated coverage, 21 lint issues, race clean on the unit suite only) checked by baseline.sh, test conventions (testify, sqlmock QuoteMeta pins, miniredis), harness defects. Use when adding or reviewing a test, preparing PR evidence, or on \"how do I test this\", \"coverage dropped\", \"PASS count dropped\", \"no such tool covdata\", \"ExpectationsWereMet\", \"flaky test\", golangci-lint issues, a -race run. Not for CGO setup (use build-and-env) or kfake probes (use diagnostics-and-tooling)."
---
# Validation and QA: evidence, baselines, tests

This skill says what counts as proof in this repo, what the suite measures today, and how to add a
test that holds up. It ships the scripts that compare your branch with the baseline and the
templates for the five common kinds of test.
Facts verified 2026-10-01 unless marked. Code facts as of 5308258 (events-processor tree
83e012866f29); the working branch may carry skills-only commits on top.

## When to use / when NOT to use

Use it when:

- you add, change or review a test in `events-processor/`;
- you prepare the evidence block of a PR, or judge whether a PR's evidence is enough;
- a number moved: PASS count, coverage, lint issues, a race, a flaky or order-dependent test;
- you copy an existing test and want to know which of its habits are defects;
- you need to know what CI checks for your PR (often: nothing).

Do NOT use it for:

- `cannot find -lexpression_go`, loader errors, Postgres for tests, toolchain versions: see `build-and-env`;
- which gates a class needs, who signs off, commit/PR rules, OPEN decisions: see `change-control`;
- building probes (kfake, overlays for experiments, scratch Postgres, clickhouse local): see `diagnostics-and-tooling`;
- designing the delivery/value/time test suites of the hardest live problem: see `event-accounting-campaign`;
- what Go must match in Rails or ClickHouse, and the parity probes: see `rails-go-parity`;
- what the code does at runtime (topology, commit algorithm, weak points): see `architecture-contract`;
- triaging a red CI run or a runtime symptom: see `debugging-playbook`;
- actionlint and image builds: see `release-and-images`; compose validation: see `run-and-operate`;
- PR body and ADR templates: see `docs-and-writing`.

## Terms

| Term | Meaning here |
|---|---|
| EP | `events-processor/`, the only first-party code (Go module `github.com/getlago/lago/events-processor`). |
| evidence | Output you produced (command, exit status, key lines) at a stated sha. A claim without it is UNVERIFIED (change-control N13). |
| baseline | The numbers in `scripts/baseline.json` (2026-10-01; its `head` is the code commit 5308258, `ep_tree` the tree measured), or a file you wrote on the PR base with `baseline.sh --write`. |
| PASS count | Number of `"Action":"pass"` test events (top-level tests + subtests at any depth). 235 today. |
| leaf test | A test or subtest that has no subtests of its own. 202 today. |
| own coverage | Statement coverage of the packages that have tests, each by its own tests (47.4%). The gated number. |
| DB mode / cache mode | EP reads Postgres per event (default) / reads an in-memory badger cache fed by snapshot + Debezium CDC (`LAGO_USE_MEMORY_CACHE=true`). Production use of cache mode is OPEN DECISION OD-1 (owner). |
| dual-mode test | One scenario run in both modes through the `DataStore` test interface (`processors/events_processor/processor_test.go:46-121`). |
| SQL pin | The exact SQL a query must emit, held in a test with `regexp.QuoteMeta` (`models/subscriptions_test.go:14-22`). |
| overlay | `go test -overlay=<json>`: build as if files were replaced or added, without touching disk. All scripts here use it. |
| KNOWN | A defect listed in a script with its verification date; it is reported but does not fail the run. |
| HD1-HD7 | This skill's harness defects (§5, `reference/harness-defects.md`). Cite them from other skills as "validation-and-qa HD3". |
| `$BASE` | `git merge-base origin/main HEAD`, the PR base. If it fails in a shallow clone: `git fetch --deepen=100 origin main`, then retry. If your branch sits on skills-only commits that are not on `origin/main`: change-control SKILL.md §1 step 4. |
| `ep-test.sh` | Shorthand for `.claude/skills/build-and-env/scripts/ep-test.sh` (Docker-free `go test` in `events-processor/`; args pass through). |
| cite paths | Code cites are relative to `events-processor/` (e.g. `models/charges.go:47`); bare `processor_test.go`, `enrichment_service_test.go`, `event_producer_service_test.go`, `processor.go`, `enrichment_service.go` live in `processors/events_processor/`. `.github/...` is repo-relative; `$API/...` is pinned lago-api; `scripts/...`, `templates/...`, `reference/...` are in this skill (`.claude/skills/validation-and-qa/`). |

Reference files (read when):

- `reference/evidence-ladder.md`: you write or review a PR's evidence; per-class detail, what is NOT evidence, the evidence block.
- `reference/baselines.md`: a number does not match, you refresh `baseline.json`, or you need the full zero-coverage list.
- `reference/writing-tests.md`: you write a test; all conventions with citations, sqlmock semantics, dual-mode rules, lago-api spec rules.
- `reference/harness-defects.md`: a test behaves oddly or you plan a harness clean-up; each defect with its reproduction.
- `reference/ci-and-static-checks.md`: you need CI's exact shape, its gaps, or a local static check.

## 1. Evidence ladder (summary)

Classes are defined by `change-control`. Each rung includes the rungs above it for EP code.

| Class | Acceptable proof | Produced by |
|---|---|---|
| C0 docs/skills | every claim carries `path:line`, a sha or command + output; every documented command was run or labelled "not runnable here; verified by reading `<file:line>`" | the commands themselves |
| C1 tests/tooling | full suite green, PASS count up by exactly the new tests, `-race` ok on the unit suite (which never runs `processRecordsAndCommit`), new leaves pass alone, no NEW unmet sqlmock expectation; a regression test is shown failing on the unfixed code | `baseline.sh`, `race-shuffle.sh --isolation`, `sqlmock-strict.sh`, `fails-on-base.sh` |
| C2 refactor | C1 + no existing test expectation changed + vet clean + `gofmt -l` empty on changed `.go` files + no new lint issue + own coverage not lower on any package (= change-control N9 plus the coverage rule) | `baseline.sh` (0 FAIL), `golangci-lint run --allow-serial-runners --new-from-rev="$BASE"` (`0 issues.`) |
| C3 behaviour | C2 + a new/changed test that FAILS on `$BASE` and PASSES after; both data modes when the logic exists in both; exact SQL pinned for query changes (a DB-only query: both pins, `reference/evidence-ladder.md` §2); parity evidence (probe output + `$API/<file>:line`) | `fails-on-base.sh` (`EVIDENCE OK`) + green run; `rails-go-parity` probe |
| C4 delivery/contract | C3 + a kfake-driven test through `processRecordsAndCommit` with per-offset outcomes + one `GOFLAGS=-race` kfake run + ADR + paired lago-api PR (OPEN DECISION OD-4 (owner)) + owner sign-off (OPEN DECISION OD-2 (owner)). A log/span/counter-only edit to a C4 file is C3 when the diff changes no control flow and `.claude/skills/event-accounting-campaign/scripts/scoreboard.sh --check-baseline` prints `moved=0` (change-control §2, "behaviour test wins") | `diagnostics-and-tooling` kfake harness, `event-accounting-campaign` ledger |
| C5 release/pins/CI | pin-sync clean; the full C2 rung on the new versions; workflow YAML parses; no new actionlint finding; images "not built locally" | change-control `pin-sync-check.sh`, `baseline.sh`, `release-and-images` |
| C6 dev env/compose | `docker compose -f <f> config --quiet` exit 0 per touched file; `bash -n` on scripts; bring-up pasted or labelled not runnable | `run-and-operate` |
| C7 security | counts and file:line only, never a value | `security-and-supply-chain`, change-control `precommit-guard.sh` |

Not evidence: "CI is green", a test you never saw fail, a coverage increase on its own, a loose
`".*"` sqlmock pattern for a query change, a cache-mode-only test, a sleep that made it pass, a
code read for runtime behaviour. Details and the paste-ready block: `reference/evidence-ladder.md`.

## 2. Baselines and acceptance thresholds (as of 2026-10-01)

Measured with go1.25.0, golangci-lint 2.5.0, Postgres 16, 4 vCPU. Full tables: `reference/baselines.md`.

| Metric | Baseline | Threshold for a PR | Re-check |
|---|---|---|---|
| PASS (top-level + subtests) | 235 = cache 67, config/database 1, config/kafka 7, models 26, processors/events_processor 50, utils 84 | never lower, total or per package; a deliberate removal is explained and the baseline refreshed in the same PR | `baseline.sh` (`pass.*`) |
| FAIL / SKIP | 0 / 0 | FAIL must be 0; a new SKIP is a WARN to explain | `baseline.sh` |
| own coverage (the gated number) | total 47.4% (487/1028): cache 40.1, config/database 76.2, config/kafka 10.9, models 41.2, processors/events_processor 68.4, utils 72.4 | not lower on any package (0.1 pt resolution). New untested code lowers it: test it | `baseline.sh` (`cover.*`) |
| `-coverpkg=./...` | 44.9% (563/1253); whole module incl. `main`, `processors`: 42.0% (563/1342) | informational only, not gated (WARN on drop) | `baseline.sh` (`coverpkg.total`); whole module: baselines §2 |
| `go vet ./...` | 0 lines | 0 | `baseline.sh` (`vet.issues`) |
| `gofmt -l` | 0 files in the whole tree | changed `.go` files: empty (change-control N9 scope, §3 step 3); whole tree: not above baseline | `baseline.sh` (`gofmt.files`) |
| golangci-lint (no config, v2 defaults) | 21 = errcheck 16, staticcheck 5 | no new issue: per-linter counts not higher AND `--new-from-rev="$BASE"` prints `0 issues.` (OPEN DECISION OD-6 (owner)) | `baseline.sh` (`lint.*`); §3 step 4 |
| `-race -count=1` (unit suite only: it never runs `ProcessEvents` / `processRecordsAndCommit`, §6) | 6 packages ok, 0 DATA RACE | same. Consumer-path (C4) changes also need `GOFLAGS=-race .claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh happy-path -n 5000 -partitions 4` -> `RESULT: PASS`, exit 0 (66 = data race) | `race-shuffle.sh --no-shuffle` |
| `-shuffle -count=10` | 6 ok | same | `race-shuffle.sh --no-race` |
| isolation (each leaf alone) | 202 leaves, 2 KNOWN failures (HD3) | no NEW failure | `race-shuffle.sh --no-race --no-shuffle --isolation` |
| strict sqlmock | 4 KNOWN unmet expectations (HD1) | no NEW one | `sqlmock-strict.sh` |
| time | suite warm 4-5 s; empty build cache 60-75 s typical (up to ~120 s under load); `-race` warm ~7-8 s | n/a | `.claude/skills/build-and-env/scripts/ep-test.sh` under `time` |

These thresholds are the default under OPEN DECISION OD-5 (owner): the Docker-free recipe
(`ep-test.sh`) is the accepted local gate. `lago exec events-processor go test ./...`
(`events-processor/CLAUDE.md:7`) stays valid for people running the dev stack.

## 3. Runbook: validate a change before the PR

change-control owns the gate: its SKILL.md §3 block "Pre-PR gate for events-processor code"
(change-control N9) is the one canonical list. This runbook produces the same evidence with this
skill's scripts and adds the class-specific checks. Labels:

<!-- evidence-check: off label definitions, not claims -->
- **REQUIRED**: part of change-control N9 / N10 for any events-processor code change; a FAIL blocks the PR.
- **CLASS-SPECIFIC**: required evidence for the class named (`reference/evidence-ladder.md`).
- **RECOMMENDED**: not a change-control gate; a NEW failure means your new test is defective: fix it.
<!-- evidence-check: on -->

Run from the repo root. Postgres must answer (`pg_isready -d postgres://lago:lago@localhost:5432/lago`);
if not, see `build-and-env`.

```bash
BASE=$(git merge-base origin/main HEAD)   # shallow clone: git fetch --deepen=100 origin main, retry
                                          # skills-only commits under your branch: change-control SKILL.md §1 step 4
V=.claude/skills/validation-and-qa/scripts
```

1. **REQUIRED (change-control N9: suite ok x6, PASS not below baseline, vet, lint counts; plus
   this skill's coverage rule).**
   `$V/baseline.sh` -> `SUMMARY baseline: 0 FAIL, 0 WARN (...)`. Any FAIL row names the metric;
   failing test names are listed under `--- failing tests`. About 12 s warm, ~30 s with a cold lint cache.
2. **REQUIRED (change-control N9: `-race`).** `$V/race-shuffle.sh --no-shuffle` ->
   `OK   race: 6 packages ok, 0 DATA RACE`. This is the unit suite only: it never runs
   `processRecordsAndCommit` (C4: step 10).
3. **REQUIRED (change-control N9: gofmt on changed files, the same scope as change-control).**
   `git diff --name-only --diff-filter=AM "$BASE" -- events-processor | grep '\.go$' | xargs -r gofmt -l`
   -> no output. (`baseline.sh` also counts the whole tree: 0 today.)
4. **REQUIRED (change-control N9: no new lint issue).** No CGO env needed:
   `( cd events-processor && GOLANGCI_LINT_CACHE="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/golangci-cache" golangci-lint run --allow-serial-runners --new-from-rev="$BASE" ./... )`
   -> `0 issues.` (`--allow-serial-runners` waits for another golangci-lint run instead of
   exiting 3 with `parallel golangci-lint is running`.)
5. **REQUIRED (change-control N10, N9 guards).** `git status --porcelain --ignored -- events-processor`
   shows only your files; `.claude/skills/change-control/scripts/precommit-guard.sh --range "$BASE..HEAD"`
   and `.claude/skills/change-control/scripts/commit-msg-check.sh --range "$BASE..HEAD"` -> `0 FAIL`.
6. **RECOMMENDED (C1: you added or changed a test).** `$V/race-shuffle.sh --no-race --isolation` ->
   `OK   shuffle: seed <n> x10, 6 packages ok`, `OK   isolation: 202 leaf tests run alone, 2 failed (2 known, 0 new)`.
   About 60-75 s (steps 2 and 6 in one run: `$V/race-shuffle.sh --isolation`). A shuffle failure
   prints the seed: re-run with `--no-race --seed <n>`.
7. **RECOMMENDED (C1: a DB-mode / sqlmock test).** `$V/sqlmock-strict.sh` ->
   `SUMMARY sqlmock-strict: 4 unmet-expectation subtests (4 known, 0 new), 0 other failures, ...`.
8. **CLASS-SPECIFIC (C1 regression test, C3+): red/green.**
   `$V/fails-on-base.sh -- -count=1 -run '<YourTest>' ./<pkg>/` -> `EVIDENCE OK: tests fail on base <sha> ...`,
   then the same test green with `ep-test.sh`. `WEAK EVIDENCE` rules: `reference/evidence-ladder.md` §2.
9. **CLASS-SPECIFIC (C3): both modes.** `ep-test.sh -v -count=1 -run '<YourTest>' ./processors/events_processor/`
   must list `.../WithCache/...` and `.../WithoutCache/...`.
10. **CLASS-SPECIFIC (C4, consumer/commit path).** The kfake test of change-control N7, plus
    `GOFLAGS=-race .claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh happy-path -n 5000 -partitions 4`
    -> `RESULT: PASS`, exit 0 (about 5 s warm, 2026-10-01).
11. **REQUIRED when a number improved (C1).** Refresh the baseline in the same PR:
    `$V/baseline.sh --write .claude/skills/validation-and-qa/scripts/baseline.json`, review the diff.
12. Paste the evidence block (`reference/evidence-ladder.md` §5).

## 4. How the suite is written

24 test files, 4,018 lines, all white-box (`package` = the package under test), testify only
(385 `assert`, 70 `require`), no `t.Parallel`, `TestMain`, fuzz, benchmarks or `testdata/`.

| Kind | Mechanism | Anchor |
|---|---|---|
| enrichment / processor | dual-mode `DataStore`: `CacheDataStore` (real badger) and `MockDataStore` (sqlmock rows); `setupEnrichmentTestEnv`, `setupProcessorTestEnv` | `processor_test.go:46-172`, `enrichment_service_test.go:21-51` |
| model queries | `tests.SetupMockStore` -> gorm on sqlmock; exact SQL with `regexp.QuoteMeta` + `WithArgs` (intentional since `9acd83e`: SQLSTATE 0A000 after API DDL) | `tests/mocked_store.go:17-41`, `models/billable_metrics_test.go:14-20` |
| cache | real in-memory badger per test (`setupTestCache`, `t.Cleanup`) | `cache/consumer_test.go:24-35` |
| Redis flag store | miniredis (`setupFlagStore`, `s.SetError`) | `models/stores_test.go:29-37,122-128` |
| producers / flag store fakes | `tests.MockMessageProducer` (always succeeds), `tests.MockFlagStore` (`ReturnedError`) | `tests/mocked_producer.go:20`, `tests/mocked_flag_store.go` |
| failures | assert `ErrorCode`, `ErrorMessage`, `ErrorMsg`, `IsRetryable`, `IsCapturable` | `enrichment_service_test.go:77-84`, `models/billable_metrics_test.go:111-112` |

Templates (each compiled and run against HEAD by `scripts/templates-check.sh`; all 5 pass, also with
`-race`, and add 0 vet/gofmt/lint issues, verified 2026-10-01):

Copy a template into a NEW file (`cp -n`; several targets such as `cache/subscriptions_test.go`
already exist: append to those instead of overwriting them).

<!-- evidence-check: off routing table; each template is compiled and run by templates-check.sh (Scripts) -->
| Change | Template | Copy to |
|---|---|---|
| enrichment value, subscription match, `processEvent` outputs | `templates/enrichment_template_test.go.tmpl` | `events-processor/processors/events_processor/<x>_test.go` |
| SQL in `models/*.go` | `templates/model_query_template_test.go.tmpl` | `events-processor/models/<table>_test.go` |
| cache lookups, tie-breaks, keys | `templates/cache_template_test.go.tmpl` | `events-processor/cache/<model>_test.go` |
| Redis flag store | `templates/redis_store_template_test.go.tmpl` | `events-processor/models/<store>_test.go` |
| Kafka client option / producer config (`ServerConfig`, `ProducerConfig`, the `[]kgo.Opt` of `NewKafkaClient`) | `templates/producer_option_template_test.go.tmpl` | `events-processor/config/kafka/<x>_option_test.go` |
| Kafka commit/retry/DLQ (delivery semantics) | none here: kfake (`diagnostics-and-tooling`), design (`event-accounting-campaign`) | change-control N7 |
<!-- evidence-check: on -->

Option plumbing needs no broker and no kfake: `kgo.NewClient` validates the options and returns
without connecting, so the producer-option template builds a client against the unreachable seed
`127.0.0.1:1` and asserts `client.OptValue(kgo.<Option>)` (default, explicit, zero, out-of-range;
`config/kafka/kafka.go:27-77`, franz-go v1.20.5). kfake is not in `events-processor/go.mod`;
adding it is a C5 change, needed only for change-control N7 delivery tests.

Rules that the templates encode (full list: `reference/writing-tests.md`):

1. One table, `t.Run(tc.name)` per case (`utils/string_test.go:11-60`); every subtest builds its
   own state (counter-example HD3, `enrichment_service_test.go:256-258`).
2. Dual-mode: nest EVERY scenario under `t.Run(mode.name)` and pass `mode.useCache`
   (counter-example HD2, `processor_test.go:183-202`).
3. DB mode: register queries in code order (billable_metrics `enrichment_service.go:39` ->
   subscriptions `:53` -> charges `processor.go:116`) and end with `ExpectationsWereMet()` (HD1).
4. Pin new SQL exactly: `"^" + regexp.QuoteMeta(q) + "$"`. sqlmock collapses whitespace and matches
   unanchored. A changed pin is a C3 change and must keep change-control N4
   (explicit columns, `deleted_at IS NULL`, `organization_id`).
5. No `time.Sleep` to wait for `processEvent`: it already waits (`processor.go:101`).
6. Never assert on the order of a multi-row result: badger returns key order, and Go map
   iteration order is random (`45b216d` (#603), a DB-mode flat-filters test from before badger,
   fixed a flaky charge-order assertion with `sort.Slice`). Use `assert.ElementsMatch` or a set.
7. Wall-clock buckets: read the clock before and after the call (counter-example
   `models/stores_test.go:59-87`).
8. Pin literal JSON for payloads; never compare `json.Marshal(x)` with itself (counter-example
   `event_producer_service_test.go:54-55,77-78`).
9. `require` for preconditions, `assert` for outcomes: an `assert` on a nil result followed by a
   dereference panics and hides every later test in the package (`config/database/database_test.go:22-24`, HD5).

## 5. Known harness defects (do not copy them)

IDs follow `reference/harness-defects.md` (the numbering source).

| # | Defect | Verify | Avoid |
|---|---|---|---|
| HD1 | `ExpectationsWereMet()` never called (`tests/mocked_store.go:38-40`); 4 DB-mode subtests register queries the code never runs | `scripts/sqlmock-strict.sh` -> `4 known, 0 new` | call it in every DB-mode test |
| HD2 | `TestProcessEvent`: only "Without Billable Metric" is nested under the mode (`processor_test.go:184-202`); 6 scenarios are siblings and get `#01`; `:424` hard-codes cache mode | `ep-test.sh -v -count=1 -run TestProcessEvent ./processors/events_processor/` -> names with `#01` | nest under `t.Run(mode.name)`; use `mode.useCache` |
| HD3 | `TestEvaluateExpression` subtests share `bm`/`event` (`enrichment_service_test.go:256-258`); 2 subtests fail alone (`expected: string("36") actual: <nil>`) | `scripts/race-shuffle.sh --isolation` -> `2 known` | state inside each subtest |
| HD4 | three redundant `time.Sleep(50ms)` (`processor_test.go:255,416,470`) | overlay without them passes `-race -count=30` (`reference/harness-defects.md` HD4) | rely on `processEvent`'s wait |
| HD5 | `TestNewConnection` panics (nil `db`) when Postgres is down (`config/database/database_test.go:21-24`) | `DATABASE_URL=postgres://lago:lago@localhost:5499/lago ep-test.sh -count=1 ./config/database/` -> `connection refused`, then `panic: ... nil pointer dereference` | `require.NoError` before dereferencing |

More: HD6 smaller defects (1.5 s TTL sleep, tautological bucket test, marshal-vs-marshal,
no-assertion test, dead fixtures, always-succeeding producer fake) and HD7 what the harness cannot
show at all: `reference/harness-defects.md` HD6-HD7.

## 6. Zero-coverage hot paths (as of 2026-10-01)

| Path | Coverage |
|---|---|
| `ProcessEvents` (`processors/events_processor/processor.go:32`): commit / withhold / DLQ per record | 0% |
| `processRecordsAndCommit`, `pollRecords`, `assigned`, `lost`, `gracefulShutdown`, `NewConsumerGroup` (`config/kafka/consumer.go:82-227`) | 0% (package 10.9%) |
| `NewKafkaClient`, producer `Produce`/`Ping` (`config/kafka/kafka.go:27`, `config/kafka/producer.go:33,52,72`); option plumbing: producer-option template (§4) | 0% |
| produce-failure -> DLQ branches (`event_producer_service.go:34-89`) | `ProduceToDeadLetterQueue` 55.6% |
| `processEvent` branches `fetch_pay_in_advance_charge` (`processor.go:117-119`), `flag_subscription_refresh` (`:129-131`); `EnrichEvent` capturable `fetch_subscription` (`enrichment_service.go:62-64`) | 0% of those blocks |
| `LoadInitialSnapshot` (`cache/cache.go:63`), `ConsumeChanges` (`:109`), `startGenericConsumer` (`cache/consumer.go:26`), all `Load*Snapshot`/`Start*Consumer` | 0% |
| cache `SearchSubscriptions` tie-break (`cache/subscriptions.go:78-101`) | 0% of those blocks (function 56.8%) |
| `GetAll*` snapshot queries, `StreamRows` / `GetAllWithStreaming` (`models/query_streaming.go:19,95`) | 0% |
| `StartProcessingEvents` (`processors/main_processor.go:102`), `main`, `config/tracing`, `config/redis` | 0% |

116 functions are at 0.0% in the whole-module profile. Raising coverage above 47.4% with
`ProcessEvents` and `processRecordsAndCommit` above 0% is a "beyond current best" TARGET, not the
current state. List and commands: `reference/baselines.md` §6.

## 7. CI shape and gaps

- The only PR workflow is `.github/workflows/events-processor-tests.yml`: path filter
  `events-processor/**` (`:7-13`), `postgres:14-alpine` (`:25`), lago-expression `v0.2.0` built
  and `ldconfig`'d (`:40-56`), Go `1.25.0` (`:61`), then `go test -v ./...` (`:64`).
- No lint, race, gofmt, coverage, shuffle or strict sqlmock in CI: the test step is the only
  check (`.github/workflows/events-processor-tests.yml:63-64`). A PR touching only the workflow
  file, docs, compose or deploy runs no check at all.
- Image builds on `main` are not gated on the tests. Required checks: UNVERIFIED.
- Details and a CANDIDATE list of CI steps: `reference/ci-and-static-checks.md`.

## 8. Static checks you can run locally

| Check | Command | Today |
|---|---|---|
| vet | `go -C events-processor vet ./...` | clean; no CGO env needed |
| gofmt | whole tree: `gofmt -l events-processor`; the gate scope (changed files): §3 step 3 | empty |
| golangci-lint 2.5.0 | `golangci-lint run --allow-serial-runners ./...` in `events-processor/` (the §3 step 4 form without `--new-from-rev`); no CGO env needed (no `--cache-dir` flag in v2: use `GOLANGCI_LINT_CACHE`) | 21 issues |
| module tidy | `go -C events-processor mod tidy -diff` | empty |
| workflow YAML | `python3 -c 'import yaml,sys;[yaml.safe_load(open(f)) for f in sys.argv[1:]]' .github/workflows/*` | parses |
| actionlint | not installed here | see `release-and-images` |
| compose | `docker compose -f docker-compose.dev.yml config --quiet` | exit 0; see `run-and-operate` |
| shell | `bash -n <script>` | passes on all repo scripts |

## 9. Cross-repo changes: lago-api specs

Only for C4 contract changes. The paired lago-api PR pins the Rails side; rules at the pin
(`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`):
never `aggregate_failure` in new tests, prefer `have_received`, run the minimum set
(`$API/AGENTS.md:212-218`); `clickhouse: true` metadata for ClickHouse specs
(`$API/spec/spec_helper.rb:145-146,165-171`); the raw payload Go consumes is pinned in
`$API/spec/services/events/kafka_producer_service_spec.rb:16-46`; scenario specs insert
`events_enriched` directly, so no lago-api spec consumes Go output
(`$API/spec/support/scenarios_helper.rb:501,513`). Running rspec here is not possible (as of 2026-10-01 the sandbox Ruby is
3.3.6 while `$API/.ruby-version` pins 4.0.6, no gems are installed, no Docker daemon). More: `reference/writing-tests.md` §6.

## 10. If you see X, do Y

| You see | Do |
|---|---|
| `go: no such tool "covdata"`, exit 1 from `-coverprofile ./...` | list tested packages (`go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{.ImportPath}}{{end}}' ./...`) or use `baseline.sh` |
| `baseline.sh` FAIL `pass.<pkg>` | a test was deleted, renamed into a failing state, or a package stopped building; read `--- failing tests` |
| FAIL `cover.<pkg>` after adding code | add tests for the new code; do not delete assertions to compensate (`baseline.sh` compares each `cover.<pkg>` at 0.1 pt) |
| FAIL `lint.errcheck` | handle the error, or justify an explicit `_ =` in review; no config file without owner sign-off (OPEN DECISION OD-6 (owner)) |
| WARN `golangci_lint` / `go` version | numbers may shift with versions; re-measure base and branch with the same tools |
| `parallel golangci-lint is running` (exit 3) | another golangci-lint holds the lock; add `--allow-serial-runners` (`baseline.sh` already does) or re-run |
| WARN `coverpkg not measured` | a test or build failed (`scripts/baseline.sh:135`); fix the FAIL rows first, the `coverpkg` row follows |
| a test passes alone but fails in the suite, or the reverse | `race-shuffle.sh --isolation`, then `--seed <n>` from the failing shuffle |
| `TestX/...#01` in `-v` output | duplicate subtest names: mis-nesting (HD2, `processor_test.go:183-202`); fix the nesting in new code |
| `could not match actual sql` | the pin differs from what gorm emits: read the actual SQL, check change-control N4, update the pin as a C3 change |
| `there is a remaining expectation which was not matched` | your test registers a query the path never runs: remove it or fix the scenario (HD1; `sqlmock-strict.sh` lists the known ones) |
| `DATA RACE` | fix it before anything else; the fakes in `tests/` are not goroutine-safe (no mutex: `tests/mocked_producer.go:9-21`) |
| nil-pointer panic in `TestNewConnection` | Postgres is down: look for `connection refused` above the trace (HD5; start Postgres: `build-and-env`) |
| a reviewer asks "does this fail without the change?" | `fails-on-base.sh -- -count=1 -run '<Test>' ./<pkg>/` |

## Scripts

All run from anywhere inside the repo, source `build-and-env/scripts/ep-env.sh` themselves, write
only to `mktemp -d` (and `--write FILE`), and leave `events-processor/` untouched.

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/baseline.sh` | measure tests (per package), own + coverpkg coverage, vet, gofmt, golangci-lint per linter; compare with `baseline.json`; exit 1 on regression | `baseline.sh`; `baseline.sh --baseline base.json`; `--write FILE`; `--no-lint --no-coverpkg`; `--quiet` | `SUMMARY baseline: 0 FAIL, 0 WARN (baseline as_of 2026-10-01 head 5308258; go test exit 0; 4s tests)`. Verified to FAIL on a failing test, a deleted test, a new errcheck issue and an unreachable Postgres |
| `scripts/baseline.json` | today's numbers (flat JSON, one key per line; `ep_tree` = events-processor tree measured) | `jq . baseline.json` | `pass.total 235`, `cover.total 47.4`, `coverpkg.total 44.9`, `lint.total 21` |
| `scripts/race-shuffle.sh` | `-race` once (unit suite), `-shuffle=<seed> -count=10`, optional `--isolation` (each leaf alone) | `race-shuffle.sh --isolation`; `--count 3 --seed 42`; `--no-race`; `--no-shuffle`; `-- ./models/` | `OK race: 6 packages ok, 0 DATA RACE`; `OK shuffle: seed <n> x10`; `OK isolation: 202 leaf tests run alone, 2 failed (2 known, 0 new)`; exit 0 |
| `scripts/sqlmock-strict.sh` | overlay a `tests/mocked_store.go` whose cleanup calls `ExpectationsWereMet()`; report unmet expectations per subtest | `sqlmock-strict.sh`; `--all` (exit 1 on any) | 4 `KNOWN unmet` lines; `SUMMARY sqlmock-strict: 4 unmet-expectation subtests (4 known, 0 new), 0 other failures, 5 packages fully ok`; exit 0 (`--all`: exit 1) |
| `scripts/fails-on-base.sh` | swap changed production `.go` files back to `$BASE` via overlay, run your tests, expect them to fail | `fails-on-base.sh -- -count=1 -run TestX ./utils/` | `EVIDENCE OK` (exit 0), `WEAK EVIDENCE` (exit 0, test does not compile on base: new function, type, field or option; paste the compile error), `NO EVIDENCE` (exit 1), exit 3 if no production file changed. All four verified in a scratch clone |
| `scripts/templates-check.sh` | overlay the 5 templates into their packages and run `^TestTemplate` | `templates-check.sh -v`; `-race` | `templates-check: OK all templates pass (5 files)` |

## Provenance and maintenance

- **Sources.** `events-processor/**/*_test.go`, `events-processor/tests/*.go`,
  `processors/events_processor/{processor,enrichment_service,event_producer_service}.go`,
  `models/{billable_metrics,subscriptions,charges,stores}.go`, `cache/subscriptions.go`,
  `.github/workflows/events-processor-tests.yml`, go-sqlmock v1.5.2 `query.go`;
  `config/kafka/{kafka,producer}.go` and franz-go v1.20.5 `pkg/kgo/client.go` (`OptValue`);
  commits `9acd83e`, `45b216d`, `2fd8e8b`, `d9c32b6`, `fff5858` read with `git -C "$H" show`;
  `$API/AGENTS.md`, `$API/spec/spec_helper.rb`, `$API/spec/support/{kafka_helper,scenarios_helper}.rb`,
  `$API/spec/services/events/kafka_producer_service_spec.rb`, `$API/.github/workflows/spec.yml`.
- **Paths.** `H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`;
  `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`.
- **Volatile facts, one re-check each** (as of 2026-10-01):
  - All baselines at once: `.claude/skills/validation-and-qa/scripts/baseline.sh --quiet` -> `0 FAIL, 0 WARN`.
  - PASS count: `.claude/skills/build-and-env/scripts/ep-test.sh -v -count=1 ./... 2>&1 | grep -c -- '--- PASS'` -> `235`.
  - Lint (no CGO env needed; cwd `events-processor/`): `GOLANGCI_LINT_CACHE="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/golangci-cache" golangci-lint run --allow-serial-runners ./... | tail -3` -> `21 issues:` / `* errcheck: 16` / `* staticcheck: 5`.
  - covdata trap: `.claude/skills/build-and-env/scripts/ep-test.sh -coverprofile=/dev/null ./... >/dev/null 2>&1; echo $?` -> `1`.
  - Unit-suite race does not reach the consumer; the kfake run does: `GOFLAGS=-race .claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh happy-path -n 5000 -partitions 4 | tail -1` -> `RESULT: PASS (every record enriched + in-advance, 0 DLQ, offsets committed)`.
  - sqlmock never verified: `grep -rn ExpectationsWereMet events-processor | wc -l` -> `0`.
  - Strict sqlmock: `.claude/skills/validation-and-qa/scripts/sqlmock-strict.sh | tail -1` -> `4 known, 0 new`.
  - Order dependence: `.claude/skills/validation-and-qa/scripts/race-shuffle.sh --no-race --no-shuffle --isolation | tail -2` -> `202 leaf tests run alone, 2 failed (2 known, 0 new)`.
  - Mis-nesting: `sed -n 424p events-processor/processors/events_processor/processor_test.go` -> `setupProcessorTestEnv(t, true)`.
  - Sleeps: `grep -c 'time.Sleep(50' events-processor/processors/events_processor/processor_test.go` -> `3`.
  - No lint config ever: `git -C "$H" log --all --oneline -- '*golangci*' | wc -l` -> `0`.
  - CI test step: `sed -n 64p .github/workflows/events-processor-tests.yml` -> `run: go test -v ./...`.
  - CI PR filter: `sed -n 12,13p .github/workflows/events-processor-tests.yml` -> `paths:` / `"events-processor/**"`.
  - Templates still valid: `.claude/skills/validation-and-qa/scripts/templates-check.sh` -> `OK all templates pass (5 files)`.
  - EP tree measured (= the code of 5308258): `git rev-parse 5308258:events-processor HEAD:events-processor | cut -c1-12` -> `83e012866f29` twice.
- **Update triggers.** Re-verify and refresh `baseline.json` when: any `*_test.go` or `tests/*.go`
  changes; a dependency or Go/golangci-lint version changes; `events-processor-tests.yml` changes;
  a harness defect is fixed (empty the KNOWN lists in `race-shuffle.sh` / `sqlmock-strict.sh`);
  franz-go is bumped (re-run `templates-check.sh`: the producer-option template pins its defaults);
  the owner decides OPEN DECISION OD-5 (owner) or OPEN DECISION OD-6 (owner); a lint config or new CI job lands; lago-api's pin moves
  (re-check §9 line numbers).
