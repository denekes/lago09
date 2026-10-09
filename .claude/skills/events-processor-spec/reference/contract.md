# Implementation contract: configuration, Kafka, Redis, Postgres, startup, shutdown

Part of `events-processor-spec` (re-implementation kit v1.6.0). Read before writing the process skeleton of an
events-processor: what it is configured with, what it reads and writes, how it starts, signals readiness and
stops. Behaviour facts: reference events-processor tree `83e012866f29` (compat profile) plus the corrected
profile where stated. Production runs **memory-cache mode** (owner decision OD-1); DB mode is the development and
fallback mode. Both are graded.

> **Licence.** The Lago events-processor and lago-api are AGPL-3.0. This chapter states observable behaviour in
> neutral words and tables; it contains no copied source. A clean-room rebuild that will not be AGPL needs legal
> review (`reimplementation-kit` reference/legal-and-provenance.md).

## 1. Role in the system

```
 billing API / ingestion connectors
          │ raw records (JSON)                         Postgres catalog (DB mode, per event)
          ▼                                            or snapshot + CDC topics (memory-cache mode)
   ┌──────────────────┐   reads metrics, subscriptions, charges   │
   │ events-processor │◀──────────────────────────────────────────┘
   └──────────────────┘
     │ enriched        │ charged-in-advance       │ dead-letter          │ refresh flag
     ▼                 ▼                          ▼                      ▼
 ClickHouse event   billing engine            dead-letter view       Redis sorted set
 store (usage)      (instant fees)            (operators)            (usage refresh clock)
```

The processor is stateless between records except for the memory cache: every output is derived from one raw
record plus the catalog at processing time.

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by run-suite.sh against the Go reference -->

## 2. Configuration (environment variables)

Names are part of the compat contract (deployments and the conformance runner set them). A rebuild that
configures itself differently ships a wrapper that maps these names.

| Variable | Meaning | Parse rule / default | Invalid or missing |
|---|---|---|---|
| `LAGO_KAFKA_BOOTSTRAP_SERVERS` | broker list | split on `,`, items trimmed | empty → fatal at startup (EP-A2) |
| `LAGO_KAFKA_RAW_EVENTS_TOPIC` | input topic | as is | not validated |
| `LAGO_KAFKA_ENRICHED_EVENTS_TOPIC` | enriched output topic | as is | empty → fatal (EP-A2) |
| `LAGO_KAFKA_EVENTS_CHARGED_IN_ADVANCE_TOPIC` | in-advance output topic | as is | empty → fatal |
| `LAGO_KAFKA_EVENTS_DEAD_LETTER_TOPIC` | dead-letter topic | as is | empty → fatal |
| `LAGO_KAFKA_CONSUMER_GROUP` | consumer-group PREFIX | group id = `<prefix>_<raw topic>` | not validated |
| `LAGO_KAFKA_SCRAM_ALGORITHM` | SASL SCRAM mechanism | `SCRAM-SHA-256` or `SCRAM-SHA-512`; empty = no SASL | reference: any other non-empty value crashes the process at startup; corrected: fatal with a message (RBD-23) |
| `LAGO_KAFKA_USERNAME`, `LAGO_KAFKA_PASSWORD` | SASL credentials | as is | — |
| `LAGO_KAFKA_TLS` | TLS to the brokers | boolean (`1`,`t`,`true`,`TRUE`,… / `0`,`f`,`false`,…); unparsable → false | — |
| `DATABASE_URL` | Postgres URL (DB mode; also the snapshot in cache mode) | libpq-style URL | unreachable → fatal (EP-A2) |
| `LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS` | DB-mode pool size | integer, default **200** | non-integer → fatal |
| `LAGO_REDIS_STORE_URL` | Redis address of the refresh flag | `host:port`; a leading `redis://` or `rediss://` is stripped | unreachable → fatal |
| `LAGO_REDIS_STORE_DB` | Redis database number | integer, default 0 | non-integer → fatal |
| `LAGO_REDIS_STORE_PASSWORD` | Redis password | as is | — |
| `LAGO_REDIS_STORE_TLS` | TLS to Redis | boolean; unparsable or unset → true only when `ENV` is `production` | — |
| `LAGO_USE_MEMORY_CACHE` | memory-cache mode | exactly `true` enables it; anything else = DB mode | — |
| `LAGO_DEBEZIUM_TOPIC_PREFIX` | CDC topic prefix (cache mode) | topics `<prefix>.public.<table>` | — |
| `ENV` | log verbosity (`development` or unset = debug) and the Redis TLS default | — | — |
| `SENTRY_DSN`, tracing variables | observability | out of scope of the contract | — |

