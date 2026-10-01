---
name: build-and-env
description: Recreates the Lago umbrella-repo working environment from zero and catalogs its build and environment traps. Covers the Docker-free events-processor recipe (CGO + libexpression_go.so via ep-env.sh, ep-test.sh, doctor.sh), Postgres for tests, the Go/Rust/lago-expression/Postgres/ClickHouse/Node version matrix, dev-stack prerequisites (SSH submodules or HTTPS rewrite, mkcert certs, hosts, the lago alias, lago_front_pnpm_store) and what each Dockerfile is for. Use when setting up a sandbox, CI-like host or dev machine, or on "cannot find -lexpression_go", "libexpression_go.so cannot open shared object file", "build constraints exclude all Go files", "no such tool covdata", "go.mod requires go >= 1.25.0", "toolchain not available", "lago command not found", "unknown command exec for lago", "cannot run ssh", empty api/ or front/, or a TestNewConnection nil-pointer panic. Not for test policy or baselines (validation-and-qa), publishing images (release-and-images) or running services (run-and-operate).
---
# Build and environment: recreate the workspace from zero

How to get from an empty machine to a green `events-processor` test run, a working dev stack, or a
local image build, and what breaks on the way (with exact error text). It owns the foundation scripts
`ep-env.sh`, `ep-test.sh`, `doctor.sh` and the alias-free compose wrapper `dc.sh`.
Code facts as of `5308258` (events-processor tree `83e012866f29`); the working branch may carry
skills-only commits on top. Verified 2026-10-01 unless marked.

## When to use / when NOT to use

Use when:
- you start in a fresh sandbox, CI-like host or workstation and need the events-processor to build/test;
- a build, link, load, toolchain, Postgres or submodule error appears (see section 5);
- docs tell you to run `lago …` and you are an agent or a script;
- you bump Go, Rust, lago-expression or a base image and need to know every place it lives.

Do NOT use for (go to the sibling instead):
- what counts as passing, baselines (235 PASS, coverage, 21 lint issues) → `validation-and-qa`;
- the pre-PR gate command list for events-processor code (N9) → `change-control`;
- probe harnesses (kfake, `go test -overlay`, scratch Postgres, clickhouse-local) → `diagnostics-and-tooling`;
- publishing images, tags, the release train, registries → `release-and-images`;
- starting/operating services, where output lands, logs → `run-and-operate`;
- what an env var means, defaults, boolean traps → `config-and-flags`;
- whether a pin/Dockerfile/compose change is allowed and its gate (C5/C6) → `change-control`;
- runtime triage (startup panics, DLQ codes) → `debugging-playbook`;
- why a pin moved, incident stories → `failure-archaeology`; history mining → `research-methodology`.

## Terms

| Term | Meaning here |
|---|---|
| lago-expression | getlago/lago-expression: a Rust expression engine. Rails uses its Ruby gem; Go uses its C ABI. |
| `libexpression_go.so` | The shared library built from lago-expression `expression-go/` with `cargo build --release`. |
| expression-go wrapper | Go module `github.com/getlago/lago-expression/expression-go` (`events-processor/go.mod:10`); cgo code that links `-lexpression_go`. Only `processors/events_processor/enrichment_service.go:8` imports it. |
| CGO | Go's C interop. Needs a C compiler; Go turns it off silently when none is on PATH. |
| Docker-free recipe | Build the `.so` once into a cache, point `CGO_LDFLAGS` (link) and `LD_LIBRARY_PATH` (load) at it, run plain `go test`. Same shape as CI (host-built `.so`, `go test ./...` against Postgres, no Docker), not identical (end of section 2a). |
| `GOTOOLCHAIN=auto` | Go's default: if `go.mod` asks for a newer Go, download that exact toolchain from `proxy.golang.org`. |
| daemon-less sandbox | Docker CLI present, no Docker daemon: `docker compose … config` works, `up`/`exec`/`build` do not. |
| dev stack | The services in `docker-compose.dev.yml` (project `lago_dev`). |
| `lago` alias | Shell alias from `docs/dev_environment.md:47-71` for `docker compose -f $LAGO_PATH/docker-compose.dev.yml`. Not lago-cli. |
| lago-cli | getlago/lago-cli, a billing CLI whose binary is also named `lago` (`README.md:62,160`). No `exec`/`up`. |
| gitlink / pin | The commit the superproject records for `api` / `front` (`git ls-tree HEAD api front`). |
| pinned checkout | Read-only depth-1 checkout of lago-api/lago-front at the pin, from `research-methodology`'s `pinned-checkout.sh`. |
| `$LAGO_SKILLS_CACHE` | Cache dir outside the repo, default `$HOME/.cache/lago-skills` (`.so`, history clone, pinned checkouts). |

Reference files:
- `reference/traps.md`: read when a trap below needs confirming; safe reproductions with full output.
- `reference/toolchain-matrix.md`: read when bumping Go/Rust/lago-expression/base images or when two contexts disagree.
- `reference/dev-stack.md`: read when bringing up `docker-compose.dev.yml` on a machine with a Docker daemon.
- `reference/images.md`: read when building an image locally or mapping a Dockerfile to its workflow.

