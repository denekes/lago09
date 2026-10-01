# Extended glossary: second-tier terms

Read this when a term is not in SKILL.md section 2: filter internals, caches, re-enrichment, flags,
dev seed data. Same conventions as SKILL.md (`$API` = pinned lago-api checkout; every `path:line` is
asserted by `scripts/lifecycle-check.sh`). Verified 2026-10-01.

## Charge filters at billing time

| Term | Meaning here | Where |
|---|---|---|
| Default bucket | The fee for events of a filtered charge that match NONE of its filters. Built on the fly as an unsaved `ChargeFilter.new` with the charge's own properties. | `$API/app/services/fees/charge_service.rb:86` |
| matching_filters / ignored_filters | At query time a filter's fee = events matching its own `{key => values}` (AND) minus events that belong to more specific "child" filters (OR of NOTs). The default bucket excludes every filter. | `$API/app/services/events/billing_period_filters/matching_and_ignored_service.rb:14` |
| Event-time filter choice | For one event (pay in advance, PG enriched_events), Rails picks ONE filter: all keys present, value `to_s` in the list, most keys wins, ties go to the oldest `updated_at`. | `$API/app/services/events/billing_period_filters/event_matching_service.rb:19`, `$API/app/services/events/billing_period_filters/event_matching_service.rb:29`, `$API/app/models/charge_filter.rb:22` |
| pricing_group_keys (legacy `grouped_by`) | Property keys that split one charge or filter fee into several grouped fees. Go reads the column but never uses it. | `$API/app/models/charge.rb:68`, `events-processor/models/charges.go:15` |
| regroup_paid_fees | For in-advance, non-invoiceable charges: collect the paid standalone fees onto an invoice later. | `$API/app/models/charge.rb:145` |
| accepts_target_wallet / `target_wallet_code` | A charge flag plus an event property that sends consumption to a named wallet. Rails checks it only for PG-store orgs (PostProcess); Go stopped handling it in `d9c32b6`. | `$API/app/models/charge.rb:27`, `$API/app/services/events/post_process_service.rb:114` |

## Caches, flags and derived state

| Term | Meaning here | Where |
|---|---|---|
| Charge-usage cache | Rails cache of computed current-usage fees per (charge, subscription, filter). Key embeds `charge.updated_at` and `filter.updated_at`. Go expired these keys until `2fd8e8b`. | `$API/app/services/subscriptions/charge_cache_service.rb:57` |
| `lazy_charge_usage_cache` | Org feature flag: validate the charge-usage cache lazily (against the newest event) instead of expiring it per event. After `2fd8e8b` it is the only event-driven invalidation for CH-store orgs; without it an entry lives until the end of the charge period or a charge/filter update (code-read; impact depends on OPEN DECISION OD-8 (owner)). | `$API/app/services/subscriptions/charge_cache_service.rb:85`, `$API/app/services/events/post_process_service.rb:85`, `$API/app/services/subscriptions/charge_cache_middleware.rb:58` |
| Current usage | Usage of the open period, computed on request through the same aggregation path, behind the charge-usage cache. | `$API/app/services/invoices/customer_usage_service.rb:130` |
| Lifetime usage | Running usage total across periods; drives progressive billing and lifetime alerts. | `$API/app/services/usage_monitoring/process_subscription_activity_service.rb:31` |
| SubscriptionActivity | Marker row "this subscription received usage; re-check lifetime usage and alerts". Written only with a premium licence and for `active` subscriptions. | `$API/app/services/usage_monitoring/track_subscription_activity_service.rb:17`, `$API/app/services/usage_monitoring/track_subscription_activity_service.rb:18` |
| Premium | `License.premium?`. Gates subscription activity, alert processing and wallet refresh. Without it, refresh flags change nothing. | `$API/app/jobs/clock/refresh_wallets_ongoing_balance_job.rb:8` |
| `clickhouse_deduplication_enabled` | Org boolean. When true (and CH-store), aggregation reads `events_enriched FINAL`; when false it reads rows as stored, duplicates included. | `$API/app/services/billable_metrics/aggregations/base_service.rb:168` |
| `postgres_enriched_events` | Org feature flag: Rails also writes Postgres `enriched_events` (one row per charge/filter) for PG-store orgs. | `$API/app/services/events/post_process_service.rb:95` |
| `enriched_events_aggregation` | Org feature flag: aggregate from `ClickhouseEnrichedStore` (the expanded table). The commit `d9c32b6` states it is "off everywhere". | `$API/app/services/events/stores/store_factory.rb:41` |
| `pre_filter_events` | Org boolean: resolve charges/filters from `events_enriched_expanded`. Go stopped feeding that table in `d9c32b6`; production state is OPEN DECISION OD-8 (owner). | `$API/app/services/events/billing_period_filters/charges_resolver.rb:14` |
| `enriched_at` | ClickHouse insert time of an `events_enriched` row (`now64(3)` since the 20260727090000 migration). | `$API/db/clickhouse_migrate/20260727090000_set_events_enriched_at_default_to_now64.rb:15` |

