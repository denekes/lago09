# Topology and naming: topics, groups, keys, payloads, downstream readers

Code facts as of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only commits on
top. Verified 2026-10-01, with lago-api at the pin `591ae90` (2026-09-08)
(`API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api)`). Regenerate the topic part with
`.claude/skills/architecture-contract/scripts/topic-map.sh`.

## 1. Kafka topics the events-processor touches

| Env var (read in `events-processor/processors/main_processor.go`) | Role | Line | Dev value (`.env.development.default`) | Created in dev by `redpandacreatetopics` | Record key | Payload |
|---|---|---|---|---|---|---|
| `LAGO_KAFKA_RAW_EVENTS_TOPIC` | consume | 171 | `events-raw` (line 78; hyphen, unlike the others) | yes (`docker-compose.dev.yml:398-405`) | none from Rails; `<org>-<ext_sub>` from connectors | `models.Event` (`events-processor/models/event.go:12-23`) |
| `LAGO_KAFKA_ENRICHED_EVENTS_TOPIC` | produce | 118 | `events_enriched` (79) | yes | `<organization_id>-<transaction_id>` (`event_producer_service.go:30`) | `models.EnrichedEvent` (`models/event.go:29-48`) |
| `LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC` | produce | 123 | `events_charged_in_advance` (85) | yes | `<organization_id>-<transaction_id>` (`event_producer_service.go:41`) | same `EnrichedEvent` JSON |
| `LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC` | produce | 128 | `events_dead_letter` (86) | yes | **none** (`event_producer_service.go:66-68`) | `models.FailedEvent` (`models/event.go:50-56`) |

All four names come only from env vars; there is no default in code. The three produced topics are required
(`initProducer`, `main_processor.go:55-76`, panics if empty, then `Ping`s the broker). The raw topic is **not
validated**: empty means the process starts and idles (verified, `startup-contract.sh` step SK9).

Producers of the raw topic (who writes what EP reads):
- Rails `Events::KafkaProducerService` (`$API/app/services/events/kafka_producer_service.rb:29-34` no key, `:43`
  `timestamp: event.timestamp.to_f.to_s`, `:48` `ingested_at: …iso8601(3)[...-1]`, `:49-52` `source: "http_ruby"`,
  `source_metadata.api_post_processed = !organization.clickhouse_events_store?`).
- Rails `ReEnrichSubscriptionEventsService` (`$API/app/services/events/stores/clickhouse/re_enrich_subscription_events_service.rb:63`).
- Redpanda Connect configs `connectors/{http,sqs,kinesis}.yml` write to `${KAFKA_TOPIC}` (different variable name)
  with key `<organization_id>-<external_subscription_id>` (`connectors/http.yml:42-43`), integer-seconds `ingested_at`
  (`timestamp_unix()`, `:31`; EP accepts it; ClickHouse `events_raw` reads it as ms, 1970-01-2x: `rails-go-parity`)
  and a `precise_total_amount_cents` that stays a JSON number when given as one (`:32-33`) — EP declares that field
  `string`, so such records fail to unmarshal (see SKILL.md loss L2) — and is replaced by the string `"0"` otherwise
  (`:34-36`; same mapping in `connectors/sqs.yml:34-38` and `connectors/kinesis.yml:38-42`). No connector path
  preserves the value: a number is dropped by EP, anything else becomes `"0"` (fix plan: `event-accounting-campaign` W2).
Payload field semantics and Rails/CH parity: `rails-go-parity`, `domain-reference`.

## 2. Consumer groups

| Group id | Built at | Value in dev | Offsets |
|---|---|---|---|
| `<LAGO_KAFKA_CONSUMER_GROUP>_<LAGO_KAFKA_RAW_EVENTS_TOPIC>` | `config/kafka/consumer.go:237` | `lago_dev_events-raw` | manual commit; a **new** group starts at the earliest offset (franz-go default `resetOffset: NewOffset().AtStart()`, `franz-go@v1.20.5/pkg/kgo/config.go:578`; observed `"input":{"events-raw":{"0":{"At":-2,…}}}` in the startup log) |
| `lago_evp_<model>_<uuid>` × 6 (memory-cache mode only) | `cache/consumer.go:27` | n/a (dev runs DB mode) | fresh UUID per process start ⇒ full replay of each CDC topic from the earliest retained offset, and 6 orphan groups left on the broker per restart |
| `$LAGO_KAFKA_CLICKHOUSE_CONSUMER_GROUP` (ClickHouse Kafka engines, not EP) | `$API/db/clickhouse_migrate/*_queue.rb:10` | `clickhouse` | owned by ClickHouse; broker list and topic are baked into the DDL at migration time |
| `lago_events_charged_in_advance_consumer` (Karafka, not EP) | `$API/karafka.rb:51` | — | Rails |

Consequence (load-bearing): renaming `LAGO_KAFKA_CONSUMER_GROUP` **or** the raw topic changes the group id, and the
new group re-processes the whole retained raw topic (duplicates are absorbed downstream only where ClickHouse dedup is
on, invariant I12 CONDITIONAL).

## 3. Memory-cache CDC topics (only with `LAGO_USE_MEMORY_CACHE=true`; OPEN DECISION OD-1)

