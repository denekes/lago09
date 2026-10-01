# Known harness defects: verify, avoid copying, fix as C1

Read this when a test behaves strangely, before you copy an existing test as a starting point, or
when you plan a harness clean-up PR. Each defect was re-verified on 2026-10-01 at `5308258`. The
suite is still green: these are defects in what the tests prove, not failures.

Path convention: code cites are relative to `events-processor/`; bare `processor_test.go`,
`enrichment_service_test.go`, `event_producer_service_test.go`, `processor.go`,
`enrichment_service.go` and `event_producer_service.go` live in `processors/events_processor/`.

Fixing any of them is a C1 change (tests only) as long as no production `.go` file and no
existing expectation string changes. Keep each fix in its own commit; run `scripts/baseline.sh`
and `scripts/race-shuffle.sh --isolation` before and after.

## D1. sqlmock expectations are never verified

- **What.** `tests.SetupMockStore` returns a cleanup that only closes the mock DB
  (`events-processor/tests/mocked_store.go:38-40`). `grep -rn ExpectationsWereMet events-processor`
  prints nothing. A test can register a query that the code never runs and still pass.
- **Verify.** `.claude/skills/validation-and-qa/scripts/sqlmock-strict.sh` overlays a strict
  cleanup. Expected output (2026-10-01):

  ```
  KNOWN unmet processors/events_processor TestEnrichEvent/WithoutCache/When_timestamp_is_invalid  -> 'SELECT \* FROM "billable_metrics".*'
  KNOWN unmet processors/events_processor TestProcessEvent/When_event_source_is_not_post_process_on_API_when_expression_failed_to_evaluate#01  -> '.* FROM "subscriptions".*'
  KNOWN unmet processors/events_processor TestProcessEvent/When_event_source_is_not_post_process_on_API_when_timestamp_is_invalid#01  -> 'SELECT \* FROM "billable_metrics".*'
  KNOWN unmet processors/events_processor TestProcessEvent/When_event_source_is_post_processed_on_API#01  -> '.* FROM "charges".*'
  SUMMARY sqlmock-strict: 4 unmet-expectation subtests (4 known, 0 new), 0 other failures, 5 packages fully ok (go test exit 1)
  ```

  `models` stays clean. All 4 are DB mode (`#01` is DB mode because of D2).
- **Why each is unmet.**
  - Timestamp-invalid: `EnrichEvent` converts the timestamp first (`enrichment_service.go:28-31`)
    and fails before the billable-metric lookup.
  - Expression failure: the expression fails inside `enrichWithBillableMetric` (`:47-50`), before
    `fetchSubscription` (`:53`).
  - `api_post_processed`: the in-advance lookup only runs when `event.NotAPIPostProcessed()`
    (`processor.go:115`).
- **Avoid copying.** In a new DB-mode test, call `ExpectationsWereMet()` yourself (the templates'
  `assertQueriesConsumed` helper, or `require.NoError(t, mock.ExpectationsWereMet())` in `models`).
  Run `sqlmock-strict.sh`: it must report `0 new`.
- **Fix (C1).** Delete the 4 dead `Set*` calls, then add the check to the cleanup in
  `tests/mocked_store.go`. Afterwards `sqlmock-strict.sh --all` exits 0 and the known list in
  the script must be emptied in the same PR. Enforced sqlmock is a "beyond current best" target.

## D2. `TestProcessEvent` subtests are mis-nested; one scenario never runs in DB mode

- **What.** Inside the mode loop (`processor_test.go:183`), only "Without Billable Metric" is
  nested under `t.Run(mode.name)` (`:184-202`). The other six scenarios (`:204-473`) are siblings
  of the mode, so Go renames the second copy with `#01`. The scenario "no charge is charged in
  advance" calls `setupProcessorTestEnv(t, true)` (`:424`) instead of `mode.useCache`.
- **Verify.**

  ```bash
  .claude/skills/build-and-env/scripts/ep-test.sh -v -count=1 -run TestProcessEvent ./processors/events_processor/ 2>&1 | grep -- '--- PASS' | sed 's/ (.*//'
  # expect 17 lines: the parent, WithCache, WithoutCache, the two .../Without_Billable_Metric,
  # 6 scenario names directly under TestProcessEvent, and the same 6 with a #01 suffix
  ```

- **Consequence.** From `-v` output you cannot tell the mode; `#01` = DB mode by position only;
  the "no in-advance charge" scenario runs in cache mode twice and never against sqlmock.
- **Avoid copying.** Nest every scenario under `t.Run(mode.name, ...)` and pass `mode.useCache`
  (the enrichment template does).
- **Fix (C1).** Move the six `t.Run` blocks inside the mode `t.Run`, replace `true` at `:424`
  with `mode.useCache`, then run the DB-mode version and make it pass. Test names change
  (`#01` disappears), the PASS count stays 50 for the package if nothing else changes; check with
  `baseline.sh`.

## D3. `TestEvaluateExpression` subtests depend on run order

