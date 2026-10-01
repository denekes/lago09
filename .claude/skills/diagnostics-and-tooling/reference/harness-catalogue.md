# Harness catalogue (full entries)

Read when you picked a harness from the SKILL.md chooser and need the exact command, the output to
expect today, how to adapt it, and what it costs. All commands run from the repo root
(`cd "$(git rev-parse --show-toplevel)"`). `S=.claude/skills/diagnostics-and-tooling/scripts`.
Outputs VERIFIED 2026-10-01. Code facts as of 5308258 (events-processor tree 83e012866f29); the working
branch may carry skills-only commits on top.
Timings: 4 vCPU sandbox, warm Go caches unless stated. Conclusions drawn from these outputs belong to
the owning skills named in each entry, not to this one.

Contents: H1 happy-path · H2 cdc-brokers · H3 binary smoke · H4 overlay · H5 scratch Postgres ·
H6 ClickHouse local · H7 compose without daemon · H8 race on the real pipeline · H9 CPU profiles ·
H10 log triage · H11 scratch copy

---

## H1. kfake happy-path (real consumer group + processor, in-process)

- **Question:** with no faults, is every raw record enriched (+ in-advance), 0 DLQ, offsets committed?
- **Run:** `$S/kfake-run.sh happy-path [-n 100] [-partitions 1] [-store cache|db -db-url URL] [-cpuprofile F] [-v]`
- **Expected today:** see `kfake-technique.md` section 4 (`RESULT: PASS`, `committed offset ... 100`,
  `events_enriched: 100  events_charged_in_advance: 100  events_dead_letter: 0`, `sum(enriched value) = 5050`).
- **Adapt:** new `cmd/<name>` (template in `kfake-technique.md` section 5). Change the events in the
  produce loop; use `Config.Wrap` to observe or drop records; use `-store db` against a scratch DB.
- **Cost:** ~0.5 s warm (binary up to date in `$LAGO_SKILLS_CACHE/kfake-harness-bin/`), ~5 s after a source
  change (relink); with an empty Go build cache allow 1-2 min (116 s measured on a shared 4 vCPU sandbox;
  plus the go1.25.0 toolchain + module download if those caches are cold too); first `ep-env.sh` ever
  ~40-60 s (cargo build of libexpression_go).
- **Owner of conclusions:** `architecture-contract` (dispositions), `event-accounting-campaign` (loss).

## H2. kfake cdc-brokers

- **Question:** do memory-cache CDC consumers work with a comma-separated broker list?
- **Run:** `$S/kfake-run.sh cdc-brokers [-wait 4s] [-v]`
- **Expected today:** `brokers=1 ... visible in cache=true` then `brokers=2 comma_joined=true:
  ConsumeChanges err=<nil>, CDC update visible in cache=false`.
- **Adapt:** produce other Debezium rows to `p.public.<table>` and query the cache getters
  (`GetBillableMetric`, `SearchSubscriptions`, `HasPayInAdvanceCharge`).
- **Cost:** ~4-6 s. No CGO needed: `go list -deps ./cmd/cdc-brokers | grep -c lago-expression` -> `0`
  (run in `scripts/kfake-harness`; same for `./cmd/smoke`, `./kfx`, `./fixture`; `./pipeline` and `./cmd/happy-path` -> `1`).
- **Owner:** meaning `architecture-contract` WP10 (as-is), variable `config-and-flags`; production
  relevance = OPEN DECISION OD-1 (owner). Fixing it is unowned: OPEN DECISION OD-20 (owner), candidate
  future campaign.

## H3. Binary smoke (`smoke-binary.sh`)

- **Question:** what does the real binary, started like production (env vars, startup checks that are
  only partially fail-fast (`architecture-contract` I14), graceful SIGTERM), do with 9 typical and
  malformed events?
- **Run:** `$S/smoke-binary.sh [db|cache|cache-cdc|all] [--keep] [--no-expected] [--env K=V ...]`
- **What it does:** `source ep-env.sh`; `go build -o $tmp/events-processor .`; builds `cmd/smoke`;
  `scratch-pg.sh create scratch_smoke_<pid> fixtures/smoke-schema.sql`; starts kfake (TCP on 127.0.0.1)
  + miniredis inside the driver; runs the binary with the dev-like env (`ENV=development`, topics
  `events-raw`, `events_enriched`, `events_charged_in_advance`, `events_dead_letter`, group `smoke` ->
  `smoke_events-raw`); produces events A-I; waits for committed offset 9; reads every output topic and the
  ZSET; sends SIGTERM; compares the result block with `fixtures/smoke-expected-<mode>.txt`; drops the DB.
