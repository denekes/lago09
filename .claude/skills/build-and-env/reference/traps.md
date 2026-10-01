# Build and environment traps: reproductions and captured output

Read when a symptom in the SKILL.md trap table needs confirming, or when you want to see the exact
output before trusting a fix. Every reproduction below was run on 2026-10-01 in a daemon-less agent
sandbox (Ubuntu 24.04, local Go 1.24.7 + `GOTOOLCHAIN=auto`, rustc 1.97.0, PostgreSQL 16.14).
All of them are read-only on the repo (change-control N10): outputs go to `mktemp -d`, the real
Postgres cluster is never stopped (a closed port or wrong password simulates failure), and caches are
redirected with env vars. Run from the repo root.

Setup used by several entries:
```bash
cd "$(git rev-parse --show-toplevel)"
T=$(mktemp -d)                      # scratch for build outputs
```

## B1. Link error: `cannot find -lexpression_go`
```bash
(cd events-processor && env -u CGO_LDFLAGS -u LD_LIBRARY_PATH go build -o "$T/ep" .)
```
```
/usr/bin/ld: cannot find -lexpression_go: No such file or directory
collect2: error: ld returned 1 exit status
```
Same for `go build ./...` (it links the main package too) and for `go test` of
`processors/events_processor`. Cause: the wrapper says `#cgo LDFLAGS: -lexpression_go` with no `-L`.
Fix: `source .claude/skills/build-and-env/scripts/ep-env.sh` (sets `CGO_LDFLAGS=-L<cache>/target/release`).

## B2. Loader error: `libexpression_go.so: cannot open shared object file`
```bash
source .claude/skills/build-and-env/scripts/ep-env.sh
(cd events-processor && go build -o "$T/ep" . && env -u LD_LIBRARY_PATH ldd "$T/ep" | grep expression \
  && env -u LD_LIBRARY_PATH "$T/ep"; env -u LD_LIBRARY_PATH go test -count=1 ./processors/events_processor/)
```
```
	libexpression_go.so => not found
.../ep: error while loading shared libraries: libexpression_go.so: cannot open shared object file: No such file or directory
/tmp/go-build.../events_processor.test: error while loading shared libraries: libexpression_go.so: cannot open shared object file: No such file or directory
FAIL	github.com/getlago/lago/events-processor/processors/events_processor	0.001s
```
The build links (58,101,160-byte binary) but the dynamic loader cannot find the `.so` at start.
Fix: `LD_LIBRARY_PATH` from `ep-env.sh`. CI instead copies the `.so` to `/usr/local/lib` and runs
`sudo ldconfig` (`.github/workflows/events-processor-tests.yml:51-56`); the Dockerfiles copy it to
`/usr/lib` (`events-processor/Dockerfile:14,22`). Do not do the system-wide copy in a shared sandbox.

With both variables set and no runtime env, the binary starts and dies with
`{"level":"ERROR","msg":"brokers not found",...}` then `panic: brokers not found`. That is EXPECTED and
proves link + load are fine; runtime configuration is the `config-and-flags` / `run-and-operate` skills.

## B3. `build constraints exclude all Go files` (cgo off: explicit or silent)
```bash
(cd events-processor && env -u CGO_LDFLAGS CGO_ENABLED=0 go build -o "$T/ep" .)
# silent variant: no C compiler on PATH
mkdir -p "$T/bin" && ln -sf "$(command -v go)" "$T/bin/go" && ln -sf "$(command -v git)" "$T/bin/git"
(cd events-processor && PATH="$T/bin" go env CGO_ENABLED && PATH="$T/bin" go build ./... 2>&1 | tail -1)
```
```
package github.com/getlago/lago/events-processor
	imports github.com/getlago/lago/events-processor/processors
	imports github.com/getlago/lago/events-processor/processors/events_processor
	imports github.com/getlago/lago-expression/expression-go: build constraints exclude all Go files in <GOMODCACHE>/github.com/getlago/lago-expression/expression-go@v0.1.4
0
	imports github.com/getlago/lago-expression/expression-go: build constraints exclude all Go files in ...
```
Go (>= 1.20) defaults `CGO_ENABLED=0` when no C compiler is found, so a host without gcc shows the
same error as an explicit `CGO_ENABLED=0`. Fix: install gcc (`build-essential`), unset `CGO_ENABLED`,
check `(cd events-processor && go env CGO_ENABLED)` prints `1`. `doctor.sh` FAILs on this.
Related: `CC` pointing at a missing compiler gives `cgo: C compiler "gcc-missing" not found: exec:
"gcc-missing": executable file not found in $PATH` (reproduced with `CC=gcc-missing go build ./...`).

