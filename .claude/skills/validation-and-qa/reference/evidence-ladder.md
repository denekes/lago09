# Evidence ladder: what counts as proof, per change class

Read this when you prepare the evidence block of a PR, or when you review one and must decide
whether the evidence is enough. The classes (C0-C7), the gates and the sign-off rules are owned by
`change-control`; this file says what output proves each gate, how to produce it, and what does
NOT count. All commands run from the repo root. Facts as of 2026-10-01.

Path convention: code cites are relative to `events-processor/`; bare `processor_test.go`,
`enrichment_service_test.go`, `event_producer_service_test.go`, `processor.go`,
`enrichment_service.go` and `event_producer_service.go` live in `processors/events_processor/`.

```bash
cd "$(git rev-parse --show-toplevel)"
V=.claude/skills/validation-and-qa/scripts
BASE=$(git merge-base origin/main HEAD)        # the PR base
```

`ep-test.sh` below means `.claude/skills/build-and-env/scripts/ep-test.sh` (go test args pass through).

## 1. The rules that apply to every class

1. **Evidence is output you produced.** A command, its exit status and the lines that matter,
   run at a stated sha. A sentence such as "tests pass" is a claim, not evidence (change-control N13).
2. **Show the red, then the green.** A test only proves a change if you saw it fail without the
   change. `$V/fails-on-base.sh` produces that run without touching the repo.
3. **Compare with a baseline, not with memory.** `$V/baseline.sh` compares against
   `scripts/baseline.json` (2026-10-01) or against a file you wrote on `$BASE`.
4. **CI is not evidence for anything but `go test -v ./...` on Postgres 14,** and only when the
   PR touches `events-processor/**` (`.github/workflows/events-processor-tests.yml:7-13,63-64`).
   Lint, race, gofmt, coverage and shuffle exist only locally.
5. **Never write into the repo to get evidence** (change-control N10). Every script here uses
   `go test -overlay` or temp dirs. After any run, `git status --porcelain --ignored -- events-processor`
   must print nothing.

## 2. The ladder

Each rung includes everything above it for events-processor code. "Known" means the item is in the
script's known list (verified 2026-10-01) and does not fail the run.

| Class | Evidence that counts | Command(s) | Pass condition |
|---|---|---|---|
| C0 docs/skills | each new claim has `path:line`, a sha or a command + output; each documented command was run, or is marked "not runnable here; verified by reading `<file:line>`" | the commands you document; `research-methodology` citation lint | outputs pasted; nothing unlabelled |
| C1 tests/tooling | full suite green; PASS count up by exactly your new tests; race clean; new leaves pass alone; no NEW unmet sqlmock expectation; for a regression test: its failing run on the unfixed code | `$V/baseline.sh`; `$V/race-shuffle.sh --isolation`; `$V/sqlmock-strict.sh`; for skill scripts `bash -n` + a real run + clean `git status` | 0 FAIL; `isolation ... 0 new`; `0 new` unmet |
| C2 refactor (no behaviour change) | C1 + no test expectation changed + vet/gofmt clean + no new lint + coverage of touched packages not lower | `$V/baseline.sh`; `golangci-lint run --new-from-rev="$BASE" ./...`; `git diff "$BASE" -- 'events-processor/*_test.go' \| grep -E '^-[^-]'` | `SUMMARY baseline: 0 FAIL`; `0 issues.`; the diff grep prints nothing |
| C3 behaviour | C2 + a new or changed test that FAILS on `$BASE` and PASSES on the branch; both data modes when the logic exists in both; exact SQL pinned for query changes; parity evidence | `$V/fails-on-base.sh -- -count=1 -run '<TestName>' ./<pkg>/` then the same `go test` green; parity probe from `rails-go-parity`; before/after table for value/time changes (`event-accounting-campaign`) | `EVIDENCE OK` + green run; both `WithCache` and `WithoutCache` subtests listed |
| C4 delivery / contract | C3 + a kfake-driven test through `processRecordsAndCommit` with a per-offset outcome (enriched / DLQ / redelivered / LOST) + ADR + paired lago-api PR | kfake harness from `diagnostics-and-tooling`; ledger from `event-accounting-campaign` | ledger pasted; ADR linked; lago-api PR linked (OPEN DECISION OD-4 (owner), default YES); owner sign-off (OPEN DECISION OD-2 (owner)) |
| C5 release/pins/CI | pin-sync output; for dependency, Go or lago-expression bumps the full C2 rung on the new versions; workflow YAML parses; actionlint shows no NEW finding; images "not built locally" | `pin-sync-check.sh` (change-control); `$V/baseline.sh` (expect a `go`/toolchain WARN on a Go bump); `python3 -c 'import yaml,sys;[yaml.safe_load(open(f)) for f in sys.argv[1:]]' .github/workflows/*`; actionlint via `release-and-images` | 0 FAIL; YAML command prints nothing |
| C6 dev env/compose/deploy | `docker compose -f <file> config --quiet` exit 0 for each touched file; service-list diff; `bash -n` on touched scripts; bring-up either done on a machine with a daemon (paste it) or labelled "not runnable in a daemon-less sandbox" | see `run-and-operate` (compose matrix) | exit 0; diff explained |
| C7 security overlay | counts-only scan output and file:line, never a value | `security-and-supply-chain` scans; change-control `precommit-guard.sh` | 0 FAIL |

