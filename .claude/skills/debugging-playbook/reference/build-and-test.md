# Build and test failures: exact output, cause, fix

Read when `go build` / `go test` / `go vet` / lint of `events-processor/` fails and SKILL.md section 6
was not enough. All commands run from the repo root unless a `cd events-processor` is shown; all
outputs captured 2026-10-01 (local Go 1.24.7, `GOTOOLCHAIN=auto` -> go1.25.0, Postgres 16). The
environment recipe itself (cargo, Postgres role, toolchain matrix) is owned by `build-and-env`;
test policy and baselines by `validation-and-qa`.

Baseline to compare against (as of 2026-10-01): `.claude/skills/build-and-env/scripts/ep-test.sh` ->
`ok` for cache, config/database, config/kafka, models, processors/events_processor, utils; `-v` shows
235 `--- PASS`, 0 FAIL, 0 SKIP. If you see anything else on a clean checkout, start here.

| # | Exact text | Reproduce | Cause | Fix |
|---|---|---|---|---|
| B1 | `/usr/bin/ld: cannot find -lexpression_go: No such file or directory` then `collect2: error: ld returned 1 exit status` | `source .claude/skills/build-and-env/scripts/ep-env.sh; cd events-processor; env -u CGO_LDFLAGS go build ./...` | the Go wrapper says only `#cgo LDFLAGS: -lexpression_go`; no `-L` | `source .claude/skills/build-and-env/scripts/ep-env.sh` (from inside the repo: it locates the repo with `git rev-parse`) |
| B2 | `events_processor.test: error while loading shared libraries: libexpression_go.so: cannot open shared object file: No such file or directory` then `FAIL ...processors/events_processor 0.001s` | `env -u LD_LIBRARY_PATH go test -count=1 ./processors/events_processor/` | link worked, the loader cannot find the `.so` | same; CI copies it to `/usr/local/lib` + `ldconfig` (`.github/workflows/events-processor-tests.yml:51-56`) |
| B3 | `imports github.com/getlago/lago-expression/expression-go: build constraints exclude all Go files in .../expression-go@v0.1.4` | `CGO_ENABLED=0 go build ./...` | cgo disabled (explicitly, or no C compiler) | unset `CGO_ENABLED`; install gcc; or `.claude/skills/build-and-env/scripts/ep-test.sh --no-cgo` (5 packages) |
| B4 | `cgo: C compiler "nonexistent-cc" not found: exec: "nonexistent-cc": executable file not found in $PATH` | `CC=nonexistent-cc go build ./...` | `CC` points nowhere | unset `CC` |
| B5 | `go: go.mod requires go >= 1.25.0 (running go 1.24.7; GOTOOLCHAIN=local)` | `GOTOOLCHAIN=local go build ./...` | old local Go, auto-download disabled | unset `GOTOOLCHAIN`, run once online |
| B6 | `go: no such tool "covdata"` (3 lines on 2026-10-01: `config/redis`, `processors`, `tests`), exit 1, although 6 packages print coverage | `go test -count=1 -coverprofile="$(mktemp -d)/c.out" ./...` | the go1.25.0 module toolchain has no `covdata`, needed for the 5 packages without tests | `PKGS=$(go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{.ImportPath}}{{end}}' ./...)` then `go test -count=1 -coverprofile="$(mktemp -d)/c.out" $PKGS` (47.4%) |
| B7 | `--- FAIL: TestNewConnection`, then `panic: runtime error: invalid memory address or nil pointer dereference [recovered, repanicked]` with frame `config/database/database_test.go:24` | `DATABASE_URL=postgres://lago:lago@127.0.0.1:5499/lago go test -count=1 ./config/database/` | Postgres unreachable; the test asserts then dereferences nil (`database_test.go:21-25`). The REAL error is printed ABOVE: `dial tcp 127.0.0.1:5499: connect: connection refused` | `pg_isready -d "$DATABASE_URL"`; sandbox: `pg_ctlcluster 16 main start` (role/db recipe: `build-and-env`) |
| B8 | `--- FAIL: TestEvaluateExpression/With_an_expression_and_with_required_fields` / `expected: string("36")` / `actual  : <nil>(<nil>)` | `go test -count=1 -run 'TestEvaluateExpression/With_an_expression_and_with_required_fields' ./processors/events_processor/` | subtests share `bm`, `event`, `result` (`processors/events_processor/enrichment_service_test.go:256-258`); this one relies on the previous sibling setting `bm.Expression` | run the parent: `go test -count=1 -run TestEvaluateExpression ./processors/events_processor/` -> `ok` |
| B9 | `ERROR Query: could not match actual sql: "SELECT "id",... FROM "billable_metrics" ..." with expected regexp "SELECT \* FROM "billable_metrics" ..."` then `--- FAIL: TestFetchBillableMetric/should_return_billable_metric_when_found` | `go test -overlay` with explicit columns in `FetchBillableMetric` (overlay technique: `diagnostics-and-tooling`) | sqlmock pins the exact SQL (by design, change-control N4) | update the expected SQL in `models/billable_metrics_test.go` in the same PR |
| B10 | `TestProcessEvent/<scenario>#01` in `-v` output | `go test -count=1 -v -run TestProcessEvent ./processors/events_processor/` | only the first scenario is nested under the mode name (`processor_test.go:183-203`); `#01` = the second mode; one scenario hard-codes cache mode (`processor_test.go:424`) | read `#01` as "second mode"; restructuring is a change-class C1 change (`validation-and-qa`) |
| B11 | `Error: unknown flag: --cache-dir` (golangci-lint) | `golangci-lint run --cache-dir x ./...` | golangci-lint v2 CLI | `GOLANGCI_LINT_CACHE=$(mktemp -d) golangci-lint run ./...` -> 21 issues baseline (OPEN DECISION OD-6 (owner) for policy) |
| B12 | expected noise in a PASSING run: `ERROR Failed to cache item ... error="DB Closed"`, `ERROR Failed to unmarshal ...`, `ERROR database connection failed component=db ... query="SELECT * FROM \"billable_metrics\"..."` | `go test -count=1 -v ./...` | deliberate negative-path tests logging through slog | nothing; only `--- FAIL` / `FAIL` lines matter |

Error-string coupling to keep in mind: tests assert the stdlib text
`strconv.ParseFloat: parsing "<value>": invalid syntax`, with `"2025-03-06 12:00:00"`
(`processors/events_processor/processor_test.go:288`, `enrichment_service_test.go:113`) and
`"2025-03-03 13:03:29"` (`models/event_test.go:54`, `utils/time_test.go:58,110`). A Go upgrade that
rewords it fails these tests without any behaviour change.

## Where CI differs from your machine

| CI (`.github/workflows/events-processor-tests.yml`) | Local recipe | Consequence |
|---|---|---|
| Postgres 14 service (`:25`) | whatever you run (sandbox 16) | only connectivity is tested; version differences do not matter today |
| lago-expression checked out at `ref: v0.2.0` (`:45`), built, copied to `/usr/local/lib` | `ep-env.sh` reads the ref from `events-processor/Dockerfile` | if the 4 pin places diverge (change-control N3), local and CI test different libraries |
| `go-version: "1.25.0"` (`:61`) | `GOTOOLCHAIN=auto` -> go1.25.0 | same |
| `go test -v ./...` only | `ep-test.sh` runs the same; add `go vet`, gofmt, lint yourself | CI has no lint/race/coverage/gofmt: the local gate is the only gate (change-control N9) |
