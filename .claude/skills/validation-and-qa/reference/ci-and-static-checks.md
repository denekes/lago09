# CI shape, CI gaps, and the static checks you can run locally

Read this when you need to know what CI will (and will not) check for your PR, or which local
static check covers a file type. Facts as of 2026-10-01, read from `.github/workflows/` at
`5308258`.

## 1. The only PR check: `events-processor-tests.yml`

| Aspect | Value | Line |
|---|---|---|
| triggers | `push` to `main` (no path filter); `pull_request` opened/synchronize/reopened with `paths: "events-processor/**"` | `.github/workflows/events-processor-tests.yml:3-13` |
| runner | `ubuntu-latest`, working dir `./events-processor` | `:18-21` |
| database | service `postgres:14-alpine`, `lago/lago/lago`, no health-check options | `:23-31` |
| lago-expression | `actions/checkout@v3` of `getlago/lago-expression` at `ref: v0.2.0`, `cargo build --release`, `sudo cp` to `/usr/local/lib`, `sudo ldconfig` (so CI needs no `CGO_LDFLAGS` / `LD_LIBRARY_PATH`) | `:40-56` |
| Go | `actions/setup-go@v4`, `go-version: "1.25.0"` | `:58-61` |
| the test | `go test -v ./...` | `:63-64` |

Of the 10 workflows, this is the only one with a `pull_request` trigger
(`grep -ln pull_request .github/workflows/*`).

## 2. Gaps (what CI never checks)