## 1. Fast path: is this machine ready?

```bash
cd "$(git rev-parse --show-toplevel)"
.claude/skills/build-and-env/scripts/doctor.sh        # read-only; exit code = number of FAIL lines
.claude/skills/build-and-env/scripts/ep-test.sh       # full events-processor suite, no Docker
```
Expected `doctor.sh` in a prepared agent sandbox (2026-10-01; paths shortened):
```
OK    repo root: <repo> (HEAD <sha>)
WARN  working clone is SHALLOW (<N> commits): use research-methodology/scripts/history-setup.sh for history
INFO  submodule api EMPTY (pinned 591ae9005110); read it via research-methodology/scripts/pinned-checkout.sh api
INFO  submodule front EMPTY (pinned 0c5e539b9e23); read it via research-methodology/scripts/pinned-checkout.sh front
OK    go: events-processor resolves to go1.25.0 (go.mod minimum: go 1.25.0; GOTOOLCHAIN=auto)
OK    cgo enabled (CC=gcc)
OK    cargo: cargo 1.97.0 (c980f4866 2026-06-30)
OK    libexpression_go.so cached for lago-expression v0.2.0: <cache>/lago-expression-v0.2.0/target/release/libexpression_go.so
OK    postgres reachable and login works: postgres://lago:***@localhost:5432/lago
INFO  docker CLI present but NO daemon: 'docker compose config' works, 'up'/'exec' do not
INFO  'lago' not defined (no binary, no rc alias): use 'docker compose -f docker-compose.dev.yml ...' or build-and-env/scripts/dc.sh
OK    golangci-lint: golangci-lint has version 2.5.0 built with go1.25.1 from ff63786c on 2025-09-21T19:04:05Z
OK    history clone: <cache>/lago-history.git (776 commits)
INFO  pinned checkout: <cache>/lago-api@591ae9005110
INFO  pinned checkout: <cache>/lago-front@0c5e539b9e23
doctor: 0 FAIL(s)
```
`INFO  pinned checkout:` lines cover only the current `api`/`front` pins; checkouts of other SHAs
(other skills cache them) are counted in one extra line, `INFO  <M> more cached checkout(s) of other
lago-api/lago-front SHAs in <cache> (…)` (50 on this host on 2026-10-01). On a host without go1.25.0 cached, the first `doctor.sh`
run downloads that toolchain (~214 MB, into `$(go env GOMODCACHE)`, never into the repo).
Expected `ep-test.sh` (4-5 s warm; 60-75 s from a cold cache including the `.so` build, up to ~120 s
on a loaded host; timings vary):
```
ep-env: lago-expression v0.2.0 -> <cache>/lago-expression-v0.2.0/target/release ; DATABASE_URL=postgres://lago:***@localhost:5432/lago
?   	github.com/getlago/lago/events-processor	[no test files]
ok  	github.com/getlago/lago/events-processor/cache	3.036s
ok  	github.com/getlago/lago/events-processor/config/database	0.030s
ok  	github.com/getlago/lago/events-processor/config/kafka	0.013s
?   	github.com/getlago/lago/events-processor/config/redis	[no test files]
?   	github.com/getlago/lago/events-processor/config/tracing	[no test files]
ok  	github.com/getlago/lago/events-processor/models	0.026s
?   	github.com/getlago/lago/events-processor/processors	[no test files]
ok  	github.com/getlago/lago/events-processor/processors/events_processor	0.731s
?   	github.com/getlago/lago/events-processor/tests	[no test files]
ok  	github.com/getlago/lago/events-processor/utils	0.006s
```
Any FAIL, or a different result: follow section 2a for the failing item, then section 5.

## 2. From zero

### 2a. Agent sandbox or CI-like host (no Docker daemon). VERIFIED end to end, cold cache

1. **Checkout.** Any clone builds; submodules and history are not needed for events-processor work.
   `git clone --depth 1 https://github.com/getlago/lago.git` (the form in `README.md:222`). VERIFIED:
   such a clone of upstream `main` (`a0de065`, 2026-09-29) passed all 6 packages with this skill's
   `ep-env.sh` sourced from inside it (the script uses the lago checkout of the current directory
   first, else the checkout that contains the script).
2. **C compiler.** `gcc` must be on PATH (Debian/Ubuntu: `build-essential`). Check:
   `(cd events-processor && go env CGO_ENABLED)` → `1`. A `0` means trap 5.3.
3. **Go.** Any Go >= 1.21 on PATH with the default `GOTOOLCHAIN=auto`. The first `go` command in
   `events-processor/` downloads exactly go1.25.0 (about 214 MB on disk, from `proxy.golang.org`) because
   `events-processor/go.mod:3` says `go 1.25.0`. Check: `(cd events-processor && go version)` →
   `go version go1.25.0 linux/amd64`. Here the local Go is 1.24.7. Offline: trap 5.6.
