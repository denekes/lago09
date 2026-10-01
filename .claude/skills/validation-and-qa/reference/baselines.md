# Baselines (measured 2026-10-01) and how they were measured

Read this when a number in a PR does not match, when you refresh `scripts/baseline.json`, or when
you need the zero-coverage list. Every number below was re-measured on 2026-10-01. Code facts as of
5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only commits on
top (`git rev-parse 5308258:events-processor HEAD:events-processor` prints the same tree twice).
Environment: go1.25.0 (fetched by `GOTOOLCHAIN=auto`; local Go is 1.24.7),
4 vCPU, Postgres 16 on localhost with role/db `lago`, golangci-lint 2.5.0, lago-expression v0.2.0.

Path convention: code cites are relative to `events-processor/`; bare `processor_test.go`,
`enrichment_service_test.go`, `event_producer_service_test.go`, `processor.go`,
`enrichment_service.go` and `event_producer_service.go` live in `processors/events_processor/`.

## 1. Test counts

`baseline.sh` counts from `go test -json` (`"Action":"pass"` events with a `Test` field).
The same numbers come from `-v` output:

```bash
.claude/skills/build-and-env/scripts/ep-test.sh -v -count=1 ./... > "${TMPDIR:-/tmp}/v.txt" 2>&1
grep -c -- '--- PASS' "${TMPDIR:-/tmp}/v.txt"       # 235
grep -c -- '^--- PASS' "${TMPDIR:-/tmp}/v.txt"      # 113 top-level
grep -cE -- '^\s+--- PASS' "${TMPDIR:-/tmp}/v.txt"  # 122 subtests (any depth)
grep -c -- '--- FAIL\|--- SKIP' "${TMPDIR:-/tmp}/v.txt"   # 0
```

<!-- evidence-check: off measurements produced by the commands in the block above and by scripts/baseline.sh -->
| package | top-level | subtests | PASS | own coverage | coverage with `-coverpkg=./...` |
|---|---|---|---|---|---|
| cache | 61 | 6 | 67 | 40.1% | 45.8% (168/367) |
| config/database | 1 | 0 | 1 | 76.2% | 76.2% (16/21) |
| config/kafka | 1 | 6 | 7 | 10.9% | 10.9% (17/156) |
| config/redis | no tests | | | n/a | 0.0% (0/14) |
| config/tracing | no tests | | | n/a | 0.0% (0/189) |
| models | 6 | 20 | 26 | 41.2% | 45.4% (54/119) |
| processors/events_processor | 8 | 42 | 50 | 68.4% | 68.4% (106/155) |
| tests (shared fakes) | no tests | | | n/a | 68.2% (15/22) |
| utils | 36 | 48 | 84 | 72.4% | 89.0% (187/210) |
| `.` (main) and `processors` | no tests | | | n/a | not in the profile |
| **total** | **113** | **122** | **235** | **47.4% (487/1028)** | **44.9% (563/1253)** |

- 24 `*_test.go` files, 4,018 lines (`find events-processor -name '*_test.go' | xargs wc -l | tail -1`).
- 0 FAIL, 0 SKIP. 202 leaf tests (tests with no subtests of their own).
- Packages without test files: `.` (main), `config/redis`, `config/tracing`, `processors`, `tests`.
<!-- evidence-check: on -->

## 2. Coverage: three numbers, three meanings

| Number | Command (cwd `events-processor/`, after `source .claude/skills/build-and-env/scripts/ep-env.sh`) | Meaning |
|---|---|---|
| 47.4% | `PKGS=$(go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{.ImportPath}}{{end}}' ./...); go test -count=1 -coverprofile="${TMPDIR:-/tmp}/c.out" $PKGS; go tool cover -func="${TMPDIR:-/tmp}/c.out" \| tail -1` | statements of the 6 tested packages, each covered by its own tests. **The gated number.** |
| 44.9% | same with `-coverpkg=./...` | statements of every package linked into a test binary, covered by any test. `main` and `processors` are missing: no test binary links them. Informational (`baseline.sh` WARNs on a drop, never FAILs). |
| 42.0% (563/1342) | the overlay snippet below | whole module including `main` (0/34) and `processors` (0/55). Informational. |

