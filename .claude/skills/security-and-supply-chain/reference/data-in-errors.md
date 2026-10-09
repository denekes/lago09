# Data in errors: Sentry extras and DLQ payloads

Read this before you add an error report, a log line or a DLQ field that carries event data, or
when someone asks "where does customer data end up besides the event store?".
Code facts as of `5308258` (events-processor tree `83e012866f29`); the working branch may carry
skills-only commits on top. `$API` = lago-api at the pinned SHA `591ae90` (2026-09-08).
Checked 2026-10-01.

## 1. What leaves the events-processor with an error

| Sink | Trigger | Payload | Where |
|---|---|---|---|
| Sentry extra `event` | a capturable enrichment failure (`result.IsCapturable()`) | the full raw `models.Event`: `organization_id`, `external_subscription_id`, `transaction_id`, `code`, **`properties`** (free-form customer map), `precise_total_amount_cents`, `source`, `timestamp`, `source_metadata`, `ingested_at` | `events-processor/processors/events_processor/processor.go:70-72` -> `utils/error_tracker.go:13-24` (`scope.SetExtra(extraKey, extraValue)`); struct `models/event.go:12-23` |
| Sentry extra `event` | DLQ produce failed | same full `models.Event` | `processors/events_processor/event_producer_service.go:70-73` |
| Sentry exception only | unmarshal error, marshal error, produce error, cache errors | error text only (no payload; cache results add only `error_code`/`error_message` extras) | `processor.go:50-53` (unmarshal); `event_producer_service.go:36,47,63` (marshal); `config/kafka/producer.go:64-65` (produce); `cache/consumer.go:72,101,137,166` |
| Kafka `events_dead_letter` | non-retryable failure, retry horizon (12 h) exceeded, or enriched/in-advance produce failure | `models.FailedEvent` = full `Event` + `initial_error_message`, `error_code`, `error_message`, `failed_at` | `event_producer_service.go:51-68`; struct `models/event.go:50-56` (`FailedEvent`); callers `processor.go:82`, `event_producer_service.go:88` |
| ClickHouse `events_dead_letter` | lago-api migrations consume the DLQ topic | column `event` (JSON) holds the whole payload; MergeTree with **no TTL** | `$API/db/clickhouse_migrate/20251110100317_create_events_dead_letter.rb:5-20`, `..._queue.rb:9`, `..._mv.rb`, `20260430075848_update_events_dead_letter_mv.rb`; `grep -rni ttl $API/db/clickhouse_migrate` returns 0 lines |
| slog (stdout) | failures | error code and message only; no payload fields | `processor.go:52,64-68`; `event_producer_service.go:35,46,62,71` |

Sentry is off unless `SENTRY_DSN` is set (`events-processor/main.go:53-58`; `Dsn: os.Getenv(...)`).
No `BeforeSend` scrubber is configured, so whatever is put in an extra is sent. The Rails side
(`$API/config/initializers/sentry.rb:3-11`) also has no scrubber; it is out of scope here.

`properties` is customer-defined: tenants can put e-mails, user ids, IP addresses or free text in
it. Treat every `properties` value as potential personal data.

## 2. OPEN DECISION OD-19 (owner): is this acceptable under the data-handling policy?

- `events-processor/Dockerfile.staging:3` says the staging image is "built for SOC2 compliance".
  `README.md:192` states SOC 2 Type II certification.
- Not decidable from the repo: whether Sentry (a third-party processor) may receive raw event
  properties, and how long DLQ rows may live in ClickHouse without a TTL.
- Until the owner decides (register: change-control section 9), label it OD-19 and do not widen
  the exposure.

## 3. Rules for changes (C7 overlay; route via change-control)

1. Do not add new Sentry extras or log fields that carry `properties` or whole events.
   Prefer identifiers: `organization_id`, `transaction_id`, `code`, `error_code`.
2. CANDIDATE fix for the existing extras: send `transaction_id`, `organization_id`, `code` and
   `error_code` instead of `event` at `processor.go:71` and `event_producer_service.go:72`. The DLQ
   is the one place where the full event belongs: no DLQ replay tool exists yet, and the
   operator-gated replay tool that ADR-001 specifies (DECIDED OD-2 (owner, 2026-10-02); CANDIDATE
   until built, `event-accounting-campaign` `reference/delivery-options.md` step 4e) needs the payload.
   This is a C2/C3 change plus C7; it changes what operators see in Sentry, so tell them in the PR.
3. CANDIDATE for lago-api (a lago-api PR, since lago-api owns the table; change-control N6,
   DECIDED OD-4): a TTL on
   `events_dead_letter` once a retention period is agreed (OD-19). No DLQ replay tool exists in this
   repo or lago-api `591ae90` (`rake events:reprocess`, `$API/lib/tasks/events.rake:89-90`, is
   re-enrichment, not DLQ replay); ADR-001 (DECIDED OD-2) specifies an operator-gated DLQ -> raw-topic
   replay tool that logs counts only, CANDIDATE until built. A TTL must leave room for that replay
   window.
4. A DLQ payload schema change is a cross-repo contract change (C4): ClickHouse MVs parse
   `organization_id`, `timestamp`, `ingested_at` out of `event` (`..._mv.rb`).

## 4. Re-verify

```bash
grep -n 'CaptureErrorResultWithExtra' events-processor/processors/events_processor/*.go   # expect processor.go:71, event_producer_service.go:72
grep -n 'SetExtra' events-processor/utils/error_tracker.go                                # expect :15,:16,:19
API=$(.claude/skills/research-methodology/scripts/pinned-checkout.sh api); grep -rni ttl "$API/db/clickhouse_migrate" | wc -l   # expect 0
```