## B4. Coverage: `go: no such tool "covdata"` and exit 1
```bash
source .claude/skills/build-and-env/scripts/ep-env.sh
(cd events-processor && go test -count=1 -coverprofile="$T/c.out" ./... >"$T/cov.txt" 2>&1; echo "exit=$?"; grep -c covdata "$T/cov.txt"; ls "$(go env GOTOOLDIR)")
```
```
exit=1
5
asm cgo compile cover link preprofile vet
```
One `go: no such tool "covdata"` per package without tests (root, config/redis, config/tracing,
processors, tests). The go1.25.0 toolchain module has no `covdata`; the local go1.24.7 install does.
Fix (exit 0, total 47.4%):
```bash
(cd events-processor && PKGS=$(go list -f '{{if or .TestGoFiles .XTestGoFiles}}{{.ImportPath}}{{end}}' ./...) \
  && go test -count=1 -coverprofile="$T/c.out" $PKGS >/dev/null && go tool cover -func="$T/c.out" | tail -1)
```
Coverage policy and the cross-package `-coverpkg` figure are in `validation-and-qa`.

## B5. Go toolchain: `GOTOOLCHAIN=local` and offline
```bash
(cd events-processor && GOTOOLCHAIN=local go list ./... 2>&1 | head -1)
E=$(mktemp -d); (cd events-processor && GOMODCACHE="$E" GOPROXY=off go version 2>&1); rm -rf -- "$E"
```
```
go: go.mod requires go >= 1.25.0 (running go 1.24.7; GOTOOLCHAIN=local)
go: downloading go1.25.0 (linux/amd64)
go: download go1.25.0 for linux/amd64: toolchain not available
```
The toolchain comes from `proxy.golang.org` (module `golang.org/toolchain@v0.0.1-go1.25.0.linux-amd64`,
about 214 MB in `$(go env GOMODCACHE)`). Fixes: run any `go` command in `events-processor/` once while
online (the toolchain is then cached), or install Go >= 1.25.0 and keep `GOTOOLCHAIN=auto`/`local`.
In the agent sandbox `https://go.dev/dl/…` and `https://dl.google.com/go/…` return HTTP 403 through
the proxy (as of 2026-10-01) while `proxy.golang.org` works, so `GOTOOLCHAIN=auto` is the only path.

## B6. Postgres down: nil-pointer panic in `TestNewConnection`
```bash
DATABASE_URL=postgres://lago:lago@localhost:5499/lago .claude/skills/build-and-env/scripts/ep-test.sh --no-cgo -count=1
```
```
ep-test: WARNING Postgres not reachable at postgres://lago:***@localhost:5499/lago - config/database TestNewConnection will FAIL with a nil-pointer panic. ...
... ERROR failed to initialize database, got error failed to connect to `user=lago database=lago`:
	127.0.0.1:5499 (localhost): dial error: dial tcp 127.0.0.1:5499: connect: connection refused ...
--- FAIL: TestNewConnection (0.01s)
    database_test.go:22: ... Received unexpected error: ...
    database_test.go:23: ... Expected value not to be nil.
panic: runtime error: invalid memory address or nil pointer dereference [recovered, repanicked]
[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=...]
...config/database.TestNewConnection(...)  .../config/database/database_test.go:24
```
Read the first `ERROR … dial tcp` line, not the stack. The test uses `assert` (not `require`) and then
dereferences `db.Connection` (`events-processor/config/database/database_test.go:21-24`).
Wrong password / missing role instead gives `failed SASL auth: FATAL: password authentication failed
for user "lago" (SQLSTATE 28P01)` (reproduced with `DATABASE_URL=postgres://lago:wrong@…`), and the
same panic. Note: `pg_isready` prints `accepting connections` even when the login would fail; `doctor.sh`
therefore also runs `psql … -c 'select 1'`. Fix: SKILL.md "Postgres for tests".

