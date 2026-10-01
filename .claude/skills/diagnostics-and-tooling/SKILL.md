---
name: diagnostics-and-tooling
description: How to MEASURE runtime behaviour in the Lago umbrella repo instead of eyeballing code - verified probe harnesses with exact commands and expected outputs. kfake (in-process Kafka) driving the REAL events-processor consumer group and processor (kfake-run.sh), binary smoke against kfake + miniredis + scratch Postgres (smoke-binary.sh), go test -overlay without touching the repo (overlay-run.sh), throwaway databases incl. the real lago-api schema (scratch-pg.sh), ClickHouse semantics via clickhouse local (ch-local.sh), compose config without a daemon, -race on the real pipeline, pprof. Use when a claim needs a probe output - "does the consumer commit past X", "what lands on the DLQ", "kfake", "EachSupportedFeature undefined", "miniredis", "-overlay", "scratch database", "toDecimal128OrZero", "clickhouse local", "no Docker daemon", "smoke test the binary", "data race". Not for conclusions (owning skills), test policy (validation-and-qa), symptom triage (debugging-playbook) or bring-up (run-and-operate).
---
# Diagnostics and tooling: measure, don't eyeball

This skill ships the probe harnesses for this repo and tells you how to run, read and adapt them.
Every harness here was run; its expected output is recorded. Conclusions drawn from the outputs live
in the owning skills. Facts verified 2026-10-01 against HEAD 5308258 unless marked (the skills
commit on top of it changes only `.claude/`).

## When to use / when NOT to use

Use this skill when:
- you are about to claim what events-processor does at runtime (commit, redelivery, DLQ, values,
  timing, concurrency) and need a probe output for it;
- you need Kafka, Redis, Postgres or ClickHouse in a sandbox with no Docker daemon;
- you want to change a test or add a probe without writing into the repo;
- you must write the kfake test that change-control N7 requires before a delivery-semantics change
  (the delivery contract itself is OPEN DECISION OD-2 (owner); this skill only measures);
- a harness here fails or drifts (version trap, expected-today diff).

Do NOT use it for:
- what the outputs mean for the design, or weak points -> `architecture-contract`;
- Go vs Rails/ClickHouse semantics and their probes (value format, time precision) -> `rails-go-parity`;
- the fault-matrix ledger and the fixes for silent loss -> `event-accounting-campaign`;
- baselines, acceptance thresholds, when `-race`/coverage is required -> `validation-and-qa`;
- symptom -> cause -> fix tables, DLQ codes, log triage script -> `debugging-playbook`;
- the evidence bar and hypothesis cards -> `research-methodology`;
- building the CGO toolchain, Postgres for tests -> `build-and-env`;
- running the dev stack or compose variants -> `run-and-operate`.

## Terms

| Term | Meaning here |
|---|---|
| probe | A throwaway program or test whose output answers one question. Never written into the repo. |
| harness | A reusable probe shipped in `scripts/` with a recorded expected output. |
| kfake | `github.com/twmb/franz-go/pkg/kfake`: an in-process Kafka broker (real TCP ports, consumer groups, commits, request interception). |
| miniredis | `github.com/alicebob/miniredis/v2`: in-process Redis (already an events-processor test dependency). |
| overlay | `go test -overlay=<json>`: compile as if files were added, replaced or deleted, without touching disk. |
| scratch DB | A Postgres database created and tagged by `scratch-pg.sh`, dropped after the probe. |
| expected-today | The output recorded on 2026-10-01, defects included. A diff is a measurement, not automatically a regression. |
| CGO env | `source .claude/skills/build-and-env/scripts/ep-env.sh`: needed to build anything importing `processors/events_processor` (links `libexpression_go`). |
| DB mode / memory-cache mode | events-processor reads Postgres per event (default) vs an in-memory badger cache fed by a snapshot + Debezium CDC (`LAGO_USE_MEMORY_CACHE=true`, `events-processor/main.go:67`). Production use of the latter is OPEN DECISION OD-1 (owner). |

## 1. The measurement rule

