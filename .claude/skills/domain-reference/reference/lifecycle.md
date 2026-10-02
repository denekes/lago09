# Event lifecycle in detail: POST /api/v1/events -> invoice

Read this when you need the exact code location of a lifecycle step, the gate that switches a step on,
or what differs between a PG-store and a CH-store organization. SKILL.md section 3 is the summary.
Every `path:line` here is asserted by `scripts/lifecycle-check.sh` (re-run it before trusting a line
number). Verified 2026-10-01: events-processor `5308258` (tree `83e012866f29`), lago-api at the pin
`591ae90` (2026-09-08) (`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`).

Actor tags: **[Rails]** API web process, **[Sidekiq]** Rails background job, **[Kafka]** a topic,
**[EP]** Go events-processor, **[CH]** ClickHouse (Kafka engine + materialized view), **[Karafka]** Rails
Kafka consumer process, **[Redis]** the Redis store, **[clock]** Rails clockwork scheduler.
Store marks: **PG** = only for orgs with `clickhouse_events_store = false`, **CH** = only for orgs with
`clickhouse_events_store = true`, **both** = every org.

## Phase A: ingestion (synchronous, inside the HTTP request)

**LC1 [Rails] both. Route and permitted fields.**
- `POST /api/v1/events` routes to `EventsController#create`: `$API/config/routes/shared_api.rb:98`,
  `$API/app/controllers/api/v1/events_controller.rb:12`.
- `POST /api/v1/events/batch` goes to `Events::CreateBatchService` (`$API/config/routes/shared_api.rb:160`).
  Max batch size is `LAGO_EVENTS_BATCH_MAX_LENGTH`, default 100 (`$API/app/services/events/create_batch_service.rb:5`).
- The controller permits exactly `transaction_id, code, timestamp, external_subscription_id,
  precise_total_amount_cents, properties` (`$API/app/controllers/api/v1/events_controller.rb:172`).
  `external_customer_id` is NOT permitted at the pin `591ae90`.

**LC2 [Rails] both. Timestamp.**
`Time.zone.at(BigDecimal(params[:timestamp]))`; a missing timestamp becomes the request time
(`$API/app/services/events/create_service.rb:53`, `$API/app/controllers/api/v1/events_controller.rb:16`).
An unparsable one returns 422 `invalid_format` (`$API/app/services/events/create_service.rb:17`).

**LC3 [Rails] both. Expression.**
If the BM has an `expression`, Rails evaluates it now and writes the result into
`properties[field_name]` (`$API/app/services/events/calculate_expression_service.rb:22`,
`$API/app/services/events/calculate_expression_service.rb:26`). The expression sees the timestamp as
INTEGER seconds (`event.timestamp.to_i`). A runtime error returns 422.

**LC4 [Rails] store branch on `organization.clickhouse_events_store?`** (`$API/app/services/events/create_service.rb:32`).
- **PG**: `event.save!` runs model validations (`$API/app/models/event.rb:14`) and hits the unique index
  `(organization_id, external_subscription_id, transaction_id)` (`$API/app/models/event.rb:95`). A duplicate
  returns 422 `value_already_exist` (`$API/app/services/events/create_service.rb:45`). Then
  `Events::PostProcessJob` is enqueued (`$API/app/services/events/create_service.rb:38`): see LC5.
- **CH**: no Postgres row, no `valid?` on the single-event path, no post-process job. The batch path does
  call `valid?` (`$API/app/services/events/create_batch_service.rb:59`).

**LC5 [Sidekiq] PG only. `Events::PostProcessService`** (`$API/app/services/events/post_process_service.rb:13`).
In order:
1. expire the Rails charge-usage cache, unless the org has the `lazy_charge_usage_cache` flag
   (`$API/app/services/events/post_process_service.rb:85`);
2. write Postgres `enriched_events` rows, only with the `postgres_enriched_events` flag
   (`$API/app/services/events/post_process_service.rb:95`);
3. track subscription activity (alerts, lifetime usage) (`$API/app/services/events/post_process_service.rb:102`);
4. `customer.flag_wallets_for_refresh` (`$API/app/services/events/post_process_service.rb:17`);
5. `target_wallet_code` error webhook (`$API/app/services/events/post_process_service.rb:114`);
6. pay in advance: enqueue `Events::PayInAdvanceJob` (`$API/app/services/events/post_process_service.rb:133`), see LC14.
Its subscription match excludes `incomplete` subscriptions (`$API/app/services/events/post_process_service.rb:46`)
and falls back to the `.active` subscription for recurring BMs (`$API/app/services/events/post_process_service.rb:68`).