- **Expected today (`db`):**
  ```
  tx_A enriched=yes value="1e-07" subscription_id="bbbbbbbb-0000-0000-0000-000000000001" in_advance=yes
  tx_B enriched=no in_advance=no dlq=fetch_billable_metric(record not found)
  tx_C enriched=no in_advance=no dlq=build_enriched_event(strconv.ParseFloat: parsing "2025-03-06 12:00:00": invalid syntax)
  tx_D on-no-output-topic
  tx_E enriched=no in_advance=no dlq=evaluate_expression(failed to evaluate expr: event.properties.a * 2 with json: {...})
  tx_F enriched=yes value="1" subscription_id="" in_advance=no
  tx_G enriched=yes value="5" subscription_id="bbbbbbbb-0000-0000-0000-000000000001" in_advance=no
  tx_H enriched=yes value="1" subscription_id="bbbbbbbb-0000-0000-0000-000000000001" in_advance=no
  tx_I enriched=yes value="4" subscription_id="bbbbbbbb-0000-0000-0000-000000000001" in_advance=no
  raw_events=9 accounted=8 on_no_output_topic=1
  committed_offset=9
  zset_members=1
  exit_after_sigterm=<nil>
  consumer_groups: smoke_events-raw + 0 lago_evp_<model>_<uuid>
  == log summary (level counts; see debugging-playbook for triage)
  ERROR=4 INFO=43 panic_lines=0          # INFO count varies by +-1 run to run; not compared
  == EXPECTED-TODAY: MATCH (<repo>/.claude/skills/diagnostics-and-tooling/scripts/fixtures/smoke-expected-db.txt)
  ```
  `cache` differs from `db` in exactly three lines: `tx_B ... dlq=fetch_billable_metric(Key not found)`,
  `tx_H ... subscription_id="" ...` (subscription NOT matched), `consumer_groups: ... + 6 lago_evp_<model>_<uuid>`.
  `cache-cdc` differs from `cache` in one line: `tx_A ... in_advance=no`.
  Script exit 0 = all modes MATCH; 3 = a mode DIFFERS (diff printed as `- expected` / `+ observed`).
- **Adapt:** edit the `cases()` list in `kfake-harness/cmd/smoke/main.go` (one line per event) and the
  expected files; run the driver directly against a kept binary:
  `$S/kfake-run.sh smoke -bin <path> -mode db -db-url <url> -log <file> [-expected <file>] [-env K=V]`.
- **New or changed variable (end to end, no daemon):** `--env K=V` (repeatable; appended after the fixed
  environment, so it also overrides; `K=` sets it empty). VERIFIED 2026-10-01:
  `$S/smoke-binary.sh db --env LAGO_USE_MEMORY_CACHE=1` -> `EXPECTED-TODAY: MATCH` (db: only the string
  `true` turns cache mode on); `$S/smoke-binary.sh db --no-expected --keep --env LAGO_KAFKA_ENRICHED_EVENTS_TOPIC=`
  -> 9 x `on-no-output-topic`, `exit_before_sigterm=exit status 2`, `ERROR=1 panic_lines=1`, log
  `panic: LAGO_KAFKA_ENRICHED_EVENTS_TOPIC variable is required` (the driver stops waiting as soon as the
  binary exits). Variable meaning and the add-a-variable checklist: `config-and-flags`.
- **Cost:** ~7-8 s for `all` warm (binary build ~6 s); `go build` of the binary with an empty Go build
  cache: allow 1-2 min (135 s measured on a shared sandbox, 2026-10-01).
- **Owner:** `architecture-contract` (dispositions, DLQ codes), `rails-go-parity` (`1e-07`, tx_H),
  `event-accounting-campaign` (tx_D silent drop), `debugging-playbook` (log triage). Memory-cache rows:
  OPEN DECISION OD-1 (owner). The cache-cdc row is hand-shaped from `extra/debezium_config.json:2`
  `column.include.list` (no real Debezium connector was run).

## H4. `go test -overlay` (`overlay-run.sh`)

- **Question:** "what would this test/probe say if file X were different?" without touching the repo
  (change-control N10).