## Tables, topics and tooling

| Term | Meaning here | Where |
|---|---|---|
| `events_charged_in_advance` | Topic Go writes for CH-store pay-in-advance events; consumed by Rails Karafka. | `events-processor/processors/events_processor/processor.go:123`, `$API/karafka.rb:51` |
| `events_enriched_expanded` | Per-charge/filter fan-out table. No longer fed by Go (`d9c32b6`), still read by the pinned Rails through `ClickhouseEnrichedStore`. | `$API/app/services/events/stores/clickhouse_store.rb:133` |
| `events_aggregated` | Former ClickHouse AggregatingMergeTree pre-aggregation; created in migration 20250814130828 and dropped in 20251202134733. | `$API/db/clickhouse_migrate/20251202134733_drop_events_aggregated.rb:9` |
| Re-enrichment | Rails replays a subscription's `events_raw` rows (deduplicated with `LIMIT 1 BY transaction_id, timestamp`) to the raw topic, with `source: http_ruby` and `api_post_processed: true`. Properties come back as strings. | `$API/app/services/events/stores/clickhouse/re_enrich_subscription_events_service.rb:58`, `$API/app/services/events/stores/clickhouse/re_enrich_subscription_events_service.rb:89` |
| Post-validation | Hourly Rails job that scans the last hour of PG events and, for orgs with a webhook endpoint, sends an `events.errors` webhook (unknown code, missing or non-numeric property, invalid filter values). Disabled by `LAGO_DISABLE_EVENTS_VALIDATION`. CH-store events are not in Postgres, so they are never post-validated (code-read). | `$API/clock.rb:176`, `$API/app/jobs/clock/events_validation_job.rb:20` |
| Events DB role | PG `Event` rows live behind the `events` connection role (same database URL unless configured otherwise). | `$API/app/models/events_record.rb:6` |
| Debezium CDC | Postgres logical-replication stream that feeds Go's memory cache in `LAGO_USE_MEMORY_CACHE=true` mode. The repo config lacks `recurring` and `pay_in_advance` columns. Production use: OPEN DECISION OD-1 (owner). Details: `architecture-contract`. | `extra/debezium_config.json:2` |
| Dev seed orgs | `db:seed` creates "Hooli" (PG-store, id `11111111-2222-3333-4444-555555555555`) and, when `LAGO_CLICKHOUSE_ENABLED == "true"`, "Hooli Clickhouse" (CH-store, id `22222222-3333-4444-5555-666666666666`). The dev env sets it to `true`. | `$API/db/seeds/01_base.rb:41`, `.env.development.default:7` |
| Product-catalog plans | `plans.pricing_type` `legacy` vs `product_catalog` (rate cards). Newer model; not involved in the event path. | `$API/app/models/plan.rb:50` |