4. **Rust** (only to build the `.so` once; skip it with `ep-test.sh --no-cgo`).
   `curl https://sh.rustup.rs -sSf | bash -s -- -y` (as `docker/Dockerfile:25` does). Rust stable
   1.97.0 builds lago-expression v0.2.0 here; production images use `rust:1.85`.
5. **Postgres** for the one DB test: section "Postgres for tests" below.
6. **CGO env.** `source .claude/skills/build-and-env/scripts/ep-env.sh` (by absolute path it works
   from any cwd). On first use it clones lago-expression at the ref in `events-processor/Dockerfile:5`
   into `$LAGO_SKILLS_CACHE` and runs `cargo build --release`. It exports `CGO_LDFLAGS`,
   `LD_LIBRARY_PATH`, `DATABASE_URL` (the `config/database` test reads it) and others.
   Cold-cache output:
   ```
   ep-env: cloning getlago/lago-expression@v0.2.0 into <cache>/lago-expression-v0.2.0
   ep-env: building libexpression_go.so (cargo build --release, ~40 s first time)
   ep-env: lago-expression v0.2.0 -> <cache>/lago-expression-v0.2.0/target/release ; DATABASE_URL=postgres://lago:***@localhost:5432/lago
   ```
   Needed for `go build` and `go test`. NOT needed for `go vet ./...` or golangci-lint: both run fine
   with the variables unset (verified with a cold `GOCACHE`; they type-check, they do not link).
7. **Tests.** `.claude/skills/build-and-env/scripts/ep-test.sh` → the 6 `ok` lines in section 1.
   `ep-test.sh -count=1 -v ./... 2>&1 | grep -c -- '--- PASS'` → `235` (113 top-level + 122 subtests).
   Pass any `go test` args; paths are relative to `events-processor/`, e.g.
   `ep-test.sh -count=1 -run TestGetEnvAsBool ./utils/`. Flags without a package (`ep-test.sh -race
   -count=1`) get `./...` added and a stderr note `ep-test: no package pattern given; testing ./...`
   (plain `go test -race` there tests only the root package, which has no tests, and exits 0).
   Before a PR, run the full list in change-control's "Pre-PR gate for events-processor code" (N9:
   tests, `-race`, vet, gofmt, new lint issues, guards); baselines are `validation-and-qa`'s.
8. **Lint (optional).** golangci-lint v2.5.0, no repo config (OPEN DECISION OD-6, owner). Install into
   the cache with a checksum check (verified):
   ```bash
   C="${LAGO_SKILLS_CACHE:-$HOME/.cache/lago-skills}"; V=2.5.0; D=$(mktemp -d)
   curl -fsSL -o "$D/gl.tgz" "https://github.com/golangci/golangci-lint/releases/download/v$V/golangci-lint-$V-linux-amd64.tar.gz"
   curl -fsSL "https://github.com/golangci/golangci-lint/releases/download/v$V/golangci-lint-$V-checksums.txt" | grep " golangci-lint-$V-linux-amd64.tar.gz\$" | sed "s#golangci-lint-$V-linux-amd64.tar.gz#$D/gl.tgz#" | sha256sum -c -
   mkdir -p "$C/bin" && tar -xzf "$D/gl.tgz" -C "$C/bin" --strip-components=1 "golangci-lint-$V-linux-amd64/golangci-lint"
   "$C/bin/golangci-lint" version     # golangci-lint has version 2.5.0 built with go1.25.1 ...
   export PATH="$C/bin:$PATH"   # doctor.sh and validation-and-qa's baseline.sh look for golangci-lint on PATH
   ```
   Run it as `(cd events-processor && GOLANGCI_LINT_CACHE=$(mktemp -d) golangci-lint run --allow-serial-runners ./...)`
   → exit 1, `21 issues: errcheck: 16, staticcheck: 5` (as of 2026-10-01). `--allow-serial-runners`
   waits for another run instead of failing with exit 3 (trap 5.20). No `ep-env.sh` needed.
   `validation-and-qa` owns the lint baseline and the "no new issues" gate.
9. **History and lago-api/lago-front source (read-only).**
   `H=$(.claude/skills/research-methodology/scripts/history-setup.sh)` (776 commits, bare, blob-less)
   and `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)` (same for `front`).
   Do not populate `api/`/`front/` just to read them (change-control N10).

`ep-test.sh` has the same shape as `.github/workflows/events-processor-tests.yml` but is not
identical: CI builds the whole lago-expression v0.2.0 workspace with the runner's unpinned Rust
(`:40-49`), installs the `.so` with `ldconfig` (`:51-56`), uses Go `1.25.0` (`:61`), a Postgres 14
service (`:25`) and `go test -v ./...` (`:64`); `ep-env.sh` builds only `expression-go/` with local
cargo and tests against the local Postgres (16 here). Whether this recipe is an accepted pre-PR gate
is OPEN DECISION OD-5 (owner); default: accepted (see section 4).

### Postgres for tests

Only `config/database` `TestNewConnection` needs Postgres, and only a login (no schema: the sandbox
`lago` db has 0 tables in `public`). `--no-cgo` still includes `config/database`.