- **Run (add a white-box probe file):**
  ```bash
  $S/overlay-run.sh --no-cgo config/kafka/zz_commit_prefix_test.go=$S/overlay-examples/commit_prefix_test.go \
      -- -count=1 -v -run TestOverlayDemo ./config/kafka/
  ```
  Expected today (~3 s):
  ```
  overlay-run: overlay map (build view only):
    config/kafka/zz_commit_prefix_test.go <- /tmp/overlay-run.XXXXXX/000-commit_prefix_test.go
  === RUN   TestOverlayDemo_CommitPrefixTable
      zz_commit_prefix_test.go:53: offset 2 not returned (retryable failure)  -> commit offset 2 (next fetch after restart starts at 2)
      zz_commit_prefix_test.go:55: offset 0 not returned                      -> no commit for this batch
      zz_commit_prefix_test.go:53: offsets 3 and 1 not returned               -> commit offset 1 (next fetch after restart starts at 1)
  --- PASS: TestOverlayDemo_CommitPrefixTable (0.00s)
  ok  	github.com/getlago/lago/events-processor/config/kafka	0.013s
  ```
- **Replace an existing file:** copy it to `$TMPDIR`, edit, map it. VERIFIED: a copy of
  `config/kafka/consumer_test.go` with the test renamed -> `--- PASS: TestFindMaxCommitableRecordOverlaid`.
- **Delete a file from the build view:** `<target>=` (empty source). VERIFIED:
  `processors/events_processor/subscription_refresh_service_test.go=` -> 7 top-level `--- PASS` instead of 8.
- **Limits:** compile-time only (a test reading files from disk sees the real disk); an overlaid file
  cannot import a module events-processor does not require (VERIFIED: `no required module provides
  package github.com/twmb/franz-go/pkg/kfake`, `[setup failed]`, exit 1; use H11 or a separate module);
  targets must be inside `events-processor/`; needs `jq`. `go test` runs in `events-processor/`, so pass
  absolute output paths (`-coverprofile="$T/c.out"`): the script compares
  `git status --porcelain --ignored -- events-processor` before/after and exits 4, printing the new
  paths, if anything appeared (a relative `-coverprofile` would; not exercised, as it writes into the repo).
- **Policy uses:** strict sqlmock (`ExpectationsWereMet`) overlay lives in `validation-and-qa`.

## H5. Throwaway Postgres (`scratch-pg.sh`)

- **Question:** "what does this SQL / this DB-mode code path do against a real Postgres?"
- **Run:**
  ```bash
  URL=$($S/scratch-pg.sh create probe_x $S/fixtures/smoke-schema.sql)   # prints postgres://lago:lago@localhost:5432/probe_x
  psql "$URL" -XAtc "select code from billable_metrics order by 1"      # api_calls / count_calls / expr_metric
  $S/scratch-pg.sh list                                                 # probe_x
  $S/scratch-pg.sh drop probe_x                                         # scratch-pg: dropped probe_x
  ```
- **Safety (VERIFIED):** `drop lago` -> `refusing reserved database 'lago'` exit 3; `drop Bad-Name` ->
  `invalid name` exit 3; a database created by hand -> `exists but is not tagged 'lago-skills scratch';
  not dropping it` exit 3; dropping a missing DB is a no-op exit 0; `create` twice recreates (idempotent).
- **Real lago-api schema** (pinned SHA, 143 public tables; `pg_partman` is not installed in the sandbox):
  ```bash
  API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)
  URL=$($S/scratch-pg.sh create --lenient probe_real "$API/db/structure.sql")
  # scratch-pg: loaded .../db/structure.sql (lenient: 1 SQL error(s) skipped)     (~3 s)
  psql "$URL" -XAt -c "EXPLAIN SELECT id FROM charges WHERE organization_id = gen_random_uuid() AND plan_id = gen_random_uuid() AND billable_metric_id = gen_random_uuid() AND pay_in_advance IS TRUE AND deleted_at IS NULL LIMIT 1" | head -2
  # Limit  (cost=0.12..8.15 rows=1 width=16)
  #   ->  Index Scan using index_charges_on_plan_id_and_billable_metric_id_and_prorated on charges ...
  $S/scratch-pg.sh drop probe_real
  ```
  Use it to check that events-processor SQL still matches lago-api columns (shape check on an empty
  table, not a performance claim). The minimal `smoke-schema.sql` is NOT the real schema.
- **Requires:** `psql`, Postgres reachable via `$DATABASE_URL` (default `postgres://lago:lago@localhost:5432/lago`)
  with CREATEDB; `DROP ... WITH (FORCE)` needs Postgres >= 13 (sandbox: 16). Sandbox restart: see `build-and-env`.