## B7. `cargo` missing
```bash
NOCARGO=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '\.cargo' | paste -sd:)
env LAGO_SKILLS_CACHE="$T/cache" PATH="$NOCARGO" bash -c 'source .claude/skills/build-and-env/scripts/ep-env.sh; echo "status=$?"'
env LAGO_SKILLS_CACHE="$T/cache" PATH="$NOCARGO" .claude/skills/build-and-env/scripts/ep-test.sh --no-cgo | grep -c '^ok'
```
```
ep-env: cargo not found; install Rust (https://rustup.rs) and re-source
status=1
5
```
Only needed once per lago-expression ref (the `.so` is cached). `--no-cgo` runs the 5 packages that do
not link the library. `doctor.sh` prints `WARN  cargo missing: …`.

## B8. Shallow working clone
```bash
git rev-parse --is-shallow-repository      # true
git show 4100da0 2>&1 | head -1
git log --oneline -- events-processor | wc -l
git blame -L3,3 events-processor/go.mod
```
```
fatal: ambiguous argument '4100da0': unknown revision or path not in the working tree.
19
^8ceca4b (Vincent Pochet 2026-05-15 16:03:52 +0200 3) go 1.25.0
```
`git blame` silently attributes every older line to the shallow boundary commit (`^` prefix). The
full history says the `go 1.25.0` line came from dependabot `932c06c`. Fix: the bare history clone,
`H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`; then
`git -C "$H" log --oneline -- events-processor events_processor | wc -l` gives 96 (the directory was
named `events_processor` before `d5bce86`). History-mining discipline: `research-methodology`.

## B9. Empty submodules and SSH URLs
```bash
git submodule status                       # -591ae90… api / -0c5e539… front  ('-' = never initialized)
git config --show-origin --get-regexp '^url\.'   # is an insteadOf rewrite active?
```
Reproduction on a scratch clone with the sandbox's injected rewrite removed from the environment:
```bash
S=$(mktemp -d)
NOGIT="env -u GIT_CONFIG_COUNT -u GIT_CONFIG_KEY_0 -u GIT_CONFIG_VALUE_0 -u GIT_CONFIG_KEY_1 -u GIT_CONFIG_VALUE_1 -u GIT_CONFIG_KEY_2 -u GIT_CONFIG_VALUE_2"
$NOGIT git clone -q --depth 1 "file://$PWD" "$S/lago" && cd "$S/lago"
$NOGIT git submodule update --init --depth 1 front                                  # fails
$NOGIT git -c url."https://github.com/".insteadOf="git@github.com:" submodule update --init --depth 1 front   # works
$NOGIT git submodule init api && $NOGIT git config submodule.api.url https://github.com/getlago/lago-api.git \
  && $NOGIT git submodule update --depth 1 api                                       # works, persistent
$NOGIT git submodule status; $NOGIT git status --porcelain                            # pins unchanged, tree clean
cd - >/dev/null
```
```
error: cannot run ssh: No such file or directory
fatal: unable to fork
fatal: clone of 'git@github.com:getlago/lago-front.git' into submodule path '.../front' failed
Failed to clone 'front' a second time, aborting
...
Submodule path 'front': checked out '0c5e539b9e23f967132de91f226b0c748be97fd5'     (4.7 s)
Submodule path 'api': checked out '591ae9005110346f1c6034ec72ea9046625668cf'       (4.8 s)
 591ae9005110346f1c6034ec72ea9046625668cf api (591ae90)
 0c5e539b9e23f967132de91f226b0c748be97fd5 front (0c5e539)
```
On a host that has `ssh` but no GitHub key the first command fails with
`git@github.com: Permission denied (publickey).` (standard git/ssh text; UNVERIFIED here, no ssh binary).
In the Claude Code cloud sandbox observed on 2026-10-01 the rewrite is pre-injected through
`GIT_CONFIG_COUNT`/`GIT_CONFIG_KEY_n` env vars, and there is no `ssh` binary at all:
`git config --show-origin --get-regexp '^url\.'` prints `command line: url.https://github.com/.insteadof git@github.com:`
(and `ssh://git@github.com/`), which is why SSH URLs "just work" there and fail on a plain host without a key.
Notes:
- The `-c` form is one-shot: `remote.origin.url` inside `front/` stays `git@github.com:…`, so later
  fetches in the submodule need the rewrite again. The `submodule.<name>.url` form writes only to
  `.git/config` (persistent, no tracked diff); `git submodule sync` resets it from `.gitmodules`.
- Neither form moves the gitlink. Still run `git diff --cached --submodule` before any commit
  (change-control N1).
- For READING lago-api/lago-front at the pin you do not need submodules at all:
  `.claude/skills/research-methodology/scripts/pinned-checkout.sh api|front`.