| Step | Command (Debian/Ubuntu, run as root or prefix `sudo`) | Expected |
|---|---|---|
| Install (fresh host) | `apt-get install -y postgresql` (Ubuntu 24.04: `apt-cache policy postgresql` → candidate `16+257build1.1`, i.e. PostgreSQL 16; the install itself was not re-run here, PG is preinstalled) | — |
| Cluster state | `pg_lsclusters` | `16  main 5432 online postgres …` |
| Start after a sandbox/container restart | `pg_ctlcluster 16 main start` | silent; if already up: `Cluster is already running.` (exit 2, harmless) |
| Role + db (idempotent, verified) | see block below | no output |
| Check reachability | `pg_isready -d postgres://lago:lago@localhost:5432/lago` | `localhost:5432 - accepting connections` |
| Check login (pg_isready does not) | `psql postgres://lago:lago@localhost:5432/lago -XAtc 'select 1'` | `1` |

```bash
su postgres -c "psql -v ON_ERROR_STOP=1 -q" <<'SQL'
DO $$BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'lago') THEN
    CREATE ROLE lago WITH LOGIN SUPERUSER PASSWORD 'lago';
  END IF;
END$$;
SQL
su postgres -c "psql -tAc \"SELECT 1 FROM pg_database WHERE datname='lago'\"" | grep -q 1 || su postgres -c "createdb -O lago lago"
```
Sandbox restart trap: in the agent sandbox the cluster does not survive a container restart (as
reported by the sandbox setup; not re-simulated today, because stopping the shared cluster would break
parallel work). Symptom: `doctor.sh` prints `WARN  postgres NOT reachable …` and `ep-test.sh` prints
`ep-test: WARNING Postgres not reachable …`; then `TestNewConnection` panics (trap 5.7). Fix:
`pg_ctlcluster 16 main start`. Other URL: `export DATABASE_URL=…` before running the scripts; they
mask the password in output (change-control N11). Version spread (CI 14, sandbox 16, compose 15,
all-in-one 17) does not matter for this test today. Do not run the dev-stack `db` service (host port
5432) at the same time. Throwaway databases for probes: `diagnostics-and-tooling`.

### 2b. Full dev stack (workstation with a Docker daemon)

Prerequisites only; bring-up itself (start order, `--wait`, event pipeline, checks, teardown) is
`run-and-operate` R1. Not runnable in a daemon-less sandbox; every step is in `reference/dev-stack.md`
with file:line and, where possible, a scratch verification. Checklist:
1. Clone with submodules. Without an SSH key (`.gitmodules:3,6` are `git@github.com:`):
   `git -c url."https://github.com/".insteadOf="git@github.com:" clone --depth 1 --recurse-submodules --shallow-submodules https://github.com/getlago/lago.git`
   (VERIFIED: 10 s, pins `591ae90`/`0c5e539`). Already cloned: `git -c url."https://github.com/".insteadOf="git@github.com:" submodule update --init --depth 1` (VERIFIED on a scratch clone, tree stays clean).
2. `export LAGO_PATH="$(git rev-parse --show-toplevel)"`; use `dc.sh` instead of the alias (section 4).
3. Certificates: `mkcert -install`, then in `traefik/certs/`: `mkcert -cert-file lago.dev.pem -key-file lago.dev-key.pem lago.dev "*.lago.dev"`
   (names from `traefik/dynamic.yml:3-4`; Ubuntu: `apt install mkcert libnss3-tools`; macOS: `brew install mkcert nss`).
4. Hosts: generate from compose, not from the stale doc list (`docs/dev_environment.md:97-106` lists
   `license.lago.dev`, lacks `console`/`pghero`): see `reference/dev-stack.md` §4 (8 hosts).
5. `cp ./api/.env.dist ./api/.env && touch ./api/config/master.key` (`docs/dev_environment.md:110-114`).
6. `docker volume create lago_front_pnpm_store`: external volume (`docker-compose.dev.yml:11-12`, `195bbc0`), undocumented.
7. Check steps 1-6 with `.claude/skills/run-and-operate/scripts/dev-preflight.sh` (expect
   `dev-preflight: 0 FAIL(s)`), then bring the stack up per `run-and-operate` R1. Alias-free forms of
   every docs command (`dc.sh up -d --wait …`, `--profile` as a global flag): `reference/dev-stack.md` §6.

### 2c. Image builds

| Dockerfile | For | Built by |
|---|---|---|
| `events-processor/Dockerfile` | production events-processor (`rust:1.85` → `golang:1.25` → `debian:13-slim`) | `.github/workflows/release-processors-image.yml:52-53`, `.github/workflows/release-images.yml:40-41`, `.github/workflows/build-processors-image.yaml:19-20` |
| `events-processor/Dockerfile.dev` | dev container (`air` + `dlv`, source bind-mounted) | `docker-compose.dev.yml:323-325` |
| `events-processor/Dockerfile.staging` | hardened Wolfi staging image, `USER 65532` | private lago-deploy workflow (`events-processor/Dockerfile.staging:8-10`) |
| `docker/Dockerfile` | all-in-one `getlago/lago` (testing/staging only) | `.github/workflows/release-docker-image.yml:56-57` (submodules `:28-30`) |
| `connectors/Dockerfile` | Redpanda Connect pipelines | `.github/workflows/build-connectors-image.yaml:24-25` |