**LC6 [Rails -> Kafka] both. Raw event produced** (`$API/app/services/events/create_service.rb:39`).
- Skipped SILENTLY when `LAGO_KAFKA_BOOTSTRAP_SERVERS` or `LAGO_KAFKA_RAW_EVENTS_TOPIC` is blank
  (`$API/app/services/events/kafka_producer_service.rb:16`). For a CH-store org that means the API answers
  200 and the event exists nowhere.
- No Kafka key (`$API/app/services/events/kafka_producer_service.rb:29`). Async `produce_many_async`.
- Payload: `timestamp` = `to_f.to_s` (`$API/app/services/events/kafka_producer_service.rb:43`),
  `precise_total_amount_cents` defaults to `"0.0"` (`$API/app/services/events/kafka_producer_service.rb:46`),
  `ingested_at` = now, ms, no `Z` (`$API/app/services/events/kafka_producer_service.rb:48`),
  `source: "http_ruby"` (`$API/app/services/events/kafka_producer_service.rb:7`),
  `api_post_processed: !clickhouse_events_store?` (`$API/app/services/events/kafka_producer_service.rb:51`).
- Field-by-field schema: see `rails-go-parity` (payload schemas).

## Phase B: streaming (asynchronous, seconds)

**LC7 [CH] both. Raw copy.** ClickHouse consumes the raw topic itself: `events_raw_queue` Kafka engine
(`$API/db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:9`) -> `events_raw_mv`
(properties become `Map(String, String)`, `$API/db/clickhouse_migrate/20231030163703_create_events_raw_mv.rb:13`)
-> `events_raw`, a plain MergeTree that never deduplicates
(`$API/db/clickhouse_migrate/20231024084411_create_events_raw.rb:6`). Read by `GET /api/v1/events/:id` for CH
orgs (`$API/app/controllers/api/v1/events_controller.rb:54`) and by re-enrichment.

**LC8 [EP] both. Consume and parse.** Consumer group id `<LAGO_KAFKA_CONSUMER_GROUP>_<raw topic>`
(`events-processor/config/kafka/consumer.go:237`, `events-processor/processors/main_processor.go:171`).
`ProcessEvents` unmarshals each record (`events-processor/processors/events_processor/processor.go:50`);
an unmarshal error is committed with NO dead-letter record (`events-processor/processors/events_processor/processor.go:56`).

**LC9 [EP] both. Enrich** (`events-processor/processors/events_processor/enrichment_service.go:27`).
1. Timestamp to float seconds (ms-truncated) and to `time.Time` (`events-processor/models/event.go:70`,
   `events-processor/utils/time.go:58`, `events-processor/utils/time.go:48`). Failure: DLQ `build_enriched_event`.
2. Billable metric by `(organization_id, code, deleted_at IS NULL)`: Postgres in DB mode (dev)
   (`events-processor/models/billable_metrics.go:63`), badger in memory-cache mode (production,
   DECIDED OD-1 (owner, 2026-10-02)) (`events-processor/processors/events_processor/enrichment_service.go:37`). Not found: DLQ
   `fetch_billable_metric` (`events-processor/processors/events_processor/enrichment_service.go:42`).
3. Expression, only when `source != "http_ruby"` (`events-processor/processors/events_processor/enrichment_service.go:104`).
4. `value`: `"1"` for count, else `fmt.Sprintf("%v", properties[field_name])`
   (`events-processor/processors/events_processor/enrichment_service.go:111`,
   `events-processor/processors/events_processor/enrichment_service.go:114`).
5. Subscription by `(organization_id, external_id)` whose `[started_at, terminated_at]` window (ms-truncated)
   holds the timestamp, newest first (`events-processor/models/subscriptions.go:32`,
   `events-processor/models/subscriptions.go:40`); recurring BMs retry at `time.Now()`
   (`events-processor/processors/events_processor/enrichment_service.go:57`). No match is NOT an error:
   the event continues with an empty `subscription_id` (`events-processor/processors/events_processor/enrichment_service.go:66`).

**LC10 [EP -> Kafka] both. Enriched event produced** to `$LAGO_KAFKA_ENRICHED_EVENTS_TOPIC`, key
`<organization_id>-<transaction_id>` (`events-processor/processors/events_processor/processor.go:111`,
`events-processor/processors/events_processor/event_producer_service.go:30`). PG-store events are enriched too,
but nothing bills from them (LC17).

**LC11 [EP -> Kafka, Redis] CH (and any non-Rails source). Post-processing.** Only when a subscription was
found AND `NotAPIPostProcessed()` (`events-processor/processors/events_processor/processor.go:115`,
`events-processor/models/event.go:86`):
- any non-deleted `pay_in_advance` charge for `(org, plan_id, billable_metric_id)`
  (`events-processor/models/charges.go:47`) -> same JSON to `events_charged_in_advance`
  (`events-processor/processors/events_processor/processor.go:123`);