- **Trap:** `go test -coverprofile=... ./...` exits **1** on go1.25.0 with
  `go: no such tool "covdata"` once per package without tests (`.`, `config/redis`,
  `config/tracing`, `processors`, `tests`). The tested packages still print coverage. Always pass
  the package list instead of `./...`. Whether CI's `setup-go` 1.25.0 has `covdata` is UNVERIFIED.
- The per-package lines printed by a `-coverpkg` run ("coverage: 20.7% of statements in ./...")
  are per test binary and do not add up; use `go tool cover -func ... | tail -1`.
- `baseline.sh` derives per-package numbers from the profile (a block counts once; the highest
  hit count wins), which reproduces `go tool cover` exactly.

Whole-module coverage (adds an empty test file to each untested package through an overlay, so no
`covdata` is needed; verified 2026-10-01, ~6 s warm):

```bash
source .claude/skills/build-and-env/scripts/ep-env.sh && cd events-processor
W=$(mktemp -d); EP=$PWD; printf '{"Replace":{' > "$W/o.json"; sep=
for d in . config/redis config/tracing processors tests; do
  p=$(sed -nE 's/^package ([a-z_]+).*/\1/p' "$d"/*.go | head -1); printf 'package %s\n' "$p" > "$W/$p.go"
  printf '%s"%s/%s/zz_cov_test.go":"%s/%s.go"' "$sep" "$EP" "$d" "$W" "$p" >> "$W/o.json"; sep=,
done; printf '}}\n' >> "$W/o.json"
go test -count=1 -overlay="$W/o.json" -coverpkg=./... -coverprofile="$W/all.out" ./... > /dev/null
go tool cover -func="$W/all.out" | tail -1        # total: (statements) 42.0%
echo "$W"                                          # outside the repo; delete it when done
```

## 3. Static checks

| Check | Command (cwd `events-processor/`) | Result | Note |
|---|---|---|---|
| go vet | `go vet ./...` | exit 0, no output | does NOT need the CGO env (type-checks, no link): verified with `env -u CGO_LDFLAGS -u LD_LIBRARY_PATH go vet ./...` |
| gofmt | `gofmt -l .` | no output | |
| module hygiene | `go mod tidy -diff` | exit 0, empty diff | |
| golangci-lint 2.5.0 | `GOLANGCI_LINT_CACHE="$LAGO_SKILLS_CACHE/golangci-cache" golangci-lint run --allow-serial-runners ./...` | exit 1, `21 issues: errcheck: 16, staticcheck: 5` | no config in the repo, ever (`git -C "$H" log --all --oneline -- '*golangci*'` prints nothing; `H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`), so v2 defaults apply: errcheck, govet, ineffassign, staticcheck, unused. Works without the CGO env. `--cache-dir` is not a flag (exit 3); use `GOLANGCI_LINT_CACHE`. ~20 s cold, ~5 s with a warm cache |
| lint gate | `golangci-lint run --new-from-rev="$BASE" ./...` | `0 issues.` at `--new-from-rev=HEAD` | the gate is "no NEW issues" (OPEN DECISION OD-6 (owner)) |

The 21 issues (file:line, linter):

