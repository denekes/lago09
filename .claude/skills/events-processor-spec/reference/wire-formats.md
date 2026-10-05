# Wire formats: raw, enriched, in-advance, dead-letter, refresh flag, CDC

Part of `events-processor-spec` (re-implementation kit v1.2.0). Read when you parse the input topic or write any
output the billing engine and ClickHouse consume. Behaviour facts: reference events-processor tree `83e012866f29`
(compat profile) plus the corrected profile where stated. Byte-level rendering rules the conformance suite
compares are in §7.

> **Licence.** The Lago events-processor and lago-api are AGPL-3.0. This chapter states observable behaviour in
> neutral words and tables; it contains no copied source. A clean-room rebuild that will not be AGPL needs legal
> review (`reimplementation-kit` reference/legal-and-provenance.md).

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun and run-suite.sh against the Go reference -->

## 1. Raw record (input topic, `LAGO_KAFKA_RAW_EVENTS_TOPIC`)

- **EP-W1** [vec: ep.decode.001, EPC-09]
  Value: one JSON object (fields and accepted types: `processing-rules.md` EP-C1). Key: not read (the
  billing API sends none; ingestion connectors send `<organization_id>-<external_subscription_id>`). Headers: not
  read.

| Field | Billing API producer | Ingestion connectors | Processor use |
|---|---|---|---|
| `organization_id` | organization id (UUID text) | from the request or a configured constant | metric/subscription/charge scope, output key |
| `external_subscription_id` | as sent by the client | as sent | subscription lookup |
| `transaction_id` | as sent | as sent | output key, idempotency downstream |
| `code` | metric code | as sent | metric lookup |
| `timestamp` | decimal-seconds STRING, e.g. `"1741007009.123"` | string or JSON number as sent, may be RFC 3339 | EP-D1..D3 |
| `properties` | object (expression already applied by the API) | object as sent | value, expression input |
| `precise_total_amount_cents` | decimal string, default `"0.0"` | JSON number (undecodable in the reference, EP-F5) | copied |
| `ingested_at` | `YYYY-MM-DDTHH:MM:SS.fff` (UTC, milliseconds) | JSON integer seconds | retry horizon (EP-L1) |
| `source` | `"http_ruby"` | absent | expression skip (EP-G1), post-processing split (EP-J1) |
| `source_metadata` | `{"api_post_processed": <true for organizations whose events are aggregated from Postgres>}` (extra keys ignored) | absent | EP-J1 |
| other keys (e.g. `external_customer_id`) | may be present | — | dropped (EP-C4) |

## 2. Enriched record (`LAGO_KAFKA_ENRICHED_EVENTS_TOPIC`)

- **EP-W2** [vec: EPC-01, EPC-06, EPC-23]
  One record per successfully enriched event (with or without subscription). Key
  `<organization_id>-<transaction_id>` (UTF-8). Value: a JSON object with exactly these fields
  (reference order shown; consumers must not depend on order, §7):

| Field | JSON type | Content |
|---|---|---|
| `organization_id` | string | raw |
| `external_subscription_id` | string | raw |
| `subscription_id` | string | matched subscription id, `""` when none (EP-H4) |
| `plan_id` | string | the matched subscription's plan id, `""` when none |
| `transaction_id` | string | raw |
| `code` | string | raw |
| `aggregation_type` | string | label of the metric type (EP-F4) |
| `properties` | object or null | raw properties after expression evaluation (EP-G2); number text per EP-C5 |
| `precise_total_amount_cents` | string | raw, `""` when absent (EP-F5) |
| `source` | string | raw; OMITTED when empty |
| `value` | string | EP-F1/F2 |
| `timestamp` | number | emitted timestamp in seconds (EP-D2) |

Example (sum metric, subscription found):
`key="11111111-1111-1111-1111-111111111111-f_redis"`
`{"organization_id":"11111111-1111-1111-1111-111111111111","external_subscription_id":"sub_ext_1","subscription_id":"bbbbbbbb-0000-0000-0000-000000000001","plan_id":"22222222-2222-2222-2222-222222222222","transaction_id":"f_redis","code":"api_calls","aggregation_type":"sum","properties":{"amount":1},"precise_total_amount_cents":"","value":"1","timestamp":1759320000}`

Downstream reader (ClickHouse store of the billing engine): reads `value` as text and derives a decimal from it
(reference: 38 digits with 26 decimals, unparsable text → 0, so `1e+06` and `<nil>` both become 0 and magnitudes
≥ 1e12 do not fit; corrected per RBD-13 and RBD-26: plain decimal text into an exact numeric(40,15)-compatible
column); reads `timestamp` as text into a millisecond date-time; reads `properties` as a map of strings.

## 3. In-advance record (`LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC`)

- **EP-W3** [vec: EPC-06]
  Same key and byte-identical value as the enriched record of the same event, produced only under
  EP-J1/EP-J2. The billing engine re-resolves the subscription itself and is idempotent on `transaction_id`.

