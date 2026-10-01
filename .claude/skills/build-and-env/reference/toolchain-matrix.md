# Toolchain and version matrix (per context)

Read when you bump a toolchain, see different `go version` / Postgres / Node output in two places,
or need to know which version a given context really uses. All values VERIFIED 2026-10-01 against
code at `5308258` unless marked. `$API` / `$FRONT` = pinned checkouts from
`.claude/skills/research-methodology/scripts/pinned-checkout.sh api|front`.

Changing any pin below is change class C5 (release/pins/images/CI) and falls under change-control N3:
pins move together, never float. The pin-sync check script belongs to the `change-control` skill.

## 1. Go (events-processor)

| Context | Version actually used | Where it is set |
|---|---|---|
| Module floor | `go 1.25.0` (no `toolchain` line) | `events-processor/go.mod:3` |
| CI tests | exactly `1.25.0` | `.github/workflows/events-processor-tests.yml:61` (`actions/setup-go@v4`, `:59`) |
| Local, any Go >= 1.21 with `GOTOOLCHAIN=auto` (the default in Go's `go.env`) | downloads and runs exactly `go1.25.0` (because go.mod says `1.25.0` and has no `toolchain` line) | this sandbox: `/usr/local/go` is 1.24.7, `cd events-processor && go version` prints `go version go1.25.0 linux/amd64` |
| mise users | `go = "1.25"` = newest 1.25.x mise knows (UNVERIFIED: mise not installed here; "fuzzy" version semantics per mise docs) | `events-processor/mise.toml:2` (added by `fff5858`, 2026-04-27; not mentioned in any doc) |
| Images (`Dockerfile`, `Dockerfile.dev`) | floating `golang:1.25`; on Docker Hub (as of 2026-10-01) `golang:1.25` has the same digest as `golang:1.25.14` | `events-processor/Dockerfile:7`, `events-processor/Dockerfile.dev:7` |
| Staging image | whatever `ghcr.io/getlago/events-processor-build:latest` ships (UNVERIFIED) | `events-processor/Dockerfile.staging:12,16` |
| Dev-container tools | `dlv@v1.25`, `air@v1.62` (pinned after `@latest` broke, `d589940`) | `events-processor/Dockerfile.dev:11-12` |

Consequences:
- Tests (CI, local) run on 1.25.0 while the shipped binary is compiled by the newest 1.25.x patch.
  Today that is harmless, but a patch-only behaviour difference would never be caught by CI.
- The go1.25.0 *toolchain module* that `GOTOOLCHAIN=auto` downloads has no `covdata` tool
  (`ls "$(go env GOTOOLDIR)"` lists `asm cgo compile cover link preprofile vet`); see trap table.
- Go 1.25 is out of upstream support: `proxy.golang.org/golang.org/toolchain/@v/list` lists
  `go1.27.0` and `go1.27.1` (as of 2026-10-01).
- History of the floor: `go 1.24.0 -> 1.25.0` was done by **dependabot** (`932c06c`, 2026-04-09 09:29
  +0200, an otel/sdk bump). CI and Dockerfiles followed 50 minutes later (`50015b0`, #725). Lesson: a
  dependency bump can raise the `go` directive; check `git diff -- events-processor/go.mod | grep '^[-+]go '`
  on every dependabot PR.

## 2. Rust and lago-expression

| Thing | Value | Where |
|---|---|---|
| Rust lib ref (the `.so` actually linked) | `v0.2.0` | `events-processor/Dockerfile:5`, `events-processor/Dockerfile.dev:5`, `events-processor/Dockerfile.staging:23` (`ARG LAGO_EXPRESSION_REF`), `.github/workflows/events-processor-tests.yml:45` |
| Go wrapper module | `expression-go v0.1.4` | `events-processor/go.mod:10`, `events-processor/go.sum:79-80` |
| Rails gem (lago-api) | lago-expression `2abd2b3` (gem version 0.2.0) | `$API/Gemfile:123`, `$API/Gemfile.lock:2-7` |
| Rust image | `rust:1.85` (Docker Hub `last_updated` 2025-03-19) | `events-processor/Dockerfile:1`, `events-processor/Dockerfile.dev:1` |
| Rust in CI | runner default, unpinned | `.github/workflows/events-processor-tests.yml:47-49` (no toolchain step) |
| Rust in this sandbox | `rustc 1.97.0`, `cargo 1.97.0` (rustup stable) | `cargo --version` |
| `.so` built by `ep-env.sh` | the ref parsed from `events-processor/Dockerfile` (`git checkout vX.Y.Z` line) | `.claude/skills/build-and-env/scripts/ep-env.sh` |

Verified facts behind the "v0.1.4 wrapper + v0.2.0 lib" split (do NOT "fix" go.mod, change-control N3):
- `git ls-remote --tags https://github.com/getlago/lago-expression` lists `expression-go/v0.1.0`,
  `expression-go/v0.1.4` and `v0.1.0 … v0.2.0`; there is no `expression-go/v0.2.0`.
- `go list -m -versions github.com/getlago/lago-expression/expression-go` prints `v0.1.0 v0.1.4`;
  `go list -m …/expression-go@v0.2.0` fails: `invalid version: unknown revision expression-go/v0.2.0`.
- `git diff --stat expression-go/v0.1.4 v0.2.0 -- expression-go/` (in a lago-expression clone) shows only
  `expression-go/Cargo.toml | 2 +-`; the `.go`/`.h` diff is 0 lines, so the cgo ABI is identical.
  `nm -D libexpression_go.so` shows `T evaluate` and `T free_evaluate`.
- Rails and Go evaluate with the same Rust core: `git diff --stat v0.2.0 2abd2b3 -- expression-core` is
  empty and `v0.2.0` is an ancestor of `2abd2b3`.
- The wrapper links with `// #cgo LDFLAGS: -lexpression_go` and no `-L` (lago-expression@v0.2.0
  `expression-go/expression.go:3`), hence `CGO_LDFLAGS` locally.
- The Rust image is part of the pin set: `5077151` bumped the ref to v0.2.0 in 3 files while
  `events-processor/Dockerfile` was still `rust:1.82`; `e8bbd60` "Fix prod release (#667)" moved it to
  `rust:1.85` the same day. The exact compile error is UNVERIFIED (not in the commit body).
- `d4e3665` added `--tags` to the `git clone` in both Dockerfiles (cached clone layers predating a tag).
- `Dockerfile.staging:20-22` says "bump both together"; there are **four** places, not two.

One-line check that the four places agree (expect four `v0.2.0` hits):
```bash
grep -nE 'git checkout v|LAGO_EXPRESSION_REF=|ref: v' events-processor/Dockerfile events-processor/Dockerfile.dev events-processor/Dockerfile.staging .github/workflows/events-processor-tests.yml
```

## 3. Postgres

| Context | Version | Where |
|---|---|---|
| events-processor CI | `postgres:14-alpine`, db/user/password `lago`/`lago`/`lago` | `.github/workflows/events-processor-tests.yml:25,29-34` |
| Agent sandbox | PostgreSQL 16.14 (Ubuntu 24.04 package), cluster `16/main` on 5432 | `psql --version`, `pg_lsclusters` |
| Dev compose | `getlago/postgres-partman:15.0-alpine`, user `lago`, password `changeme`, dbs `lago,lago_test` | `docker-compose.dev.yml:40,45-48` |
| Root self-host compose | `getlago/postgres-partman:15.0-alpine` (was `postgres:14-alpine` until `97d1f0b`, 2026-01-27) | `docker-compose.yml:7` |
| `deploy/` variants | plain `postgres:15-alpine` (no partman) | `deploy/docker-compose.local.yml:10`, `deploy/docker-compose.light.yml:10`, `deploy/docker-compose.production.yml:11` |
| All-in-one image | `postgresql-17` + `postgresql-17-partman` (Debian packages) | `docker/Dockerfile:49` |
| lago-api CI | `getlago/postgres-partman:15.0-alpine` | `$API/.github/workflows/spec.yml:15`, `$API/.github/workflows/migrations-test.yml:15` |

Why the spread is tolerable today: the only events-processor test that touches Postgres
(`TestNewConnection`, `events-processor/config/database/database_test.go:10-26`) needs a connection, not
a schema (the sandbox `lago` db has 0 tables in `public`). It will matter once DB-backed tests exist.

## 4. ClickHouse, Redpanda (for completeness; the events-processor has no ClickHouse client)

| Context | Version | Where |
|---|---|---|
| Dev compose ClickHouse | `clickhouse/clickhouse-server:26.2-alpine` | `docker-compose.dev.yml:460` |
| lago-api spec CI | `clickhouse/clickhouse-server:25.12-alpine` | `$API/.github/workflows/spec.yml:77` |
| lago-api migrations CI | `clickhouse/clickhouse-server:26.4-alpine` | `$API/.github/workflows/migrations-test.yml:65` |
| Root compose, `deploy/`, all-in-one | no ClickHouse service | `grep -ni clickhouse docker-compose.yml deploy/*.yml docker/Dockerfile` (no hits) |
| Dev Redpanda | `redpanda:v25.2.10`; console `v3.2.2`; connectors `latest` (floating) | `docker-compose.dev.yml:369,392,412,436` |
| Production ClickHouse version | UNVERIFIED (not visible from this repo) | — |

For a local ClickHouse to probe SQL semantics, see the `diagnostics-and-tooling` skill.

## 5. Ruby / Node / pnpm / Bundler (all-in-one `getlago/lago` image and the submodules)

| Thing | Value | Where |
|---|---|---|
| Node (all-in-one) | `NODE_VERSION=24` (major only, floating) | `docker/Dockerfile:1` |
| Ruby (all-in-one) | `RUBY_VERSION=4.0.6` | `docker/Dockerfile:2` |
| pnpm (all-in-one) | `corepack prepare pnpm@latest` + non-frozen `pnpm install` (floating) | `docker/Dockerfile:11-13` |
| Bundler (all-in-one) | `4.0.4` | `docker/Dockerfile:18` |
| Rust (all-in-one api_build) | rustup stable, unpinned | `docker/Dockerfile:25` |
| lago-front requires | node `24.20.0`, `pnpm@10.34.5` | `$FRONT/package.json:192`, `$FRONT/package.json:11` |
| lago-front images | `node:24.20.0-alpine`; prod Dockerfile uses `--frozen-lockfile`; dev Dockerfile uses `pnpm@latest` | `$FRONT/Dockerfile:4,25`, `$FRONT/Dockerfile.dev:1,6` |
| lago-api requires | ruby `4.0.6`; lockfile `BUNDLED WITH 4.0.16` | `$API/.ruby-version`, `$API/Gemfile:6`, `$API/Gemfile.lock:1191-1192` |
| lago-api images | `ruby:4.0.6-slim`, bundler `4.0.19`; `Dockerfile.dev` sets `BUNDLER_VERSION='4.0.19'` but installs `4.0.4` | `$API/Dockerfile:10,23,25`, `$API/Dockerfile.dev:22,30` |
| lago-api pdfcpu build stage | `golang:1.26.6` | `$API/Dockerfile:2,4` |

`pnpm@latest` is not hypothetical: `18b26d0` (#617) fixed a v1.35.0 all-in-one build failure
(`ERR_PNPM_ABORTED_REMOVE_MODULES_DIR_NO_TTY`) that its commit body attributes to a pnpm version update (pnpm/pnpm#9966).
Building and publishing these images is the `release-and-images` skill.

## 6. Lint and other tools (not pinned in the repo)

| Tool | Version in use | Notes |
|---|---|---|
| golangci-lint | v2.5.0 (built with go1.25.1) | No config file has ever existed in the repo. Policy is OPEN DECISION OD-6 (owner); baseline and gate are in `validation-and-qa`. `--cache-dir` is not a v2 flag; use `GOLANGCI_LINT_CACHE`. |
| actionlint / shellcheck / hadolint | not installed here | `release-and-images` and `security-and-supply-chain` own workflow and Dockerfile linting. |
| gcc | 13.3.0 here | Required for cgo; without a C compiler on PATH Go silently sets `CGO_ENABLED=0`. |

## Re-verification one-liners

```bash
sed -n 3p events-processor/go.mod; sed -n 2p events-processor/mise.toml          # go 1.25.0 / go = "1.25"
grep -n 'go-version' .github/workflows/events-processor-tests.yml                  # :61 "1.25.0"
grep -nE '^FROM (rust|golang)' events-processor/Dockerfile events-processor/Dockerfile.dev   # rust:1.85, golang:1.25
grep -n 'image:' docker-compose.dev.yml | grep -E 'postgres|clickhouse|redpanda'   # partman 15.0, ch 26.2, redpanda v25.2.10
sed -n 1,2p docker/Dockerfile; sed -n 18p docker/Dockerfile                        # NODE 24, RUBY 4.0.6, bundler 4.0.4
(cd events-processor && go version)                                               # go1.25.0 with GOTOOLCHAIN=auto
```
