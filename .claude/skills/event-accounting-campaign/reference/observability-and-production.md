# W5 observability and production verification (Phases 1 and 6)

Read when you design the Phase 1 signals, review a PR that adds them, or plan a production rollout and
its verification (Phase 6). Code facts as of 5308258 (events-processor tree 83e012866f29); the working
branch may carry skills-only commits on top; lago-api at the pin `591ae90` (2026-09-08). Verified 2026-10-01
unless marked. Production itself is invisible from this repo: everything about production
below is UNVERIFIED and routed to the owner.

## 1. What events-processor tells you today

| Signal | Where | What it does NOT tell you |
|---|---|---|
| JSON log to stdout, level Debug when `ENV` is `development` (also the default when `ENV` is unset), otherwise Info | `events-processor/main.go:31-41` | — |
| `Error unmarshalling message` | `processors/events_processor/processor.go:52` | that the record was committed with no DLQ (case 4/5 SENTRY_ONLY) |
| `<error message>` with `error_code` | `processor.go:64-68` | whether the record went to the DLQ or was withheld for retry (both log the same line) |
| `No commitable record in batch, skipping commit…` (Warn) | `config/kafka/consumer.go:98` | only fires when the FIRST record of a batch is withheld; a withheld record later in a batch, and the later commit that skips it (case 1), log nothing |
| `error while pushing to dead letter topic` | `processors/events_processor/event_producer_service.go:71` | that the record was then committed (case 7) |
| `Error when committing offets to kafka…` | `consumer.go:106` | — (not retried) |
| Sentry events | `main.go:53`; `processor.go:70-72`; `event_producer_service.go:72`; `config/kafka/producer.go:65` | not-found failures are NonCapturable (ledger case 10: 0 captures) |
| Kafka client metrics (kotel) | `config/kafka/kafka.go:42`, only with the OpenTelemetry provider (`TRACING_PROVIDER=opentelemetry`, or `TRACING_PROVIDER` unset/other with `OTEL_EXPORTER_OTLP_ENDPOINT` set and `DD_TRACE_ENABLED` not true: `config/tracing/tracer.go:87-102`) and `KAFKA_TRACING_ENABLED=true` (`tracer.go:27,117`); meter provider set at `config/tracing/otel_tracer.go:183` | anything about dispositions; no consumer-lag-per-record view |
| HTTP health/metrics endpoint | none: `grep -rn 'ListenAndServe' --include=*.go events-processor` = 0 hits | — |

## 2. Phase 1 signal spec (CANDIDATE)

One disposition per raw record, emitted where the decision is made (`processor.go:49-88`,
`event_producer_service.go:60-90`), plus one line per batch where the commit is decided
(`consumer.go:89-108`):

<!-- evidence-check: off design spec (CANDIDATE), not claims -->
| Name (log field `disposition` / counter label) | Emitted when | Ledger case that must show it |
|---|---|---|
| `enriched` | enriched produce succeeded | neighbours, sentinels |
| `dlq` + `error_code` | DLQ produce succeeded | 3, 6, 10 |
| `withheld` + `error_code` | retryable, returned unprocessed | 1, 2, 8, 9 |
| `undecodable` | unmarshal error | 4, 5 |
| `dlq_push_failed` + `error_code` | DLQ produce failed | 7 |
| `enriched_push_failed` | enriched produce failed (then `dlq`) | 6 |
| batch line: `batch_size`, `processed`, `withheld`, `commit_offset` or `commit_skipped` | per `processRecordsAndCommit` | all |

Rules for the implementation:
- Fields: `topic`, `partition`, `offset`, `error_code`, `transaction_id`; never the event JSON or
  properties (PII; the DLQ already embeds it: see `security-and-supply-chain`).
- Counters through `otel.GetMeterProvider()` (already used at `config/tracing/otel_tracer.go:132`) only add value when the OpenTelemetry
  provider is on; the log field must work without it.
- Gate: `scoreboard.sh --check-baseline` must print `moved=0` (observability must not change any
  disposition), plus a unit test per disposition (`validation-and-qa` for test conventions).
- Verify with the probe: run `run.sh accounting-probe -v` (and `-mode cache -v`) and check that each case
  prints its disposition line (case 1 must show `withheld` for offset 0 and a batch line committing 3).