## 4. Dead-letter record (`LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC`)

- **EP-W4** No key. Value: a JSON object [vec: ep.decode.001, ep.decode.004, ep.decode.018, ep.decode.019, ep.decode.021, ep.decode.022, EPC-03, EPC-09, EPC-18]

| Field | JSON type | Content |
|---|---|---|
| `event` | object | the DECODED raw event written back: `organization_id`, `external_subscription_id`, `transaction_id`, `code`, `precise_total_amount_cents` (strings, `""` when absent), `properties` (object or null; numbers per EP-C5; reference: for a failure AFTER expression evaluation — subscription, charge or flag error, rejected produce — the properties already hold the expression result of EP-G2, e.g. `{"a":2,"total":"4"}`; observed in both modes, not yet pinned by a golden), `source` (omitted when empty), `timestamp` (as received: string, number re-encoded per EP-C5, or null), `source_metadata` (object or null), `ingested_at` (`YYYY-MM-DDTHH:MM:SS` or null, EP-D5); unknown keys dropped |
| `initial_error_message` | string | implementation text of the underlying error (not a contract, RBD-24) |
| `error_message` | string | fixed text per code (table below) |
| `error_code` | string | table below |
| `failed_at` | string | RFC 3339 with fractional seconds and offset, time of the failure |

| `error_code` | `error_message` | Cause | Retryable in the reference |
|---|---|---|---|
| `build_enriched_event` | `Error while converting event to enriched event` | invalid timestamp (EP-D1), the `null` literal (EP-C3) | no |
| `fetch_billable_metric` | `Error fetching billable metric` | metric not found (EP-E1) / lookup error (EP-E2) | not found: no; lookup error: yes |
| `evaluate_expression` | `Error evaluating custom expression` | EP-G3 | no |
| `fetch_subscription` | `Error fetching subscription` | subscription lookup error (not "none found") | yes |
| `fetch_pay_in_advance_charge` | `Error fetching pay in advance charge` | charge lookup error | yes |
| `flag_subscription_refresh` | `Error flagging subscription refresh` | refresh-flag write error | yes |
| `""` | `""` | the broker rejected the enriched or in-advance produce; `initial_error_message` = `failed to push to <topic> topic` (EP-L2, EP-L3) | — |

Retryable codes reach the dead-letter topic only past the retry horizon (`delivery-and-failures.md` EP-L1).
Corrected profile: every dead-letter record has a non-empty `error_code` (RBD-6), and a record whose bytes could
not be decoded is dead-lettered with its raw bytes and the parse error (RBD-4). The exact names are an open owner
question (KQ-5); until the owner rules, the kit DEFAULT below is `proposed` so that implementations converge. The
suite grades only what is decided: a non-empty `error_code` (`on_dlq`, `done_with_cause`) and, for undecodable
bytes, attribution by `raw_event`.

| Cause (corrected profile) | `error_code` | `error_message` | `event` | Other fields |
|---|---|---|---|---|
| undecodable record value (RBD-4), including a numeric `precise_total_amount_cents` when it is not accepted | `decode_event` | `Error decoding event` | the all-empty event (exactly the object written for the JSON literal `null`, `ep.decode.004`) | `raw_event` = the record value as a JSON string (UTF-8; invalid byte sequences replaced by U+FFFD), `initial_error_message` = the parse error |
| non-finite timestamp `NaN` / `Inf` (RBD-4) | `build_enriched_event` | `Error while converting event to enriched event` | the decoded event | — |
| broker rejects the enriched produce, record-specific (RBD-6) | `produce_enriched_event` | `Error producing enriched event` | the decoded event (expression result included, as for other failures after EP-G2) | `initial_error_message` = the broker error |
| retry budget or maximum age exhausted (RBD-1, RBD-3) | the failing step's code from the table above (e.g. `fetch_subscription`) | that step's message | the decoded event | `initial_error_message` = the last underlying error |

`raw_event` is additive: any dead-letter record may carry it, and the suite then attributes the record by byte
equality of `raw_event` with a produced raw value before it looks at `event.transaction_id` (EP-P6). A rejected
in-advance produce (RBD-7, proposed) and a rejected dead-letter produce (RBD-5) are not dead-lettered at all
(SYSTEMIC), so they need no code.

## 5. Refresh flag (Redis, `LAGO_REDIS_STORE_URL`)

- **EP-W5** [vec: ep.refresh_member.001, ep.refresh_member.003, ep.refresh_member.004, EPC-24]
  Sorted set named `subscription_refreshed_v2` in database `LAGO_REDIS_STORE_DB`. Member
  `<organization_id>:<subscription_id>|<bucket>`, score = Unix seconds at write time, bucket = score floored to a
  multiple of 10 (EP-K1). The billing engine's clock reads members whose score is at least 10 s old, takes the
  subscription id between the last `:` before `|` and the `|`, refreshes that subscription's usage and removes the
  member.