Sizing rule (reference behaviour, EP-L6): pool size × replicas must stay below the connections the database grants
the processor's role, otherwise bursts turn into retryable failures and, in the reference, into silent loss.

## 3. Kafka objects

- **EP-A6** [vec: EPC-10, EPC-21, EPC-22]
  Input: topic `LAGO_KAFKA_RAW_EVENTS_TOPIC`, consumed in consumer group `<LAGO_KAFKA_CONSUMER_GROUP>_<raw topic>`
  (offset continuity across implementations depends on reusing this exact group id). A group without committed
  offsets starts at the EARLIEST retained offset. Offsets are committed manually per partition after a batch
  (`delivery-and-failures.md` §1); there is no automatic commit.
- **EP-A7** [vec: EPC-18, EPC-19, EPC-20, EPC-23]
  Outputs: enriched and in-advance records keyed `<organization_id>-<transaction_id>`; dead-letter
  records unkeyed; partition chosen by the producer's default partitioner. Producer guarantees (reference): wait
  for all in-sync replicas, idempotent producer, unlimited retries of retriable broker errors (so a broker outage
  blocks the record instead of losing it); a non-retriable rejection fails the produce (EP-L2..L4). Contract for a
  rebuild (both profiles): acknowledgement by all in-sync replicas is required; idempotence is NOT required,
  because duplicates are tolerated and removed downstream on `transaction_id` (EP-R7, RBD-11). Under the
  conformance suite, prefer a non-idempotent producer: an idempotent librdkafka producer stalls after the suite's
  injected rejection (`conformance-suite.md` §10, gotcha 11).
- **EP-A8** [vec: EPC-31, EPC-32, EPC-33, EPC-34]
  Memory-cache mode adds one consumer per CDC topic (`memory-cache-mode.md`), each in a NEW consumer group
  `lago_evp_<table>_<random UUID>` per process start, starting at the earliest offset, committing after every poll.

## 4. Postgres read set (DB mode)

The processor only reads. Per event, at most: one metric query, one or two subscription queries (two for a
recurring metric without a subscription at the event time), one charge query (only with a subscription and not
API-post-processed). The snapshot of memory-cache mode reads the same tables once.

| Table | Columns read | Selection |
|---|---|---|
| `billable_metrics` | `id`, `organization_id`, `code`, `aggregation_type` (integer), `recurring`, `field_name`, `expression`, `created_at`, `updated_at`, `deleted_at` | `organization_id = ? AND code = ? AND deleted_at IS NULL`, first row |
| `subscriptions` | `id`, `organization_id`, `external_id`, `plan_id`, `created_at`, `updated_at`, `started_at`, `terminated_at` (both `timestamp without time zone`, UTC wall clock, microseconds) | EP-H1 window, order EP-H1, first row |
| `charges` | `id` (existence only) | `organization_id = ? AND plan_id = ? AND billable_metric_id = ? AND pay_in_advance AND deleted_at IS NULL`, any row |
| `billable_metric_filters`, `charge_filters`, `charge_filter_values` | snapshot only (cache mode) | `deleted_at IS NULL` |

A least-privilege role with SELECT on these tables suffices (the conformance runner grants exactly that). The
reference never writes to Postgres.

## 5. Startup

- **EP-A1** [vec: EPC-26, EPC-27, EPC-28, EPC-29]
  Order (reference): logging, tracing and error reporting; in cache mode the snapshot (blocking) and the
  six CDC consumers; the broker list; three producers (enriched, in-advance, dead letter), each checked against the
  brokers; in DB mode the Postgres pool (checked with one round trip); Redis (checked with a ping); finally the
  consumer group join.
- **EP-A2** [vec: EPC-26, EPC-27, EPC-28, EPC-29]
  Fail fast: an empty broker list, an empty output-topic variable, an unreachable Redis, an unreachable
  Postgres (DB mode; cache mode: the snapshot connection), or a broker that does not answer the producer check
  stops the process with a NON-ZERO exit status BEFORE it joins the consumer group (reference status 2). Corrected
  (RBD-23): the same, within 30 s, with a message on the log, never a crash or a hang (a client library that
  waits forever on an empty broker list fails EPC-29).
- **EP-A3** [vec: EPC-26, EPC-27, EPC-28, EPC-29]
  Reference cache mode: CDC groups are created before the broker and Redis checks, so a failed start
  can leave up to six orphan `lago_evp_*` groups (timing-dependent, not compared). A snapshot table that fails to
  load is skipped silently (empty cache for that table; every event then dead-letters as "not found").