- ZADD `subscription_refreshed_v2` member `<org>:<subscription_id>|<10 s bucket>`, score = wall-clock now
  (`events-processor/processors/events_processor/processor.go:128`, `events-processor/models/stores.go:62`,
  `events-processor/processors/main_processor.go:152`).

For a PG-store org's connector event (no `source`) Go emits both as well, but Rails' `PayInAdvanceService`
drops Kafka-origin events of PG-store orgs whenever Kafka is configured
(`$API/app/services/events/pay_in_advance_service.rb:23`), so no in-advance fee results (code-read).

**LC12 [EP] both. Disposition.** A failed event that is retryable and ingested less than 12 h ago is not
marked for commit; anything else goes to the DLQ and is marked
(`events-processor/processors/events_processor/processor.go:74`,
`events-processor/processors/events_processor/processor.go:82`). "Not marked" does NOT guarantee a retry:
the partition commits up to the record before the first unmarked one, and when nothing in the batch is
committable it skips the commit (`events-processor/config/kafka/consumer.go:98`). The code comment says the
record "will be re-polled after the next rebalance", but it is re-polled only if the partition is reassigned or
the process restarts before any later commit; with franz-go's default cooperative-sticky balancer (not
overridden here) a rebalance usually keeps the partition. Once a later offset of that partition is committed,
the failed record is never read again (silent loss). The commit algorithm and every place a record can be
lost: `architecture-contract`; the fix campaign: `event-accounting-campaign`.

**LC13 [CH] both. Enriched copy.** `events_enriched_queue` reads 8 columns only (no `subscription_id`,
`plan_id` or `aggregation_type`) (`$API/db/clickhouse_migrate/20240705084952_create_events_enriched_queue.rb:9`,
`$API/db/clickhouse_migrate/20240705084952_create_events_enriched_queue.rb:14`) -> `events_enriched_mv`
(`$API/db/clickhouse_migrate/20240705085501_create_events_enriched_mv.rb:10`) -> `events_enriched`,
`ReplacingMergeTree(timestamp)` (`$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:6`) with
`decimal_value Decimal(38, 26) DEFAULT toDecimal128OrZero(value, 26)`
(`$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32`).

## Phase C: reactions (seconds to minutes)

**LC14 [Karafka -> Sidekiq] Pay in advance.**
- **CH**: `EventsChargedInAdvanceConsumer` (`$API/karafka.rb:51`) enqueues `Events::PayInAdvanceJob` with a
  15 s delay so ClickHouse can merge (`$API/app/consumers/events_charged_in_advance_consumer.rb:6`,
  `$API/app/services/events/stores/clickhouse_store.rb:11`).
- **PG**: the job comes from LC5 directly (`$API/app/services/events/post_process_service.rb:133`).
- **both**: `Events::PayInAdvanceService` is authoritative. It ignores the wrong origin per store
  (`$API/app/services/events/pay_in_advance_service.rb:18`), requires the property for sum/unique_count
  (`$API/app/services/events/pay_in_advance_service.rb:63`), is idempotent on `transaction_id`
  (`$API/app/services/events/pay_in_advance_service.rb:56`), then creates a standalone fee
  (`invoiceable: false`) or an invoice (`invoiceable: true`) (`$API/app/services/events/pay_in_advance_service.rb:26`).

**LC15 [clock -> Sidekiq] CH. Subscription refresh.** Registered only when BOTH `LAGO_REDIS_STORE_URL` and
`LAGO_CLICKHOUSE_ENABLED` are present (`$API/clock.rb:210`), every 10 s. It pops members whose score is at
least 10 s old (`$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:26`) ->
`Subscriptions::FlagRefreshedJob` -> `customer.flag_wallets_for_refresh` and subscription activity
(`$API/app/services/subscriptions/flag_refreshed_service.rb:14`,
`$API/app/services/subscriptions/flag_refreshed_service.rb:16`). **PG**: done inline in LC5.

**LC16 [clock -> Sidekiq] both. Alerts, lifetime usage, wallets.**
- `ProcessAllSubscriptionActivitiesJob` every `LAGO_SUBSCRIPTION_ACTIVITY_PROCESSING_INTERVAL_SECONDS`,
  default 60 s (`$API/clock.rb:33`): progressive billing and alerts
  (`$API/app/services/usage_monitoring/process_subscription_activity_service.rb:31`). Premium only
  (`$API/app/jobs/clock/process_all_subscription_activities_job.rb:8`).
- `RefreshWalletsOngoingBalanceJob` every `LAGO_WALLET_ONGOING_BALANCE_REFRESH_INTERVAL_SECONDS`, default 300 s,
  only if `LAGO_MEMCACHE_SERVERS` or `LAGO_REDIS_CACHE_URL` is set (`$API/clock.rb:55`). Premium only, customers
  with `awaiting_wallet_refresh` (`$API/app/jobs/clock/refresh_wallets_ongoing_balance_job.rb:8`,
  `$API/app/jobs/clock/refresh_wallets_ongoing_balance_job.rb:10`).