Local build commands (CANDIDATE, need a daemon) and image-build traps: `reference/images.md`.
No image is built on PRs, so a local build is the only pre-merge check. Publishing: `release-and-images`.

## 3. Toolchain and version matrix (summary)

| Thing | Values by context (file:line) |
|---|---|
| Go | floor `go 1.25.0` (`events-processor/go.mod:3`); CI `1.25.0` (`.github/workflows/events-processor-tests.yml:61`); `GOTOOLCHAIN=auto` → go1.25.0; mise `"1.25"` (`events-processor/mise.toml:2`); images floating `golang:1.25` (`events-processor/Dockerfile:7`, `events-processor/Dockerfile.dev:7`) = `golang:1.25.14` on Docker Hub (as of 2026-10-01) |
| lago-expression `.so` | `v0.2.0` in 4 places: `events-processor/Dockerfile:5`, `events-processor/Dockerfile.dev:5`, `events-processor/Dockerfile.staging:23`, `.github/workflows/events-processor-tests.yml:45` |
| expression-go wrapper | `v0.1.4` (`events-processor/go.mod:10`). No `expression-go/v0.2.0` tag exists; wrapper ABI identical. Do not "fix" it (change-control N3). |
| Rust | `rust:1.85` (`events-processor/Dockerfile:1`, `events-processor/Dockerfile.dev:1`); CI runner default (unpinned); sandbox 1.97.0 |
| Postgres | CI 14 (`.github/workflows/events-processor-tests.yml:25`); sandbox 16.14; compose partman 15.0 (`docker-compose.dev.yml:40`, `docker-compose.yml:7`); `deploy/*.yml` 15 (`deploy/docker-compose.local.yml:10`); all-in-one 17 (`docker/Dockerfile:49`) |
| ClickHouse | dev 26.2 (`docker-compose.dev.yml:460`); lago-api CI 25.12 / 26.4 (`$API/.github/workflows/spec.yml:77`, `migrations-test.yml:65`); the events-processor has no ClickHouse client |
| Ruby / Node / pnpm (all-in-one) | Ruby 4.0.6, Node 24 (major), `pnpm@latest`, Bundler 4.0.4 (`docker/Dockerfile:1-2,12,18`); lago-front wants node 24.20.0 + pnpm 10.34.5 (`$FRONT/package.json:192,11`) |

Full table, history of each pin and one-line checks: `reference/toolchain-matrix.md`.
Read when bumping anything or when two contexts disagree. Moving pins is C5; they move together (change-control N3).

## 4. The `lago` name collision and alias-free commands

`lago` means two unrelated things, and neither works for an agent:

| `lago` is… | Defined by | In an agent / CI shell |
|---|---|---|
| shell alias for `docker compose -f $LAGO_PATH/docker-compose.dev.yml` | `docs/dev_environment.md:47-71` (rc files) | `bash: line N: lago: command not found`, exit 127: non-interactive bash does not expand aliases (`expand_aliases` is off) |
| getlago/lago-cli binary (installs to `/usr/local/bin/lago` by default) | `README.md:62,160` | `lago exec …` → `Error: unknown command "exec" for "lago"`; `lago up -d` → `Error: unknown shorthand flag: 'd' in -d` (exit 2; lago-cli `49a7a03` built in scratch) |

In an interactive shell an alias wins over a same-named binary; in scripts the binary wins.
`doctor.sh` reports which case applies. Alias-free equivalents:

| Docs say | Agent-safe command | Needs daemon |
|---|---|---|
| `lago exec events-processor go test ./...` (`events-processor/CLAUDE.md:7`, `events-processor/README.md:29`) | `.claude/skills/build-and-env/scripts/ep-test.sh` | no |
| same, inside the dev container | `.claude/skills/build-and-env/scripts/dc.sh exec -T events-processor go test ./...` | yes |
| `lago config --services` | `dc.sh config --services` (25 services; `--profile '*'` → 30) | no |
| `lago up -d --wait <svc…>` | `dc.sh up -d --wait <svc…>` | yes |
| `lago exec api bundle exec rspec <file>` (`$API/AGENTS.md:8`) | `dc.sh exec -T api bundle exec rspec <file>` | yes |
| `lago --profile redis-sentinel up -d` | `dc.sh --profile redis-sentinel up -d` | yes |

`dc.sh` = `docker compose -f "${LAGO_PATH:-<this repo>}/docker-compose.dev.yml" "$@"`; `-T` avoids TTY
allocation in non-interactive shells.