1. A claim about runtime behaviour is accepted only with a probe output: the exact command, its
   output and its exit status, run at a stated sha. A code read is evidence for what code SAYS, not
   for what it DOES. The full evidence bar is in `research-methodology` (section "The evidence bar");
   claims without evidence are labelled UNVERIFIED (change-control N13).
2. Predict the number before you run (`research-methodology` hypothesis card). Include a control: a
   run where the effect must NOT appear (e.g. `cdc-brokers` runs the single-broker case first).
3. Wait on observable conditions (committed offset, high watermark), not on `sleep`. Re-run
   timing-sensitive probes at least twice.
4. Probes never write into the repo (change-control N10): overlays, `$TMPDIR`, scratch DBs,
   `$LAGO_SKILLS_CACHE`. After any probe, `git status --porcelain --ignored -- events-processor`
   must print nothing (plain `git status` hides ignored build outputs, see Traps).
5. Name versions in results from external tools (ClickHouse, franz-go): "on CH 26.2.19.43", never
   "ClickHouse does".
6. Publish the measurement where the reader will look: the owning skill, the PR body, or the
   expected-today file of the harness.

## 2. Chooser: question -> harness

| If your question is ... | Use | Cost (warm) |
|---|---|---|
| Does the real consumer + processor enrich, produce and commit N records? | `kfake-run.sh happy-path` | ~3 s |
| What happens to a record when X fails / is slow / the pod restarts? | new kfake scenario (`reference/kfake-technique.md` s.5); the fault matrix itself is `event-accounting-campaign`'s | minutes to write |
| Does the memory-cache CDC consumer work with my broker list? | `kfake-run.sh cdc-brokers` | ~5 s |
| What does the real BINARY do with typical and malformed events? | `smoke-binary.sh [db\|cache\|cache-cdc\|all]` | ~8 s |
| What would a test say if this file were different / a probe test existed? | `overlay-run.sh` | ~3 s |
| What does this SQL do on Postgres / on the real lago-api schema? | `scratch-pg.sh create [--lenient]` | <1-3 s |
| What does ClickHouse do with this string/function? | `ch-local.sh "<SQL>"` | 16 s first, 0.2 s after |
| Does a compose file parse; what does a service resolve to? | `docker compose -f <file> config` | <1 s |
| Is the consumer path race-free? Where does CPU go? | `GOFLAGS=-race kfake-run.sh ...`, `-cpuprofile` | ~8 s |
| Need a go.mod change for the experiment | scratch copy (`reference/harness-catalogue.md` H11) | ~5 s |

Every row's exact command, expected output, adaptation and owner: `reference/harness-catalogue.md`
(read when you have picked a row).

## 3. Quick start (run once to confirm your sandbox)

```bash
cd "$(git rev-parse --show-toplevel)"
S=.claude/skills/diagnostics-and-tooling/scripts
$S/kfake-run.sh --check          # expect: franz-go: events-processor=v1.20.5 harness=v1.20.5 / kfake-run: check OK
$S/kfake-run.sh happy-path       # expect last line: RESULT: PASS (every record enriched + in-advance, 0 DLQ, offsets committed)
$S/smoke-binary.sh all           # expect 3 x "== EXPECTED-TODAY: MATCH", then "smoke-binary: total ~8s, exit 0"
```
Prerequisites: Go (GOTOOLCHAIN=auto fetches go1.25.0), cargo for the first `ep-env.sh` (~40-60 s),
`psql` + a reachable Postgres for `smoke-binary.sh`/`scratch-pg.sh` (if `pg_isready` fails, see
`build-and-env`), `jq` for `overlay-run.sh`. First harness build with an empty Go build cache: allow
1-2 min (116 s measured on a shared 4 vCPU sandbox, 2026-10-01); warm reruns ~0.5 s. The scripts work
from any directory; relative paths you pass in flags resolve from YOUR current directory.

## 4. kfake: drive the REAL consumer in-process