## Phase D: billing (hourly)

**LC17 [clock -> Sidekiq] both. Invoice.**
1. `Clock::SubscriptionsBillerJob` hourly at `:10` (`$API/clock.rb:79`) -> one `OrganizationBillingJob` per org
   (`$API/app/jobs/clock/subscriptions_biller_job.rb:9`) -> `BillSubscriptionJob` per group of the org's `billable_subscriptions`
   (grouped by customer, payment method, currency, ...) (`$API/app/services/subscriptions/organization_billing_service.rb:36`).
2. `Invoices::SubscriptionService` (`$API/app/jobs/bill_subscription_job.rb:20`) -> `Invoices::CalculateFeesService`
   (`$API/app/services/invoices/subscription_service.rb:56`) -> `Fees::ChargeService` per charge
   (`$API/app/services/invoices/calculate_fees_service.rb:134`).
3. One fee per charge filter plus one "default bucket" fee for events matching no filter
   (`$API/app/services/fees/charge_service.rb:74`, `$API/app/services/fees/charge_service.rb:86`).
4. Charge period boundaries are computed in the customer's timezone
   (`$API/app/services/subscriptions/dates_service.rb:95`, `$API/app/services/subscriptions/dates_service.rb:99`).
5. Aggregation: `BillableMetrics::AggregationFactory` (`$API/app/services/fees/charge_service.rb:435`) asks
   `StoreFactory.store_class` (`$API/app/services/billable_metrics/aggregation_factory.rb:7`):
   - **PG**: `PostgresStore` reads Postgres `events` and the raw `properties` (`$API/app/services/events/stores/postgres_store.rb:7`).
     Go's `value` is never read.
   - **CH** (and `LAGO_CLICKHOUSE_ENABLED` present, `$API/app/services/events/stores/store_factory.rb:38`):
     `ClickhouseStore` reads `events_enriched FINAL` (`$API/app/services/events/stores/clickhouse_store.rb:111`)
     when the org has `clickhouse_deduplication_enabled` (`$API/app/services/billable_metrics/aggregations/base_service.rb:168`),
     otherwise the rows as stored, duplicates included. It defaults to false; org creation (only when
     `LAGO_CLICKHOUSE_ENABLED` casts to true AND `LAGO_DEFAULT_EVENT_STORE=clickhouse`,
     `$API/app/services/organizations/create_service.rb:17`), the rake recipe
     (`$API/lib/tasks/recipes/clickhouse.rake:109`) and the enriched-store migration set it true; the dev seed
     CH org leaves it false (`$API/db/seeds/01_base.rb:54`). No job deduplicates `events_enriched` itself:
     `CleanDuplicatedService` has no caller at the pin (only its spec); pay in advance relies on
     `already_processed?` (LC14).
     sum/max/latest/weighted read `decimal_value` (`$API/app/services/events/stores/clickhouse_store.rb:542`);
     unique_count reads the raw `value` string (`$API/app/services/events/stores/clickhouse/unique_count_query.rb:311`).
6. Charge model turns aggregated units into an amount -> fee -> invoice (`$API/app/services/fees/charge_service.rb:149`).

Current usage (`GET /customers/:id/current_usage`) runs the same aggregation path, behind the charge-usage
cache (`$API/app/services/invoices/customer_usage_service.rb:130`).

## PG-store vs CH-store at a glance

<!-- evidence-check: off summary of LC1-LC17 above; every cell names the step that carries its anchors -->
| Step | PG-store org | CH-store org |
|---|---|---|
| Event persisted for billing | Postgres `events` (LC4) | ClickHouse `events_enriched` via Go (LC13) |
| Validation / duplicate `transaction_id` | 422 at request time (LC4) | none at request time; dedup at query time, if enabled (LC17) |
| Expression | Rails (LC3) | Rails (LC3); Go only for non-`http_ruby` sources (LC9) |
| `value` used by billing | Rails reads `properties->>field_name` | Go's `value` string -> `decimal_value` |
| Wallet refresh flag, subscription activity | Sidekiq PostProcess, immediate (LC5) | Go ZADD -> clock every 10 s (LC11, LC15) |
| Pay in advance trigger | Sidekiq PostProcess (LC5) | Go topic -> Karafka, +15 s (LC11, LC14) |
| Charge-usage cache invalidation | eager, unless `lazy_charge_usage_cache` (LC5) | event-driven only through `lazy_charge_usage_cache`; otherwise an entry lives until the period end (`reference/glossary-extended.md`; `rails-go-parity`, pinned-SHA drift) |
| Does events-processor matter for billing? | No (it still runs and writes CH, LC10) | Yes, on every step from LC8 |
<!-- evidence-check: on -->