- These are TODAY's dispositions. ADR-001 replaces `withheld` with `retried` (to the retry topic) and adds a
  SYSTEMIC pause signal (section 5); Phase 1 ships first so that the ADR-001 PR can show the change.

<!-- evidence-check: on -->

## 3. Production reconciliation query (CANDIDATE; needs production ClickHouse = owner)

ClickHouse's own Kafka engine also consumes the raw topic into `events_raw`
(`$API/db/clickhouse_migrate/20231026124912_create_events_raw_queue.rb:8-10`, table
`20231024084411_create_events_raw.rb:10-19`), so production can be audited without touching
events-processor: every raw `(organization_id, transaction_id)` should be in `events_enriched` or in
`events_dead_letter` (`20251110100317_create_events_dead_letter.rb:10-22`).

```sql
WITH toDateTime64('2026-09-30 00:00:00', 3) AS f, toDateTime64('2026-10-01 00:00:00', 3) AS t
SELECT r.organization_id, count() AS unaccounted, groupArray(10)(r.transaction_id) AS sample
FROM events_raw AS r
WHERE r.ingested_at >= f AND r.ingested_at < t
  AND (r.organization_id, r.transaction_id) NOT IN (SELECT organization_id, transaction_id FROM events_enriched WHERE enriched_at >= f)
  AND (r.organization_id, r.transaction_id) NOT IN (SELECT organization_id, transaction_id FROM events_dead_letter WHERE failed_at >= f)
GROUP BY r.organization_id ORDER BY r.organization_id;
```
- VERIFIED only for syntax and semantics on `clickhouse local` 26.2.19.43 with synthetic tables (same
  column names and types as the migrations; rows: o1 a enriched, o1 b DLQ, o1 c missing, o2 a missing):
  output `o1 1 ['c']` and `o2 1 ['a']`. Re-run: create the three tables and rows in a `--queries-file`
  and run `"$(.claude/skills/diagnostics-and-tooling/scripts/ch-local.sh --path)" local --multiquery --queries-file <file> </dev/null`
  (without `</dev/null` it waits on stdin).
- Not run against production. Cost on large tables UNVERIFIED: start with one organization and one hour.
- Connector blind spot (VERIFIED 2026-10-01 on `clickhouse local` 26.2.19.43 and 26.2.9.9, JSONEachRow
  with the `events_raw_queue` column types): connectors send `ingested_at` as an integer of Unix seconds
  (`root.ingested_at = timestamp_unix()`, `connectors/http.yml:31`, `sqs.yml:33`, `kinesis.yml:37`), and
  ClickHouse reads that JSON number into `DateTime64(3)` as milliseconds: `1727800000` -> `1970-01-20
  23:56:40.000`. Connector rows therefore fall outside any `ingested_at` window and the query above never
  counts them (Go parses the same field correctly, `utils/time.go:82-101`). To include them, use this WHERE
  clause (same synthetic test plus a connector row: `o3 1 ['x']` is reported, the query above misses it):
  ```sql
  WHERE ((r.ingested_at >= f AND r.ingested_at < t)
         OR (r.ingested_at < toDateTime64('1971-01-01 00:00:00', 3) AND r.timestamp >= f AND r.timestamp < t))
  ```
  Production ClickHouse version and settings are UNVERIFIED (owner), so re-check the parse there first.
- Other blind spots: records ClickHouse cannot parse either (invalid JSON, ledger case 4) are presumably
  absent from `events_raw` too (UNVERIFIED: the raw queue migration sets no `kafka_skip_broken_messages`, so
  what the Kafka engine does with such a message depends on ClickHouse defaults); RFC3339 `timestamp`s from
  non-Rails producers break the raw MV's `toDateTime64(timestamp, 3)` (`rails-go-parity`, contract row P5).
  Numeric `precise_total_amount_cents` (case 5) IS parsed by ClickHouse (`Decimal(40,15)`, same test), so
  case-5 events reach `events_raw`, but they come from connectors: only the connector-aware WHERE clause
  finds them. Leave a lag margin (rows enriched after `t` are still found because the subqueries only bound below).