What it is: `scripts/kfake-harness/` is a Go module (`lagoskills/kfakeharness`) that imports the
repo's events-processor through `replace github.com/getlago/lago/events-processor =>
../../../../../events-processor` and wires the production components the way
`events-processor/processors/main_processor.go:102` `StartProcessingEvents` does (minus env parsing,
SASL/TLS, Kafka client tracer hooks and panics: `reference/kfake-technique.md` s.6): `kafka.NewConsumerGroup`
(`events-processor/config/kafka/consumer.go:227`, group id `<prefix>_<topic>` at `:237`), the poll loop, per-partition
`processRecordsAndCommit` (`:82`) and `findMaxCommitableRecord` (`:278`), the real `EventProcessor`,
real producers, and the Redis flag store on miniredis.

**Version trap (VERIFIED).** kfake has no tags. `go get .../kfake@latest` pulls franz-go v1.21.7 and a
go1.26 toolchain under events-processor (which ships v1.20.5); forcing v1.20.5 back with `replace`
fails with `vs.EachSupportedFeature undefined`. The module pins
`github.com/twmb/franz-go/pkg/kfake v0.0.0-20251123185109-2b5c574e9ddd` (requires franz-go v1.20.4,
so v1.20.5 stays). Never run `go get -u` in the harness; re-pin per `reference/kfake-technique.md` s.2.

Packages (details and API: `reference/kfake-technique.md` s.3):

| Package | CGO | Use it for |
|---|---|---|
| `kfx` | no | start kfake with topics, produce, read to high watermark, committed offsets, groups; embeds `*kfake.Cluster` (`Control` for broker-level fault injection) |
| `fixture` | no | one deterministic tenant; `SeedCache` for memory-cache mode; same rows as `scripts/fixtures/smoke-schema.sql` for DB mode |
| `pipeline` | yes | `pipeline.New(ctx, Config{...})` + `Run(ctx)`; `Config.Wrap` wraps the real `ProcessEvents` (observe batches, drop a record = retryable path, panic = crash) |

Demo scenarios (expected outputs: `reference/kfake-technique.md` s.4):

```bash
$S/kfake-run.sh happy-path -n 5000 -partitions 3     # committed 5000, enriched 5000, in-advance 5000, DLQ 0, PASS
$S/kfake-run.sh happy-path -store db -db-url "$($S/scratch-pg.sh create hp_db $S/fixtures/smoke-schema.sql)"; $S/scratch-pg.sh drop hp_db
$S/kfake-run.sh cdc-brokers                          # brokers=1 -> visible=true ; brokers=2 comma_joined=true -> visible=false
```

`kfake-run.sh` builds the scenario into `$LAGO_SKILLS_CACHE/kfake-harness-bin/` and execs it, so the
scenario's exit code is the script's exit code (happy-path: 0 PASS, 1 FAIL, 2 setup error; 66 = race
found under `GOFLAGS=-race`). Plain `go run` would turn every non-zero exit into 1.

Add a scenario: `cmd/<name>/main.go` following the template in `reference/kfake-technique.md` s.5,
then `kfake-run.sh --check` and `GOFLAGS=-race kfake-run.sh <name>`. The fault-matrix ledger
(per-offset enriched/DLQ/redelivered/LOST) is built by `event-accounting-campaign` on these packages;
do not duplicate it here.

## 5. Binary smoke: the real binary, end to end, no Docker

`smoke-binary.sh` builds `events-processor` into a mktemp dir (with `ep-env.sh`), creates a scratch
DB from `fixtures/smoke-schema.sql`, and runs the binary with a dev-like environment against kfake
(TCP on 127.0.0.1) and miniredis hosted by the `cmd/smoke` driver. It produces 9 events, waits for the
committed offset, reads every output topic and the ZSET, sends SIGTERM and compares the result block
with `fixtures/smoke-expected-<mode>.txt`.

```bash
$S/smoke-binary.sh all            # exit 0: all modes MATCH; 3: a mode DIFFERS (diff printed); 2: setup error
$S/smoke-binary.sh db --keep      # keep binary + logs in the printed temp dir (for jq triage)
```

Observed 2026-10-01 (identical on 3 runs):

| Event | db | cache | cache-cdc |
|---|---|---|---|
| A sum metric, `amount: 0.0000001`, pay-in-advance charge | enriched `value="1e-07"` + in-advance | same | enriched, **in_advance=no** |
| B unknown code | DLQ `fetch_billable_metric(record not found)` | DLQ `(Key not found)` | same as cache |
| C timestamp `"2025-03-06 12:00:00"` | DLQ `build_enriched_event` | same | same |
| D invalid JSON | **on no output topic** (committed) | same | same |
| E expression + extra boolean property | DLQ `evaluate_expression` | same | same |
| F unknown subscription | enriched, `subscription_id=""` | same | same |
| G `http_ruby`, `api_post_processed=true` | enriched only | same | same |
| H event at the ms the sub started (+500 us) | enriched, sub matched | enriched, **sub NOT matched** | same as cache |
| I expression OK | enriched `value="4"` | same | same |
| totals | committed 9/9, ZSET 1 member, clean SIGTERM exit | + 6 `lago_evp_<model>_<uuid>` groups | same |

What these mean (defects, contracts) is owned by `architecture-contract`, `rails-go-parity` and
`event-accounting-campaign`; memory-cache rows depend on OPEN DECISION OD-1 (owner). If your PR
changes a row on purpose, update the expected file in the same PR (and its change class gates:
change-control C3/C4).

## 6. go test -overlay: change tests without touching the repo

```bash
$S/overlay-run.sh --no-cgo config/kafka/zz_commit_prefix_test.go=$S/overlay-examples/commit_prefix_test.go \
    -- -count=1 -v -run TestOverlayDemo ./config/kafka/