- **Cost:** < 1 s with the fixture; ~3 s with the real schema.

## H6. ClickHouse function semantics (`ch-local.sh`)

- **Question:** "what does ClickHouse do with the string events-processor produced?" (e.g. the
  `events_enriched.decimal_value` column DEFAULT `toDecimal128OrZero(value, 26)`,
  `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32`).
- **Run:**
  ```bash
  $S/ch-local.sh "SELECT toDecimal128OrZero('1e+06', 26)"        # 1000000
  $S/ch-local.sh "SELECT version(), toDecimal128OrZero('1e+06', 26), toDecimal128OrZero('<nil>', 26),
     toDecimal128OrZero('999999999999', 26), toDecimal128OrZero('1000000000000', 26),
     toDecimal128OrZero('1e-07', 26) FORMAT Vertical"
  # version(): 26.2.19.43 | 1000000 | 0 | 999999999999 | 0 | 0.0000001
  printf "SELECT 1;\nSELECT toDateTime64('1727787600.123', 3, 'UTC');\n" | $S/ch-local.sh -
  # 1
  # 2024-10-01 13:00:00.123
  $S/ch-local.sh --version    # 26.2.19.43 ; $S/ch-local.sh --path -> <cache>/clickhouse/<version>/clickhouse
  ```
  A SQL error returns ClickHouse's code (e.g. `SELEC 1` -> `Code: 62 ... SYNTAX_ERROR`, exit 62).
- **Shared layout (owned here):** `$LAGO_SKILLS_CACHE/clickhouse/<version>/clickhouse`. Other skills obtain
  the binary with `"$($S/ch-local.sh --path)"` and never hardcode a versioned path (`rails-go-parity`'s
  `ch-decimal-probe.sh` also reuses a legacy `clickhouse-<version>/clickhouse` if one exists).
- **stdin:** query mode runs `clickhouse local --query` with `</dev/null`, so an inherited open stdin pipe
  cannot stall it; `-` mode reads the SQL from stdin and needs EOF (close the pipe). When calling the
  binary directly, do the same (`</dev/null` or `--queries-file`).
- **Version:** `CH_VERSION=<x.y.z.w>` if set; else the newest patch of 26.2 already in the cache (no
  network); else, or with `--refresh`, the newest `v26.2.*-stable` tag on GitHub (26.2.19.43 on 2026-10-01).
  The minor comes from the floating `clickhouse/clickhouse-server:26.2-alpine` in `docker-compose.dev.yml:460`.
  Production's version is unknown: results say what THIS version does.
- **Cost:** first run downloads ~211 MB from GitHub release assets (13-16 s here), sha512-verified, 724 MB
  on disk under `$LAGO_SKILLS_CACHE/clickhouse/`; then ~0.2 s per query. `packages.clickhouse.com` was
  blocked by the sandbox egress proxy (403); if GitHub is blocked too, the script exits 2: report
  "ClickHouse semantics UNVERIFIED", do not guess.
- **Owner:** `rails-go-parity` (value/decimal semantics), OPEN DECISION OD-3 (owner) for any schema change.

## H7. docker compose without a daemon

- **Question:** "does this compose file parse, and what does it resolve to?" (no `up`/`exec`/`ps`:
  those need the daemon and fail with `failed to connect to the docker API at unix:///var/run/docker.sock`).
- **Run:**
  ```bash
  docker compose -f docker-compose.dev.yml config --quiet && echo valid           # valid (0.13 s)
  docker compose -f docker-compose.dev.yml config --profiles                       # mailpit / redis-sentinel
  docker compose -f docker-compose.dev.yml config --services | wc -l               # 25
  docker compose -f docker-compose.dev.yml config --format json \
    | jq '.services["events-processor"].environment | {LAGO_KAFKA_RAW_EVENTS_TOPIC, LAGO_KAFKA_CONSUMER_GROUP}'
  # {"LAGO_KAFKA_RAW_EVENTS_TOPIC": "events-raw", "LAGO_KAFKA_CONSUMER_GROUP": "lago_dev"}
  ```
  `docker-compose.yml` also validates but warns about unset variables (e.g. `LAGO_DISABLE_SEGMENT`).
- **Never** print whole resolved environments: they contain key/licence-shaped values (change-control N11).
- **Owner:** `run-and-operate` (compose matrix across all files, bring-up), `config-and-flags` (variables).

## H8. Race detector on the REAL pipeline

