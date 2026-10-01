# Known weak points (full register)

Verified 2026-10-01 at HEAD 5308258. Severity is the skill author's judgement (impact × likelihood), not an owner
decision. "Owner" = the sibling skill that owns the fix or the deeper analysis. Paths relative to `events-processor/`.
Memory-cache rows: production impact depends on OPEN DECISION OD-1.

| ID | Sev | Weak point (plain statement) | Evidence | Status | Owner |
|---|---|---|---|---|---|
| WP1 | HIGH | A retryable failure younger than 12 h is lost if any later batch on the same partition commits. No DLQ, no metric, Sentry only. | `processor.go:74-79`; `config/kafka/consumer.go:92-104`; probe: offset 2 seen once, committed offset 7 | VERIFIED (probe re-run) | event-accounting-campaign W1 (OD-2) |
| WP2 | HIGH | Undecodable records are committed with no DLQ copy; includes numeric `precise_total_amount_cents` (connectors) and unparsable `ingested_at`. | `processor.go:49-60`; `models/event.go:18`; `connectors/http.yml:32-33` | VERIFIED (unmarshal probe) | event-accounting-campaign |
| WP3 | HIGH | Enriched / in-advance produce failure ⇒ DLQ + commit; DLQ failure ⇒ Sentry is the only copy; `processEvent` reports success either way. | `event_producer_service.go:66-73,87-91`; `processor.go:110-113` | code-level | event-accounting-campaign |
| WP4 | HIGH | `value` built with `%v` on float64 (`1e+06`, `<nil>`, precision loss > 2^53); ClickHouse decimal conversion zeroes some of them. | `enrichment_service.go:111-116` | Go side VERIFIED; CH side see `rails-go-parity` (OD-3) | rails-go-parity / campaign W2 |
| WP5 | MEDIUM | `utils.ToTime` float math puts 496/1000 ms-precision string timestamps 1 ms early; RFC3339 input not normalised to UTC. Subscription lookup uses this time; emitted `timestamp` uses the correct `ToFloat64Timestamp`. | `utils/time.go:20-29,48` | VERIFIED (496/1000) | rails-go-parity / campaign W3 |
| WP6 | HIGH (OD-1) | Debezium column list lacks `charges.pay_in_advance` and `billable_metrics.recurring`; a CDC update overwrites the cached row with zero values ⇒ in-advance events and the recurring fallback silently stop. | `extra/debezium_config.json:2`; `cache/consumer.go:93,158` | code-level VERIFIED by reading | memory-cache hardening: no campaign owns it (report to owner) |
| WP7 | HIGH (OD-1) | Snapshot table failures are swallowed; the pod runs with an empty/partial cache and DLQs everything as `fetch_billable_metric`. | `cache/cache.go:78-106` | VERIFIED (S6: 0/6 loads, process continued) | same as WP6 |
| WP8 | HIGH (OD-1) | Cache subscription lookup is a raw prefix scan: external ids containing `:` leak into shorter ids. | `cache/subscriptions.go:46` | VERIFIED (probe) | rails-go-parity (parity harness) |
| WP9 | MEDIUM (OD-1) | Cache compares subscription bounds at µs, DB/Rails at ms ⇒ modes disagree on the boundary millisecond. | `cache/subscriptions.go:60-65` vs `models/subscriptions.go:32-33` | VERIFIED (probe) | rails-go-parity |
| WP10 | MEDIUM (OD-1) | CDC consumers: raw broker string (no comma split), no SASL/TLS, no logger, new UUID group per start (full replay + orphan groups), fetch errors loop forever. | `cache/consumer.go:26-35,66-74` | code-level | config-and-flags (vars), memory-cache hardening |
| WP11 | MEDIUM | `FetchBillableMetric` still uses implicit `SELECT *`: a billable_metrics column-add ⇒ SQLSTATE 0A000 ⇒ retryable failures ⇒ WP1. The test pins the bad SQL. | `models/billable_metrics.go:61`; `models/billable_metrics_test.go:14-15` | VERIFIED (`invariants-grep.sh` FLAG) | change-control N4 (small C3 fix) |
| WP12 | MEDIUM | Unbounded per-record goroutines (≤10 000 per poll) against DB pool 200 and Redis pool 10 (4 s pool timeout): timeouts become retryable failures ⇒ WP1. | `processor.go:38-44`; `consumer.go:168`; `config/redis/redis.go:38-39` | code-level | event-accounting-campaign |
| WP13 | MEDIUM | No context deadlines: batch ctx `Background`, no gorm `WithContext`, `ProduceSync` with unbounded record retries ⇒ a broker/DB stall blocks the partition, delays rebalances (60 s timeout) and blocks shutdown until SIGKILL. (Redis is the exception: go-redis client timeouts, `config/redis/redis.go:35-39`.) | `consumer.go:83,245`; `config/kafka/producer.go:62`; `franz-go@v1.20.5/pkg/kgo/config.go:563,595` | code-level | event-accounting-campaign |
| WP14 | MEDIUM | Head-of-line blocking: one slow partition stalls dispatch to the others (unbuffered channel). | `consumer.go:122,195` | code-level | event-accounting-campaign |
| WP15 | MEDIUM | Any non-context fetch error panics the process (no Sentry). | `consumer.go:175-183` | code-level | debugging-playbook |
| WP16 | MEDIUM | Startup validation gaps: empty raw topic / group (group `_`, idles), empty Debezium prefix, `LAGO_USE_MEMORY_CACHE` only literal `true`, SCRAM typo ⇒ SIGSEGV without log. | `main.go:67`; `main_processor.go:171-172`; `config/kafka/kafka.go:48-64` | VERIFIED (`startup-contract.sh` S4, S6, S7, K9) | config-and-flags, debugging-playbook |
| WP17 | MEDIUM | Partial side effects: enriched is produced before the in-advance check / ZADD can fail. | `processor.go:110-131` | code-level | event-accounting-campaign |
| WP18 | LOW | No metrics, no health endpoint, no lag signal; spans are never nested (`GetContext()` unused). | no `net/http` import; `config/tracing/tracing.go:24` unused | VERIFIED (grep) | run-and-operate, diagnostics-and-tooling |
| WP19 | LOW | PII: Sentry extra carries the full event; `evaluate_expression` DLQ message embeds the event JSON. | `processor.go:70-72`; `enrichment_service.go:136-138` | code-level | security-and-supply-chain |
| WP20 | LOW | Redis TLS uses `InsecureSkipVerify: true`; `ENV=production` silently enables TLS when `LAGO_REDIS_STORE_TLS` is unset (`panic: EOF` against plaintext Redis). | `config/redis/redis.go:42-48`; `main_processor.go:84-91` | VERIFIED (K7) | security-and-supply-chain, config-and-flags |
| WP21 | LOW | Typed-nil tracer provider: `main.go:46` check can never fire (SA4023); a failed OTel init later dereferences nil. | `config/tracing/otel_tracer.go:147-173`; `tracer.go:54` | code-level (lint) | validation-and-qa |
| WP22 | LOW | `lost()` dereferences `cg.consumers[tp]` without a nil check. | `consumer.go:139-141` | UNVERIFIED trigger | debugging-playbook |
| WP23 | LOW | `Cache.Wait()` never called: badger may close under a CDC goroutine at shutdown. | `main.go:75`; `cache/cache.go:59-61` | UNVERIFIED impact | — |
| WP24 | LOW | DLQ payload is lossy: `ingested_at` without ms; `properties` may already be mutated by the expression (shared map); DLQ table keeps duplicates. | `utils/time.go:103-111`; `models/event.go:65`; `enrichment_service.go:134` | code-level | debugging-playbook (triage) |
| WP25 | LOW | Dead code kept alive: `LAGO_REDIS_CACHE_*` constants, `CacheStore`/`ExpireKey` (since `2fd8e8b`), three filter caches with snapshots + CDC consumers and `AcceptsTargetWallet`/`PricingGroupKeys` (since `d9c32b6`). | `main_processor.go:40-43`; `models/stores.go:75-104`; `cache/{billable_metric_filters,charge_filters,charge_filter_values}.go` | VERIFIED (grep: no readers) | docs-and-writing (README), change-control (C2 cleanup) |
| WP26 | LOW | A missing raw topic is not fatal: the client logs `UNKNOWN_TOPIC_OR_PARTITION` at INFO and waits; the dev `events-processor` service does not depend on `redpandacreatetopics`. | K8 log; `docker-compose.dev.yml:326-332` | VERIFIED | run-and-operate |

Coverage of the delivery path (why nothing catches regressions here), measured 2026-10-01 with
`go test -coverpkg=./... -coverprofile=… <packages with tests>` (total 44.9%): `ProcessEvents`,
`processRecordsAndCommit`, `pollRecords`, `assigned`, `lost`, `gracefulShutdown`, `NewProducer`, `Produce`,
`LoadInitialSnapshot`, every `Load<Model>Snapshot`, `ConsumeChanges`, every `Start<Model>Consumer` and
`startGenericConsumer` are at 0.0%; `findMaxCommitableRecord` is at 100%. The mock producer always returns true
(`tests/mocked_producer.go:15-21`), so produce-failure/DLQ paths are untested. Baselines: `validation-and-qa`.
