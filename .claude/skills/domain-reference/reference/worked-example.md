# Worked example: one event from HTTP to the number ClickHouse sums

Read this when you need to see, concretely, what each layer does to an event: which fields survive,
what `value` becomes, which topics and Redis keys are written, and what ClickHouse stores. The Go and
ClickHouse stages below were EXECUTED with `scripts/worked-example.sh` (2026-10-01, events-processor
`5308258`, ClickHouse local 26.2.19.43; identical output on 26.2.9.9). The Rails stage is read from code
(no Rails runtime here).

## Setup (what the script seeds)

<!-- evidence-check: off fixture rows seeded by scripts/worked-example.sh (the script is the evidence) -->
| Object | Value |
|---|---|
| Organization | "Hooli Clickhouse" `22222222-3333-4444-5555-666666666666` (the dev seed CH-store org, `$API/db/seeds/01_base.rb:41`) |
| Billable metric | code `storage`, aggregation `sum_agg` (int 1), `field_name` `gb`, no expression, not recurring |
| Subscription | `external_id` `sub_ext_42`, id `sub-2222`, plan `plan-2222`, started 2024-09-01, not terminated |
| Charge | plan `plan-2222` x BM `storage`, `pay_in_advance: true` |
<!-- evidence-check: on -->

## The client call

```http
POST /api/v1/events
Authorization: Bearer <org api key>

{"event": {"transaction_id": "tx-e1", "external_subscription_id": "sub_ext_42", "code": "storage",
           "timestamp": "1727787600.123", "properties": {"gb": 12.5, "region": "eu"}}}
```
`1727787600.123` is 2024-10-01T13:00:00.123Z.

## Stage 1 [Rails, code-read]: what lands on the raw topic

1. `parse_timestamp`: `Time.zone.at(BigDecimal("1727787600.123"))` (`$API/app/services/events/create_service.rb:53`).
2. No expression on `storage`, so properties are unchanged (`$API/app/services/events/calculate_expression_service.rb:22`).
3. CH-store org: no Postgres row, no post-process job (`$API/app/services/events/create_service.rb:32`).
4. `KafkaProducerService#build_payload` (`$API/app/services/events/kafka_producer_service.rb:43`) produces, with no key:

```json
{"organization_id":"22222222-3333-4444-5555-666666666666","external_customer_id":null,
 "external_subscription_id":"sub_ext_42","transaction_id":"tx-e1","timestamp":"1727787600.123",
 "code":"storage","precise_total_amount_cents":"0.0","properties":{"gb":12.5,"region":"eu"},
 "ingested_at":"<now, ms, no Z>","source":"http_ruby","source_metadata":{"api_post_processed":false}}
```

Caveat on `timestamp`: it is `Time#to_f.to_s`, not the client's string. On Ruby 3.3.6 (this sandbox),
`Time.at(BigDecimal("1727787600.123")).to_f.to_s` is `"1727787600.1230001"`, and for 129 of the 1000
millisecond values `.000`-`.999` the string sits just BELOW the ms (e.g. `1727787600.002` -> `"1727787600.0019999"`), so Go's
ms truncation lands 1 ms early. lago-api pins Ruby 4.0.6 (`$API/Gemfile:6`): UNVERIFIED there. The Go
side's own float issues are owned by `rails-go-parity`. The example uses the clean string.

## Stage 2 [EP, executed]: what events-processor emits

`ProcessEvents` -> `EnrichEvent` (`events-processor/processors/events_processor/enrichment_service.go:27`):

| Step | Code | Result for tx-e1 |
|---|---|---|
| Unmarshal into `models.Event` | `events-processor/processors/events_processor/processor.go:50` | `external_customer_id` dropped (no field in `events-processor/models/event.go:12`) |
| Timestamp | `events-processor/utils/time.go:58` | float `1727787600.123` (ms-truncated) |
| BM lookup (org, code) | `events-processor/processors/events_processor/enrichment_service.go:37` | `storage`, `aggregation_type` "sum" |
| Expression | `events-processor/processors/events_processor/enrichment_service.go:104` | skipped: `source` is `http_ruby` |
| `value` | `events-processor/processors/events_processor/enrichment_service.go:114` | `fmt.Sprintf("%v", 12.5)` = `"12.5"` |
| Subscription | `events-processor/models/subscriptions.go:32` | `sub-2222`, plan `plan-2222` |
| Produce enriched | `events-processor/processors/events_processor/event_producer_service.go:30` | key `22222222-...-666666666666-tx-e1` |
| Post-processing gate | `events-processor/processors/events_processor/processor.go:115` | open: subscription found, `api_post_processed` false |
| Pay-in-advance charge? | `events-processor/models/charges.go:47` | yes -> same JSON to `events_charged_in_advance` |
| Refresh flag | `events-processor/models/stores.go:62` | ZADD member `22222222-...-666666666666:sub-2222\|<10 s bucket>` |
| Disposition | `events-processor/processors/events_processor/processor.go:74` | success, marked for commit |