# --- PASS: TestOverlayDemo_CommitPrefixTable ... ok  github.com/getlago/lago/events-processor/config/kafka
```
- `<target>=<source>` adds (target missing) or replaces (target exists); `<target>=` deletes from the
  build view. Targets are relative to `events-processor/`. Omit `--no-cgo` for
  `processors/events_processor`. Default go test args: `-count=1 ./...`.
- An overlaid `_test.go` in the same package can call unexported functions (white-box probes).
- Limits: compile-time only (runtime file reads see the real disk); no new module dependencies (use a
  scratch copy or a separate module). `go test` runs in `events-processor/`: pass ABSOLUTE output
  paths (`-coverprofile="$T/c.out"`); a relative one lands in the repo, hidden by `.gitignore`, and
  the script exits 4 and prints it (it compares `git status --porcelain --ignored` before/after).
- Strict-sqlmock overlay and other test-policy overlays: `validation-and-qa`.

## 7. Throwaway Postgres

```bash
URL=$($S/scratch-pg.sh create probe_x $S/fixtures/smoke-schema.sql)   # postgres://lago:lago@localhost:5432/probe_x
$S/scratch-pg.sh list ; $S/scratch-pg.sh drop probe_x
API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)
$S/scratch-pg.sh create --lenient probe_real "$API/db/structure.sql"  # "lenient: 1 SQL error(s) skipped" (pg_partman absent), 143 tables
```
Drops only databases it tagged (`COMMENT ... 'lago-skills scratch'`); refuses `lago`, `postgres`,
templates and untagged DBs (exit 3). Admin URL = `$DATABASE_URL` (default
`postgres://lago:lago@localhost:5432/lago`).

## 8. ClickHouse semantics locally

```bash
$S/ch-local.sh "SELECT toDecimal128OrZero('1e+06', 26)"    # 1000000   (CH 26.2.19.43)
$S/ch-local.sh "SELECT toDecimal128OrZero('1000000000000', 26), toDecimal128OrZero('<nil>', 26)"   # 0  0
```
Downloads the official static binary from GitHub release assets (sha512-checked) into
`$LAGO_SKILLS_CACHE/clickhouse/<ver>/` once (~211 MB, 724 MB on disk). Version = `CH_VERSION`, else the
newest cached patch of the minor in `docker-compose.dev.yml:460` (`26.2-alpine`), else (or with
`--refresh`) the newest `v26.2.*-stable` tag on GitHub (26.2.19.43 on 2026-10-01). Production's version is
unknown; any schema change is OPEN DECISION OD-3 (owner). `packages.clickhouse.com` was blocked by the
sandbox proxy; if GitHub is blocked too the script exits 2: then ClickHouse semantics stay UNVERIFIED.

## 9. Compose without a daemon