### C1 detail: a new test

1. Run it 3 times and alone: `ep-test.sh -count=3 -run '^TestNew$' ./<pkg>/`.
2. Run it under the race detector: `ep-test.sh -race -count=1 -run '^TestNew$' ./<pkg>/`.
3. `$V/race-shuffle.sh --isolation`: every leaf of your test must pass alone (no shared state).
4. `$V/sqlmock-strict.sh`: your DB-mode test must not add an unmet expectation.
5. `$V/baseline.sh`: `pass.total` goes up by exactly the number of new leaves plus parents.
   Refresh `baseline.json` in the same PR (§4).

### C3 detail: the red/green pair

```bash
$V/fails-on-base.sh -- -count=1 -run 'TestFoo' ./processors/events_processor/
# expect: "--- FAIL: TestFoo..." then "EVIDENCE OK: tests fail on base <sha> (N production file(s) swapped back)"
.claude/skills/build-and-env/scripts/ep-test.sh -count=1 -run 'TestFoo' ./processors/events_processor/
# expect: ok  github.com/getlago/lago/events-processor/processors/events_processor
```

- `WEAK EVIDENCE` (the test does not compile on base) is acceptable only for a new function.
  For a behaviour change, write the test against the existing API first.
- `NO EVIDENCE` (exit 1): the test passes without your change. It does not pin the change.
- Verified 2026-10-01 in a scratch clone: a `ParseBrokersEnv` change plus its test gave
  `EVIDENCE OK`; an unrelated existing test gave `NO EVIDENCE`; a test of a new function gave
  `WEAK EVIDENCE`; no production change gave exit 3.

### Both data modes (C3)

The enrichment path exists twice: DB mode (Postgres via gorm) and memory-cache mode (badger fed by
a snapshot + Debezium CDC, `LAGO_USE_MEMORY_CACHE=true`). Whether production runs the cache is
OPEN DECISION OD-1 (owner), so a change to shared logic needs evidence in BOTH modes:
the `-v` output must show `.../WithCache/<case>` and `.../WithoutCache/<case>`.
Use `templates/enrichment_template_test.go.tmpl`.

## 3. What is NOT evidence

