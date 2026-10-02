# Extended glossary: second-tier terms

Read this when a term is not in SKILL.md section 2: filter internals, caches, re-enrichment, flags,
dev seed data. Same conventions as SKILL.md (`$API` = pinned lago-api checkout; every `path:line` is
asserted by `scripts/lifecycle-check.sh`). Verified 2026-10-01 (events-processor `5308258`, lago-api at the
pin `591ae90`).

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

## Money and rounding (kit-executed)

Read this before you compare amounts across fees, taxes, invoices, credit notes or wallets: the totals do not add up
by construction. Every row was EXECUTED on 2026-10-02 by the `billing-engine-spec` vectors named in it (lago-api at
the pin); `RBD-n` is the kit's rebuild decision (`reimplementation-kit`). Misconception summary: SKILL.md MC20, MC21.

| Term | Meaning here | Where |
|---|---|---|
| Half away from zero | The rounding of money, metric rounding and expression `round`, on exact decimals, negatives included: 0.125 EUR → 13 cents, -0.125 EUR → -13 cents, 0.135 → 14 (a decimal tie, not a binary one). RBD-95. | `$API/app/services/fees/charge_service.rb:290`; vectors `domain.money.to_minor_units.003`, `.004` |
| `amount_cents` vs `precise_amount_cents` | A fee stores the rounded minor-unit amount and the unrounded decimal next to it; later steps (taxes, credit notes) mostly start from the precise one. | `$API/app/services/fees/charge_service.rb:292`; vector `pricing.fee_money.001` |
| `unit_amount_cents` | Truncated toward zero, not rounded: a unit amount of 0.0199 EUR is stored as 1 cent, while `amount_cents` rounds half away from zero. RBD-47. | `$API/app/services/fees/charge_service.rb:293` (decimal into an integer column); vectors `pricing.fee_money.001`, `.007` |
| Applied tax row vs fee tax total | Each applied-tax row is rounded; the fee's `taxes_amount_cents` is the rounded sum of the UNROUNDED rows, so rows can disagree with the total (two 10 % taxes on 15 cents: rows 2 + 2, total 3; three on 14 cents: rows 1 + 1 + 1, total 4). RBD-69. | `$API/app/services/fees/apply_taxes_service.rb:40`, `$API/app/services/fees/apply_taxes_service.rb:51`; vectors `domain.money.fee_taxes.001`, `.005` |
| Invoice tax total | The rounded sum of unrounded per-fee contributions, not the sum of fee taxes (four 1-cent fees at 40 %: each fee tax 0, invoice tax 2). The taxable base on an invoice tax row is truncated to whole cents while the tax uses the fraction. RBD-69. | `$API/app/services/invoices/apply_taxes_service.rb:44`; vectors `invoice.totals.016`, `invoice.totals.001`, `invoice.apply_taxes.005` |
| Wallet credit snapping | Paid and granted (invoiceable) credits are converted to money, rounded to the currency, and converted back, so they snap to whole minor units (1034 credits at 0.001 EUR become 1030); voided (non-invoiceable) credits keep their count while the money rounds. Conversions divide in binary floating point. RBD-81. | `$API/app/models/wallet_credit.rb:26`, `$API/app/models/wallet_credit.rb:32`; vectors `wallets.credits.001`, `.002`, `.004`, `wallets.top_up.015` |
| Credit-note rounding | A credit note whose items and total differ by one cent is accepted and adjusted so sub-total + taxes = total; automatic items are truncated to 5 decimals; the note that credits the remaining amount absorbs the tax residue of earlier notes (rows are not adjusted). RBD-75. | `$API/app/services/credit_notes/adjust_amounts_with_rounding_service.rb:13`, `$API/app/services/credit_notes/create_service.rb:278`; vectors `credit_notes.compute.011`, `credit_notes.termination.002`, `credit_notes.compute.002` |
| Float islands | Steps computed with limited precision before rounding, mostly binary floating point: tax `fdiv`, coupon percentages (17.5 % of 180 cents = 31, exact 32), creditable amounts (12.999999999999998), single-day subscription price and proration, package counts; prorated aggregation ratios use a database decimal ceiled to 5 places (3.1 x 11/31 → 1.10001). RBD-96 (umbrella of RBD-42, 43, 46, 52, 55, 68). | `$API/app/services/fees/apply_taxes_service.rb:37`; vectors `invoice.coupon_amount.010`, `invoice.available_to_credit.006`, `aggregation.prorated.island.001`; tag `float-island` in the kit |

## Tables, topics and tooling

| Term | Meaning here | Where |
|---|---|---|
| `events_charged_in_advance` | Topic Go writes for CH-store pay-in-advance events; consumed by Rails Karafka. | `events-processor/processors/events_processor/processor.go:123`, `$API/karafka.rb:51` |
| `events_enriched_expanded` | Per-charge/filter fan-out table. No longer fed by Go (`d9c32b6`), still read by the pinned Rails through `ClickhouseEnrichedStore`. | `$API/app/services/events/stores/clickhouse_store.rb:133` |
| `events_aggregated` | Former ClickHouse AggregatingMergeTree pre-aggregation; created in migration 20250814130828 and dropped in 20251202134733. | `$API/db/clickhouse_migrate/20251202134733_drop_events_aggregated.rb:9` |
| Re-enrichment | Rails replays a subscription's `events_raw` rows (deduplicated with `LIMIT 1 BY transaction_id, timestamp`) to the raw topic, with `source: http_ruby` and `api_post_processed: true`. Properties come back as strings. It re-reads `events_raw`, not the DLQ: no DLQ replay tool exists (ADR-001, DECIDED OD-2 (owner, 2026-10-02), specifies an operator-gated DLQ -> raw-topic replay tool: CANDIDATE until built, `event-accounting-campaign`). | `$API/app/services/events/stores/clickhouse/re_enrich_subscription_events_service.rb:58`, `$API/app/services/events/stores/clickhouse/re_enrich_subscription_events_service.rb:89` |
| Post-validation | Hourly Rails job that scans the last hour of PG events and, for orgs with a webhook endpoint, sends an `events.errors` webhook (unknown code, missing or non-numeric property, invalid filter values). Disabled by `LAGO_DISABLE_EVENTS_VALIDATION`. CH-store events are not in Postgres, so they are never post-validated (code-read). | `$API/clock.rb:176`, `$API/app/jobs/clock/events_validation_job.rb:20` |
| Events DB role | PG `Event` rows live behind the `events` connection role (same database URL unless configured otherwise). | `$API/app/models/events_record.rb:6` |
| Debezium CDC | Postgres logical-replication stream that feeds Go's memory cache in `LAGO_USE_MEMORY_CACHE=true` mode. The repo config lacks `recurring` and `pay_in_advance` columns. Production runs memory-cache mode (DECIDED OD-1 (owner, 2026-10-02)); whether the production connector uses this column list is OPEN DECISION OD-1b (owner). Details: `architecture-contract`. | `extra/debezium_config.json:2` |
| Dev seed orgs | `db:seed` creates "Hooli" (PG-store, id `11111111-2222-3333-4444-555555555555`) and, when `LAGO_CLICKHOUSE_ENABLED == "true"`, "Hooli Clickhouse" (CH-store, id `22222222-3333-4444-5555-666666666666`). The dev env sets it to `true`. | `$API/db/seeds/01_base.rb:41`, `.env.development.default:7` |
| Product-catalog plans | `plans.pricing_type` `legacy` vs `product_catalog` (rate cards). Newer model; not involved in the event path. | `$API/app/models/plan.rb:50` |