| Where | Issue |
|---|---|
| production errcheck (8) | `cache/cache.go:76` errGroup.Wait; `config/kafka/consumer.go:134` errgroup.Wait; `config/tracing/datadog_tracer.go:111` ddtracer.Start; `main.go:75` memCache.Close; `models/query_streaming.go:35` rows.Close; `processors/events_processor/processor.go:95` g.Wait; `processor.go:101` errgroup.Wait; `processors/main_processor.go:156` flagger.Close |
| test errcheck (8) | `cache/cache_test.go:82,209`; `cache/consumer_test.go:31,215`; `models/stores_test.go:115`; `processors/events_processor/enrichment_service_test.go:33`; `processor_test.go:150`; `tests/mocked_store.go:39` |
| staticcheck (5) | `main.go:46:5` SA4023 "this comparison is never true" (`tracerProvider == nil` is dead code) and its companion `main.go:45:20` "SA4023(related information)", counted as a separate issue; ST1005 capitalised error strings at `utils/time.go:45`, `utils/result_test.go:12,107` |

So the staticcheck count is 5 issues but 4 distinct findings. Per-linter counts are what
`baseline.sh` compares; `--new-from-rev` is what change-control's C2 gate runs.

## 4. Race, shuffle, isolation, strict sqlmock

| Check | Command | Result 2026-10-01 | Wall time (warm) |
|---|---|---|---|
| race (unit suite only: never runs `ProcessEvents` / `processRecordsAndCommit`) | `ep-test.sh -race -count=1 ./...` | 6 ok, 0 `WARNING: DATA RACE` | ~7-8 s (cache 5.4 s) |
| race on the real consumer path | `GOFLAGS=-race .claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh happy-path -n 5000 -partitions 4` | `RESULT: PASS`, exit 0 (66 = data race) | ~5 s |
| shuffle | `ep-test.sh -shuffle=on -count=10 ./...` | 6 ok | ~31 s (cache 29 s: `TestDeleteWithTTL_Success` sleeps 1.5 s per round) |
| isolation | `scripts/race-shuffle.sh --isolation` | 202 leaves run alone, 2 fail (both known, `TestEvaluateExpression`) | ~25-31 s |
| strict sqlmock | `scripts/sqlmock-strict.sh` | 4 subtests with unmet expectations (all known) | ~6 s |

