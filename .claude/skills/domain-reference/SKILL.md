---
name: domain-reference
description: "Lago billing domain as it works in THIS repo: a glossary with code locations in the Go events-processor and the pinned lago-api (organization, customer vs user, external_subscription_id, billable metric, aggregation_type enum, field_name, expression, recurring, charge, charge filter, ALL_FILTER_VALUES, pay_in_advance, invoiceable, prorated, transaction_id, timestamp vs ingested_at, precise_total_amount_cents, http_ruby, api_post_processed, value/decimal_value, events_raw, events_enriched, wallets, alerts, subscription refresh, fees, invoices, billing period), who does what from POST /api/v1/events to invoice (Rails, Sidekiq, events-processor, ClickHouse), PG-store vs CH-store orgs, a runnable worked example and bug-causing misconceptions. Use for \"what does X mean here\", \"where is X in code\", \"who computes usage\", \"why 2e+06\", \"why not billed\". Not for Go<->Rails contracts (rails-go-parity), env vars (config-and-flags), events-processor internals (architecture-contract) or fixes (event-accounting-campaign)."
---
# Domain reference: Lago billing as it works in this repo

What a mid-level engineer or agent lacks before touching `events-processor/`: what each billing term means
in THIS code, where it lives on both sides (Go here, Rails at the pinned SHA), who does what between
`POST /api/v1/events` and an invoice, and which beliefs cause bugs. It describes; it does not prescribe fixes.
Code facts as of `5308258` (events-processor tree `83e012866f29`); the working branch may carry skills-only
commits on top. lago-api at the pin `591ae90` (2026-09-08, the `api` gitlink, v1.53.0). Verified 2026-10-01
unless marked.

## When to use / when NOT to use

Use it when you:
- need the meaning of a billing term here and its code location in both repos (section 2, `scripts/where-is.sh`);
- need to know which component performs a step of the event lifecycle, and whether the step applies to
  PG-store or CH-store organizations (section 3, `reference/lifecycle.md`);
- reason about a billed quantity, a duplicate, a subscription match or a timestamp and want the
  misconceptions first (section 5);
- onboard onto events-processor and want to see one event end to end (section 4, `scripts/worked-example.sh`).

Do NOT use it for (go to the sibling instead):
- the row-by-row Go vs Rails/ClickHouse contract, payload schemas, value/time divergence probes, the
  pinned-SHA drift list → `rails-go-parity`;
- what an env var does, its default, boolean-parsing traps (`LAGO_CLICKHOUSE_ENABLED`) → `config-and-flags`;
- events-processor internals: commit algorithm, record disposition, DB vs memory-cache mode, invariants →
  `architecture-contract`;
- fixing silent loss, value fidelity or time semantics → `event-accounting-campaign`;
- triaging a live symptom or DLQ `error_code` → `debugging-playbook`; probe harnesses → `diagnostics-and-tooling`;
- running the stack → `run-and-operate`; CGO/test environment → `build-and-env`; gates and change classes →
  `change-control`; why the code got this way → `failure-archaeology`; evidence rules → `research-methodology`.

## Terms (conventions of this skill)

- **`$API`**: pinned lago-api checkout, `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`.
  Rails citations are `$API/<path>:<line>`; repo citations are repo-relative (`events-processor/...:<line>`).
- **Actor tags**: [Rails] API web process, [Sidekiq] Rails job, [Karafka] Rails Kafka consumer, [clock] Rails
  clockwork, [EP] Go events-processor, [CH] ClickHouse (Kafka engine + materialized views), [Redis] store.
- **PG / CH / both**: a step that runs only for PG-store orgs, only for CH-store orgs, or for every org.
- **OPEN DECISION OD-n (owner)**: a question only the owner can settle (production state, schema budget).
  Do not treat it as settled; any change that depends on one goes through `change-control`'s gate.
- **Confidence labels**: VERIFIED (read or run on 2026-10-01), CANDIDATE (code-read inference, not run end
  to end), UNVERIFIED (could not be checked here).
- Every domain term is defined in section 2 or in `reference/glossary-extended.md`.

## 1. The model in one screen

```text
client ─POST /api/v1/events─► [Rails] expression, validate ─PG-store org─► Postgres events ─► [Sidekiq] PostProcess
                                 │                                          (wallet flag, alerts activity, in-advance job)
                                 └─both stores, only if Kafka env set─► raw topic (no key) ─► [CH] events_raw
                                                                            │
                                                                            ▼
                                       [EP] BM + subscription lookup, value = "%v" of properties[field_name]
                                         ├─► events_enriched ─► [CH] events_enriched (billing source of CH-store orgs)
                                         ├─► events_charged_in_advance ─► [Karafka] ─► PayInAdvanceJob   (CH-store only)
                                         ├─► Redis ZSET subscription_refreshed_v2 ─► [clock] every 10 s (CH-store only)
                                         └─► events_dead_letter (failures)
[clock] hourly ─► invoices: per subscription and period, aggregate Postgres events (PG-store)
                  or events_enriched [FINAL if dedup on] (CH-store) ─► charge model ─► fees ─► invoice
```

