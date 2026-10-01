# Payload schemas across the Rails / Go / ClickHouse boundary (field by field)

Read this when you add, rename, retype or stop sending a field on any of the four topics, when a
consumer "silently ignores" data, or when you write a producer other than Rails. Facts verified
2026-10-01 at events-processor `5308258` and `$API` = lago-api `591ae90`
(`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`).
Wire samples below are real output of `scripts/run-probe.sh value` (section "wire").
ClickHouse behaviour is from `scripts/ch-decimal-probe.sh` on ClickHouse 26.2.9.9 with default
settings; production ClickHouse version and settings are UNVERIFIED.

Topic env names (both sides): `LAGO_KAFKA_RAW_EVENTS_TOPIC`, `LAGO_KAFKA_ENRICHED_EVENTS_TOPIC`,
`LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC`, `LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC`
(`events-processor/processors/main_processor.go:32-36`; dev values `.env.development.default:78-86`:
`events-raw` with a hyphen, `events_enriched`, `events_charged_in_advance`, `events_dead_letter`).
Any field change here is a cross-repo contract change: change-control N6 (paired lago-api PR, OPEN
DECISION OD-4 (owner)), and a versioned topic if the format changes incompatibly.

## 1. Raw event (topic `LAGO_KAFKA_RAW_EVENTS_TOPIC`)

Producers: Rails `Events::KafkaProducerService#build_payload` (`$API/app/services/events/kafka_producer_service.rb:36-54`,
for PG-store AND CH-store orgs, `$API/app/services/events/create_service.rb:39`, only if both
`LAGO_KAFKA_BOOTSTRAP_SERVERS` and `LAGO_KAFKA_RAW_EVENTS_TOPIC` are non-blank, `kafka_producer_service.rb:16-17`); Rails
re-enrichment (`$API/app/services/events/stores/clickhouse/re_enrich_subscription_events_service.rb:73-93`);
Redpanda Connect mappings `connectors/http.yml:25-36`, `connectors/kinesis.yml:31-42`, `connectors/sqs.yml:27-38`.
Consumers: Go `models.Event` (`events-processor/models/event.go:12-27`, unmarshalled at
`events-processor/processors/events_processor/processor.go:50`); ClickHouse `events_raw_queue`
(`$API/db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:14-24`) → `events_raw_mv`
(`20231030163703_create_events_raw_mv.rb:11,13`).

