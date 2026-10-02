# How the events-processor suite is written, and how to add a test

Read this before you write or review a test in `events-processor/`. Each convention cites where it
is practised; each template in `templates/` is compiled and run against HEAD by
`scripts/templates-check.sh` (verified 2026-10-01: all 5 files pass, also with `-race`, and add
0 gofmt, 0 vet and 0 golangci-lint issues).

Path convention: code cites are relative to `events-processor/`; bare `processor_test.go`,
`enrichment_service_test.go`, `event_producer_service_test.go`, `processor.go`,
`enrichment_service.go` and `event_producer_service.go` live in `processors/events_processor/`.

## 1. Conventions as practised (as of 2026-10-01)

| # | Convention | Evidence | Rule for new tests |
|---|---|---|---|
| 1 | testify only: 385 `assert.*`, 70 `require.*` calls; most used `assert.Equal` (164), `assert.True` (88), `require.True` (43) | `grep -rhoE '\b(assert\|require)\.[A-Za-z]+' --include='*_test.go' events-processor \| sort \| uniq -c \| sort -rn` | `require` for preconditions whose failure makes the rest meaningless (setup writes, `result.Success()` before `.Value()`), `assert` for outcomes. The `cache/*` tests do this (`cache/consumer_test.go:24-35`) |
| 2 | white-box: every test file is in the package it tests (0 `package xxx_test`) | `grep -rl '^package .*_test$' --include='*_test.go' events-processor` prints nothing | calling unexported functions (`processEvent`, `searchJSON`, `processRecord`, `findMaxCommitableRecord`) is normal here |
| 3 | names: `TestFunc` or `TestFunc_Scenario`; subtests are sentences | `models/billable_metrics_test.go:23` "should return billable metric when found"; `processor_test.go:204` "When event source is ..." | name the behaviour, not the implementation |
| 4 | fixture org id `1a901a90-1a90-1a90-1a90-1a901a901a90` | `processor_test.go:192` and most files | reuse it; it makes grep across tests easy |
| 5 | table-driven where cases share a shape | `utils/string_test.go:11-60`, `config/kafka/consumer_test.go:20-123` (both with `t.Run` per case) | always `t.Run(tc.name, ...)` inside the loop. Some older loops have no `t.Run`, so a failure does not name the case (`models/billable_metrics_test.go:157-160`, `utils/result_test.go:36-62`, `utils/time_test.go:48-52`) |
| 6 | dual-mode `DataStore`: the same scenario runs against a real in-memory badger (`CacheDataStore`) and sqlmock (`MockDataStore`) | interface `processor_test.go:46-54`; impls `:56-121`; loops `enrichment_service_test.go:54-60`, `:299-305`, `processor_test.go:175-181` | the parity mechanism between `LAGO_USE_MEMORY_CACHE=true` and DB mode. Nest every scenario under `t.Run(mode.name)` |
| 7 | sqlmock behind gorm through the production `database.OpenConnection` | `tests/mocked_store.go:17-41` | use `tests.SetupMockStore(t)` (or `setupApiStore(t)` in `models`) and `defer cleanup()` |
| 8 | exact SQL pinned with `regexp.QuoteMeta` + `WithArgs` in `models` tests | `models/billable_metrics_test.go:14-20`, `models/subscriptions_test.go:14-22` | **intentional**: `9acd83e` moved `FetchSubscription` to explicit columns "derived from the Subscription struct via schema.Parse ... and the test's expected SQL pins it" (SQLSTATE 0A000 after API DDL). Do not loosen these pins |
| 9 | loose SQL patterns in the processor/enrichment helpers (`".* FROM \"subscriptions\".*"`, `".*"`) | `processor_test.go:91-120` | fine for scenario tests; never for a query change (pin it in `models`) |
| 10 | miniredis for the Redis flag store | `setupFlagStore` `models/stores_test.go:29-37` (`miniredis.RunT(t)` stops with the test); failure injection `s.SetError` `:122-128` | no real Redis in unit tests |
| 11 | real in-memory badger | `setupTestCache` `cache/consumer_test.go:24-35` (`t.Cleanup(cache.Close)`) | one cache per test or subtest; no sharing |
| 12 | shared fakes in package `tests` | `MockMessageProducer` (`tests/mocked_producer.go`: records last key/value and `ExecutionCount`, `Produce` always returns true at :20); `MockFlagStore` (`tests/mocked_flag_store.go`: configurable `ReturnedError`); `MockCacheStore` (dead since `2fd8e8b`) | the fakes have no mutex; safe today because each is used by one goroutine per `processEvent`. Add a mutex before sharing one across goroutines |
| 13 | `utils.Result` assertions | `ErrorCode()` / `ErrorMessage()` / `ErrorMsg()` (`enrichment_service_test.go:77-84`); `IsRetryable()` / `IsCapturable()` (`models/billable_metrics_test.go:111-112,137-138`) | assert all three error fields and both flags for every failure case: they decide DLQ vs retry (`processor.go:70-82`) |
| 14 | error classification | `utils.FailedResult` defaults to Retryable + Capturable (`utils/result.go:113-120`); not-found is turned NonRetryable + NonCapturable (`models/billable_metrics.go:75-83`, `models/subscriptions.go:79-87`) | a new store function must follow the same split and test it |
| 15 | sort or use sets before asserting on unordered results | `45b216d` (#603, 2025-10-14, before badger `fff5858`) fixed a flaky DB-mode flat-filters test (`TestEnrichEvent/..._with_multiple_flat_filters`) whose charge order came from Go map iteration, with `sort.Slice`; `cache/cache_test.go:437-443` uses a set for `searchJSON` results (badger key order) | `assert.ElementsMatch` or sort first |
| 16 | never used: `t.Parallel`, benchmarks, fuzz, examples, `TestMain`, `t.Skip`, build tags, `testdata/` | `grep -rn 't.Parallel\|func Benchmark\|func Fuzz\|TestMain\|t.Skip\|//go:build' --include='*_test.go' events-processor` prints nothing | adding one is fine but say so in the PR: `t.Parallel` with the unsynchronised fakes of row 12 will race |
| 17 | noise in green runs | `ERROR Failed to cache item ... "DB Closed"`, `ERROR database connection failed ... query="SELECT * FROM \"billable_metrics\" ..."` | these are negative-path tests logging through slog, not failures |

## 2. Which template for which change

| You are changing | Start from | Package dir | Key point |
|---|---|---|---|
| enrichment value, aggregation, subscription matching, expression handling | `templates/enrichment_template_test.go.tmpl` (`TestTemplateEnrichEvent_Value`) | `processors/events_processor/` | both modes; register DB queries in code order; `assertQueriesConsumed` |
| what `processEvent` produces (topics, flag store, DLQ on enrichment failure) | same file (`TestTemplateProcessEvent_Producers`) | `processors/events_processor/` | no `time.Sleep`; correct nesting |
| a SQL query in `models/*.go` | `templates/model_query_template_test.go.tmpl` | `models/` | exact SQL anchored `^...$`; `WithArgs`; `ExpectationsWereMet` |
| cache lookups, keys, tie-breaks, CDC record handling | `templates/cache_template_test.go.tmpl` | `cache/` | fresh badger per case; order-insensitive asserts; no ties |
| the Redis flag store (`subscription_refreshed_v2`) | `templates/redis_store_template_test.go.tmpl` | `models/` | clock-safe buckets; `SetError`; canceled context |
| a Kafka client option or producer config (`ServerConfig`, `ProducerConfig`, the `[]kgo.Opt` passed to `NewKafkaClient`) | `templates/producer_option_template_test.go.tmpl` | `config/kafka/` | no broker, no kfake: `kgo.NewClient` validates options and returns without connecting; assert `client.OptValue(kgo.<Option>)` for default / explicit / zero / out-of-range (the last must return an error) |
| Kafka commit, retry, DLQ semantics (delivery) | not here: kfake harness (`diagnostics-and-tooling`), campaign design (`event-accounting-campaign`); kfake is not in `events-processor/go.mod` (adding it is C5) | `config/kafka/`, `processors/events_processor/` | change-control N7 |

How to use a template:

```bash
cp -n .claude/skills/validation-and-qa/templates/model_query_template_test.go.tmpl \
   events-processor/models/charges_test.go          # -n: never overwrite; then rename TestTemplate* and the cases
.claude/skills/build-and-env/scripts/ep-test.sh -count=1 -run 'TestHasPayInAdvanceCharge' ./models/
```

`models/charges_test.go` does not exist today (as of 2026-10-01), so the copy is safe. Several
other natural targets do exist (`cache/subscriptions_test.go`, `cache/charges_test.go`,
`models/subscriptions_test.go`): append the template's test function to them instead of copying
over them (an overwritten file loses tests; `baseline.sh` would report a `pass.<pkg>` FAIL).

To try a template without copying it into the repo, run `scripts/templates-check.sh -v`; it
overlays all five into their packages.

## 3. sqlmock: semantics you must know

Verified in `github.com/DATA-DOG/go-sqlmock@v1.5.2` (`query.go`), the version in `go.mod:6`:

- The default matcher (`QueryMatcherRegexp`) collapses every run of whitespace to one space in
  both the expected pattern and the actual SQL, then does an **unanchored** regexp match. So a
  multi-line pinned query works, and `regexp.QuoteMeta` is needed for `*`, `$1`, `(`, `.`.
- Unanchored means the actual SQL only has to CONTAIN the pattern. The existing pins are full
  queries, so in practice they are exact; new pins should add `^` and `$`
  (`"^" + regexp.QuoteMeta(q) + "$"`), as the model-query template does.
- Expectations are ordered by default: register them in the order the code runs the queries
  (enrichment: `billable_metrics`, then `subscriptions`, then `charges`).
- An expectation that is never executed is only reported by `mock.ExpectationsWereMet()`.
  `tests/mocked_store.go` never calls it, so call it yourself (templates do) and run
  `scripts/sqlmock-strict.sh`.
- To learn the SQL gorm emits, pin a wrong string, run, and copy the `could not match actual sql:`
  text. Example (verified): `Select("id")` on `charges` emits `SELECT id FROM "charges" ...`
  (unquoted `id`), not `SELECT "id"`.
- A diff in a pinned SQL string is a behaviour change (class C3) and must still satisfy
  change-control N4: explicit column list, `deleted_at IS NULL` on soft-deletable tables,
  `organization_id` on every query. Known residual: `FetchBillableMetric` uses gorm `First`
  (`models/billable_metrics.go:59-66`), so its pin is `SELECT * FROM "billable_metrics" ...`
  (`models/billable_metrics_test.go:14-20`). Do not copy that shape.

## 4. Dual-mode tests: rules

1. Loop over `{"WithCache", true}, {"WithoutCache", false}` and put EVERY scenario inside
   `t.Run(mode.name, ...)`. `TestProcessEvent` gets this wrong (`harness-defects.md` HD2).
2. Never hard-code `setupProcessorTestEnv(t, true)` inside a mode loop (`processor_test.go:424`
   does, so that scenario never runs in DB mode).
3. When the two modes legitimately differ, branch on `mode.useCache` and say why in a comment
   (`enrichment_service_test.go:78-82`: "Key not found" vs "record not found";
   `:226-239`: cache filters by `started_at`, sqlmock does not evaluate WHERE).
4. In DB mode, `MockDataStore` returns rows without evaluating the WHERE clause, so a DB-mode
   test proves the Go code's handling of rows, not the SQL. Pin the SQL in a `models` test.
5. Cache mode needs data the SQL path does not: e.g. `StartedAt` on a subscription
   (`cache/subscriptions.go:56`) and matching `OrganizationID`/`PlanID`/`BillableMetricID` keys
   on a charge.

## 5. Things to avoid (each was found in this suite)

| Avoid | Instead | Where it happened |
|---|---|---|
| sharing variables across subtests (`bm`, `event`, `result` declared in the parent) | build everything inside each subtest | `TestEvaluateExpression` (`enrichment_service_test.go:252-296`) |
| `time.Sleep` to wait for goroutines | rely on the happens-before the code gives (`processEvent` waits via `defer errgroup.Wait()`, `processor.go:101`); otherwise a channel or `assert.Eventually` | `processor_test.go:255,416,470` (redundant) |
| real-time sleeps for TTLs | keep TTLs tiny or inject time; if you must sleep, keep it under 100 ms | `cache/cache_test.go:362` (1.5 s, about half the cache package time) |
| wall-clock assertions computed AFTER the call | read the clock before and after, accept both buckets | `models/stores_test.go:59-74` |
| asserting on what you just inserted by hand | assert on what the code produced | "new bucket after time window advances" `models/stores_test.go:102-120` |
| comparing `json.Marshal(x)` with `json.Marshal(x)` | pin the literal JSON (field names are a contract with lago-api and ClickHouse) | `event_producer_service_test.go:54-55,77-78` |
| tests without assertions | at least one assertion that fails if the behaviour breaks | `TestCache_ConcurrentAccess` (`cache/cache_test.go:276-307`) |
| `assert.Equal(t, actual, expected)` | `assert.Equal(t, expected, actual)`: the failure diff labels them | `utils/result_test.go:38` and others |
| pinning stdlib error text when the code returns the wrong error | assert the error code and flags; pin text only for our own messages | `processor_test.go:288` pins `strconv.ParseFloat ...` because `ToTime` returns the ParseFloat error (`utils/time.go:20-29`) |
| a fake that always succeeds | add a failure switch to the fake (as `MockFlagStore.ReturnedError`) | `tests/mocked_producer.go:20` |
| `assert` on a precondition, then dereferencing the value | `require` for preconditions: a nil dereference panics and hides every later test in the package | `config/database/database_test.go:22-24` (HD5) |

## 6. lago-api specs (only for cross-repo changes)

You need lago-api specs only when a change is C4 (a contract both repos read or write). The
paired lago-api PR pins the format on the Rails side; it is needed when the K row lists a lago-api
dependent of the changed part (DECIDED OD-4 (owner, 2026-10-02); change-control
`reference/cross-repo-protocol.md` §1).
Read lago-api at the pin: `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`.

| Rule or fact | Where (`$API` = lago-api@591ae90) |
|---|---|
| run rspec in the api container: `lago exec api bundle exec rspec <args>` (an alias agent shells do not load; not runnable in this sandbox: Ruby 3.3.6 vs `$API/.ruby-version` 4.0.6, no gems, no Docker daemon; UNVERIFIED here) | `$API/AGENTS.md:8` |
| never use `aggregate_failure` in new tests; prefer `have_received`; run as few tests as possible | `$API/AGENTS.md:212-218` |
| model spec section order: enums, associations, Clickhouse associations, scopes, validations; ClickHouse associations in their own block with `clickhouse: true` | `$API/AGENTS.md:222-236` |
| `clickhouse: true` metadata opens network access to `LAGO_CLICKHOUSE_HOST` (48 spec files use it) | `$API/spec/spec_helper.rb:145-146,165-171` |
| `:capture_kafka_messages` stubs the Karafka producer | `$API/spec/support/kafka_helper.rb:19-20` |
| the raw-event payload (what Go unmarshals) is pinned field by field; the topic comes from `LAGO_KAFKA_RAW_EVENTS_TOPIC` (the spec sets `raw_events`; `.env.development.default:78` sets `events-raw`) | `$API/spec/services/events/kafka_producer_service_spec.rb:16-46` |
| scenario specs write `events_enriched` rows directly (`Clickhouse::EventsEnriched.create!`), bypassing Kafka and Go: no lago-api spec consumes Go output | `$API/spec/support/scenarios_helper.rb:501,513` |
| lago-api spec CI: Postgres `getlago/postgres-partman:15.0-alpine`, ClickHouse `25.12-alpine` | `$API/.github/workflows/spec.yml:15,77` |

So for a contract change: pin the Go side in an events-processor test (literal JSON, not
marshal-vs-marshal), pin the Rails side in the matching lago-api spec, and run the parity check
from `rails-go-parity`. The protocol (versioned names, deploy order) is in change-control.