## B10. `lago` in agent shells
```bash
bash -c 'alias lago="echo ALIAS"
lago exec x'; echo "exit=$?"
```
```
bash: line 2: lago: command not found
exit=127
```
Non-interactive bash does not expand aliases (`expand_aliases` is off), and agent shells do not read
`~/.bashrc` interactively. With getlago/lago-cli installed (binary literally named `lago`, default
install dir `/usr/local/bin`), the same command reaches that binary instead (lago-cli `49a7a03`, built
from source into a scratch dir):
```
$ lago exec events-processor go test ./...
Error: unknown command "exec" for "lago"           (exit 2)
$ lago up -d
Error: unknown shorthand flag: 'd' in -d            (exit 2)
```
In an interactive shell an alias wins over a binary of the same name; in scripts the binary wins.
Fix: `.claude/skills/build-and-env/scripts/dc.sh …` or `docker compose -f docker-compose.dev.yml …`.

## B11. No Docker daemon
```bash
docker ps; docker compose -f docker-compose.dev.yml up --dry-run front
```
```
failed to connect to the docker API at unix:///var/run/docker.sock; check if the path is correct and if the daemon is running: dial unix /var/run/docker.sock: connect: no such file or directory
unable to get image 'redis:7-alpine': failed to connect to the docker API at unix:///var/run/docker.sock; ...
```
(The image named in the second message varies between runs: `redis:7-alpine`,
`getlago/postgres-partman:15.0-alpine`, `front_dev`, ... The `failed to connect to the docker API` part is stable.)
`docker build --check …` fails the same way, so no Dockerfile can be built or lint-checked here.
`docker compose … config` (and `--services`, `--profiles`, `--volumes`, `--quiet`) work.

## B12. Built binary not ignored
```bash
for p in events-processor/event_processors events-processor/events-processor events-processor/tmp/main events-processor/cover.out; do
  git check-ignore -q "$p" && echo "ignored  $p" || echo "NOT ignored  $p"; done
```
```
NOT ignored  events-processor/event_processors
ignored  events-processor/events-processor
ignored  events-processor/tmp/main
ignored  events-processor/cover.out
```
`events-processor/README.md:13` builds `event_processors`; `.gitignore:24` only ignores
`events-processor` (the default `go build` output name); `tmp/` covers air's output. Always build to
`-o "$TMPDIR/…"` (change-control N10). There is no `.dockerignore` in `events-processor/` either, so a
stray binary or `.env` there is copied into a local image build by `COPY . /app/` (`Dockerfile:11`).

## B13. Do not "align" the wrapper version
```bash
(cd events-processor && go list -m github.com/getlago/lago-expression/expression-go@v0.2.0)
```
```
go: github.com/getlago/lago-expression/expression-go@v0.2.0: invalid version: unknown revision expression-go/v0.2.0
```
See `reference/toolchain-matrix.md` §2 (ABI identical; change-control N3).

## B14. golangci-lint v2 flag, and parallel runs
`golangci-lint run --cache-dir X ./...` gives `Error: unknown flag: --cache-dir`. Use
`GOLANGCI_LINT_CACHE=$(mktemp -d) golangci-lint run --allow-parallel-runners ./...` (exit 1, `21 issues: errcheck: 16,
staticcheck: 5` as of 2026-10-01).
Without `--allow-parallel-runners`, a run started while another golangci-lint holds
`${TMPDIR:-/tmp}/golangci-lint.lock` waits briefly, then prints `Error: parallel golangci-lint is running`
and exits 3 (reproduced by holding the lock with `flock "$TD/golangci-lint.lock" sleep 15 &` and running
with `TMPDIR=$TD`; first seen when parallel agents linted on the same host). `go vet ./...` and golangci-lint do NOT need `ep-env.sh`: both
exited as usual with `CGO_LDFLAGS`/`LD_LIBRARY_PATH` unset, verified with a cold `GOCACHE` (they
type-check, they do not link). Lint policy: OPEN DECISION OD-6 (owner); baseline in `validation-and-qa`.

## B15. External volume `lago_front_pnpm_store` (dev stack)
`docker-compose.dev.yml:11-12` declares it `external: true` (added by `195bbc0`); `docker compose …
config --volumes` lists it. Compose refuses to start `front` until it exists
(`docker volume create lago_front_pnpm_store`). The exact Compose error text is UNVERIFIED here (no
daemon); no doc mentions the volume (`grep -rn pnpm_store docs README.md` is empty).