<!-- evidence-check: off field table; sources are the file:line ranges in the paragraph above, wire samples, and probe sections named in cells -->
| Field | Rails API producer | Rails re-enrichment | connectors/*.yml | Go `models.Event` | CH `events_raw_queue` | Notes |
|---|---|---|---|---|---|---|
| `organization_id` | `organization.id` | `event.organization_id` | `this.event.organization_id` (http) or env `${ORGANIZATION_ID}` (kinesis, sqs) | `string` | `String` | |
| `external_customer_id` | `event.external_customer_id` | same | absent | **not modelled** | `String` NOT NULL (absent → `''`) | Go drops it; the DLQ copy loses it too |
| `external_subscription_id` | yes | yes | yes | `string` | `String` | |
| `transaction_id` | yes | yes | yes | `string` | `String` | |
| `timestamp` | `event.timestamp.to_f.to_s` (`"1741007009.123"`) | `strftime("%s.%3N")` (`:82`) | client value as sent (string or number; may be RFC3339) | `any`; parsed by `utils.ToFloat64Timestamp` + `utils.ToTime` (`events-processor/models/event.go:70-81`) | `String` → MV `toDateTime64(timestamp, 3)` | RFC3339 with `Z`/offset: Go accepts (since `76c1b3b`), the CH raw MV raises `CANNOT_PARSE_TEXT` (probe R) |
| `code` | yes | yes | yes | `string` | `String` | |
| `precise_total_amount_cents` | `.to_s`, default `"0.0"` (`:46`) | same | JSON number passed through; anything else becomes `"0"` | `string` | `Nullable(Decimal(40,15))` | A JSON **number** fails Go unmarshal → record committed, no DLQ (probe: `json: cannot unmarshal number into Go struct field Event.precise_total_amount_cents of type string`). A string amount from a connector client becomes `"0"` |
| `properties` | `event.properties` (expression already applied) | `JSON.parse` of `events_raw.properties` → every value is a **string** | client JSON | `map[string]any` (numbers → `float64`) | `String` → MV `JSONExtract(properties, 'Map(String, String)')` | Number fidelity lost above 2^53 in Go |
| `ingested_at` | `Time.zone.now.iso8601(3)[...-1]` → `"2025-03-03T13:03:30.456"` (UTC: no `config.time_zone` in `$API/config`) | same (`:86`) | `timestamp_unix()` → JSON integer seconds | `utils.CustomTime`: layout `2006-01-02T15:04:05` (fraction accepted), else `ToTime` (`events-processor/utils/time.go:82-101`) | `DateTime64(3)` | CH reads a JSON **integer** as milliseconds: connector `1741007010` → `1970-01-21 03:36:47.010` in `events_raw` (probe R; Kafka-engine settings in production UNVERIFIED). Go reads it correctly |
| `source` | `"http_ruby"` (`:7,49`) | `"http_ruby"` | absent | `string` (`omitempty`) | skipped (`input_format_skip_unknown_fields=1`) | Absent ⇒ Go treats the event as not post-processed and evaluates expressions |
| `source_metadata` | `{api_post_processed: !organization.clickhouse_events_store?}` (`:50-52`) | `{api_post_processed: true, reprocess: <bool>}` (`:88-91`) | absent | `*SourceMetadata{api_post_processed}` (`reprocess` ignored since `d9c32b6`) | skipped | |
| Kafka key | none (`:29-34`) | none (`:66-71`) | `<org>-<external_subscription_id>` (`connectors/http.yml:43`, `kinesis.yml:49`, `sqs.yml:45`) | not read | not read | No consumer depends on raw keys |
<!-- evidence-check: on -->

## 2. Enriched event (topic `LAGO_KAFKA_ENRICHED_EVENTS_TOPIC`)

Producer: Go `EventProducerService.ProduceEnrichedEvent` (`events-processor/processors/events_processor/event_producer_service.go:29-38`),
for every successfully enriched event, with or without a subscription (`processor.go:110-113`).
Key: `<organization_id>-<transaction_id>` (`:30`, since `731e18f`).
Consumer: ClickHouse `events_enriched_queue` (`$API/db/clickhouse_migrate/20240705084952_create_events_enriched_queue.rb:14-23`)
→ `events_enriched_mv` (`20240705085501_create_events_enriched_mv.rb:6-15`) → `events_enriched`
(`20240705080709_create_events_enriched.rb:5-35`; cloud DDL `cloud/02_events_enriched.sql:1-18`).

Wire sample (BM sum on `amount`, no subscription):
`key="org-probe-tx-wire"`
`{"organization_id":"org-probe","external_subscription_id":"sub-probe","subscription_id":"","plan_id":"","transaction_id":"tx-wire","code":"probe_sum","aggregation_type":"sum","properties":{"amount":9007199254740992,"region":"eu"},"precise_total_amount_cents":"0.0","source":"http_ruby","value":"9.007199254740992e+15","timestamp":1741007009.123}`
(input `amount` was `9007199254740993`).

<!-- evidence-check: off field table; Go side is events-processor/models/event.go:34-45, CH side the migrations cited above, values from the wire sample -->
| Go JSON field (`events-processor/models/event.go:34-45`) | Go source of the value | CH queue column | CH `events_enriched` column | Rails reader |
|---|---|---|---|---|
| `organization_id` | raw | `String` | `String` (ORDER BY) | every query |
| `external_subscription_id` | raw | `String` | `String` (ORDER BY) | joined to the subscription window at query time |
| `subscription_id` | matched subscription or `""` | — (skipped) | — | none: Rails re-resolves |
| `plan_id` | matched subscription or `""` | — | — | none |
| `transaction_id` | raw | `String` | `String` (ORDER BY) | dedup identity |
| `code` | raw | `String` | `String` (ORDER BY) | |
| `aggregation_type` | `BillableMetric.AggregationType.String()` (`"sum"`) | — | — | none |
| `properties` | raw map, after Go expression evaluation for non-`http_ruby` sources | `String` | `Map(String,String)` via `JSONExtract`; numbers keep JSON text (`1000000`), `true`→`'true'`, `null`→`''`, objects → JSON text (probe E) | filters / grouping |
| `precise_total_amount_cents` | raw string | `Nullable(Decimal(40,15))` (`''`→0, probe E) | same | percentage / dynamic charges |
| `source` | raw, `omitempty` | — | — | none |
| `value` | `"1"` for count, else `fmt.Sprintf("%v", properties[field_name])` (`enrichment_service.go:111-116`) | `Nullable(String)` | `value` + `decimal_value Decimal(38,26) DEFAULT toDecimal128OrZero(value, 26)` | numeric aggregations read `decimal_value` (`$API/app/services/events/stores/clickhouse_store.rb:418` max, `:542` sum, `:598` prorated_sum, `:190` events_values); unique_count reads `value` raw (`clickhouse/unique_count_query.rb:311`) |
| `timestamp` | `float64` seconds, ms-truncated for string input (`utils/time.go:58`), untouched for float input (`:71-72`) | `String` (JSON number read as text) | `DateTime64(3)` via `toDateTime64(timestamp, 3)` | window filters |
| — | — | — | `sorted_properties DEFAULT mapSort(properties)`, `enriched_at DEFAULT now64(3)` (`20260727090000_*`) | `MAX(enriched_at)` = lazy usage-cache watermark |
<!-- evidence-check: on -->

Engine: `ReplacingMergeTree(timestamp)`, ORDER BY `(organization_id, code, external_subscription_id, toDate(timestamp), timestamp, transaction_id)`:
Go redeliveries of the same event collapse at merge / `FINAL`. A redelivery whose `value` string differs
(e.g. original `"1e+06"` vs re-enriched `"1000000"`) is still one row after merge, but which `value` wins
is the ReplacingMergeTree rule, not "the newest enrichment" (UNVERIFIED end to end).

## 3. Charged-in-advance event (topic `LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC`)

Producer: Go `ProduceChargedInAdvanceEvent` (`event_producer_service.go:40-49`), same JSON and key as §2, only when
the event has a subscription AND `NotAPIPostProcessed()` AND `HasPayInAdvanceCharge` (`processor.go:115-126`).
Consumer: Karafka group `lago_events_charged_in_advance_consumer` (`$API/karafka.rb:49-58`, registered only if
the topic env var is present; Karafka DLQ topic `unprocessed_events`, `max_retries: 1`, `:55`) →
`EventsChargedInAdvanceConsumer` → `Events::PayInAdvanceJob` delayed by `CLICKHOUSE_MERGE_DELAY = 15.seconds`
(`$API/app/consumers/events_charged_in_advance_consumer.rb:6`, `clickhouse_store.rb:11`) →
`PayInAdvanceService` → `Events::CommonFactory` Hash branch (`$API/app/services/events/common_factory.rb:9-24`).

| Key Rails reads | From Go | Rails behaviour |
|---|---|---|
| `id` | absent | `nil` ⇒ treated as Kafka-origin; skipped for PG-store orgs (`pay_in_advance_service.rb:18-24`) |
| `organization_id`, `transaction_id`, `external_subscription_id`, `code`, `properties` | yes | `properties[field_name].present?` required except count/custom (`$API/app/services/events/pay_in_advance_service.rb:59-64`) |
| `timestamp_with_precision` | absent | `Time.zone.parse(nil)` raises, rescued → `Time.zone.at(source["timestamp"].to_f)` (`$API/app/models/events/common.rb:55-65`) |
| `timestamp` | float seconds | `Time.zone.at(source["timestamp"].to_f)` (`$API/app/models/events/common.rb:62,64`) |
| `precise_total_amount_cents` | string | `BigDecimal(...)` if present (`common_factory.rb:20-22`) |
| `subscription_id`, `plan_id`, `value`, `aggregation_type`, `source` | yes | ignored: Rails re-resolves the subscription (`common.rb:33-46`) and recomputes |

Idempotency: `already_processed?` on `pay_in_advance_event_transaction_id` (`pay_in_advance_service.rb:55-57`).

## 4. Dead letter (topic `LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC`)

Producer: Go `ProduceToDeadLetterQueue` (`event_producer_service.go:51-74`), **no key**, for non-retryable
failures, retryable failures older than 12 h by `ingested_at` (`processor.go:74-82`), and enriched/in-advance
produce failures (`event_producer_service.go:87-89`, empty `error_code`). JSON unmarshal failures never reach
it (`processor.go:50-60`). Consumer: ClickHouse `events_dead_letter_queue`
(`$API/db/clickhouse_migrate/20251110130723_create_events_dead_letter_queue.rb:14-20`) → MV
(`20260430075848_update_events_dead_letter_mv.rb:7-26`) → `events_dead_letter` (plain `MergeTree`,
`20251110100317_create_events_dead_letter.rb:5-8`: duplicates are kept).

Wire sample:
`{"event":{"organization_id":"org-probe","external_subscription_id":"sub-probe","transaction_id":"tx-wire","code":"probe_sum","properties":{"amount":9007199254740992,"region":"eu"},"precise_total_amount_cents":"0.0","source":"http_ruby","timestamp":"1741007009.123","source_metadata":{"api_post_processed":false},"ingested_at":"2025-03-03T13:03:30"},"initial_error_message":"record not found","error_message":"Error fetching billable metric","error_code":"fetch_billable_metric","failed_at":"2026-10-01T20:50:47.441991473Z"}`

| Go field (`models.FailedEvent`, `event.go:50-56`) | Content | CH column / MV expression | CH result |
|---|---|---|---|
| `event` | `models.Event` **re-marshalled** (`events-processor/processors/events_processor/event_producer_service.go:52-53`), not the original bytes: no `external_customer_id`, unknown fields dropped, properties re-encoded from `float64`, `timestamp` keeps its JSON type, `ingested_at` as `2006-01-02T15:04:05` (ms dropped) or `null` | `event String` → `JSON` column; `JSONExtractString(event, 'organization_id' / 'external_subscription_id' / 'code' / 'transaction_id')` | |
| `event.timestamp` | as received | (`$API/db/clickhouse_migrate/20260430075848_update_events_dead_letter_mv.rb:13-19`) `COALESCE(toDateTime64OrNull(s,3), toDateTime64(toFloat64OrNull(s),3), toDateTime64(ingested_at,3))` | float string or number → exact; RFC3339 `Z`/offset → falls back to `ingested_at` (probe L) |
| `event.ingested_at` | `"…T13:03:30"` or `null` (`events-processor/utils/time.go:103-111`) | `toDateTime64(JSONExtractString(event,'ingested_at'), 3)` (`…_update_events_dead_letter_mv.rb:20`) | `null` → `1970-01-01 00:00:00.000` (probe L) |
| `initial_error_message` | raw error text (`ErrorMsg()`, `event_producer_service.go:54`; `events-processor/utils/result.go:51-57`) | `String` | |
| `error_message` | human message (`ErrorMessage()`, `events-processor/processors/events_processor/event_producer_service.go:56`) | `String` | |
| `error_code` | `build_enriched_event`, `fetch_billable_metric`, `evaluate_expression`, `fetch_subscription` (`enrichment_service.go:30,42,63,107`), `fetch_pay_in_advance_charge`, `flag_subscription_refresh` (`processor.go:118,130`), `""` for produce failures | `String` | |
| `failed_at` | `time.Now()` RFC3339Nano with the process zone (`events-processor/processors/events_processor/event_producer_service.go:57`) | `parseDateTime64BestEffort(failed_at)` | |

## 5. Redis refresh message (not Kafka, same contract class)

ZSET `subscription_refreshed_v2`; member `"<organization_id>:<subscription_id>|<bucket>"`; bucket =
`floor(now/10)*10`; score = `time.Now().Unix()` (processing time, not event time). Go: `events-processor/models/stores.go:54-69`,
`events-processor/processors/events_processor/subscription_refresh_service.go:22`, `main_processor.go:152`.
Rails: `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:7-38`. Full row: contract P20.