`docker compose -f docker-compose.dev.yml config --quiet && echo valid` works with no daemon (0.13 s);
`config --services`, `--profiles`, `--format json | jq '.services["events-processor"].environment.LAGO_KAFKA_CONSUMER_GROUP'`
(-> `"lago_dev"`) answer "what will it resolve to". `up`/`exec`/`ps` fail: `failed to connect to the
docker API at unix:///var/run/docker.sock`. Never dump whole resolved environments (change-control N11).
All compose files and bring-up: `run-and-operate`.

## 10. Race, shuffle, profiling (policy: `validation-and-qa`)

| Goal | Command | Observed 2026-10-01 |
|---|---|---|
| Race on the unit suite | `.claude/skills/build-and-env/scripts/ep-test.sh -race -count=1 ./...` | 6 packages ok, ~8-11 s |
| Race on the REAL consumer path (the unit suite never runs it) | `GOFLAGS=-race $S/kfake-run.sh happy-path -n 5000 -partitions 4` | PASS, 0 races (x3; DB mode too) |
| Order dependence | `.claude/skills/build-and-env/scripts/ep-test.sh -count=1 -shuffle=on -v ./utils/`; replay with `-shuffle=<seed>` | prints `-test.shuffle <seed>` |
| CPU through the pipeline | `T=$(mktemp -d); $S/kfake-run.sh happy-path -n 50000 -partitions 4 -cpuprofile $T/cpu.out; go tool pprof -top $T/cpu.out` | 8 batches, elapsed 3.0-3.5 s; relative use only |
| CPU of a unit test | `go test -run X -cpuprofile $T/cpu.out -o $T/x.test ./pkg/` (CGO env; full command: `reference/harness-catalogue.md` H9) | always pass `-o` (Traps) |

## 11. Traps that cost time when measuring

| If you see / do | It is | Do |
|---|---|---|
| `vs.EachSupportedFeature undefined` | latest kfake vs franz-go v1.20.5 | use the pinned kfake (section 4) |
| `go: upgraded github.com/twmb/franz-go v1.20.5 => v1.21.7` after `go get` | MVS moved franz-go under your probe | revert go.mod; never `go get -u` in a probe module |
| `-race` reports `events-processor/config/tracing/tracer.go:76` `GetTracer` | your harness did not call `tracing.InitTracer` like `events-processor/main.go:45-50` | `pipeline.New` does it; copy that line in custom wiring |
| `events_processor.test` / `events-processor` binary / `*.out` lying in `events-processor/`, invisible in `git status` | ignored by `events-processor/.gitignore:12,15,24` | `go build -o $T/...`, `go test -o $T/...`; check `git status --porcelain --ignored -- events-processor` |
| `cannot find -lexpression_go` / `libexpression_go.so: cannot open` | CGO env missing | `source .claude/skills/build-and-env/scripts/ep-env.sh` (details: `build-and-env`) |
| Probe sleeps then reads: flaky counts | race between your read and the commit | `kfx.WaitCommitted` / `ReadAll` to high watermark |
| `go test` result `(cached)` | cache hit, nothing re-ran | `-count=1` |
| overlay change not visible to a test reading a file | overlays are compile-time only | scratch copy (`reference/harness-catalogue.md` H11) |
| CDC consumer silently receives nothing | comma-separated `LAGO_KAFKA_BOOTSTRAP_SERVERS` (`events-processor/cache/consumer.go:28-31`) | measure with `cdc-brokers`; owner: `architecture-contract` |
| scratch DB left behind after a crash | the trap did not run | `scratch-pg.sh list`, then `drop` each |