Message on `events_enriched` (and, identical, on `events_charged_in_advance`), as captured:

```json
{"organization_id":"22222222-3333-4444-5555-666666666666","external_subscription_id":"sub_ext_42",
 "subscription_id":"sub-2222","plan_id":"plan-2222","transaction_id":"tx-e1","code":"storage",
 "aggregation_type":"sum","properties":{"gb":12.5,"region":"eu"},"precise_total_amount_cents":"0.0",
 "source":"http_ruby","value":"12.5","timestamp":1727787600.123}
```

## Stage 3 [CH, executed]: what `events_enriched` stores

The queue reads 8 of those fields (`$API/db/clickhouse_migrate/20240705084952_create_events_enriched_queue.rb:14`);
`subscription_id`, `plan_id`, `aggregation_type` and `source` are dropped. The MV and column defaults give:

<!-- evidence-check: off output of scripts/worked-example.sh ClickHouse stage; expressions cited in the rows -->
| Column | Expression | tx-e1 |
|---|---|---|
| `timestamp` | `toDateTime64(timestamp, 3)` (`$API/db/clickhouse_migrate/20240705085501_create_events_enriched_mv.rb:10`) | `2024-10-01 13:00:00.123` |
| `properties` | `JSONExtract(properties, 'Map(String, String)')` | `{'gb':'12.5','region':'eu'}` |
| `value` | as sent | `12.5` |
| `decimal_value` | `toDecimal128OrZero(value, 26)` (`$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:32`) | `12.5` |
<!-- evidence-check: on -->

At invoice time, `sum_agg` over this subscription's period is `sum(decimal_value)` over its `events_enriched`
rows (`$API/app/services/events/stores/clickhouse_store.rb:542`). That `12.5` is the number billed. For this
dev seed org the rows are read WITHOUT `FINAL`: the seed creates it with only `clickhouse_events_store`
(`$API/db/seeds/01_base.rb:54`), so `clickhouse_deduplication_enabled` keeps its default false
(`$API/app/models/organization.rb:348`) and a resent `tx-e1` would be summed twice (code-read).

## Variants (same run)

<!-- evidence-check: off output of scripts/worked-example.sh (Reproduce section below) -->
| Case | Input | Go `value` | Topics / Redis | CH `decimal_value` |
|---|---|---|---|---|
| E2 PG-store org ("Hooli"), `api_post_processed: true` | gb 12.5 | `"12.5"` | enriched only; no in-advance, no ZADD | 12.5 (but billing reads Postgres, not this row) |
| E3 big number | `{"gb":2000000}` | `"2e+06"` | enriched + in-advance + ZADD | 2000000 (`properties` keep `'2000000'`) |
| E4 property missing | `{"region":"eu"}` | `"<nil>"`, on the wire `"\u003cnil\u003e"` (Go JSON escapes `<` `>`) | enriched + in-advance (Rails will refuse the fee later) + ZADD | 0 |
| E5 count BM with a stale `field_name` | `{"ignored_for_count":7}` | `"1"` | enriched + ZADD (no in-advance charge on that BM) | 1 |
| E6 connector-shaped (no `source`), BM expression `event.properties.mb / 1024` | `{"mb":"3072"}` | `"3"`; properties gain `"gb":"3"` | enriched + ZADD | 3 |
| E7 unknown code | `no_such_metric` | none | `events_dead_letter`, `error_code` `fetch_billable_metric`, no key; record committed | none |
<!-- evidence-check: on -->

Aggregate over E1+E3+E4 (CH-store org, code `storage`): `count() = 3`, `sum(decimal_value) = 2000012.5`,
`uniqExact(value) = 3`: a unique_count BM on that property would count `"<nil>"` as a value.

## Reproduce

```bash
cd "$(git rev-parse --show-toplevel)"
.claude/skills/domain-reference/scripts/worked-example.sh          # ~3-5 s warm (~20 s on a cold Go cache); 20 CHECK lines
.claude/skills/domain-reference/scripts/worked-example.sh --raw    # keep real ingested_at / bucket / failed_at
```
Expected tail: `RESULT: all checks matched`, exit 0. A `CHECK MISMATCH` means events-processor or the
ClickHouse expressions changed behaviour: re-verify this skill and `rails-go-parity` before trusting either.
