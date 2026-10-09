# Build and test failures: lookup table

Read when `go build` / `go test` / `go vet` / lint of `events-processor/` fails and SKILL.md section 6
was not enough. This file only maps the exact text to an `explain-error.sh` entry and to the owner row.
Reproduction, cause and fix live with the owner, so they are kept in one place:

- build, toolchain and Postgres-for-tests rows: `build-and-env` (`reference/traps.md` B1-B15; SKILL.md
  section 5 "Trap table");
- test-harness rows (order-dependent subtests, sqlmock pins, `#01` names, log noise):
  `validation-and-qa` (harness defects HD#, `reference/harness-defects.md`; SKILL.md section 10 "If you see X").

`explain-error.sh --id <entry>` prints the playbook's short cause / confirm / fix for any row. All texts
were captured 2026-10-01 (local Go 1.24.7, `GOTOOLCHAIN=auto` -> go1.25.0, Postgres 16).

Baseline to compare against (as of 2026-10-01; owner `validation-and-qa`):
`.claude/skills/build-and-env/scripts/ep-test.sh` -> `ok` for cache, config/database, config/kafka,
models, processors/events_processor, utils; `-v` shows 235 `--- PASS`, 0 FAIL, 0 SKIP.

| # | Exact text (first line) | Entry | Owner row |
|---|---|---|---|
| BT1 | `/usr/bin/ld: cannot find -lexpression_go: No such file or directory` | `build-link` | build-and-env B1 |
| BT2 | `events_processor.test: error while loading shared libraries: libexpression_go.so: cannot open shared object file: No such file or directory` | `build-loader` | build-and-env B2 |
| BT3 | `imports github.com/getlago/lago-expression/expression-go: build constraints exclude all Go files in .../expression-go@v0.1.4` | `build-cgo-disabled` | build-and-env B3 |
| BT4 | `cgo: C compiler "nonexistent-cc" not found: exec: "nonexistent-cc": executable file not found in $PATH` | `build-cc-missing` | build-and-env B3 |
| BT5 | `go: go.mod requires go >= 1.25.0 (running go 1.24.7; GOTOOLCHAIN=local)` | `build-go-toolchain` | build-and-env B5 |
| BT6 | `go: no such tool "covdata"` (5 lines on 2026-10-01: `.` (main), `config/redis`, `config/tracing`, `processors`, `tests`), exit 1, although the 6 tested packages print coverage | `test-covdata` | build-and-env B4 (gated coverage number: `validation-and-qa`) |
| BT7 | `--- FAIL: TestNewConnection`, then `panic: runtime error: invalid memory address or nil pointer dereference` with frame `config/database/database_test.go:24`; the real error is ABOVE the stack | `test-pg-down` | build-and-env B6 |
| BT8 | `--- FAIL: TestEvaluateExpression/With_an_expression_and_with_required_fields` or `--- FAIL: TestEvaluateExpression/With_a_float_timestamp` (`expected: string("36")`, `actual  : <nil>(<nil>)`), only when run alone | `test-order-dependent` | validation-and-qa HD3 |
| BT9 | `ERROR Query: could not match actual sql: "SELECT ..." with expected regexp "..."` | `test-sqlmock-mismatch` | validation-and-qa section 10; change-control N4 |
| BT10 | `TestProcessEvent/<scenario>#01` in `-v` output | `test-dup-name` | validation-and-qa HD2 |
| BT11 | `Error: unknown flag: --cache-dir` (golangci-lint) | `test-lint-cache-dir` | build-and-env B14 |
| BT12 | noise in a PASSING run: `ERROR Failed to cache item ... error="DB Closed"`, `ERROR Failed to unmarshal ...`, `ERROR database connection failed component=db ...` | - (not a failure) | validation-and-qa `reference/writing-tests.md` (noise in green runs) |
| BT13 | `go: module github.com/getlago/lago-expression@v0.2.0 found, but does not contain package .../expression-go` | `build-expression-tag` | build-and-env B13 |
| BT14 | `Error: parallel golangci-lint is running` | `test-lint-parallel` | build-and-env B14 |

Only `--- FAIL` / `FAIL` lines matter in a test run; `ERROR` lines in a green run are deliberate
negative-path tests (BT12).

Error-string coupling: tests pin the stdlib text `strconv.ParseFloat: parsing "<value>": invalid syntax`
(`processors/events_processor/processor_test.go:288`, `enrichment_service_test.go:113`,
`models/event_test.go:54`, `utils/time_test.go:58,110`). A Go upgrade that rewords it fails these tests
with no behaviour change (test-design rule: `validation-and-qa` `reference/writing-tests.md`).

Green locally, red in CI (or the reverse): CI's shape (Postgres 14 service, lago-expression built from
the workflow's own ref, Go 1.25.0, `go test -v ./...` only, no lint/race/gofmt/coverage) is owned by
`validation-and-qa` section 7; the triage row is `dev-ci-release.md` CI3.
