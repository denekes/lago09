# Invariants I1-I15 (statement · enforced at · breaks if violated · guarding test)

Code facts as of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only commits on
top. Verified 2026-10-01. Paths relative to `events-processor/`. "Guard" = a test that fails if the
invariant is broken; "none" means nothing in CI would notice. Status: HOLDS / VIOLATED (where) / PARTIAL /
CONDITIONAL (holds only under a setting outside this repo).
`invariants-grep.sh` re-checks I1-I3, I7, I8, I9 (the `12*time.Hour` literal), I10, I11 statically; a 2026-10-01
mutation run on a scratch copy (add `Select` to the BM query, drop `deleted_at` from the charges query, 12 h → 24 h,
a `ctx` field in `FlagStore`, disable the `!ok` guard) turned the I2 FLAG off and raised N4-del, N5-ctx, N7-guard and
CONTRACT FLAGs as intended.

### I1 Every per-event read is scoped by `organization_id` — HOLDS
- Enforced: `models/billable_metrics.go:63`, `models/subscriptions.go:30`, `models/charges.go:54`; cache keys start
  `<prefix>:<org>:` (`cache/billable_metrics.go:18-20`, `cache/subscriptions.go:21-23`, `cache/charges.go:18-20`);
  snapshot queries are global by design (`models/query_streaming.go:25`).
- Breaks: cross-tenant enrichment (one org's BM/plan applied to another's event). History `9ef876a` (ING-123,
  whether it leaked is OPEN DECISION OD-9, UNVERIFIED).
- Guard: exact SQL pins `models/billable_metrics_test.go:14-20`, `models/subscriptions_test.go:14-22`; key tests
  `cache/*_test.go TestBuild*Key`. Charges query: **none** (only `.* FROM "charges".*`, `processor_test.go:108`).

### I2 Explicit column lists on tables Rails migrates (no implicit `SELECT *`) — VIOLATED
- Enforced: `models/subscriptions.go:24,37` (`schema.Parse` → `Select(DBNames)`), `models/charges.go:52`, snapshot
  `SelectFields` in every `models/*.go GetAll*`.
- Violated: `models/billable_metrics.go:61` `FetchBillableMetric` uses gorm `First` (implicit `SELECT *`), and its
  test pins the `SELECT *` (`models/billable_metrics_test.go:14-15`).
- Breaks: after a Rails column-add migration, each pooled pgx connection fails once with SQLSTATE 0A000 ("cached plan
  must not change result type"). pgx then drops that cached statement (`pgx/v5@v5.9.2/rows.go:172-180`,
  `pgx/v5@v5.9.2/conn.go:520-529`; pin `go.mod:13`), so each connection heals after one failure. Each failure is a retryable
  `fetch_billable_metric`, which is LOST under L1 as soon as a later record of the partition commits. The Postgres behaviour was
  reproduced 2026-10-01 in psql on a TEMP table: `PREPARE q AS SELECT * …; ALTER TABLE … ADD COLUMN …; EXECUTE q` →
  `ERROR: cached plan must not change result type`. History `9acd83e` (ING-15),
  `3ac94a2` (ING-143). Rule: change-control N4.
- Guard: `models/subscriptions_test.go` pins the column list; nothing guards billable_metrics.

### I3 Soft-deleted rows are invisible (`deleted_at IS NULL`) — HOLDS
- Enforced: `models/billable_metrics.go:63`, `models/charges.go:54`, snapshot `WhereCondition` of every soft-deletable
  table (`models/{billable_metrics,charges,billable_metric_filters,charge_filters,charge_filter_values}.go`);
  CDC deletes (`cache/consumer.go:107-140`). `subscriptions` has no `deleted_at` in lago-api (`$API/db/structure.sql`).