- **Question:** "is the consumer + processor path race-free under concurrency?" The unit suite's
  `-race` run never executes `processRecordsAndCommit` (0% coverage), so it cannot answer this.
- **Run:** `GOFLAGS=-race $S/kfake-run.sh happy-path -n 5000 -partitions 4` (same for `-store db`, `cdc-brokers`).
- **Expected today:** `RESULT: PASS`, exit 0 and no `WARNING: DATA RACE` (re-verified 2026-10-01: 2 runs x
  5000 records x 4 partitions, DB mode 3000 x 3, cdc-brokers). ~5-8 s warm; the first `-race` build
  recompiles every package with instrumentation (minutes on a cold cache).
- **Trap (VERIFIED):** a harness that skips `tracing.InitTracer` reports `Found 1 data race(s)` in
  `events-processor/config/tracing/tracer.go:76-77` (`GetTracer` lazy init); the program exits 66
  (`kfake-run.sh` passes 66 through; a bare `go run` prints `exit status 66` and itself exits 1).
  Production calls `InitTracer` first (`events-processor/main.go:45-50`), so that report is a harness artifact.
- **Policy** (when `-race` is required, CI gaps): `validation-and-qa`.

## H9. CPU profiles

- Real pipeline: `T=$(mktemp -d); $S/kfake-run.sh happy-path -n 50000 -partitions 4 -cpuprofile $T/cpu.out;
  go tool pprof -top -nodecount=12 $T/cpu.out; rm -rf $T` -> `elapsed:` ~2.9-3.5 s, top nodes are syscalls,
  memmove, `encoding/json.checkValid` (kfake and miniredis share the process; compare runs, not absolutes).
- Unit test: `T=$(mktemp -d); (source .claude/skills/build-and-env/scripts/ep-env.sh; cd events-processor &&
  go test -count=1 -run TestProcessEvent -cpuprofile $T/cpu.out -o $T/ep.test ./processors/events_processor/ &&
  go tool pprof -top -nodecount=8 $T/ep.test $T/cpu.out)`.
- **Trap (VERIFIED):** without `-o`, `go test -cpuprofile` writes `events_processor.test` into
  `events-processor/`, and `git status` does NOT show it because `events-processor/.gitignore:12` ignores
  `*.test` (likewise `:15` `*.out`, `:24` the `events-processor` binary from a bare `go build`).
  Check with `git status --porcelain --ignored -- events-processor` (expect no output).
- No `Benchmark*` functions exist in events-processor: `grep -rn 'func Benchmark' events-processor | wc -l` -> `0` (2026-10-01).

## H10. Log triage one-liners (events-processor JSON logs)

On a smoke log (`$S/smoke-binary.sh db --keep` prints `smoke-binary: kept <dir>` on stderr):
```bash
L=<kept dir>/smoke-db.log
jq -r '.level' "$L" | sort | uniq -c                                   # 4 ERROR / 42-43 INFO
jq -r 'select(.level=="ERROR") | [.error_code // "-", .msg[0:60]] | @tsv' "$L" | sort | uniq -c
#  1 -                       Error unmarshalling message
#  1 build_enriched_event    Error while converting event to enriched event
#  1 evaluate_expression     Error evaluating custom expression
#  1 fetch_billable_metric   Error fetching billable metric
jq -r 'select(.msg|test("Starting event consumer|Received shutdown|Gracefully shutting|Event processor stopped|leaving group")) | .msg' "$L"
# Starting event consumer / Received shutdown signal / Gracefully shutting down consumer group / leaving group / Event processor stopped
grep -vc '^{' "$L"                                                     # 0 non-JSON lines (a panic would add some)
```
Mapping messages to causes and fixes: `debugging-playbook` (owns `triage-ep-log.sh` and the symptom
tables); DLQ error_code -> cause -> retryable: `architecture-contract` section 9.

## H11. Scratch copy (when an overlay is not enough)

When the experiment must change `go.mod` (dependency bump) or many files:
```bash
C=$(mktemp -d); cp -r events-processor "$C/ep"; (source .claude/skills/build-and-env/scripts/ep-env.sh; cd "$C/ep" && go test -count=1 ./utils/ ./processors/events_processor/)
# ok ... utils / ok ... processors/events_processor   (~5 s)
rm -rf "$C"
```
Edit freely inside `$C/ep`; the repo stays untouched (change-control N10). For new dependencies that only
probes need, prefer a separate module with a `replace` (like `kfake-harness`).