`events-processor/CLAUDE.md:10` says "Direct `go build` / `go test` won't work locally due to CGO
dependencies. Always use `lago exec`". That is stale for daemon-less sandboxes: they work with
`ep-env.sh` (section 2a). OPEN DECISION OD-5 (owner): is `ep-test.sh` an accepted pre-PR gate, or is
`lago exec` mandatory? Default until decided: the Docker-free recipe is accepted (same shape as CI, not identical);
`lago exec`/`dc.sh exec` stays valid for dev-stack users. CANDIDATE replacement text for that file
(a C0 docs change; the stale-claim register is `docs-and-writing`): "Tests without Docker:
`.claude/skills/build-and-env/scripts/ep-test.sh` (builds libexpression_go.so once; same shape as CI). With
the dev stack: `docker compose -f docker-compose.dev.yml exec -T events-processor go test ./...`."

## 5. Trap table

Exact text as captured 2026-10-01. Reproductions with full output: `reference/traps.md` (B-numbers).

| # | Symptom (exact text) | Cause | Fix |
|---|---|---|---|
| 5.1 | `/usr/bin/ld: cannot find -lexpression_go: No such file or directory` (B1) | `CGO_LDFLAGS` has no `-L` to the `.so`; the wrapper only says `#cgo LDFLAGS: -lexpression_go` | `source .claude/skills/build-and-env/scripts/ep-env.sh`; it also exports `DATABASE_URL`, so plain `go test ./...` without it fails `config/database` too (5.7) |
| 5.2 | `error while loading shared libraries: libexpression_go.so: cannot open shared object file: No such file or directory`; tests: `FAIL …/processors/events_processor 0.001s` (B2) | built fine, loader cannot find the `.so` (`ldd` → `not found`) | `ep-env.sh` sets `LD_LIBRARY_PATH` (CI uses `/usr/local/lib` + `ldconfig`) |
| 5.3 | `build constraints exclude all Go files in …/expression-go@v0.1.4` (B3) | cgo off: `CGO_ENABLED=0`, or no C compiler on PATH (Go then defaults to 0) | install gcc; unset `CGO_ENABLED`; `go env CGO_ENABLED` must be `1`; or `ep-test.sh --no-cgo` |
| 5.4 | `cgo: C compiler "X" not found: exec: "X": executable file not found in $PATH` (B3) | `CC` names a missing compiler | fix `CC` or install it |
| 5.5 | `go: no such tool "covdata"` and exit 1 from `go test -coverprofile=… ./...` (B4) | go1.25.0 toolchain module ships no `covdata`; needed for packages without tests | cover only packages with tests (B4 command; prints 47.4%); coverage policy and the gated 47.4% definition: `validation-and-qa` |
| 5.6 | `go: go.mod requires go >= 1.25.0 (running go 1.24.7; GOTOOLCHAIN=local)` / `go: download go1.25.0 for linux/amd64: toolchain not available` (B5) | `GOTOOLCHAIN=local` with old Go / offline or `GOPROXY=off` | unset `GOTOOLCHAIN`; run once online; or install Go >= 1.25.0. In the sandbox `go.dev/dl` is 403, `proxy.golang.org` works |
| 5.7 | `--- FAIL: TestNewConnection` + `panic: runtime error: invalid memory address or nil pointer dereference` at `database_test.go:24`; first line above: `dial tcp 127.0.0.1:<port>: connect: connection refused` or `password authentication failed for user "lago" (SQLSTATE 28P01)`, or ``failed to connect to `user=root database=` `` … `role "root" does not exist (SQLSTATE 28000)` (your OS user) (B6) | Postgres down (sandbox restart) or role/db/password wrong; `DATABASE_URL` unset (plain `go test` without `ep-env.sh`; the test reads `os.Getenv("DATABASE_URL")`, `database_test.go:18`); the test uses `assert`, then dereferences nil | "Postgres for tests": `pg_ctlcluster 16 main start`, role/db block; source `ep-env.sh` or `export DATABASE_URL=…` |
| 5.8 | `ep-env: cargo not found; install Rust (https://rustup.rs) and re-source` (B7) | no Rust, `.so` not cached for this ref | rustup (step 4), or `ep-test.sh --no-cgo` (5 packages) |
| 5.9 | `fatal: ambiguous argument '4100da0': unknown revision or path not in the working tree.`; `git blame` shows `^8ceca4b` on every old line (B8) | shallow working clone (a few dozen commits; full history 776) | `H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`; `git -C "$H" log -- events-processor events_processor` |
| 5.10 | `ls api front` empty; `git submodule status` lines start with `-` | submodules never initialized | read-only: `pinned-checkout.sh api` (or `front`); dev stack: section 2b step 1 |
| 5.11 | `error: cannot run ssh: No such file or directory` / `fatal: clone of 'git@github.com:getlago/lago-front.git' … failed` (B9); with ssh but no key: `Permission denied (publickey).` (UNVERIFIED here) | `.gitmodules:3,6` use SSH URLs | `git -c url."https://github.com/".insteadOf="git@github.com:" submodule update --init --depth 1`, or `submodule.<name>.url` override (B9). The Claude Code cloud sandbox observed on 2026-10-01 pre-injects this rewrite via `GIT_CONFIG_*` env (`git config --show-origin --get-regexp '^url\.'` → `command line:`) |
| 5.12 | `lago: command not found` (exit 127) / `Error: unknown command "exec" for "lago"` (B10) | alias only in interactive shells / lago-cli binary | section 4: `dc.sh …` or `ep-test.sh` |
| 5.13 | `failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: …` (B11) | no Docker daemon | only `config` works; use the Docker-free recipe |
| 5.14 | different `go version` per context, no error | `go.mod` floor 1.25.0 vs mise `"1.25"` vs `golang:1.25` (=1.25.14) vs CI 1.25.0; dependabot raised the floor (`932c06c`) 50 min before CI/Dockerfiles followed (`50015b0`) | treat CI's 1.25.0 as the test reference; bump all Go pins together (change-control N3); watch `^[-+]go ` in dependabot diffs |
| 5.15 | `?? events-processor/event_processors` in `git status` after following `events-processor/README.md:13` (B12) | `events-processor/.gitignore:24` ignores only `events-processor` | build with `-o "$(mktemp -d)/ep"`; never commit binaries (change-control N10) |
| 5.16 | `invalid version: unknown revision expression-go/v0.2.0` (B13) | trying to align go.mod with the `.so` ref | don't: no such tag, ABI identical (change-control N3) |
| 5.17 | `Error: unknown flag: --cache-dir` (golangci-lint) (B14) | v2 CLI | `GOLANGCI_LINT_CACHE=$(mktemp -d) golangci-lint run --allow-serial-runners ./...` |
| 5.18 | `front` will not start in the dev stack (exact text UNVERIFIED, no daemon) (B15) | `lago_front_pnpm_store` is `external: true`, nobody creates it | `docker volume create lago_front_pnpm_store` |
| 5.19 | `panic: brokers not found` when running a freshly built binary | expected with no runtime env: link and load are fine | startup panics: `debugging-playbook` §2; required env: `run-and-operate` §5.1 |
| 5.20 | `Error: parallel golangci-lint is running` (exit 3, after a wait) (B14) | another golangci-lint holds `${TMPDIR:-/tmp}/golangci-lint.lock` (e.g. a parallel agent) | `golangci-lint run --allow-serial-runners ./...` (waits for the other run instead of exiting 3) |