- Breaks: events of a deleted BM keep being enriched (`8ceca4b`, #740).
- Guard: the BM exact-SQL pin contains `deleted_at IS NULL` (`models/billable_metrics_test.go:17`); no test feeds a
  deleted row; charges: none.

### I4 DB-mode subscription resolution mirrors Rails `Events::Common#subscription` — HOLDS (DB) / PARTIAL (cache)
- Enforced: `models/subscriptions.go:29-40` (ms `date_trunc`, `terminated_at DESC NULLS FIRST, started_at DESC`).
  Cache emulation `cache/subscriptions.go:45-117` compares at µs and prefix-scans (see `memory-cache.md`).
- Breaks: wrong `subscription_id` / `plan_id` ⇒ wrong pay-in-advance decision and refresh flag.
- Guard: `models/subscriptions_test.go` pins the SQL; cache ordering: none for the tie-breaks. Rails side and
  divergences: `rails-go-parity`.

### I5 Exactly one side post-processes an event — HOLDS
- Statement: in-advance production and the refresh ZADD happen only if a subscription was found **and**
  `NotAPIPostProcessed()` (not `http_ruby` with `source_metadata.api_post_processed=true`).
- Enforced: `processors/events_processor/processor.go:115`, `models/event.go:86-92`; Rails sets
  `api_post_processed = !organization.clickhouse_events_store?` (`$API/app/services/events/kafka_producer_service.rb:50-52`).
- Breaks: double pay-in-advance fees / double refresh for Postgres-store orgs, or none for ClickHouse-store orgs.
- Guard: `models/event_test.go TestNotAPIPostProcessed`; `processor_test.go:204` ("post processed on API" ⇒ 0 in-advance).

### I6 Custom expressions are evaluated only for non-`http_ruby` sources — HOLDS
- Enforced: `enrichment_service.go:104` (Rails evaluated it at ingestion).
- Breaks: double evaluation changes `properties[field_name]` and `value`.
- Guard: none dedicated (the `processor_test.go:204` case has no expression).

### I7 Side effects use the batch context (`context.Background()`), never the process context — HOLDS
- Enforced: `processRecordsAndCommit` creates the batch ctx `context.Background()` (`config/kafka/consumer.go:83`) and
  passes the same ctx to every record of the batch; stores take ctx as an argument
  (`models/stores.go:50-54`, comment states the rule).
- Breaks: every Redis write in flight during a rolling restart fails with `context canceled` (`02a4bc8`, #785).
  Rule: change-control N5.
- Guard: none (no shutdown test); `invariants-grep.sh` rule `N5-ctx` flags a `context.Context` struct field.

### I8 Commit only a processed prefix of the batch, never a nil record — HOLDS within a batch
- Enforced: `config/kafka/consumer.go:92-104,278-308`.
- Breaks: franz-go segfault (`9acd83e`, ING-15) or committing past an unprocessed record **inside** the batch.
- Guard: `config/kafka/consumer_test.go TestFindMaxCommitableRecord` (6 cases). `processRecordsAndCommit` itself has
  0% coverage. Across batches the invariant does **not** extend: loss L1.

### I9 Retry horizon: a retryable failure older than 12 h (by `ingested_at`) goes to the DLQ — HOLDS
- Enforced: `processors/events_processor/processor.go:74`. Missing `ingested_at` = zero time = "old" ⇒ immediate DLQ
  (verified: `since>12h=true` for an event without `ingested_at`).
- Breaks / decided: ADR-001 (DECIDED OD-2 (owner, 2026-10-02), `event-accounting-campaign`
  `reference/delivery-options.md`) keeps 12 h as the default max age of a retried record before the DLQ; the
  as-is mechanism (no retry at all, loss L1) is what ADR-001 replaces.
- Guard: none (`ProcessEvents` has 0% coverage; tests call `processEvent`).

### I10 Redis refresh contract `subscription_refreshed_v2` / `<org>:<sub>|<10 s bucket>` / score = now — HOLDS
- Enforced: `processors/main_processor.go:152`, `processors/events_processor/subscription_refresh_service.go:22`,
  `models/stores.go:16,54-69`; Rails `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:7,14,26-37`.
- Breaks: Rails never refreshes subscriptions (stale usage, alerts, wallets) or refresh starvation (`42615c9`).
  Rule: change-control N6 (the Rails clock reads it, so a paired lago-api PR: DECIDED OD-4).
- Guard: `models/stores_test.go TestFlag` (format, bucket, same-window dedup), `subscription_refresh_service_test.go`.
  Cross-repo constants: `rails-go-parity`.

### I11 Output key = `<organization_id>-<transaction_id>` on enriched and in-advance; DLQ unkeyed — HOLDS
- Enforced: `processors/events_processor/event_producer_service.go:30,41,66-68`.
- Breaks: partition distribution / ordering assumptions downstream (`731e18f` changed it from `<org>-<ext_sub>-<code>`).
- Guard: `event_producer_service_test.go:45-52` (enriched key), `:74` (in-advance key).

### I12 Duplicates are safe only because downstream dedups on `transaction_id` — CONDITIONAL (outside this repo)
- Statement: the pipeline is at-least-once (commit after side effects; redelivery on restart/rebalance/commit error).
  It relies on `events_enriched` = `ReplacingMergeTree(timestamp)` ordered by (…, timestamp, transaction_id)
  (`$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:6-20`) and on `Events::PayInAdvanceJob`
  `unique :until_executed` keyed on (org, external_subscription_id, transaction_id)
  (`$API/app/jobs/events/pay_in_advance_job.rb:13,21`). `events_dead_letter` is a plain MergeTree: DLQ duplicates persist.
- Breaks: never emit without `transaction_id`, never rewrite it, never change the enriched ORDER BY assumptions
  without lago-api (change-control N6).
- Condition: billing reads `events_enriched` with `FINAL` only when the org has `clickhouse_deduplication_enabled`
  (`$API/app/services/billable_metrics/aggregations/base_service.rb:161-169`; default false,
  `$API/app/models/organization.rb:348`; the only env-driven setter is org creation with `LAGO_CLICKHOUSE_ENABLED` +
  `LAGO_DEFAULT_EVENT_STORE=clickhouse`, `$API/app/services/organizations/create_service.rb:17-19`; also set by the
  clickhouse rake recipe `$API/lib/tasks/recipes/clickhouse.rake:109` and the enriched-store migration
  `$API/app/services/events/stores/clickhouse/enriched_store_migration/comparison_service.rb:61-64`; the dev seed CH org
  leaves it false, `$API/db/seeds/01_base.rb:54`). Without it, redelivered duplicates are summed until a background
  merge. In-advance fees are idempotent through `PayInAdvanceService#already_processed?`
  (`$API/app/services/events/pay_in_advance_service.rb:15,55-57`); the job lock only blocks concurrent duplicates.
  `CleanDuplicatedService` has no caller at the pin `591ae90`.
- Guard: none in this repo.

### I13 CDC apply is monotonic per key — HOLDS
- Enforced: `cache/consumer.go:143-156` (skip unless message `updated_at` ms is strictly newer), `:107-121` (delete only
  when the cached id equals the message id).
- Breaks: stale or resurrected cache entries; deleting a re-created BM code.
- Guard: `cache/consumer_test.go` (`SkipUpdate_OlderTimestamp`, `SkipUpdate_SameTimestamp`, `Delete_MatchingID`,
  `Delete_NotInCache`, `UpdateExisting_NewerTimestamp`).

### I14 Startup is only partially fail-fast: required config missing ⇒ panic before consuming — PARTIAL
- Enforced: `utils/error_tracker.go:30-34` (`LogAndPanic`), `processors/main_processor.go:103-179`, `main.go:72-80`.
- Gaps (verified with `startup-contract.sh`): empty raw topic / consumer group accepted (SK9), empty
  `LAGO_DEBEZIUM_TOPIC_PREFIX` accepted (S6), snapshot table errors swallowed (S6), unknown SCRAM algorithm
  SIGSEGVs without log/Sentry (S4), `LAGO_USE_MEMORY_CACHE=1` silently means DB mode (S7), `brokers not found` is
  never sent to Sentry (S1), and in cache mode Postgres is checked before the brokers (S5). Other skills cite this
  list as "partially fail-fast (architecture-contract I14)".
- Guard: none in CI; `startup-contract.sh` (exit 0 = documented contract still holds).

### I15 Classification: missing BM ⇒ DLQ (non-retryable, not captured); missing subscription ⇒ still enriched — HOLDS
- Enforced: `models/billable_metrics.go:75-83`, `cache/cache.go:189-191`, `models/subscriptions.go:79-87`,
  `processors/events_processor/enrichment_service.go:41-43,61-67` (recurring BM: retry at `time.Now()` first, `:57-59`).
- Breaks: retry storms (if not-found became retryable) or lost usage (if a missing subscription dropped the event).
- Guard: `enrichment_service_test.go:64` ("Without Billable Metric"), `:149`/`:197` (recurring / non-recurring
  without active subscription), `processor_test.go:293` ("no subscriptions are found").

### Historical invariant (removed; keep for archaeology)
Charge-filter selection had to match Rails `ChargeFilters::EventMatchingService` (`0b56915`, ING-543); the code was
deleted with `flat_filters` in `d9c32b6`. Reintroducing per-event charge/filter resolution in Go is forbidden without a
parity spec, parity test and owner sign-off (change-control N8).