`-shuffle` reorders only top-level tests (Go's `testing` shuffles `m.tests`), never subtests, so
it cannot find the `TestEvaluateExpression` dependency. Only isolation does.

## 5. Timings

<!-- evidence-check: off timings; the "How measured" column is the command, run under time -->
| What | Time | How measured |
|---|---|---|
| full suite, warm build cache | 4-5 s | `time ep-test.sh` |
| full suite, empty `GOCACHE`, warm module cache | 60-75 s typical on 4 vCPU, up to ~120 s under load (runs on 2026-10-01: 74 s, 123 s loaded; build-and-env measured ~62 s) | `GOCACHE=<empty dir> ep-test.sh` |
| full suite with `-race`, warm | ~7-8 s | `time ep-test.sh -race -count=1 ./...` |
| `baseline.sh` | ~12 s with a warm lint cache, ~29 s cold | `time scripts/baseline.sh` |
| `race-shuffle.sh` (default x10) | ~40 s; `--isolation` ~60-75 s; `--isolation --count 3` ~43 s | `time` |
| slowest tests | `TestDeleteWithTTL_Success` 1.52 s (`cache/cache_test.go:362` sleep), `TestProcessEvent` 0.50 s, `TestEnrichEvent` 0.15 s | `-v` output |
<!-- evidence-check: on -->

## 6. Zero-coverage hot paths (merged whole-module profile, 2026-10-01)

These are the paths where a bug loses or mis-values events and no test would notice. Each one is
a gap, not a target to fix in passing: delivery code changes are C4 (change-control N7).

| Area | Function (file:line) | Coverage | Why it matters |
|---|---|---|---|
| per-record disposition | `ProcessEvents` (`processors/events_processor/processor.go:32`) | 0% | commits undecodable records with no DLQ (`:50-59`), withholds retryable failures younger than 12 h (`:74-79`), DLQs the rest (`:82`) |
| processEvent error branches | `processor.go:117-119` (`fetch_pay_in_advance_charge`), `:129-131` (`flag_subscription_refresh`) | 0% of those blocks (`processEvent` 90.5%) | DLQ codes never produced by a test |
| enrichment error branch | `enrichment_service.go:62-64` (`fetch_subscription`, capturable) | 0% (`EnrichEvent` 92.9%) | `MockDataStore.ExpectSubscriptionError` exists (`processor_test.go:115-117`) but nothing calls it |
| produce failures | `event_producer_service.go:34-37,45-48,61-64,70-73,78-80,87-89` | `ProduceEnrichedEvent` 60%, `ProduceChargedInAdvanceEvent` 60%, `ProduceToDeadLetterQueue` 55.6% | `tests.MockMessageProducer.Produce` always returns true (`tests/mocked_producer.go:20`) |
| Kafka consumer group | `processRecordsAndCommit` (`config/kafka/consumer.go:82`), `assigned` (:111), `lost` (:132), `poll` (:152), `pollRecords` (:167), `gracefulShutdown` (:207), `NewConsumerGroup` (:227) | 0% (package 10.9%; only `findMaxCommitableRecord` :278 is 100%) | the commit algorithm; change-control N7 requires a kfake test before changing it |
| Kafka client/producer | `NewKafkaClient` (`config/kafka/kafka.go:27`), `NewProducer`/`Produce`/`Ping` (`config/kafka/producer.go:33,52,72`) | 0% | SASL/TLS options; an unknown SCRAM algorithm panics (`debugging-playbook`). Option plumbing needs no broker: `templates/producer_option_template_test.go.tmpl` |
| memory cache load | `LoadInitialSnapshot` (`cache/cache.go:63`), `ConsumeChanges` (:109), `startGenericConsumer` (`cache/consumer.go:26`), every `Load*Snapshot` / `Start*Consumer` | 0% | snapshot failures are swallowed (`architecture-contract`); OPEN DECISION OD-1 (owner) decides how much this matters |
| cache subscription tie-break | `SearchSubscriptions` (`cache/subscriptions.go:45`), blocks `:49-51`, `:56-57`, `:78-101` | 56.8% | must mirror `ORDER BY terminated_at DESC NULLS FIRST, started_at DESC` (`models/subscriptions.go:40`); no test has two candidates (the cache template adds them) |
| snapshot SQL | `GetAll*` in `models/*.go`, `StreamRows` / `GetAllWithStreaming` (`models/query_streaming.go:19,95`) | 0% | the snapshot SQL never runs against sqlmock or Postgres |
| pay-in-advance SQL | `ApiStore.HasPayInAdvanceCharge` (`models/charges.go:47`) | 80%, via a loose regex only (`processor_test.go:108`) | its WHERE clause is unpinned (the model-query template pins it) |
| wiring | `StartProcessingEvents` (`processors/main_processor.go:102`), `main` (`main.go:27`), `config/tracing` (0/189), `config/redis` (0/14) | 0% | startup is only partially fail-fast (`architecture-contract` I14); startup order and its panics are only checked by binary smoke (`diagnostics-and-tooling`) |

Re-derive the full list (116 functions at 0.0%) with the overlay snippet of §2, then:
`go tool cover -func="$W/all.out" | awk '$NF=="0.0%"'`.

Raising these numbers is a "beyond current best" TARGET (coverage above 47.4% with `ProcessEvents`
and `processRecordsAndCommit` above 0%), not the current state. The design of the delivery tests
belongs to `event-accounting-campaign`.

## 7. Refresh procedure

1. Run `.claude/skills/validation-and-qa/scripts/baseline.sh`. Read every row that is not `OK`.
2. If only improvements are reported, write the new file:
   `.claude/skills/validation-and-qa/scripts/baseline.sh --write .claude/skills/validation-and-qa/scripts/baseline.json`.
3. Review `git diff -- .claude/skills/validation-and-qa/scripts/baseline.json`.
4. Update the numbers in SKILL.md §2 and in this file in the same commit (class C1).
5. If golangci-lint or Go changes version, expect a `WARN` row; re-measure and say so in the PR.