Topic = `$LAGO_DEBEZIUM_TOPIC_PREFIX` + `.public.<table>` (constants `cache/<model>.go:15`, `cache/subscriptions.go:18`).
The prefix is not validated: empty gives topics `.public.billable_metrics` etc. (verified, `startup-contract.sh` S6).
Reference connector config `extra/debezium_config.json`: `topic.prefix` `lago_proc_cdc` (line 47), six tables
(line 41), column whitelist (line 2), `snapshot.mode: no_data` (line 39), unwrap SMT with
`delete.handling.mode: rewrite` (lines 48-54). The events-processor `README.md` example uses `lago_dbz` instead.
Whether production uses this file is unknown (OD-1). Details: `memory-cache.md`.

## 4. Redis

| Item | Value | Where |
|---|---|---|
| Key | `subscription_refreshed_v2` (sorted set) | `processors/main_processor.go:152` |
| Member | `<organization_id>:<subscription_id>|<floor(now_unix/10)*10>` | `processors/events_processor/subscription_refresh_service.go:22`, `models/stores.go:54-69` |
| Score | processing wall clock (unix seconds), **not** the event timestamp | `models/stores.go:55,61` |
| Bucket | `SUBSCRIPTION_BUCKET_DURATION int64 = 10` | `models/stores.go:16` |
| TTL | none; Rails removes members after reading them | `$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:26-37` |
| Reader | `Clock::ConsumeSubscriptionRefreshedQueueJob` every 10 s, scheduled only if `LAGO_REDIS_STORE_URL` and `LAGO_CLICKHOUSE_ENABLED` are present | `$API/clock.rb:210-215` |
| Rails parse | `value.split("|").first.split(":").last` = subscription id | `consume_subscription_refreshed_queue_service.rb:32` |
| Connection | `LAGO_REDIS_STORE_URL` (`redis://`/`rediss://` prefix stripped, does NOT enable TLS), `_PASSWORD`, `_DB`, `_TLS` (default `ENV=="production"`) | `main_processor.go:78-100`, `config/redis/redis.go:25-48` |

This is a cross-repo contract: change only with lago-api, versioned key, planned deploy order
(change-control N6, OPEN DECISION OD-4: paired lago-api PR). History: `7421650` (SADD on `subscription_refreshed`)
→ `42615c9` (bucketed ZADD on `_v2`) → `fb6401d` (bucket 15 s → 10 s).

## 5. Downstream readers at the pinned lago-api SHA

| Topic | Reader | Evidence (`$API/…`) |
|---|---|---|
| enriched | ClickHouse Kafka engine `events_enriched_queue` → `events_enriched_mv` → `events_enriched` `ReplacingMergeTree(timestamp)`, ORDER BY (organization_id, code, external_subscription_id, toDate(timestamp), timestamp, transaction_id); `decimal_value Decimal(38,26) DEFAULT toDecimal128OrZero(value, 26)` | `db/clickhouse_migrate/20240705084952_create_events_enriched_queue.rb:8-11`, `20240705085501_create_events_enriched_mv.rb`, `20240705080709_create_events_enriched.rb:6-20,31-32` |
| charged_in_advance | Karafka `EventsChargedInAdvanceConsumer` → `Events::PayInAdvanceJob.set(wait: CLICKHOUSE_MERGE_DELAY)`; Karafka DLQ topic `unprocessed_events` (hard-coded, not created in dev) | `karafka.rb:49-58`, `app/consumers/events_charged_in_advance_consumer.rb:6` |
| dead_letter | ClickHouse `events_dead_letter_queue` → MV → `events_dead_letter` (plain `MergeTree`, duplicates persist) | `db/clickhouse_migrate/20251110130723_create_events_dead_letter_queue.rb:8-11`, `20251110100317_create_events_dead_letter.rb:6`, `20260430075848_update_events_dead_letter_mv.rb` |
| raw | also ClickHouse `events_raw_queue` → `events_raw` (independent of EP) | `db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:8-11` |

The events-processor has **no ClickHouse client**: everything reaches ClickHouse through these Kafka engines.
Removed topic: `events_enriched_expanded` (producer removed in `d9c32b6`, 2026-09-18); pinned lago-api still has
its queue migration reading `LAGO_KAFKA_ENRICHED_EVENTS_EXPANDED_TOPIC`
(`20250814124830_create_events_enriched_expanded_queue.rb`) — drift owned by `rails-go-parity`.

## 6. Payload shapes (JSON field names; semantics in `rails-go-parity`)

- `Event` in: `organization_id, external_subscription_id, transaction_id, code, properties (map), precise_total_amount_cents (string!), source, timestamp (any: string float / number / RFC3339), source_metadata.api_post_processed, ingested_at (CustomTime)`.
- `EnrichedEvent` out: the above (minus `ingested_at`, `source_metadata`) plus `subscription_id, plan_id, aggregation_type, value (*string), timestamp (float64 seconds, ms-truncated for string input)`.
- `FailedEvent` out (DLQ): `{event: <Event>, initial_error_message, error_message, error_code, failed_at}`; `ingested_at` re-serialised without milliseconds (`utils/time.go:103-111`).