## Scripts

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/kfake-run.sh` | build (to `$LAGO_SKILLS_CACHE/kfake-harness-bin/`) and run a kfake scenario with the CGO env, passing its exit code through; `--check` = vet + gofmt + franz-go pin | `kfake-run.sh happy-path` | `RESULT: PASS ...`, exit 0; `--check` -> `kfake-run: check OK` |
| `scripts/kfake-harness/` (Go module) | `kfx`, `fixture`, `pipeline` packages; `cmd/happy-path`, `cmd/cdc-brokers`, `cmd/smoke` | see section 4 | see `reference/kfake-technique.md` |
| `scripts/smoke-binary.sh` | build the binary to a temp dir, smoke it in db/cache/cache-cdc | `smoke-binary.sh all` | 3 x `EXPECTED-TODAY: MATCH`, exit 0 |
| `scripts/overlay-run.sh` | `go test -overlay` from `target=source` pairs | section 6 | `--- PASS: TestOverlayDemo_CommitPrefixTable` |
| `scripts/scratch-pg.sh` | create/drop/list/url tagged scratch DBs; `--lenient` for the real schema | section 7 | URL on stdout; `dropped <name>` |
| `scripts/ch-local.sh` | `clickhouse local` from a cached official binary | section 8 | `1000000` |
| `scripts/fixtures/smoke-schema.sql` | minimal Lago-shaped schema + fixture tenant (same ids as `fixture.go`) | `$S/scratch-pg.sh create x $S/fixtures/smoke-schema.sql` | 3 BMs, 1 sub, 2 charges |
| `scripts/fixtures/smoke-expected-{db,cache,cache-cdc}.txt` | expected-today result blocks | used by `smoke-binary.sh` | — |
| `scripts/overlay-examples/commit_prefix_test.go` | white-box overlay demo for `findMaxCommitableRecord` | section 6 | 3 logged decisions, PASS |

Exit codes are documented in each script header (`<script> --help` prints it). All scripts write only
to mktemp dirs, scratch DBs, `$LAGO_SKILLS_CACHE` or output paths you pass explicitly.
Re-verified end to end on 2026-10-01 by an independent pass (every command above re-run; exit codes,
outputs and cited lines checked).

## Provenance and maintenance

- Sources: `events-processor/config/kafka/consumer.go`, `processors/main_processor.go`,
  `processors/events_processor/processor.go`, `cache/consumer.go`, `config/tracing/tracer.go`,
  `main.go`, `events-processor/.gitignore`, `events-processor/go.mod`, `extra/debezium_config.json`,
  `docker-compose.dev.yml`; pinned lago-api `db/structure.sql`,
  `db/clickhouse_migrate/20240705080709_create_events_enriched.rb`; kfake source at
  `v0.0.0-20251123185109-2b5c574e9ddd` (`cluster.go`, `config.go`); commit `475761d` (#633, the Datadog
  tracing PR that also bumped franz-go v1.20.3 -> v1.20.5).
- Volatile facts and one-line re-verification (as of 2026-10-01):
  - franz-go pin: `grep -n 'twmb/franz-go v' events-processor/go.mod` -> `18: github.com/twmb/franz-go v1.20.5`
  - harness pin in sync: `.claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh --check` -> `check OK`
  - exit codes pass through: `.claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh happy-path -store bogus; echo $?` -> `2`
  - latest kfake still incompatible: `go list -m github.com/twmb/franz-go/pkg/kfake@latest` -> `v0.0.0-20260927204940-b5a45ccfdf7e` (re-run the s.2 reproduction if it changed)
  - harness still mirrors production wiring: `grep -n 'func StartProcessingEvents' events-processor/processors/main_processor.go` -> `102:`; diff its body against `pipeline.New`
  - binary behaviour: `.claude/skills/diagnostics-and-tooling/scripts/smoke-binary.sh all` -> exit 0
  - CH dev minor: `grep -n 'image: clickhouse/clickhouse-server' docker-compose.dev.yml` -> `460: ... 26.2-alpine`; `ch-local.sh --version` -> `26.2.19.43`
  - real schema loads: `$S/scratch-pg.sh create --lenient x "$API/db/structure.sql"; $S/scratch-pg.sh drop x` -> `lenient: 1 SQL error(s) skipped`
- Update triggers: franz-go or Go version bump in `events-processor/go.mod`; any change to
  `StartProcessingEvents`, `NewConsumerGroup`, `processRecordsAndCommit`, `ProcessEvents`, the env
  vars the binary reads, or the models' SQL columns; a lago-api pin bump (real schema); a change of
  the dev ClickHouse image; any `EXPECTED-TODAY: DIFFERS` from `smoke-binary.sh`.
