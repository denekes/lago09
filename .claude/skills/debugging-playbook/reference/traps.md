# Traps that cost real time: story, tell-tale sign, shortcut

Read when a symptom smells familiar, or before you sink an hour into one of these areas. Each trap
is something that already cost this project days to months. Durations are computed from commit dates
in the full-history clone (`H=$(.claude/skills/research-methodology/scripts/history-setup.sh)`;
`git -C "$H" log -1 --format='%h %ad %s' --date=short <sha>`). The full narrative of each chain
(why each fix was chosen, what was rejected) is in `failure-archaeology`; this file is the debugging
view: how to recognise the trap fast and what to do instead.

Format per trap: **Story** (what happened, how long, commits) / **Tell-tale** (what you see) /
**Shortcut** (what to do first) / **Rule** (the doctrine that came out of it).

## T1. A retryable failure is silently skipped (Kafka commit path)

- **Story.** `cec0eb2` (#502, 2025-03-31) replaced the origin design (`4100da0`: commit every batch)
  with "do not commit retryable failures", plus a stray `return` that could end a partition goroutine;
  `656c829` (#511) counted unparseable records as processed (committed, Sentry only); `600e195` (#628)
  turned the `return` into a skipped commit and introduced an infinite poll loop, hotfixed 3 days later
  by `b604769` (#629); `b6d3616` (#608) removed the `return`, which exposed `CommitRecords([nil])`;
  `9acd83e` (#735, 2026-05-06, ING-15) fixed "segfaulting the pod inside franz-go". 401 days, 6 commits,
  a production segfault (full chain: `failure-archaeology` chain A).
  The residual is still live: the commit takes the longest processed prefix, so a LATER batch on the
  same partition commits past a failed offset (`config/kafka/consumer.go:89-104`). Re-measured
  2026-10-01 with the real binary: offset 0 failed retryably, offset 2 committed, group offset 3,
  offset 0 never redelivered and never on the DLQ (`events-processor.md` E4.1).
- **Tell-tale.** ERROR lines with `fetch_subscription`, `fetch_pay_in_advance_charge`,
  `flag_subscription_refresh` or `fetch_billable_metric` + a DB error; WARN
  `No commitable record in batch, skipping commit`; counts in ClickHouse `events_raw` above
  `events_enriched` + `events_dead_letter` for the window.
- **Shortcut.** `triage-ep-log.sh` prints the retryable count; the `events_raw` NOT IN query
  (`events-processor.md` E4.1) lists candidate transaction_ids. Restore the failing dependency first.
- **Rule.** change-control N7: no commit/delivery change without a `processRecordsAndCommit` test,
  conformance to ADR-001 (the delivery contract, DECIDED OD-2 (owner, 2026-10-02)) and owner sign-off.
  The fix is `event-accounting-campaign` W1.

## T2. SQLSTATE 0A000 after every Rails column add

- **Story.** `bd92069` (#634, 2025-11-18) dropped a join and gorm started emitting `SELECT *` for
  subscriptions; every lago-api migration that added a column then broke cached plans with
  `cached plan must not change result type (SQLSTATE 0A000)` until `9acd83e` (2026-05-06): 169 days.
  The same bug hit the `flat_filters` view (`3ac94a2`, #741, ING-143). `FetchBillableMetric` still uses
  gorm `First` = `SELECT *` (`models/billable_metrics.go:59-66`; the test pins `SELECT \*`).
  Re-measured 2026-10-01: pool size 1, `ALTER TABLE billable_metrics ADD COLUMN zz_new int` mid-run ->
  one `fetch_billable_metric` 0A000 failure, the next event healed (pgx re-prepares), and the failed
  offset was committed past (T1): LOST.
- **Tell-tale.** A burst of `fetch_billable_metric` errors right after an API deploy with migrations;
  the `component=db` line shows `"query":"SELECT * FROM \"billable_metrics\" ..."`. At most one failure
  per pooled connection (default pool 200).
- **Shortcut.** Correlate with the lago-api migration time. It heals by itself; the damage is the
  skipped offsets (T1), so run the E4.1 query for that window.
- **Rule.** change-control N4: explicit column lists, pinned SQL in the sqlmock test.

## T3. `context canceled` on every rolling restart

- **Story.** `b6d3616` (#608, 2025-11-25) introduced a cancelable process context that the Redis stores
  captured; every in-flight ZADD failed on SIGTERM until `02a4bc8` (#785, 2026-08-27): 275 days.
- **Tell-tale.** `flag_subscription_refresh` ERROR lines with `"error":"context canceled"` clustered at
  `Received shutdown signal`. Do NOT confuse with the benign franz-go INFO `heartbeat errored ...
  context canceled` and cache INFO `Context canceled during fetch`, which every clean shutdown prints.
- **Shortcut.** `explain-error.sh` separates them (`dlq-flag-ctx-canceled` vs `run-shutdown-ctx`).
- **Rule.** change-control N5: per-record side effects (Redis, produce) use the batch context that
  `processRecordsAndCommit` creates (`context.Background()`, `config/kafka/consumer.go:83`) and passes to
  every record, never the process/signal context that SIGTERM cancels.

## T4. "Everything DLQs as fetch_billable_metric" (empty memory cache)

- **Story.** Memory-cache mode (`fff5858`, #639, 2026-04-27) loads 6 tables at startup; a failing snapshot
  query is returned but never logged or acted on (`cache/cache.go:78-106`, `:240-243`), so the process
  serves an empty cache. Reproduced 2026-10-01: `DATABASE_URL` pointing at a database without the
  lago-api schema -> 6 `SQLSTATE 42P01` lines, no `Completed snapshot load`, 8 of 9 events DLQ'd as
  `fetch_billable_metric` `Key not found`, offsets committed 9/9, process healthy-looking.
- **Tell-tale.** `Key not found` for EVERY metric code; DLQ volume equals input volume.
- **Shortcut.** `triage-ep-log.sh` on the log FROM PROCESS START prints `snapshot loads: started 6,
  completed 0` and a WARNING (or `WARNING: snapshot loaded 0 billable_metrics` when the pod read the wrong
  database). Fix `DATABASE_URL` and restart (the snapshot runs only at startup). Events already DLQ'd as
  `Key not found` stay there: no DLQ replay tool exists today (`run-and-operate` section 5.4); ADR-001
  (DECIDED OD-2) plans an operator-gated one, and until then a manual re-feed is CANDIDATE and needs owner
  sign-off. Count them with the E3 query (`events-processor.md`) or the burst query in `run-and-operate`
  `reference/memory-cache-ops.md` §1, and escalate (SKILL.md section 9).
- **Rule.** Production runs cache mode (DECIDED OD-1 (owner, 2026-10-02)), so this is a production
  outage mode, silent today. Hardening is `event-accounting-campaign` W6 (DEFAULT APPLIED OD-20); the as-is
  defects are `architecture-contract` WP6-WP10. Not a debugging-session fix.

## T5. Comma-separated brokers: the CDC consumers are silently dead

- **Story.** `09a5cc7` (#612, 2025-10-28) taught the MAIN consumer to split
  `LAGO_KAFKA_BOOTSTRAP_SERVERS`; the memory-cache CDC consumers added six months later (`fff5858`)
  pass the raw string as one seed with no logger (`cache/consumer.go:28-35`). `events-processor/README.md:40`
  even shows a comma list as the example. Open for 157 days as of 2026-10-01.
- **Tell-tale.** Nothing. The CDC loops log no error; edits made in the app never reach the cache;
  DEBUG `Cache updated from stream` never appears. Verified 2026-10-01: comma list -> 6 CDC consumers
  "Starting consumer", zero WARN/ERROR lines.
- **Shortcut.** `printenv LAGO_KAFKA_BOOTSTRAP_SERVERS` contains a comma + cache mode on = this trap.
  Measure with `diagnostics-and-tooling` (`cdc-brokers` scenario: visible=false).
- **Rule.** Production runs cache mode (DECIDED OD-1); whether production passes a broker list or needs
  SASL/TLS is OPEN DECISION OD-1b (owner). Hardening: `event-accounting-campaign` W6 (DEFAULT APPLIED OD-20).

## T6. Pay-in-advance silently stops after a charge edit (memory-cache mode)

- **Story.** `extra/debezium_config.json:2` (unchanged since `fff5858`) omits `charges.pay_in_advance`,
  `charges.accepts_target_wallet` and `billable_metrics.recurring` (`recurring` was added to the Go model
  later, `b4ad153`, 2026-07-27). CDC upserts replace the whole cached row, so the flag reads false.
- **Tell-tale.** `events_charged_in_advance` drops to zero for a plan right after someone edits a
  charge, while `events_enriched` keeps flowing; no error anywhere; the volume comes back after the next
  deploy or restart (the snapshot re-reads full rows; INFERRED from `cache/consumer.go:143-156`) and drops
  again at the next edit. Binary smoke `cache-cdc` row A shows `in_advance=no` (re-run 2026-10-02).
- **Shortcut.** Print the column list (`events-processor.md` E6) and get the production connector's list
  (`run-and-operate` `reference/memory-cache-ops.md` §0). Production runs cache mode (DECIDED OD-1);
  whether its connector uses this file is OPEN DECISION OD-1b (owner), the first thing to verify.
- **Rule.** Fix: `event-accounting-campaign` W6 (DEFAULT APPLIED OD-20); cross-repo fields follow
  change-control N6 (the Debezium config lives outside this repo: contract K9).

## T7. Connector events vanish: numeric `precise_total_amount_cents`

- **Story.** The connectors (`190aa81`, #596, 2025-09-18) pass a numeric `precise_total_amount_cents`
  through (`connectors/http.yml:32-36`, `kinesis.yml:38-39`, `sqs.yml:34-35`), their README uses a
  number (`connectors/README.md:20`), and EP declares the field `string` (`models/event.go:18`). Every such
  event fails `json.Unmarshal`, is committed and never DLQ'd. Open 378 days as of 2026-10-01. Evidence:
  the EP half is VERIFIED (probe: `json.Unmarshal` into `models.Event`); the connector half is code-read,
  not runnable here (the connector image is Docker-only; only `connectors/sqs.yml` has a `tests:` block).
- **Tell-tale.** `Error unmarshalling message` with `json: cannot unmarshal number into Go struct field
  Event.precise_total_amount_cents of type string`. Sentry has the error; the payload is still in
  ClickHouse `events_raw` (its own Kafka engine parses the number into `Decimal(40,15)`; VERIFIED with
  `clickhouse local` JSONEachRow on the same column types, production ClickHouse UNVERIFIED), but connectors
  send `ingested_at` as integer seconds, which ClickHouse reads as ms (1970-01-2x): only the
  connector-aware query in `events-processor.md` E4.1 finds these rows.
- **Shortcut.** `explain-error.sh` -> `loss-ptac-number`. Direct producers can send it as a string. Through
  the connectors there is no value-preserving workaround: they map every non-number (a string, or the
  field absent) to `"0"` (`connectors/http.yml:32-37`, `kinesis.yml:38-43`, `sqs.yml:34-39`), so the event
  survives with a zero amount, and a number drops the event.
- **Rule.** The fix is `event-accounting-campaign` (W2) with `rails-go-parity`; cross-repo payload
  rules: change-control N6.

## T8. `"1e+06"`, `"<nil>"`, and sums that become 0

- **Story.** Since the first commit (`4100da0`, 2025-03-11) `value = fmt.Sprintf("%v", ...)` on a
  float64 (`enrichment_service.go:114`). ClickHouse parses `"1e+06"` fine (1000000), but
  `toDecimal128OrZero(value, 26)` into `Decimal(38,26)` zeroes `"<nil>"`, any |x| >= 1e12 (negatives
  too) and any non-numeric `%v` string (`true`, `map[x:1]`); unique_count compares raw strings.
  Re-measured 2026-10-01 with `clickhouse local` 26.2.19.43 (`diagnostics-and-tooling` `ch-local.sh`).
  A Go-only formatting fix does not cure |x| >= 1e12: the column holds 12 integer digits.
- **Tell-tale.** A customer's sum is 0 or far too low for large quantities; unique_count higher than
  the number of distinct business values.
- **Shortcut.** The `events_enriched` string query in `events-processor.md` E5.
- **Rule.** A ClickHouse schema change is allowed (DECIDED OD-3 (owner, 2026-10-02)); its DDL lives in
  lago-api, so it ships as a paired lago-api PR with a deploy order (DECIDED OD-4). Value fidelity is
  `event-accounting-campaign` W2; the contract table is `rails-go-parity`.

## T9. "Direct go build / go test won't work" (it does)

- **Story.** `events-processor/CLAUDE.md:10` (added `c340ddf`, #711, 2026-03-05) says to always use
  `lago exec`; `README.md:13-15` shows a `go build` that fails to link. Agents without Docker stop
  there. The truth: link needs `CGO_LDFLAGS`, the loader needs `LD_LIBRARY_PATH`, coverage over `./...`
  needs a workaround; five of six tested packages need no CGO at all.
- **Tell-tale.** `cannot find -lexpression_go`, `libexpression_go.so: cannot open shared object file`,
  `go: no such tool "covdata"`.
- **Shortcut.** `.claude/skills/build-and-env/scripts/ep-test.sh` (same shape as CI, not identical: CI uses a PG 14 service and builds the whole lago-expression workspace). An accepted
  pre-PR gate: DECIDED OD-5 (owner, 2026-10-02); `lago exec` stays valid for dev-stack users.
- **Rule.** change-control N9 (pre-PR gate) and change-control N3 (do not "fix" `go.mod`'s expression-go v0.1.4).

## T10. `TestNewConnection` nil-pointer panic hides "Postgres is down"

- **Story.** The sandbox Postgres does not survive container restarts; the test asserts `NoError` and
  then dereferences `db.Connection` (`config/database/database_test.go:21-25`), so the first thing you
  see is a SIGSEGV stack.
- **Tell-tale.** `panic: runtime error: invalid memory address or nil pointer dereference` with frame
  `database_test.go:24`.
- **Shortcut.** Scroll UP: the real line is `dial tcp ...: connect: connection refused` (or `password
  authentication failed`). `pg_isready -d "$DATABASE_URL"`; `pg_ctlcluster 16 main start` (owner row:
  `build-and-env` B6; the test's nil dereference itself is harness defect `validation-and-qa` HD5).

## T11. A single subtest fails, the whole test passes

- **Story.** `TestEvaluateExpression` subtests share and mutate `bm`/`event`/`result`
  (`enrichment_service_test.go:256-258`); narrowing `-run` to one subtest (the habit `$API/AGENTS.md:218`
  encourages: "Run as minimum number of tests as possible") fails with `expected: string("36") actual: <nil>`.
- **Shortcut.** Run the parent test. Two subtests fail alone: `With_an_expression_and_with_required_fields`
  and `With_a_float_timestamp` (owner: `validation-and-qa` HD3). Fixing the test is a change-class C1 change.

## T12. Traefik `ws` entrypoint, and the fix that moved the submodules

- **Story.** `4b4b35f` (2022-07-13) added `entrypoints=web,ws,websecure` to dev labels; `traefik/traefik.yml`
  never defined `ws` (unchanged since the scaffold), so Traefik logged
  `ERR EntryPoint doesn't exist entryPointName=ws` for 1210 days until `12b8101` (#618, 2025-11-04).
  That fix PR ALSO moved the `api`/`front` gitlinks by accident (`git commit -a` with drifted
  submodules); reverted by `647de3e` (#620) the same day.
- **Tell-tale.** `EntryPoint doesn't exist`; a `Subproject commit` line in a non-release diff.
- **Shortcut.** Only `web` and `websecure` exist. Before any commit run
  `.claude/skills/change-control/scripts/precommit-guard.sh` (expect `0 FAIL`). It checks
  `git diff --cached --submodule=short --ignore-submodules=none -- api front`; the plain
  `--submodule` form is blind when `diff.ignoreSubmodules` or `submodule.<name>.ignore` is `all`.
- **Rule.** change-control N1.

## T13. Dev compose startup races and init scripts that never ran

- **Story.** `lago up -d` (the docs' alias for `docker compose -f docker-compose.dev.yml up -d`)
  failed randomly (`RedisClient::CannotConnectError` in `migrate`, `unable to create topics ...
  connection refused`) until health conditions were added (`c80a7b5`, #580,
  2025-09-03); re-running topic creation failed until `scripts/create-topics.sh` made it idempotent
  (`5477e39`, #581). The `lago_test` database was never created for 774 days because of an init-script
  path typo (`2747b04` 2023-09-22 -> `e5392e9` #621 2025-11-04).
- **Tell-tale.** Failures that disappear on a second `up`; a database missing although a script
  "creates" it.
- **Shortcut.** `docker compose -f docker-compose.dev.yml config --format json | jq '.services.<svc>.depends_on'`
  (works without a daemon). Init scripts run only on an empty PGDATA; creating `lago_test` by hand
  beats `down -v` (which destroys every dev volume; `dev-ci-release.md` DEV13).
- **Rule.** change-control N12 (infra dependencies `service_healthy`, one-shot jobs
  `service_completed_successfully`); a dependency edge change is change class C6.

## T14. The all-in-one image breaks on release day

- **Story.** `docker/Dockerfile` is built only by `release-docker-image.yml` (on `release`), so drift
  surfaces when the release is cut: the v1.35.0 build failed in the `corepack prepare pnpm@latest` /
  `pnpm prune` step (`18b26d0`, #617; which pnpm ran is UNVERIFIED); Bundler 4
  removed `--without`, latent for 15 days, broke v1.45.0 (`558814a`, #722, v1.45.1 cut); Node and Ruby
  ARGs lagged api/front on the v1.53.0 bump, fixed 33 and 49 minutes later (`b267320`, `f719ef1`);
  Debian trixie roll after the Ruby 3.4.5 bump (`14fa1e0`, fixed `b6b98c8`, #592). `getlago/lago`
  v1.33.0-v1.33.2 and v1.48.0-v1.50.0 were never published on Docker Hub (as of 2026-10-01; list:
  `release-and-images`). In all, 10 `fix` commits touch `docker/` since 2025-05.
- **Tell-tale.** Red `Release Single Docker Image` run; strings in `dev-ci-release.md` RD1-RD4.
- **Shortcut.** Before tagging: compare `docker/Dockerfile:1-2` with `$API/.ruby-version` and front
  `engines.node`; dispatch the workflow (`workflow_dispatch`) on the release commit first
  (`release-and-images` owns the procedure). `pnpm@latest` is still at `docker/Dockerfile:12`; lago-front's
  `packageManager` pin makes it inert today, a conditional risk if front drops that pin.
- **Rule.** change-control N3 (no floating tools).

## T15. Dev email: Mailpit is up, delivery still fails (CANDIDATE, found 2026-10-01)

Doc correction: `docs-and-writing` SC-39.

- **Story.** `8f8334e` (#777, 2026-09-03) replaced the `mailhog` dev service with `mailpit` (behind a
  profile) and added a doc note that delivery raises while Mailpit is down. lago-api's development
  config still hard-codes `address: "mailhog", port: 1025` (`$API/config/environments/development.rb:70-73`,
  also on lago-api main `b5500bc` of 2026-10-01) and the `mailpit` service has no `mailhog` network alias.
- **Tell-tale.** Delivery errors from the API in dev even after
  `docker compose -f docker-compose.dev.yml up -d --wait mailpit` (the docs write `lago up ...`)
  (expected name-resolution error; runtime UNVERIFIED here, no daemon).
- **Shortcut.** `docker compose -f docker-compose.dev.yml --profile mailpit config --format json | jq
  '.services.mailpit.networks'` shows no alias. Route the fix (alias on the service, a change-class C6 change, or a
  lago-api change) to `run-and-operate`.

## T16. Deleted billable metrics still matched

- **Story.** `fff5858` swapped `gorm.DeletedAt` for `utils.NullTime`, silently dropping gorm's
  soft-delete scope; events were enriched against deleted metrics for 18 days until `8ceca4b` (#740,
  2026-05-15) added an explicit `deleted_at IS NULL` (`models/billable_metrics.go:63`).
- **Tell-tale.** Enriched events for a code whose metric was deleted in the app.
- **Shortcut.** Check the query string, not the struct tags: `grep -n 'deleted_at' events-processor/models/*.go`.
- **Rule.** change-control N4.