## 6. CDC rows (memory-cache mode only)

- **EP-W6** [vec: EPC-31, EPC-32, EPC-33, EPC-34]
  Topics `<LAGO_DEBEZIUM_TOPIC_PREFIX>.public.<table>` for `billable_metrics`, `subscriptions`,
  `charges`, `billable_metric_filters`, `charge_filters`, `charge_filter_values`. Value: one flat JSON object per
  changed row (the CDC envelope already unwrapped: column name → value), date-times as integer microseconds since
  the epoch (RFC 3339 strings also accepted), booleans as JSON booleans, `properties` as JSON text or object; extra
  keys such as `__deleted`, `__table`, `__lsn` are ignored. A column that is absent from the row is NOT kept from
  the cached version (EP-N4). Key: not read. Apply rules: `memory-cache-mode.md` EP-N3..N6.

| Table | Columns the processor uses |
|---|---|
| billable_metrics | `id`, `organization_id`, `code`, `aggregation_type` (integer code), `recurring`, `field_name`, `expression`, `updated_at`, `deleted_at` |
| subscriptions | `id`, `organization_id`, `external_id`, `plan_id`, `started_at`, `terminated_at`, `updated_at` |
| charges | `id`, `organization_id`, `plan_id`, `billable_metric_id`, `pay_in_advance`, `updated_at`, `deleted_at` |
| filter tables | loaded and kept current, read by no rule |

## 7. Canonical form (how the suite compares records)

- **EP-W7** [vec: EPC-00, EPC-09, EPC-24]
  For comparison every output value is decoded with number literals preserved, re-encoded with object
  keys sorted, no insignificant whitespace and no HTML escaping (`<`, `>`, `&` stay literal), then masked:
  `failed_at` → `<RFC3339>` (after checking it parses), a dead-letter `event.ingested_at` produced from a run-time
  template → `<NOW-<h>h:<layout>>` (the layout is part of the contract), refresh-flag bucket → `<BUCKET>` (after
  checking `bucket mod 10 = 0` and `0 ≤ score − bucket < 10`). Key order and whitespace are therefore free;
  number TEXT is not (`1759320000` ≠ `1759320000.0`) (RBD-24, KQ-6). Under `--loose-errors`
  `initial_error_message` is compared only as empty / non-empty.

<!-- evidence-check: on -->

## 8. Peer expectations (what other systems rely on)

| Peer | Reads | Relies on |
|---|---|---|
| ClickHouse enriched table (billing engine, events aggregated in ClickHouse) | enriched topic | field names, `value` text, `timestamp` number text, `properties` text map; dedup by `transaction_id` only when the organization enables it |
| Billing engine in-advance consumer | in-advance topic | `organization_id`, `transaction_id`, `external_subscription_id`, `code`, `properties`, `timestamp`, `precise_total_amount_cents`; idempotent per `transaction_id` |
| Billing engine refresh clock | refresh flag | member grammar EP-W5, 10 s minimum age |
| Dead-letter view (ClickHouse) | dead-letter topic | `event.*` fields read as strings (missing `timestamp` falls back to `ingested_at`), `error_code`, `error_message`, `initial_error_message`, `failed_at`; a new top-level field (`raw_event`) is additive |

## Provenance (maintainers)

Reference: events-processor tree `83e012866f29`: record structs `events-processor/models/event.go:12` (raw),
`:29` (enriched), `:50` (dead letter); keys `events-processor/processors/events_processor/event_producer_service.go:29`
and `:40`, dead-letter `:51`; refresh flag `events-processor/models/stores.go:54`, set name
`events-processor/processors/main_processor.go:152`; CDC decoding `events-processor/utils/json.go:12`,
`events-processor/cache/consumer.go:92`. Billing-engine peers @591ae90: raw producer
`$API/app/services/events/kafka_producer_service.rb:36`; refresh consumer
`$API/app/services/subscriptions/consume_subscription_refreshed_queue_service.rb:7`; in-advance consumer
`$API/app/services/events/pay_in_advance_service.rb:12`; ClickHouse enriched table
`$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:5`; dead-letter view
`$API/db/clickhouse_migrate/20260430075848_update_events_dead_letter_mv.rb:7`.

Kit default dead-letter names (2026-10-05, `proposed` until the owner answers KQ-5): they follow the reference's
step-named codes (`build_enriched_event`, `fetch_*`, `flag_subscription_refresh`), keep the reference's own code
for an exhausted retry (the reference writes the step code past its 12 h horizon, EPC-12 golden), and reuse the
all-empty `event` object the reference already writes for the JSON literal `null` (`ep.decode.004`, EPC-09 golden),
so existing dead-letter readers see no new shape. The maintainer self-test IUT (`scripts/maintainer/selftest-iut.py`)
writes the undecodable default.