## 6. Non-negotiables that bite during environment work

- change-control N1: populating submodules never needs a commit; before any commit run
  `.claude/skills/change-control/scripts/precommit-guard.sh` (expect `SUMMARY precommit-guard: 0 FAIL`).
  It runs `git diff --cached --submodule=short --ignore-submodules=none -- api front`; without
  `--ignore-submodules=none` the diff shows nothing when `diff.ignoreSubmodules=all` or
  `submodule.<name>.ignore=all` is set.
- change-control N3: Go, Rust image and the four lago-expression places move together; no `@latest`.
- change-control N10: build outputs, coverage files, probe clones go to `mktemp -d` or `$LAGO_SKILLS_CACHE`.
- change-control N11: never paste a real `DATABASE_URL` password; the scripts mask it as `***`.
- change-control N13: when you claim "tests pass", paste the `ep-test.sh` output; the rest of the PR
  evidence is change-control's "Pre-PR gate for events-processor code" (N9).

## Scripts

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/ep-env.sh` (source it) | Build/cache `libexpression_go.so` at the ref in `events-processor/Dockerfile`; export `LAGO_REPO LAGO_SKILLS_CACHE LAGO_EXPRESSION_REF LAGO_EXPRESSION_LIB CGO_LDFLAGS LD_LIBRARY_PATH DATABASE_URL`. Repo: the cwd's lago checkout, else the script's own (works from any cwd). Status 1 on failure; executed instead of sourced: exit 2. `LAGO_EXPRESSION_REF=vX source …` tests a bump. | `source .claude/skills/build-and-env/scripts/ep-env.sh` | `ep-env: lago-expression v0.2.0 -> <cache>/lago-expression-v0.2.0/target/release ; DATABASE_URL=postgres://lago:***@localhost:5432/lago` |
| `scripts/ep-test.sh` | Docker-free `go test` (default `-count=1 ./...`); `--no-cgo [flags]` = the 5 packages that do not link the `.so` (always appended; pass flags, not packages). Flags without a package: `./...` is added. Warns if Postgres is unreachable. Exit = `go test`'s. | `.claude/skills/build-and-env/scripts/ep-test.sh`; `… --no-cgo -v` | 6 `ok` (full); 5 `ok` (`--no-cgo`) |
| `scripts/doctor.sh` | Readiness report, read-only on the repo (repo depth, submodules, Go, cgo, cargo, `.so`, Postgres reachability + login, Docker daemon, `lago` alias/binary, lint, history clone, pinned checkouts for the current pins + a count of others). Exit = number of FAILs. May download go1.25.0 into `GOMODCACHE` on first run (`GOTOOLCHAIN=auto`). | `.claude/skills/build-and-env/scripts/doctor.sh` | `doctor: 0 FAIL(s)` (section 1) |
| `scripts/dc.sh` | Alias-free `docker compose -f <repo>/docker-compose.dev.yml "$@"` (`LAGO_PATH` overrides the repo). Exit = compose's; 2 if docker or the file is missing; prints a no-daemon hint on failure. | `.claude/skills/build-and-env/scripts/dc.sh config --services \| wc -l` | `25` (verified with `config` subcommands only) |