- **EP-A4** [vec: EPC-00, EPC-26, EPC-27, EPC-28, EPC-29]
  Readiness (observable from outside): the consumer group is Stable and its members own every partition
  of the raw topic. Every dependency is connected before that point, so readiness means "ready to process". The
  suite produces nothing before readiness.
- **EP-A5** [vec: prose only — not observable by the suite] Liveness signals beyond Kafka (HTTP health endpoint, metrics) are not part of the reference and not
  graded; a rebuild may add them.

## 6. Shutdown

- **EP-M1** [vec: EPC-11, EPC-21]
  On SIGTERM (or SIGINT) the process stops fetching, finishes the in-flight batch of every partition,
  commits per `delivery-and-failures.md` §1, leaves the group and exits with status 0. A restart resumes at the
  committed offsets: no record lost or duplicated by a graceful restart (KEEP, RBD-12). SIGKILL loses nothing
  committed but re-processes everything after the last commit (duplicates downstream are then expected,
  RBD-11).

## 7. Corrected-profile additions to the contract

| Item | Reference | Corrected |
|---|---|---|
| Retry topic | none | ADR-001 candidate `<raw topic>-retry`, consumer group `<prefix>_<retry topic>`, headers `attempt`, `first_failed_at`, `last_error_code`, `not_before` (names and variable: open owner question KQ-1; the suite does not seed or observe it, so corrected scenarios are designed to succeed with in-place retries) |
| Unknown SCRAM mechanism | crash | fatal with message (RBD-23) |
| Producer | idempotent, all in-sync replicas | all in-sync replicas required; idempotence optional (EP-A7) |
| Systemic failure | records left unprocessed, later commits pass them | pause the affected partitions with backoff 1 s → 60 s, commit nothing past the first record without a disposition (RBD-5, RBD-10); under the conformance suite retry delays are capped at 2 s by an implementation-specific setting (`delivery-and-failures.md` EP-R3) |
| Profile switch | — | an implementation that offers both profiles may select one by a setting of its own (for example an environment variable passed with `--impl-env`); not part of this contract, graded on separate runs (`conformance-suite.md` §9) |
| Observability | logs, error reporter | counters per disposition, lag, retry depth (not graded) |

<!-- evidence-check: on -->

## 8. Interfaces with other systems

| Peer | Direction | Contract fixed by |
|---|---|---|
| Billing API (lago-api) | produces raw records (only when its Kafka variables are set) | `wire-formats.md` §1 |
| Ingestion connectors | produce raw records (numeric timestamps, integer `ingested_at`) | `wire-formats.md` §1 |
| ClickHouse event store | consumes enriched | `wire-formats.md` §2 |
| Billing engine in-advance consumer | consumes in-advance | `wire-formats.md` §3 |
| Billing engine refresh clock | reads and removes refresh-flag members | `wire-formats.md` §5 |
| CDC pipeline (memory-cache mode) | produces catalog rows | `wire-formats.md` §6; production connector configuration unknown (owner question OD-1b) |
| Error reporter, tracing | receives | not graded |

## Provenance (maintainers)

Reference events-processor tree `83e012866f29`: startup `events-processor/main.go:27` (cache switch `:67`),
`events-processor/processors/main_processor.go:102` (broker check), `:56` (topic variables), `:80` (Redis),
`:133` (Postgres pool, default 200), `:152` (sorted-set name); group id `events-processor/config/kafka/consumer.go:237`,
poll size `:168`; SCRAM switch `events-processor/config/kafka/kafka.go:56`; Redis URL prefix
`events-processor/config/redis/redis.go:25`; snapshot `events-processor/cache/cache.go:63`; CDC group id
`events-processor/cache/consumer.go:27`. Exit statuses and readiness observed with
`scripts/run-suite.sh --only 'EPC-2[0-9]'` against the reference binary (3 passes per mode, 2026-10-02).

Addition of 2026-10-05 (kit v1.1): the idempotent-producer stall was measured with the maintainer self-test IUT
switched to `enable.idempotence=true` (confluent-kafka and librdkafka 2.15.1): after the runner's INVALID_RECORD
answers were cleared, every later produce failed with UNKNOWN_LEADER_EPOCH ("Leader epoch is newer than broker
epoch"), so EPC-19 ended with both records PENDING_UNCOMMITTED (`run-suite.sh --only 'EPC-(18|19|20)' --profile
corrected`: EPC-19 FAIL; EPC-18 fails for this IUT in any case, a documented deviation; EPC-20 UNRULED); the
unmodified self-test IUT (`enable.idempotence=false`) passes EPC-19. The Go reference's idempotent franz-go producer is not affected (compat goldens of EPC-18..20).