- A non-zero answer on today's code is expected for every transient DB/Redis error followed by traffic
  (case 1) and, with the connector-aware WHERE clause, every connector event with a numeric amount
  (case 5). The size of that number is the production baseline that the ADR-001 rollout
  (DECIDED OD-2 (owner, 2026-10-02)) must drive to 0; run it before and after each Phase 4 step.

## 4. Phase 6 rollout checklist (per merged campaign change)

1. Before deploy: the PR's evidence block (ledger, scoreboard, parity probes) is in the PR; deploy order and
   rollback are written (change-control N6 for contract changes).
2. Know the mode: production runs memory-cache mode (DECIDED OD-1 (owner, 2026-10-02)); its CDC config
   (Debezium column list, CDC brokers and auth) is OPEN DECISION OD-1b (owner). Before deploy, both
   ledgers (`run.sh accounting-probe` and `run.sh accounting-probe -mode cache`) and the cache smoke runs
   (`memory-cache-w6.md` s.4) carry the evidence; dev keeps DB mode, so a dev-stack check alone proves
   nothing about production.
3. Know the flags: OPEN DECISION OD-8 (owner) (`pre_filter_events`, `lazy_charge_usage_cache`,
   `enriched_events_aggregation`): value/time changes affect only orgs whose billing reads `events_enriched`.
4. Canary one replica. Production topology (replicas, partitions, grace period) is UNVERIFIED;
   `docs/architecture.md:262` lists an "Events Processor Worker" with 1 replica, and it is unclear whether that
   row means this Go service.
5. Watch for 24 h: disposition counts by `error_code` (Phase 1), Warn lines from `consumer.go:98`, DLQ rate,
   consumer lag from the broker side (events-processor exports none), Sentry volume, and the reconciliation
   query on the canary window: `unaccounted` must not grow.
6. Rollback: redeploy the previous image; for value/time changes, note that rows written in between keep the
   new format (unique_count transition, `value-and-time.md` s.5) and decide whether to re-enrich
   (`$API/app/services/events/stores/clickhouse/re_enrich_subscription_events_service.rb` exists; using it is
   lago-api work).
7. Record the outcome in the PR / incident note (`docs-and-writing` templates) and update the scoreboard
   baseline in this skill.

## 5. ADR-001 observability (contract point 4; DECIDED OD-2 (owner, 2026-10-02); names CANDIDATE)

ADR-001 (`delivery-options.md` s.0.3 point 4) makes these part of the delivery contract: a Phase 4 step
that changes a disposition ships the signal that shows it.

<!-- evidence-check: off CANDIDATE signal spec; emission path evidence is in section 1 -->
| Signal | Type and labels | Alert / use |
|---|---|---|
| records by disposition | counter `lago_evp_records_total{disposition=enriched\|retried\|dlq, error_code}` | DLQ rate per `error_code` (alert on a jump); retried share |
| in-place retries | counter `lago_evp_inplace_retries_total{error_code}` | blips absorbed without the retry topic |
| SYSTEMIC pause | counter `lago_evp_systemic_pause_seconds_total{dependency=postgres\|cache\|redis\|kafka}` + gauge of paused partitions | alert when a pause lasts longer than the backoff cap (60 s) several times in a row |
| consumer lag | per partition, raw and retry groups, from the broker side or `kadm` lag | alert on growth; expected to grow during a SYSTEMIC pause |
| retry topic | depth (retry group lag) and age (now - `first_failed_at` of the oldest parked record) | age near the 12 h max age = records about to be DLQ'd |
| reconciliation | the section 3 query, connector-aware WHERE clause, daily per org | `unaccounted` must stay 0 after ADR-001 |
| memory cache (W6) | `lago_evp_cdc_records_dropped_total{model}`, snapshot rows loaded per model at start, cache misses by kind | a dropped CDC record or a 0-row snapshot is a W6 incident (`memory-cache-w6.md`) |
<!-- evidence-check: on -->

Emission: there is no metrics endpoint today (section 1); counters go through the OpenTelemetry meter
provider the Kafka client hooks already use (`events-processor/config/tracing/otel_tracer.go:132,183`),
which is active only with the OpenTelemetry provider (section 1 row "Kafka client metrics"). Whether
production runs that provider is UNVERIFIED (owner); a `/metrics` endpoint is a CANDIDATE alternative. The
log field `disposition` (section 2) must work without either.