All four were run on 2026-10-01, including from a cold cache (`LAGO_SKILLS_CACHE=$(mktemp -d)`:
clone + cargo build + full suite in 55-61 s; 60-75 s typical), from `/tmp` (outside the repo), with
cargo removed from PATH, with `CGO_ENABLED=0`, offline (`GOPROXY=off`, empty `GOMODCACHE`), with a
closed Postgres port, with a wrong or missing password (also under a pseudo-TTY: `doctor.sh` never
prompts), and with a lago-cli binary on PATH. `dc.sh` was exercised with `config` subcommands only
(no daemon here; `dc.sh ps` exits 1 with the no-daemon note).

## Provenance and maintenance

- Sources: `events-processor/{go.mod,mise.toml,Dockerfile,Dockerfile.dev,Dockerfile.staging,CLAUDE.md,README.md,.gitignore,.air.toml}`,
  `events-processor/config/database/database_test.go`, `.github/workflows/events-processor-tests.yml`,
  `.github/workflows/{release-processors-image.yml,release-images.yml,build-processors-image.yaml,release-docker-image.yml,build-connectors-image.yaml}`,
  `docs/dev_environment.md`, `docker-compose.dev.yml`, `docker-compose.yml`, `deploy/*.yml`, `docker/Dockerfile`,
  `connectors/Dockerfile`, `.gitmodules`, `.gitignore`, `traefik/dynamic.yml`, `.env.development.default`;
  `$API/{Gemfile,Gemfile.lock,.ruby-version,Dockerfile,Dockerfile.dev,AGENTS.md,.github/workflows/spec.yml}`,
  `$FRONT/{package.json,Dockerfile,Dockerfile.dev}`; lago-expression tags `v0.2.0`, `expression-go/v0.1.4`, `2abd2b3`;
  getlago/lago-cli `49a7a03`. Commits: `4100da0`, `07d1d4d`, `d589940`, `5077151`, `e8bbd60`, `d4e3665`,
  `932c06c`, `50015b0`, `fff5858`, `195bbc0`, `97d1f0b`, `d5bce86`, `18b26d0`, `986f29b`.
- Volatile facts and one-line re-verification (expected as of 2026-10-01):
  - `git ls-tree HEAD api front` → `591ae9005110…` / `0c5e539b9e23…`
  - `sed -n 3p events-processor/go.mod` → `go 1.25.0`; `(cd events-processor && go version)` → `go1.25.0`
  - `grep -nE 'git checkout v|LAGO_EXPRESSION_REF=|ref: v' events-processor/Dockerfile events-processor/Dockerfile.dev events-processor/Dockerfile.staging .github/workflows/events-processor-tests.yml` → 4 × `v0.2.0`
  - `git ls-remote --tags https://github.com/getlago/lago-expression | grep -c 'expression-go/v0.2.0'` → `0`
  - `ls "$(cd events-processor && go env GOTOOLDIR)" | grep -c covdata` → `0`
  - `.claude/skills/build-and-env/scripts/ep-test.sh -count=1 -v ./... 2>&1 | grep -c -- '--- PASS'` → `235`
  - `.claude/skills/build-and-env/scripts/doctor.sh >/dev/null; echo $?` → `0` (prepared sandbox)
  - `R=$PWD; (cd /tmp && bash -c "source $R/.claude/skills/build-and-env/scripts/ep-env.sh 2>/dev/null; echo rc=\$?")` → `rc=0`
  - `.claude/skills/build-and-env/scripts/ep-test.sh -race -count=1 2>&1 | grep -c '^ok'` → `6` (flags only: `./...` added)
  - `.claude/skills/build-and-env/scripts/dc.sh --profile '*' config --services | wc -l` → `30`
  - `git check-ignore -q events-processor/event_processors || echo not-ignored` → `not-ignored`
  - `curl -fsS https://hub.docker.com/v2/repositories/library/golang/tags/1.25 | grep -o '"digest":"[^"]*' | head -1` → same digest as tag `1.25.14`
  - `git ls-remote https://github.com/getlago/lago-cli HEAD` → `49a7a03…` (if changed, re-check for an `exec`/`up` subcommand)
  - `git rev-parse --is-shallow-repository` → `true` in agent sessions
- Update triggers: a lago-expression ref, Rust image or Go version bump (any of the four places);
  a dependabot PR touching the `go` line; a new Dockerfile or workflow; changes to volumes, profiles or
  `Host()` rules in `docker-compose.dev.yml`; edits to `docs/dev_environment.md` or
  `events-processor/CLAUDE.md` (OD-5 decided); a new test package that needs Postgres or the `.so`;
  a Go release that ships `covdata` in the toolchain module; a new sandbox image (Postgres or local Go
  version change); lago-cli adding `exec`.