Five laws that hold today:
1. Rails owns every business decision: charges, filters, fees, invoices, wallets, alerts. Go enriches and
   routes; it never aggregates or prices (change-control N8).
2. One per-org boolean, `clickhouse_events_store`, picks the path; the Kafka and `LAGO_CLICKHOUSE_ENABLED`
   env vars decide whether that path actually works (section 3 table; `$API/app/services/events/create_service.rb:32`).
3. For a CH-store org, Go's `value` string IS the billed quantity (through `decimal_value`). For a PG-store
   org it is not used for billing (Rails reads the Postgres `properties`) (`$API/app/services/events/stores/clickhouse_store.rb:542`,
   `$API/app/services/events/stores/postgres_store.rb:7`).
4. At most one side post-processes each event (never both), chosen by `source` +
   `source_metadata.api_post_processed` (`events-processor/models/event.go:86`).
5. Usage is aggregated at query time over stored rows; there is no live pre-aggregation
   (`$API/app/services/fees/charge_service.rb:435`).

## 2. Glossary

Second-tier terms (filter internals, caches, flags, re-enrichment, dev seeds): `reference/glossary-extended.md`.
Find any term in both code bases: `.claude/skills/domain-reference/scripts/where-is.sh <term>`.

<!-- evidence-check: off glossary rows: the Where column carries the evidence; each anchor is asserted by scripts/lifecycle-check.sh -->
| Term | Meaning here | Where |
|---|---|---|
| Organization | The tenant: the company that uses Lago to bill ITS customers. The API key resolves to it; every Go query and cache key carries `organization_id`. | `events-processor/models/billable_metrics.go:63`, `$API/app/models/organization.rb:57` |
| Customer | The party being BILLED (the tenant's end customer). Owns subscriptions, invoices, wallets. `docs/architecture.md` has this INVERTED (below). | `$API/app/models/customer.rb:62`, `$API/app/models/customer.rb:69` |
| User | A person who LOGS IN to Lago (dashboard), linked to organizations through memberships. Never billed. `docs/architecture.md:546` and `docs/architecture.md:548` swap Customer and User: trust the models. | `$API/app/models/user.rb:6`, `$API/app/models/user.rb:12` |
| external_customer_id | The tenant's id for a customer (`customers.external_id`). On events it is legacy: `POST /api/v1/events` does not permit it, Rails sends `null`, Go drops it. | `$API/app/controllers/api/v1/events_controller.rb:172`, `$API/app/services/events/kafka_producer_service.rb:39`, `events-processor/models/event.go:12` |
| Subscription | A customer on a plan, with `started_at`/`terminated_at` and a status (pending, active, terminated, canceled, incomplete). An upgrade or downgrade creates a NEW row with the same `external_id`. Go's struct has no status. | `$API/app/models/subscription.rb:58`, `$API/app/models/subscription.rb:15`, `events-processor/models/subscriptions.go:13` |
| external_subscription_id | What an event carries. Matched to `subscriptions.external_id` plus the `[started_at, terminated_at]` window at the event timestamp; never the primary key. | `events-processor/models/subscriptions.go:32`, `$API/app/services/events/post_process_service.rb:45` |
| Plan | Price book: interval (weekly, monthly, yearly, quarterly, semiannual), subscription fee in advance or arrears, and charges. Overrides are child plans (`parent_id`). | `$API/app/models/plan.rb:42`, `$API/app/models/plan.rb:177` |
| Billable metric (BM) | What to meter: `code` + `aggregation_type` + `field_name` [+ `expression`, `recurring`, filters]. Soft-deleted; `code` unique per org among kept rows. Events reference it by `code`. | `events-processor/models/billable_metrics.go:46`, `$API/app/models/billable_metric.rb:157` |
| aggregation_type | Integer enum, same numbers in both repos: count 0, sum 1, max 2, unique_count 3, (4 = deleted recurring_count), weighted_sum 5, latest 6, custom 7. Rails names end in `_agg`; Go strings do not (`"sum"`). | `$API/app/models/billable_metric.rb:28`, `events-processor/models/billable_metrics.go:12`, `events-processor/models/billable_metrics.go:16` |
| field_name | The property that holds the number (or the unique key). Forced to nil for count; optional for custom. | `$API/app/models/billable_metric.rb:105`, `$API/app/models/billable_metric.rb:109` |
| expression | lago-expression formula whose result is written INTO `properties[field_name]` before aggregation. Rails evaluates it for API events; Go only for events whose `source` is not `http_ruby`. | `$API/app/services/events/calculate_expression_service.rb:26`, `events-processor/processors/events_processor/enrichment_service.go:132` |
| Recurring BM | Usage carries over periods (seats, storage). Not allowed with count, max, latest. A backdated event with no matching subscription falls back to the current one. | `$API/app/models/billable_metric.rb:113`, `events-processor/processors/events_processor/enrichment_service.go:57` |
| Billable metric filter | A `{key, values[]}` dimension declared on a BM (e.g. `region: [eu, us]`). Go caches these but never reads them. | `$API/app/models/billable_metric_filter.rb:3`, `events-processor/models/billable_metric_filters.go:8` |
| Charge | Prices ONE BM inside ONE plan: charge model, properties, `pay_in_advance`, `invoiceable`, `prorated`, filters. Go uses only `pay_in_advance` (it also loads `accepts_target_wallet` and `pricing_group_keys`, unused). | `$API/app/models/charge.rb:3`, `events-processor/models/charges.go:13` |
| Charge model | How units become money: standard, graduated, package, percentage, volume, graduated_percentage, custom, dynamic. Rails only. | `$API/app/models/charge.rb:29` |
| pay_in_advance (charge) | Bill each event when it arrives instead of at period end. Only count/sum/unique_count/custom BMs, never volume. | `$API/app/models/charge.rb:136`, `$API/app/models/billable_metric.rb:38`, `events-processor/models/charges.go:47` |
| invoiceable | For an in-advance charge: `true` creates an invoice per event; `false` creates a standalone fee. Must be `true` unless the charge is in advance. | `$API/app/models/charge.rb:123`, `$API/app/services/events/pay_in_advance_service.rb:26` |
| prorated | The charge is prorated by time inside the period. Recurring BMs with limited charge models only. | `$API/app/models/charge.rb:163`, `$API/app/services/billable_metrics/aggregation_factory.rb:30` |
| Charge filter | A price bucket inside a charge, defined by `{BMF key => subset of values}`. Ordered by `updated_at` ascending. Events matching no filter go to the "default bucket". | `$API/app/models/charge_filter.rb:22`, `$API/app/services/fees/charge_service.rb:86` |
| Charge filter value, ALL_FILTER_VALUES | Links a charge filter to one BMF with its chosen values. The sentinel `"__ALL_FILTER_VALUES__"` means "every value the BMF declares" and must be the only element. | `$API/app/models/charge_filter_value.rb:9`, `$API/app/models/charge_filter_value.rb:27`, `$API/app/models/charge_filter.rb:72` |
| Event | One metered occurrence: `transaction_id, external_subscription_id, code, timestamp, properties, precise_total_amount_cents`. | `$API/app/controllers/api/v1/events_controller.rb:172`, `events-processor/models/event.go:12` |
| properties | Free-form JSON. Postgres keeps JSON types; ClickHouse stores `Map(String, String)`, so numbers become strings there. | `$API/db/clickhouse_migrate/20240705085501_create_events_enriched_mv.rb:12` |
| transaction_id | Client idempotency key. PG-store: unique per `(org, external_subscription_id, transaction_id)`, duplicate = 422. CH-store: no check at ingestion; `FINAL` collapses rows equal on `(code, org, external_subscription_id, transaction_id, timestamp)` only when deduplication is enabled. In-advance fees are idempotent on it. | `$API/app/models/event.rb:95`, `$API/app/services/events/stores/clickhouse_store.rb:13`, `$API/app/services/events/pay_in_advance_service.rb:56` |
| timestamp | When usage happened (client value, or request time). Picks the subscription and the billing period. Rails sends float seconds as a string; Go truncates to ms; ClickHouse stores `DateTime64(3)`. | `$API/app/services/events/kafka_producer_service.rb:43`, `events-processor/utils/time.go:58` |
| ingested_at | When Rails produced the raw message (ms, no `Z`); connectors set integer Unix seconds instead (ClickHouse misreads them: `rails-go-parity`). Go uses it only for the 12 h retry horizon. Never used for billing. | `$API/app/services/events/kafka_producer_service.rb:48`, `connectors/http.yml:31`, `events-processor/processors/events_processor/processor.go:74` |
| precise_total_amount_cents | Optional decimal amount used by percentage/dynamic pricing. Rails sends a string (default `"0.0"`); Go declares a string, so a JSON number fails unmarshal (committed, no DLQ). | `$API/app/services/events/kafka_producer_service.rb:46`, `events-processor/models/event.go:18` |
| source, api_post_processed | `source: "http_ruby"` = produced by Rails (API or re-enrichment); connectors send none. `api_post_processed: true` = Rails already post-processed it (PG-store orgs). Go post-processes unless both hold. | `events-processor/models/event.go:86`, `$API/app/services/events/kafka_producer_service.rb:51` |
| Enriched event | Go's output: the event plus `aggregation_type`, `subscription_id`, `plan_id`, `value`, float `timestamp`. ClickHouse reads 8 of its fields and drops the rest. | `events-processor/models/event.go:29`, `$API/db/clickhouse_migrate/20240705084952_create_events_enriched_queue.rb:14` |
| value, decimal_value | `value`: Go's `fmt.Sprintf("%v", properties[field_name])`, `"1"` for count. `decimal_value`: `toDecimal128OrZero(value, 26)` in ClickHouse, what sum/max/latest/weighted aggregate. | `events-processor/processors/events_processor/enrichment_service.go:114`, `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32` |
| events_raw (CH) | ClickHouse's own copy of the raw topic. MergeTree, never deduplicated. Used by `GET /events/:id` and re-enrichment for CH-store orgs. | `$API/db/clickhouse_migrate/20231024084411_create_events_raw.rb:6`, `$API/app/controllers/api/v1/events_controller.rb:54` |
| events_enriched (CH) | Billing source of CH-store orgs, fed by Go. `ReplacingMergeTree(timestamp)`, read with `FINAL` only when the org has `clickhouse_deduplication_enabled`. | `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:6`, `$API/app/services/events/stores/clickhouse_store.rb:111` |
| events_dead_letter | Go's dead-letter topic (and ClickHouse table): the original event plus `error_code` and messages. | `events-processor/models/event.go:50`, `events-processor/processors/events_processor/processor.go:82` |
| PG-store vs CH-store org | Per-org boolean `clickhouse_events_store` (default false). New orgs get CH only if `LAGO_CLICKHOUSE_ENABLED` casts to true AND `LAGO_DEFAULT_EVENT_STORE=clickhouse`; existing orgs move with a rake recipe. | `$API/app/models/organization.rb:349`, `$API/app/services/organizations/create_service.rb:17`, `$API/lib/tasks/recipes/clickhouse.rake:109` |
| Pre-aggregation | None live: aggregation runs at query time over rows. Past attempts: `events_aggregated` (dropped) and the per-charge `events_enriched_expanded` (Go stopped feeding it in `d9c32b6`; pinned Rails still reads it when `pre_filter_events`, OPEN DECISION OD-8 (owner)). | `$API/db/clickhouse_migrate/20251202134733_drop_events_aggregated.rb:9`, `$API/app/services/events/billing_period_filters/charges_resolver.rb:14` |
| DB mode / memory-cache mode | How Go looks up BMs, subscriptions, charges: live Postgres (default, dev) or an in-memory badger store fed by Debezium CDC (`LAGO_USE_MEMORY_CACHE=true`; production use is OPEN DECISION OD-1 (owner)). | `events-processor/main.go:67`, `events-processor/processors/events_processor/enrichment_service.go:36` |
| Subscription refresh | "This subscription got usage; refresh its derived state soon." Go ZADDs `<org>:<sub>\|<10 s bucket>` to Redis ZSET `subscription_refreshed_v2`; the Rails clock pops entries at least 10 s old. It does NOT recompute usage. | `events-processor/models/stores.go:62`, `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:7` |
| Wallet, ongoing balance | Prepaid credits of a customer. `balance` = credits held; `ongoing_balance` = balance minus current not-yet-invoiced usage, recomputed asynchronously for customers flagged `awaiting_wallet_refresh`. | `$API/app/models/wallet.rb:156`, `$API/app/models/customer.rb:371` |
| Alerts | Usage monitors on a subscription (current usage amount, BM units, lifetime usage, wallet balances), evaluated by the subscription-activity clock. Premium. | `$API/app/models/usage_monitoring/alert.rb:10` |
| Usage threshold | Progressive billing: an amount threshold on a plan or subscription; crossing it issues a mid-period `progressive_billing` invoice. | `$API/app/models/usage_threshold.rb:3`, `$API/app/models/invoice.rb:92` |
| Billing period | The window a subscription is billed for, from the plan interval and `billing_time` (calendar or anniversary), computed in the CUSTOMER's timezone. Charges have their own `charges_from/to_datetime`. | `$API/app/services/subscriptions/dates_service.rb:95`, `$API/app/models/subscription.rb:68` |
| In advance vs in arrears | Subscription fee: `plan.pay_in_advance` bills at period start, else at period end. Charges: `pay_in_advance` bills per event (LC14), else usage is aggregated at period end (LC17). | `$API/app/models/plan.rb:177`, `$API/app/models/charge.rb:136` |
| Fee | One priced line: `fee_type` charge, add_on, subscription, credit, commitment, fixed_charge, product. A charge fee carries units, `events_count`, `charge_filter_id`. | `$API/app/models/fee.rb:52` |
| Invoice | Groups fees for one customer. `invoice_type` subscription, add_on, credit, one_off, advance_charges, progressive_billing. | `$API/app/models/invoice.rb:92` |
<!-- evidence-check: on -->

## 3. Event lifecycle: POST /api/v1/events -> invoice

Full step text with every anchor, the PG vs CH table and gates: `reference/lifecycle.md` (read when you
need the exact line or the switch that enables a step). Anchors are asserted by `scripts/lifecycle-check.sh`.

<!-- evidence-check: off summary of reference/lifecycle.md, where every step carries its path:line -->
| # | Actor | Store | What happens |
|---|---|---|---|
| LC1 | Rails | both | `POST /api/v1/events` (or `/batch`, max `LAGO_EVENTS_BATCH_MAX_LENGTH`, default 100). Six fields permitted. |
| LC2 | Rails | both | Timestamp parsed as BigDecimal; missing = request time. |
| LC3 | Rails | both | BM expression evaluated (integer-second timestamp); result written into `properties[field_name]`. |
| LC4 | Rails -> PG | PG | `event.save!`: validations, duplicate `transaction_id` -> 422. CH-store: nothing persisted; the single-event path validates nothing (batch does). |
| LC5 | Sidekiq | PG | PostProcess: charge-usage cache expiry, subscription activity, wallet flag, pay-in-advance job. |
| LC6 | Rails -> Kafka | both | Raw payload, no key, `source: http_ruby`, `api_post_processed = !CH`. Skipped SILENTLY without Kafka env. |
| LC7 | CH | both | `events_raw` (copy of the raw topic, never deduplicated). |
| LC8 | EP | both | Consume group `<LAGO_KAFKA_CONSUMER_GROUP>_<topic>`; bad JSON is committed with no DLQ. |
| LC9 | EP | both | Enrich: ms timestamp, BM (unknown -> DLQ), expression (non-`http_ruby` only), `value`, subscription (none -> continue). |
| LC10 | EP -> Kafka | both | `events_enriched`, key `<org>-<transaction_id>`. |
| LC11 | EP -> Kafka, Redis | CH | If a subscription matched: `events_charged_in_advance` (any in-advance charge), ZADD refresh flag. |
| LC12 | EP | both | Failure: retryable and < 12 h -> not marked for commit (re-polled only if the partition is reassigned or the process restarts before a later commit; LOST once a later offset of the partition commits); else DLQ + commit (`architecture-contract`). |
| LC13 | CH | both | `events_enriched` ReplacingMergeTree; `decimal_value = toDecimal128OrZero(value, 26)`. |
| LC14 | Karafka -> Sidekiq | CH | `PayInAdvanceJob` after 15 s -> fee or invoice. PG-store: job comes from LC5. |
| LC15 | clock -> Sidekiq | CH | Every 10 s: pop refresh ZSET -> wallet flag + subscription activity. PG-store: done in LC5. |
| LC16 | clock -> Sidekiq | both | Alerts and lifetime usage (60 s), wallet ongoing balance (300 s, only with a cache URL set). Premium. |
| LC17 | clock -> Sidekiq | both | Hourly `:10`: fees per charge/filter + default bucket; aggregate Postgres (PG) or `events_enriched` (CH; `FINAL` only with `clickhouse_deduplication_enabled`); charge model -> invoice. |
<!-- evidence-check: on -->

Which path is an org on? Decide with this table (code-read, `$API/app/services/events/create_service.rb:32`,
`$API/app/services/events/stores/store_factory.rb:38`, `$API/app/services/events/kafka_producer_service.rb:16`):

<!-- evidence-check: off decision table derived from the three anchors cited just above it -->
| `clickhouse_events_store` | `LAGO_CLICKHOUSE_ENABLED` present | Kafka env set | Ingestion writes | Billing reads | Result |
|---|---|---|---|---|---|
| false | any | no | Postgres | Postgres | classic self-host path; events-processor not involved |
| false | any | yes | Postgres + raw topic | Postgres | EP enriches, nobody bills from it |
| true | yes | yes | raw topic only | `events_enriched` | the CH path of section 1 |
| true | no | yes | raw topic only | Postgres (empty) | bills 0 (CANDIDATE, code-read, not run end to end) |
| true | any | no | nothing | n/a | API returns 200, event stored nowhere (CANDIDATE, code-read) |
<!-- evidence-check: on -->

## 4. Worked example (executed)

One event for the dev seed CH-store org "Hooli Clickhouse": BM `storage` (sum, `field_name` `gb`), client
sends `{"gb": 12.5, "region": "eu"}` at `1727787600.123`. Run it yourself:

```bash
cd "$(git rev-parse --show-toplevel)"
.claude/skills/domain-reference/scripts/worked-example.sh     # Go via go test -overlay, then clickhouse local
```

<!-- evidence-check: off rows are the output of scripts/worked-example.sh (command above); code lines per step in reference/worked-example.md -->
| Layer | What the event looks like |
|---|---|
| Raw topic (Rails, code-read) | `timestamp:"1727787600.123"` (idealized; Ruby may print `"1727787600.1230001"`, see MC17), `properties:{"gb":12.5,"region":"eu"}`, `external_customer_id:null`, `source:"http_ruby"`, `api_post_processed:false`, no key |
| `events_enriched` (Go, executed) | key `22222222-...-tx-e1`; `"value":"12.5"`, `"timestamp":1727787600.123`, `"aggregation_type":"sum"`, `subscription_id`, `plan_id` added; same JSON on `events_charged_in_advance`; Redis member `<org>:sub-2222\|<bucket>` |
| ClickHouse row (executed) | `timestamp` `2024-10-01 13:00:00.123`, `properties` `{'gb':'12.5','region':'eu'}`, `value` `12.5`, `decimal_value` `12.5` |
| Invoice (code-read) | `sum(decimal_value)` over `events_enriched` for the subscription's charge period; WITHOUT `FINAL` for this dev seed org, because the seed never sets `clickhouse_deduplication_enabled` (default false) |
<!-- evidence-check: on -->

Variants from the same run: `2000000` -> `"2e+06"` -> 2000000; missing property -> `"<nil>"` -> 0 (and a
unique_count would count it); count BM -> `"1"`; PG-store org -> enriched but no in-advance and no refresh flag;
unknown code -> `events_dead_letter` `fetch_billable_metric`, still committed. Every message, the CH table and
the code line per step: `reference/worked-example.md`.

## 5. Misconceptions that cause bugs here

<!-- evidence-check: off each row's Evidence column carries path:line or a command; anchors asserted by lifecycle-check.sh -->
| # | Belief | Reality here | Evidence |
|---|---|---|---|
| MC1 | "events-processor aggregates usage / computes invoices." | It enriches and routes. No ClickHouse client, no aggregation code. Rails aggregates at query time. | the only `clickhouse` mention in non-test Go is a comment, `events-processor/models/stores.go:97` (command in section 7); `$API/app/services/billable_metrics/aggregation_factory.rb:7` |
| MC2 | "`LAGO_CLICKHOUSE_ENABLED=false` turns ClickHouse off" (as `docs/dev_environment.md:154` says). | MIXED (owner: `config-and-flags`, `bool-semantics.sh`): the 12 `.present?`/`.blank?` sites, incl. the store factory and the refresh clock, stay ON with `"false"`; org creation (`Boolean.cast`) and 2 seed `== "true"` sites turn OFF. | `$API/app/services/events/stores/store_factory.rb:10`, `$API/clock.rb:210`, `$API/app/services/organizations/create_service.rb:17`, `$API/db/seeds/01_base.rb:41` |
| MC3 | "Customer = the Lago client, User = the billed party" (`docs/architecture.md:546`). | Inverted. Customer is billed; User logs in. | `$API/app/models/customer.rb:62`, `$API/app/models/user.rb:6` |
| MC4 | "A count BM counts events that have `field_name`." | Count ignores `field_name`: Rails nils it, Go emits `"1"` for every event. | `$API/app/models/billable_metric.rb:105`, `events-processor/processors/events_processor/enrichment_service.go:111`, worked example E5 |
| MC5 | "An event belongs to a subscription id." | It belongs to `(organization, external_subscription_id)` plus its timestamp. Upgrades reuse `external_id`; `events_enriched` has no `subscription_id` column (only the no-longer-fed `events_enriched_expanded` has one); billing filters on `external_subscription_id` + period. | `$API/app/services/events/stores/clickhouse_store.rb:120`, `$API/db/clickhouse_migrate/20240705084952_create_events_enriched_queue.rb:16` |
| MC6 | "`transaction_id` deduplicates everywhere." | PG-store: per `(org, external_subscription_id)`. CH-store: no check at ingestion; resending with a new timestamp double-counts; `FINAL` only if `clickhouse_deduplication_enabled`. | `$API/app/models/event.rb:95`, `$API/app/services/events/stores/clickhouse_store.rb:13`, `$API/app/services/billable_metrics/aggregations/base_service.rb:168` |
| MC7 | "No subscription -> the event is dropped or dead-lettered." | Go keeps enriching with an empty `subscription_id` (and skips in-advance and the refresh flag). DLQ: unknown BM, bad timestamp, expression failure at once; a retryable DB/Redis failure only once `ingested_at` is 12 h old; a failed produce to `events_enriched`/`events_charged_in_advance`. Retryable is per failure, not per `error_code` (table: `architecture-contract` section 9). | `events-processor/processors/events_processor/enrichment_service.go:66` (feature `dd75456`), `events-processor/processors/events_processor/processor.go:74`, `events-processor/processors/events_processor/event_producer_service.go:88` |
| MC8 | "`value` is the property as the client sent it." | Go `%v`: `2000000` -> `"2e+06"`, missing -> `"<nil>"`. CH: `"<nil>"` and values >= 1e12 become 0; unique_count compares raw strings. Changing Go's format is C3 + C4 with a paired lago-api PR (`change-control` N6); a CH schema change is OPEN DECISION OD-3 (owner). | `events-processor/processors/events_processor/enrichment_service.go:114`, `$API/app/services/events/stores/clickhouse/unique_count_query.rb:311`, worked example E3/E4; details `rails-go-parity` |
| MC9 | "If Go emits to `events_charged_in_advance`, a fee will be created." | Go only pre-filters. Rails re-resolves the subscription, needs the property for sum/unique_count, and is idempotent on `transaction_id`. | `$API/app/services/events/pay_in_advance_service.rb:63`, `$API/app/services/events/pay_in_advance_service.rb:56`, worked example E4 |
| MC10 | "A subscription refresh recalculates usage now." | It sets `awaiting_wallet_refresh` and a SubscriptionActivity row after >= 10 s; wallets then refresh every 300 s only if `LAGO_MEMCACHE_SERVERS` or `LAGO_REDIS_CACHE_URL` is set (and `LAGO_DISABLE_WALLET_REFRESH` is not `"true"`), alerts every 60 s, premium only. The clock job exists only if `LAGO_REDIS_STORE_URL` and `LAGO_CLICKHOUSE_ENABLED` are present. | `$API/app/services/subscriptions/flag_refreshed_service.rb:14`, `$API/clock.rb:210`, `$API/clock.rb:55` |
| MC11 | "Self-hosted Lago runs events-processor." | Only `docker-compose.dev.yml` runs it. Root `docker-compose.yml`, `deploy/*.yml` and `docker/` have no Kafka, ClickHouse or events-processor, so orgs self-hosted with these files are PG-store and EP is irrelevant to them (the public Helm chart, lago-helm-charts `d473b1e`, deploys events-processor only when `global.clickhouse.enabled`, see `run-and-operate`; managed production is invisible from here, OPEN DECISION OD-1 (owner)). | `docker-compose.dev.yml:318`; zero matches in `docker-compose.yml`, `deploy/*.yml`, `docker/runner.sh` (command in section 7) |
| MC12 | "Flipping `clickhouse_events_store` on an org is enough." | Ingestion follows the org flag alone; aggregation also needs `LAGO_CLICKHOUSE_ENABLED` present; without Kafka env the event is dropped after a 200 (section 3 table). Migrate with the rake recipe, which compares usage first. | `$API/app/services/events/create_service.rb:32`, `$API/app/services/events/stores/store_factory.rb:38`, `$API/lib/tasks/recipes/clickhouse.rake:109` |
| MC13 | "An expression gives the same result wherever it runs." | Rails passes integer-second `event.timestamp`, Go a float with ms; Go evaluates only for non-`http_ruby` sources. | `$API/app/services/events/calculate_expression_service.rb:22`, `events-processor/processors/events_processor/enrichment_service.go:104`; details `rails-go-parity` |
| MC14 | "Billing periods are UTC days." | Boundaries are shifted to the customer's applicable timezone. | `$API/app/services/subscriptions/dates_service.rb:68`, `$API/app/services/subscriptions/dates_service.rb:99` |
| MC15 | "`external_customer_id` on an event identifies the customer." | Not accepted by `POST /api/v1/events` at the pin `591ae90`; Rails sends `null`; Go drops it. The customer is reached through the subscription. | `$API/app/controllers/api/v1/events_controller.rb:172`, `$API/app/services/events/kafka_producer_service.rb:39` |
| MC16 | "Connector events (`connectors/*.yml`) behave like API events." | They bypass Rails: no `source`, so Go evaluates expressions and post-processes for ANY org; they never reach Postgres, so a PG-store org does not bill them and Rails drops Go's in-advance message for them (CANDIDATE, code-read); `precise_total_amount_cents`: any non-number (string or absent) becomes `"0"` and a JSON number is passed through, fails Go unmarshal and is committed with no DLQ record (an ERROR log line and a Sentry capture only, `events-processor/processors/events_processor/processor.go:56`); no value-preserving workaround exists through the connectors. | `connectors/http.yml:29`, `connectors/http.yml:32`, `events-processor/models/event.go:18`, `$API/app/services/events/stores/postgres_store.rb:7`, `$API/app/services/events/pay_in_advance_service.rb:23` |
| MC17 | "The timestamp string Rails puts on Kafka equals the client's." | It is `Time#to_f.to_s`. On Ruby 3.3.6, 270 of 1000 ms values print differently and 129 truncate 1 ms early in Go. lago-api pins Ruby 4.0.6: UNVERIFIED there (CANDIDATE; `rails-go-parity` P22). Owner of the fix: `event-accounting-campaign` (time semantics). | `$API/app/services/events/kafka_producer_service.rb:43`, `$API/Gemfile:6`; command in section 7 |
<!-- evidence-check: on -->

## 6. Scripts

All three are read-only on the repo (change-control N10) and run from anywhere inside it.

| Script | Purpose | Example | Expected output (2026-10-01) |
|---|---|---|---|
| `scripts/where-is.sh` | Grep a term across `events-processor/` (no tests) and `$API` `app/ db/ clock.rb karafka.rb`; curated regexes for 43 glossary terms (`--list`), CamelCase variant for other snake_case terms; `-C N`, `-m N`, `--ep`, `--api`, `--tests`, `--wide`, `-E`. | `where-is.sh ALL_FILTER_VALUES` | `== events-processor @ 5308258` (last commit touching `events-processor/`; `+dirty` if the tree differs) `(no match ...)`, then 10 `$API/...:<line>:` hits, `[10 matching lines]`; exit 0 (1 = no hit anywhere, 2 = usage error, invalid regex or checkout error) |
| `scripts/lifecycle-check.sh` | Assert every `path:line` cited in this skill against `scripts/anchors.tsv`; report MOVED (with the new line), CHANGED, GONE, UNASSERTED, STALE. `--emit` regenerates the table from current code (review every row first); `--table F` checks another table. | `lifecycle-check.sh` | `lifecycle-check: 206 anchors OK, 0 problem(s); events-processor @ 5308258, lago-api @ 591ae90`; exit 0 (1 = drift, 2 = setup) |
| `scripts/worked-example.sh` | Section 4: seven raw events through the real `ProcessEvents` (`go test -overlay`, memory cache, miniredis) and the ClickHouse queue/MV expressions (`clickhouse local` from the cache that `diagnostics-and-tooling`'s `ch-local.sh --path` fills; SKIP, never a download, if no binary). 15 Go + 5 CH checks. | `worked-example.sh` | `CHECK ok ...` x20, `RESULT: all checks matched`; exit 0 (1 = behaviour changed, 2 = CGO/build error). `--no-ch`, `--raw`, `--ch-bin PATH` |

## 7. Provenance and maintenance

- Sources: `events-processor/` (models, processors, utils, config/kafka, main.go); `$API` at `591ae90`
  (`app/controllers/api/v1/events_controller.rb`, `app/services/events/*`, `app/services/events/stores/*`,
  `app/models/{organization,customer,user,subscription,plan,billable_metric,charge,charge_filter,charge_filter_value,fee,invoice,wallet}.rb`,
  `clock.rb`, `karafka.rb`, `db/clickhouse_migrate/*`, `db/seeds/01_base.rb`); `docs/architecture.md`,
  `docs/dev_environment.md`, `connectors/*.yml`, compose files. Commits: `d9c32b6` (#797, flat filters and
  expanded topic removed), `2fd8e8b` (#766, Go stops expiring charge cache), `b4ad153` (#768, recurring
  fallback), `dd75456` (#512, keep enriching without subscription), `d1c1629` (#496, `source_metadata`),
  `3dae52f` (#567, expanded producer added), `8ceca4b` (#740, deleted BMs filtered).
- Volatile facts and one-line re-verification (from repo root):
  - every anchor still holds: `.claude/skills/domain-reference/scripts/lifecycle-check.sh` -> `0 problem(s)`
  - worked example unchanged: `.claude/skills/domain-reference/scripts/worked-example.sh | tail -n1` -> `RESULT: all checks matched`
  - pinned lago-api: `git ls-tree HEAD api` -> `591ae9005110...` (as of 2026-10-01)
  - aggregation enum: `API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api); sed -n 28,37p "$API/app/models/billable_metric.rb"; sed -n 11,20p events-processor/models/billable_metrics.go` -> 0,1,2,3,(4 gap),5,6,7 on both sides
  - docs glossary still inverted: `sed -n 546,548p docs/architecture.md` -> "Customer ... operates", "User ... billed"
  - no ClickHouse in Go: `grep -rniE clickhouse --include=*.go events-processor | grep -v _test.go | wc -l` -> `1`
  - self-host has no EP: `grep -cE 'KAFKA|events-processor|clickhouse' docker-compose.yml deploy/*.yml docker/runner.sh` -> `:0` for each file
  - Ruby timestamp drift (CANDIDATE, needs `ruby`; MC17): `ruby -rbigdecimal -e 'n=(0..999).count{|m| f=Time.at(BigDecimal(format("1727787600.%03d",m))).to_f.to_s.to_f; (f*1000).truncate%1000!=m}; puts n'` -> `129` on Ruby 3.3.6
- Update triggers: an `api` gitlink bump (release PR); any change to `events-processor/models/event.go`,
  `models/{subscriptions,charges,stores,billable_metrics}.go`, `processors/events_processor/*.go`; a lago-api change
  to events services, stores, ClickHouse migrations, `clock.rb` or `karafka.rb`; a fix of `docs/architecture.md`'s
  glossary; owner answers on OPEN DECISION OD-1, OD-3 or OD-8; `lifecycle-check.sh` or `worked-example.sh` exiting 1.