- **What.** `bm`, `event` and `result` are declared in the parent (`enrichment_service_test.go:256-258`).
  "With an expression but without required fields" sets `bm.Expression` and `bm.FieldName`
  (`:266-267`); "With an expression and with required fields" sets `event.Properties` (`:283`)
  and relies on the earlier `bm`; "With a float timestamp" relies on both.
- **Verify.**

  ```bash
  .claude/skills/build-and-env/scripts/ep-test.sh -count=1 -run 'TestEvaluateExpression/^With_an_expression_and_with_required_fields$' ./processors/events_processor/
  # FAIL: expected: string("36")  actual: <nil>(<nil>)
  .claude/skills/build-and-env/scripts/ep-test.sh -count=1 -run 'TestEvaluateExpression/^With_a_float_timestamp$' ./processors/events_processor/
  # FAIL: same message
  .claude/skills/validation-and-qa/scripts/race-shuffle.sh --no-race --no-shuffle --isolation
  # KNOWN isolation: ... With_a_float_timestamp / ... With_an_expression_and_with_required_fields
  # OK   isolation: 202 leaf tests run alone, 2 failed (2 known, 0 new)
  ```

  `-shuffle` does not catch this: it reorders top-level tests only.
- **Avoid copying.** Declare all inputs inside each subtest (or in a table row). Run your test
  with `race-shuffle.sh --isolation`.
- **Fix (C1).** Give each subtest its own `bm` and `event`. Then remove the two entries from
  `KNOWN_ISOLATION_FAILURES` in `scripts/race-shuffle.sh`.
- Related, safe today: `event_producer_service_test.go:16-21` and
  `subscription_refresh_service_test.go:13-16` use package-level variables that every top-level
  test re-initialises with `setup*()` first. Isolation passes for them.

## D4. Redundant `time.Sleep(50ms)` in `TestProcessEvent`

- **What.** `processor_test.go:255,416,470` sleep "to give some time to the go routine", with
  `// TODO: Improve this by using channels` at `:415,469`. `processEvent` already waits for its
  producer goroutines (`defer errgroup.Wait()`, `processor.go:101`), so the counters are final
  when it returns.
- **Verify** (read-only overlay that deletes the three sleeps):

  ```bash
  source .claude/skills/build-and-env/scripts/ep-env.sh && cd events-processor
  W=$(mktemp -d); sed '/time.Sleep(50 \* time.Millisecond)/d' processors/events_processor/processor_test.go > "$W/p_test.go"
  printf '{"Replace":{"%s":"%s"}}' "$PWD/processors/events_processor/processor_test.go" "$W/p_test.go" > "$W/o.json"
  go test -race -count=30 -overlay="$W/o.json" -run TestProcessEvent ./processors/events_processor/
  # ok ... (about 10 s): 30 race-checked runs without the sleeps
  ```

- **Avoid copying.** Never add a sleep to wait for `processEvent`. If you test code that really
  returns before its goroutines finish, use a channel or `assert.Eventually` with a short tick.
- **Fix (C1).** Delete the three sleeps and the two TODOs.

## D5. Smaller defects worth knowing

| Defect | Where | Effect | Avoid |
|---|---|---|---|
| `TestNewConnection` panics when Postgres is down | `config/database/database_test.go:21-24` (`assert.NoError` then `db.Connection` on nil) | SIGSEGV; the real cause (`dial tcp ... connection refused`) is printed ABOVE the stack | use `require.NoError`; start Postgres (`build-and-env`) |
| 1.5 s real sleep for a TTL | `cache/cache_test.go:362` | ~half of the cache package time; x10 under `-count=10` | tiny TTLs |
| wall-clock bucket race (never observed) | `models/stores_test.go:59-87` recompute `time.Now()` after the call | could flake at an x9.999 s boundary | the redis-store template's before/after pattern |
| tautological test | `models/stores_test.go:102-120` inserts the second member by hand and counts 2 | proves nothing about bucketing | assert on code output |
| marshal-vs-marshal | `event_producer_service_test.go:54-55,77-78` | field names of `events_enriched` are not pinned | literal JSON |
| no-assertion test | `TestCache_ConcurrentAccess` `cache/cache_test.go:276-307` | coverage without checks | at least one assertion |
| unused fixtures | `MockDataStore.ExpectSubscriptionError` (`processor_test.go:115-117`) is never called; `tests.MockCacheStore` and `ProcessorTestEnv.CacheStore` (`processor_test.go:127,140,168`) are dead since `2fd8e8b` | dead weight, misleading | do not build on them |
| producer fake cannot fail | `tests/mocked_producer.go:20` | produce-failure -> DLQ branches untested | add a failure switch when you need it |
| reversed `assert.Equal` arguments | `utils/result_test.go:38` and neighbours | confusing failure diffs | `(t, expected, actual)` |

## D6. What the harness cannot show at all

Unit tests with these fakes cannot show rebalances, commit ordering, redelivery or anything that
needs a broker. `ProcessEvents` and `processRecordsAndCommit` have 0% coverage. Those need the
kfake harness (`diagnostics-and-tooling`) and, for the delivery contract, the
`event-accounting-campaign` ledger. Do not try to fake Kafka inside the existing unit tests.