| Gap | Consequence | Local substitute |
|---|---|---|
| no golangci-lint, no config committed (OPEN DECISION OD-6 (owner)) | 21 issues today; new ones land silently | `scripts/baseline.sh`, `golangci-lint run --allow-serial-runners --new-from-rev="$BASE"` |
| no `-race` | concurrency regressions only show in production | `scripts/race-shuffle.sh` (unit suite only: it never runs `processRecordsAndCommit`); for the consumer path `GOFLAGS=-race .claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh happy-path -n 5000 -partitions 4` (`RESULT: PASS`) |
| no coverage | coverage can fall to anything | `scripts/baseline.sh` (`cover.*` rows) |
| no gofmt / explicit vet | `go test` runs only a small vet subset | `gofmt -l`, `go vet ./...` |
| no shuffle / isolation | order-dependent tests stay hidden (`TestEvaluateExpression`) | `scripts/race-shuffle.sh --isolation` |
| sqlmock expectations not enforced | dead fixtures pass | `scripts/sqlmock-strict.sh` |
| PR path filter `events-processor/**` | a PR that edits only `.github/workflows/events-processor-tests.yml` (or docs, compose, deploy, Dockerfiles outside `events-processor/`) runs NO check; the workflow change is first exercised on the push to `main` | run the steps locally; watch the first `main` run |
| image builds are not gated on tests | `build-processors-image.yaml` runs on push to `main` with its own path filter and no dependency on the test workflow | none locally; see `release-and-images` |
| required status checks / branch protection | not visible from git: UNVERIFIED | ask the owner (`change-control` §Review routing) |
| Postgres 14 in CI vs 15 (dev compose, lago-api CI) vs 16 (this sandbox) | today only `TestNewConnection` touches Postgres and needs no version-specific feature; matters once DB-backed tests exist | target the oldest (14) when you add one |
| exact `1.25.0` | no 1.25.x patches in CI; adding `-coverprofile ./...` would hit the `covdata` trap if that toolchain lacks the tool (UNVERIFIED for setup-go's tarball) | list tested packages (see `baselines.md` §2) |
| action majors `checkout@v3`, `setup-go@v4`; `mkdir -p /tmp/libs` unused (`:54`) | actionlint 1.7.7 (fetched by the `release-and-images` actionlint script, not on PATH) reports 3 findings on this file, 2026-10-01: "the runner of `actions/checkout@v3` action is too old to run on GitHub Actions" at `:38` and `:41`, same for `actions/setup-go@v4` at `:59`. Whether GitHub still runs them today is UNVERIFIED from here | actionlint via `release-and-images` |

Raising CI to lint + race + coverage + actionlint is a "beyond current best" TARGET, not the
current state. A workflow change is class C5 (and a lint config needs owner sign-off: OPEN DECISION OD-6 (owner)).

CANDIDATE (not run in CI; each step was run locally on 2026-10-01 with the results in
`baselines.md`) steps for a future CI job, after the existing test step:

1. `go vet ./...` and `test -z "$(gofmt -l .)"`.
2. `golangci-lint run --new-from-rev=origin/${{ github.base_ref }} ./...` (needs fetch depth > 1).
3. `go test -race -count=1 ./...`.
4. `go test -coverprofile=c.out $(go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{.ImportPath}}{{end}}' ./...)`.

## 3. Static checks available locally

| What | Command (repo root unless stated) | Result 2026-10-01 | Owner of details |
|---|---|---|---|
| go vet | `go -C events-processor vet ./...` | exit 0, no output; works without the CGO env | here |
| gofmt | `gofmt -l events-processor` | no output | here |
| go mod tidy | `go -C events-processor mod tidy -diff` | exit 0, empty | here |
| golangci-lint v2.5.0 | `( cd events-processor && GOLANGCI_LINT_CACHE="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}/golangci-cache" golangci-lint run --allow-serial-runners ./... )` (no CGO env needed: verified with `env -u CGO_LDFLAGS -u LD_LIBRARY_PATH`) | `21 issues: errcheck: 16, staticcheck: 5`, exit 1 (without `--allow-serial-runners` a concurrent run exits 3: `parallel golangci-lint is running`) | here (`baselines.md` §3) |
| workflow YAML parses | `python3 -c 'import yaml,sys;[yaml.safe_load(open(f)) for f in sys.argv[1:]]' .github/workflows/*` | prints nothing, exit 0 (10 files) | here |
| actionlint | not installed in this sandbox | n/a | `release-and-images` (actionlint script) |
| compose files | `docker compose -f docker-compose.dev.yml config --quiet` (no daemon needed) | exit 0; the root `docker-compose.yml` prints 25 "variable is not set" warnings and exits 0 | `run-and-operate` (compose matrix) |
| shell syntax | `bash -n deploy/deploy.sh docker/runner.sh scripts/create-topics.sh extra/init-letsencrypt.sh extra/init-selfsigned.sh` (one file per call) | all pass | `run-and-operate`, `security-and-supply-chain` |
| shellcheck, hadolint | not installed here | n/a | fetch into `$LAGO_SKILLS_CACHE` if needed (`build-and-env`) |
| Dockerfile builds | impossible without a Docker daemon | label "not built locally; verified by reading `<file:line>`" | `release-and-images` |
| commit messages, staged gitlinks, pins | change-control scripts (`precommit-guard.sh`, `commit-msg-check.sh`, `pin-sync-check.sh`) | see change-control | `change-control` |

## 4. Mapping: change class -> what CI checks -> what you must run

| Class | CI on the PR | You run |
|---|---|---|
| C0 docs/skills | nothing | the documented commands; `bash -n` + a run for skill scripts |
| C1 tests | `go test -v ./...` if under `events-processor/` | `baseline.sh`, `race-shuffle.sh --isolation`, `sqlmock-strict.sh` |
| C2/C3/C4 EP code | `go test -v ./...` | the change-control N9 gate (validation-and-qa SKILL.md §3, REQUIRED steps) + the C1 set + `fails-on-base.sh` (C3+) + kfake test and one `GOFLAGS=-race` kfake run (C4) |
| C5 workflows/pins | `go test -v ./...` only if a file under `events-processor/` changed | YAML parse, actionlint, pin-sync, full C2 set for bumps |
| C6 compose/deploy | nothing | `docker compose -f <f> config --quiet`, `bash -n` |
| C7 security | nothing | security-and-supply-chain scans, precommit-guard |