| Offered as evidence | Why it is not enough | Ask for |
|---|---|---|
| "CI is green" | CI runs only `go test -v ./...`, only on `events-processor/**` PRs; no lint, race, gofmt, coverage | the `baseline.sh` table and `race-shuffle.sh` summary |
| a new test that passes | it may pass without the change | the `fails-on-base.sh` run |
| coverage went up | coverage counts executed lines, not checked behaviour (`TestCache_ConcurrentAccess`, `cache/cache_test.go:276-307`, has 0 assertions and still adds coverage) | the assertion that fails on base |
| a sqlmock test with a loose pattern (`".*"`, `".* FROM \"charges\".*"`) for a query change | any SQL matches; change-control N4 (explicit columns, `deleted_at IS NULL`, `organization_id`) stays unchecked | the exact SQL with `regexp.QuoteMeta` (`models/subscriptions_test.go:14-22`) |
| a sqlmock test without `ExpectationsWereMet()` | a query the code skips still passes (4 such subtests today) | `sqlmock-strict.sh` shows `0 new` |
| a cache-mode-only test for logic that exists in DB mode | parity is the point of the dual-mode pattern | both modes in `-v` output |
| a test made green with `time.Sleep` | hides a missing synchronisation and slows the suite | a happens-before (e.g. `processEvent` already waits, `processor.go:101`) |
| a code read for runtime behaviour (commit, redelivery, DLQ) | code says, probes measure (`diagnostics-and-tooling`) | a probe or kfake output |
| a doc, comment or commit message | they drift (`events-processor/CLAUDE.md:10` is wrong about `go test`) | the command and its output |
| `go test -run 'Parent/Child'` passing | `-run` narrows, but a child can depend on an earlier sibling (`TestEvaluateExpression`) | `race-shuffle.sh --isolation` |

## 4. Refreshing the baseline (when numbers legitimately change)

A PR that adds tests, raises coverage or fixes lint issues should refresh `scripts/baseline.json`
in the same PR, so the next PR is held to the new level.

```bash
.claude/skills/validation-and-qa/scripts/baseline.sh --write .claude/skills/validation-and-qa/scripts/baseline.json
git diff -- .claude/skills/validation-and-qa/scripts/baseline.json   # review: only expected keys move
```

- A number that goes DOWN on purpose (tests deleted with removed code, as `d9c32b6` did with
  flat filters) needs one sentence in the PR body saying which tests and why. Then refresh.
- Compare against the PR base instead of the committed file when `main` moved since 2026-10-01.
  Do not stash or check out the base in your working tree (change-control N10); measure it in a
  scratch clone (verified 2026-10-01: about 1 min for clone + two full measurements; add
  `--no-lint --no-coverpkg` to both `baseline.sh` calls for a quicker, partial compare):

  ```bash
  W=$(mktemp -d); B="$W/base"
  git clone -q . "$B" && git -C "$B" checkout -q "$BASE"
  mkdir -p "$B/.claude" && cp -r .claude/skills "$B/.claude/"     # skills may not exist at $BASE
  "$B/.claude/skills/validation-and-qa/scripts/baseline.sh" --write "$W/base.json" --quiet
  .claude/skills/validation-and-qa/scripts/baseline.sh --baseline "$W/base.json"
  # expect on an unchanged branch: SUMMARY baseline: 0 FAIL, 0 WARN (baseline as_of <today> head <BASE>; ...)
  ```

  Delete `$W` yourself afterwards (print it first, then remove that literal path).

## 5. Evidence block (paste into the PR body)

```
Class: C3 (+C1)   Base: <sha>   Head: <sha>
baseline.sh:      SUMMARY baseline: 0 FAIL, 0 WARN  (pass.total 235 -> <n>; cover.<pkg> <old> -> <new>)
race-shuffle.sh:  OK race: 6 packages ok, 0 DATA RACE; OK shuffle: seed <n> x10; isolation: <n> leaf tests, 2 known, 0 new
sqlmock-strict:   4 unmet (4 known, 0 new)
golangci-lint --new-from-rev=<base>: 0 issues. (repo baseline 21)
fails-on-base:    EVIDENCE OK: TestFoo fails on base <sha>; green on head
both data modes:  TestFoo/WithCache/..., TestFoo/WithoutCache/... PASS
parity:           <rails-go-parity probe output or $API/<file>:<line>>
```

Templates for the rest of the PR body (Context, Description, ADR) are in `docs-and-writing`.
