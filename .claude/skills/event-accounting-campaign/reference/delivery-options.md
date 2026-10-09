# W1 delivery semantics: ADR-001 (the delivery contract), mechanism, constraints, implementation plan

Read when you implement or review Phase 4, any change to `events-processor/config/kafka/consumer.go`,
the disposition block of `processor.go` or `event_producer_service.go`, or when someone asks "retry topic
or block the partition?". The choice is made: **ADR-001, ACCEPTED (delegated by owner 2026-10-02)** (section 0).
Code facts as of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only
commits on top. franz-go v1.20.5 (module cache source); lago-api at the pin `591ae90` (2026-09-08).
Sections 1-4 verified 2026-10-01; section 0 facts re-verified 2026-10-02. Nothing here is implemented:
the decision is ACCEPTED, the code is CANDIDATE until merged with evidence.

## 0. ADR-001: delivery contract for retryable and non-retryable failures

- **Status:** ACCEPTED (delegated by owner 2026-10-02). The owner answered OD-2 with "reason with industry best
  practice"; recorded as DECIDED OD-2 (owner, 2026-10-02) in `change-control` §9. The owner may amend it;
  an implementation that deviates from it needs the owner before review (`change-control` §8 rules).
- **Decisions touched:** DECIDED OD-2 (owner, 2026-10-02) (this ADR); DECIDED OD-3 (owner, 2026-10-02)
  (ClickHouse schema/config work allowed, used for dedup); DECIDED OD-4 (owner, 2026-10-02) (paired PRs only
  where another repo depends); DECIDED OD-1 (owner, 2026-10-02) (production runs memory-cache mode, so every
  gate runs in both modes); OPEN DECISION OD-1b (owner) does not change this ADR.
- **Change class of the implementation:** C4 (+ C6 for the dev topic list); change-control N7 applies
  (in-repo kfake ledger test + this ADR referenced in the PR). The CHOICE is not reopened per PR.

### 0.1 Context (measured)

- Ledger today (`.claude/skills/event-accounting-campaign/scripts/run.sh accounting-probe [-mode cache]`, 2026-10-02): DB mode `UNACCOUNTED=5` (1 LOST, 1 SKIPPED_RETRY,
  3 SENTRY_ONLY); memory-cache mode `UNACCOUNTED=4` (cases 4, 5, 7 SENTRY_ONLY, case 8 SKIPPED_RETRY).
  Mechanism: section 1. "Commit every record" measured: `UNACCOUNTED` 5 -> 7 (SKILL.md Phase 4 overlay).
- SYSTEMIC failures are not hypothetical (2026-10-02): a 200-record burst against a Postgres role with
  `CONNECTION LIMIT 30` and the default pool of 200 (`events-processor/processors/main_processor.go:134`) loses
  164-170 of 200 records (opt-in ledger case 15,
  `.claude/skills/event-accounting-campaign/scripts/run.sh accounting-probe -case db-connection-exhaustion`); the
  kit measured 85-170 of 201 on the reference binary (`events-processor-spec` EPC-30). Every refused connection
  is a retryable lookup failure that today's commit rule skips (section 1); under this ADR it is SYSTEMIC (pause,
  back off, commit nothing past the first record without a disposition).
- A non-finite `timestamp` (`"NaN"`) is committed with no output: `strconv.ParseFloat` accepts it
  (`events-processor/utils/time.go:56-58`) and the marshal error of the enriched record is only logged
  (`events-processor/processors/events_processor/event_producer_service.go:77-79`). Opt-in ledger case 16: SENTRY_ONLY
  in both modes; kit `events-processor-spec` EPC-08. A PERMANENT failure that must reach the DLQ with a cause.
- Repo facts that shape the choice (verified 2026-10-02):

| Fact | Evidence | Consequence |
|---|---|---|
| produced keys are `<org>-<transaction_id>` | `events-processor/processors/events_processor/event_producer_service.go:30,41`; DLQ records carry no key (`:66-68`) | no per-subscription ordering requirement on our outputs: a record may be retried out of order |
| franz-go can pause, resume and rewind partitions | `PauseFetchPartitions` `franz-go@v1.20.5/pkg/kgo/consumer.go:617`, `ResumeFetchPartitions` `:651`, `SetOffsets` `:682` (with its group-consuming caveats `:665-681`) | SYSTEMIC handling can pause without a seek-back |
| producer: acks = all ISR, idempotent | franz-go default `acks: AllISRAcks()` (`franz-go@v1.20.5/pkg/kgo/config.go:557`), idempotency on unless `DisableIdempotentWrite` (`:221`, `:1052`); events-processor passes no producer option (`events-processor/config/kafka/producer.go:34-35`) | a successful `ProduceSync` is a durable disposition |
| one goroutine per record, up to 10 000 records per poll, unbuffered fan-out, `BlockRebalanceOnPoll` | `events-processor/config/kafka/consumer.go:168,122,195,245`; `processor.go:38-44` | in-batch waiting must stay far below the 60 s rebalance timeout; never block the poll loop |
| downstream dedup is conditional | `FINAL` only with `clickhouse_deduplication_enabled` (`$API/app/services/billable_metrics/aggregations/base_service.rb:161-169`); pay-in-advance `already_processed?` (`$API/app/services/events/pay_in_advance_service.rb:15,55-56`); section 4 | retries may duplicate side effects: downstream idempotency becomes a requirement (point 3) |

### 0.2 Industry practice relied on

<!-- evidence-check: off external sources cited as industry practice (URLs), not repo claims -->
Cited as practice, not as proof. The pages were not fetchable from this sandbox (search summaries only,
2026-10-02):
- Uber Engineering, "Building Reliable Reprocessing and Dead Letter Queues with Apache Kafka" (2018,
  https://www.uber.com/blog/reliable-reprocessing/): primary topic -> delayed retry topic(s) -> DLQ;
  non-blocking reprocessing so failures do not stall real-time traffic.
- Confluent, "Error handling patterns in Kafka" (https://www.confluent.io/blog/error-handling-patterns-in-kafka/)
  and "Kafka dead letter queue" (https://www.confluent.io/learn/kafka-dead-letter-queue/): a DLQ so failed
  records do not block the pipeline; stop/block only when ordering must be preserved.
- Spring for Apache Kafka reference, "Combining blocking and non-blocking retries"
  (https://docs.spring.io/spring-kafka/reference/retrytopic/retry-topic-combine-blocking.html): retry in
  place (blocking) for errors likely to hit the next records too (e.g. database access), send
  record-specific failures to retry topics, dead-letter topic at the end.
<!-- evidence-check: on -->

### 0.3 Decision

<!-- evidence-check: off ADR-001 decision text (normative, ACCEPTED 2026-10-02); evidence in 0.1 and sections 1-4 -->
1. **Classify every failure** as SYSTEMIC, TRANSIENT (record-level) or PERMANENT:

| Class | What it is | Action | Ledger cases |
|---|---|---|---|
| SYSTEMIC | a dependency is unavailable (Postgres or the cache source, Redis, Kafka produce to the DLQ or retry topic), or most of a batch fails with the same retryable error (e.g. connection exhaustion: refused connections) | route nothing; pause the affected partitions (`PauseFetchPartitions`); commit nothing past the first un-dispositioned record; exponential backoff with jitter (default 1 s doubling to a 60 s cap); probe the dependency; resume when healthy. Head-of-line blocking is correct here: every record would fail | 7, 15, new 13, 14 |
| TRANSIENT | a retryable error on one record while its neighbours succeed | small in-place retry of the failed step (default 3 attempts, 100 ms -> 1 s, jittered; total far below the rebalance timeout because of `BlockRebalanceOnPoll`); then publish the ORIGINAL record to a retry topic (default name `<raw>-retry`) with headers `attempt`, `first_failed_at`, `last_error_code`, `not_before`; that publish IS the record's disposition. A retry consumer re-processes when due. After N attempts (default 5) or a max age (default 12 h from `ingested_at`, today's horizon) -> DLQ with the cause | 1, 2, 3, 8, 9, new 11, 12 |
| PERMANENT | non-retryable: unknown billable metric, invalid payload (including a non-finite `timestamp`), unmarshal error, expression error | DLQ at once with the cause. Unmarshal failures go to the DLQ with the raw bytes and the parse error, never a silent commit | 4, 5, 6, 10, 16 |

2. **Commit rule.** Commit offset N only when every record <= N has a DURABLE disposition acknowledged by
   Kafka with acks=all: enriched (+ in-advance) produced, OR retry-topic produced, OR DLQ produced. A failed
   DLQ or retry-topic produce is SYSTEMIC (pause + backoff), never "Sentry only".
3. **Side-effect order per record.** Produce `events_enriched` first; only after it succeeds produce
   `events_charged_in_advance` and set the Redis refresh flag. Retries can still duplicate side effects, so
   downstream idempotency is REQUIRED: transaction_id dedup in ClickHouse (`clickhouse_deduplication_enabled`
   / `FINAL` for CH-store orgs; config/schema work allowed by DECIDED OD-3 (owner, 2026-10-02)) and pay-in-advance
   `already_processed?` (exists, section 4).
4. **Observability is part of the contract:** counters per disposition (enriched, retried, dlq by
   `error_code`, systemic pause seconds), consumer lag per partition, retry-topic depth and age, a DLQ-rate
   alert and a daily connector-aware reconciliation (raw vs enriched UNION DLQ): `observability-and-production.md` s.5.
5. **Replay:** an operator-gated DLQ -> raw-topic replay tool that stamps a replay header; safe only because
   of point 3. A later step (section 6, step 4e); until it ships, no DLQ replay tool exists.
6. **Rejected:**
   - commit everything: silent loss (ledger `UNACCOUNTED` 5 -> 7, measured);
   - block the partition on ANY record failure: one poison record stalls a tenant's traffic for up to 12 h;
   - unbounded in-process retry: rebalances stall under `BlockRebalanceOnPoll`, the member is kicked after 60 s;
   - Kafka transactions / exactly-once: the Redis side effect is not transactional; cost without closing the gap.

Default parameters (tune with ledger and throughput evidence in the PR; changing a default is not a
deviation, changing a class or the commit rule is): SYSTEMIC detector = a dependency health check fails,
or at least 50 % of a batch of at least 10 records fails with the same retryable `error_code` (CANDIDATE threshold);
retry-topic schedule 30 s, 2 min, 10 min, 1 h, 4 h (CANDIDATE; sums to about 5 h 13 min, inside 12 h).
<!-- evidence-check: on -->

### 0.4 Topic and contract impact (DECIDED OD-4 (owner, 2026-10-02): paired PR only where another repo depends)

| Change | Who else reads or writes it | Paired PR | Class |
|---|---|---|---|
| new retry topic `<raw>-retry` + its env var + the retry consumer group `<LAGO_KAFKA_CONSUMER_GROUP>_<retry topic>` | no other repo reads it (internal to events-processor); it must EXIST in every environment | no lago-api PR. Dev: `docker-compose.dev.yml:398-405` topic list + `.env.development.default:78-86` (C4 + C6). lago-helm-charts provisions the existing topics (`change-control` K6 row: `charts/lago/values.yaml:113` + the create-topic job), so a paired helm PR adds the topic; production provisioning = owner/ops. A new group starts at the earliest offset (`change-control` K7) | C4 + C6 |
| DLQ payload gains the raw bytes + parse error for unmarshal failures | lago-api ClickHouse `events_dead_letter_queue` and its MV, which reads `JSONExtractString(event, …)` (`$API/db/clickhouse_migrate/20260430075848_update_events_dead_letter_mv.rb:9-26`) | YES: paired lago-api PR (K6 dependency); the tolerant reader ships first (lago-api), then Go (`change-control` §6: Go writes K6) | C4 |
| new `error_code` values (e.g. `retry_exhausted:<code>`) | same DLQ table: a string column | additive, no paired PR (`change-control` K6 row) | C4 |
| enriched and in-advance payloads (`event_producer_service.go:28-45`) | unchanged by ADR-001 | none | — |

### 0.5 Consequences

<!-- evidence-check: off ADR consequences (normative); evidence in 0.1, 0.4 and sections 1-4 -->
- Positive: no silent loss by construction (every committed record has a durable disposition); a poison
  record never blocks its partition; an outage blocks instead of flooding the DLQ; the 12 h horizon becomes
  a bounded, observable retry window instead of a window that never re-polls (case 1).
- Negative: duplicates on retry and replay are expected, so downstream idempotency is a prerequisite
  (point 3, section 4); a new topic to provision and monitor; a retried record lands later than its
  neighbours (acceptable: keys are per transaction, 0.1); consumer lag grows during a SYSTEMIC pause (by
  design: alert on it).
- Memory-cache mode (production: DECIDED OD-1 (owner, 2026-10-02)): a cache miss can be CDC lag rather than a permanent fact.
  ADR-001 classifies "not found" as PERMANENT; whether a miss on a recently created object should be
  TRANSIENT is a W6 question (`memory-cache-w6.md` s.3, CANDIDATE), not a change of this ADR.
<!-- evidence-check: on -->

### 0.6 Failure matrix: expected disposition under ADR-001 (the Phase 4 ledger targets)

Cases 1-10 exist today (`ledger-and-matrix.md` s.3); 11-14 are added in step 4a (section 6). "RETRIED" =
finally ENRICHED or DLQ after at least one hop through the retry topic (a new probe outcome, step 4a).
<!-- evidence-check: off TARGET table; the "today" column is the measured ledger (ledger-and-matrix.md s.3-4, run.sh accounting-probe [-mode cache]) -->

| # | Case | Today DB / cache | Class | Target after step 4c (both modes where the case exists) |
|---|---|---|---|---|
| 1 | `retryable-then-later-batch` | LOST / n/a | TRANSIENT | ENRICHED (in-place retry succeeds) |
| 2 | `retryable-only-batch` | REDELIVERED / n/a | TRANSIENT | ENRICHED |
| 3 | `retryable-stale-12h` (re-armed to fail 4x) | DLQ / n/a | TRANSIENT past max age | DLQ, cause `retry_exhausted:fetch_subscription` (max age), never on the retry topic |
| 4 | `unmarshal-bad-json` | SENTRY_ONLY / SENTRY_ONLY | PERMANENT | DLQ with raw bytes + parse error (step 4d, K6 paired PR) |
| 5 | `numeric-precise-total-amount-cents` | SENTRY_ONLY / SENTRY_ONLY | PERMANENT until W2 | ENRICHED after Phase 2 item 3; DLQ (raw bytes) after step 4d if W2 is later |
| 6 | `enriched-produce-failure` (INVALID_RECORD) | DLQ, in_adv=1 / same | PERMANENT (record-specific broker error) | DLQ, **in_adv=0** (point 3) |
| 7 | `dlq-produce-failure` | SENTRY_ONLY / SENTRY_ONLY | SYSTEMIC | DLQ after the pause (REDELIVERED with final DLQ is equally fine); never committed before |
| 8 | `redis-flag-then-later-batch` | SKIPPED_RETRY / SKIPPED_RETRY | TRANSIENT | ENRICHED, enriched=1, in_adv=1, ZSET member set (the flag step is retried, not the produce) |
| 9 | `redis-flag-only-batch` | REDELIVERED (x2) / same | TRANSIENT | ENRICHED, enriched=1, in_adv=1 |
| 10 | `missing-bm-nonretryable` | DLQ / DLQ | PERMANENT | DLQ (unchanged) |
| 11 | `retryable-exceeds-inplace` (new: fault 4x on one record, neighbours fine) | LOST predicted / n/a | TRANSIENT | RETRIED (final ENRICHED) |
| 12 | `retryable-exhausts-retry-topic` (new: fault persists over 5 retry attempts; schedule compressed to ms) | LOST predicted / n/a | TRANSIENT | DLQ `retry_exhausted:fetch_subscription`, headers attempt=5 |
| 13 | `systemic-outage` (new: every lookup or Redis call fails for a while, 20 records) | PENDING then REDELIVERED predicted / same | SYSTEMIC | 0 records on the retry topic or DLQ; partition paused, then all ENRICHED; systemic pause counter > 0 |
| 14 | `retry-produce-failure` (new: case 11 while the retry topic rejects produces) | n/a (no retry topic) | SYSTEMIC | RETRIED (final ENRICHED) after the pause; never committed before |
| 15 | `db-connection-exhaustion` (OPT-IN, built 2026-10-02: 200-record burst, role `CONNECTION LIMIT 30`, pool 200) | 164-170 of 200 LOST (measured) / n/a | SYSTEMIC | every burst row ENRICHED (pause and back off while connections are refused); 0 LOST, 0 duplicates; kit EPC-30 PASS |
| 16 | `non-finite-timestamp` (OPT-IN, built 2026-10-02: `"timestamp": "NaN"`) | SENTRY_ONLY / SENTRY_ONLY (measured) | PERMANENT | DLQ with a non-empty cause (e.g. `build_enriched_event`); kit EPC-08 PASS |

<!-- evidence-check: on -->
Totals target: `LOST=0 SKIPPED_RETRY=0 SENTRY_ONLY=0 PENDING=0 ENRICHED+DLQ=0 UNACCOUNTED=0` in DB mode
and in cache mode, for the default run and for the opt-in cases 15-16 (`ledger-and-matrix.md` s.3). "Predicted"
rows are hypotheses until step 4a measures them. Second gate: the kit's corrected profile, run on the candidate
binary (`ledger-and-matrix.md` s.7).

## 1. The mechanism (measured: ledger cases 1, 2, 8)

1. `ProcessEvents` returns only the records it wants committed. A retryable failure younger than 12 h is
   left out (`events-processor/processors/events_processor/processor.go:74-78`). `FailedResult` defaults to
   `Retryable=true, Capture=true` (`events-processor/utils/result.go:113-120`), so every unknown DB, badger or
   Redis error takes this path.
2. `processRecordsAndCommit` commits the longest processed prefix of THIS batch
   (`events-processor/config/kafka/consumer.go:89-104`), or skips the commit when the first record failed
   (`:94-99`, comment: "records will be re-polled after the next rebalance").
3. franz-go's fetch position is in memory and already past the batch; nothing rewinds it. The next fully
   processed batch on the partition calls `CommitRecords` with a higher offset (`:104`). The withheld record
   is now below the committed offset: it is never re-polled, never DLQ'd. Case 1 -> LOST; case 8 ->
   SKIPPED_RETRY (enriched and in-advance were produced before the Redis failure at `processor.go:110-131`).
4. It is redelivered only if the process restarts or loses the partition before any later commit on that
   partition (case 2 control -> REDELIVERED; the skip at `consumer.go:94-99`). With steady traffic that window is one batch.

Related accounting holes that are not the retry path (cases 4, 5, 7): `processor.go:50-59` commits
undecodable records with no DLQ; `event_producer_service.go:70-73` only logs and captures a failed DLQ produce
and the record is still committed.

## 2. Constraints any implementation must respect (ADR-001 answers each in section 0)

| Constraint | Evidence | Consequence for a fix |
|---|---|---|
| `BlockRebalanceOnPoll` | `consumer.go:245`; `AllowRebalance` at `:203` runs after dispatch | dispatch blocks on an unbuffered channel (`:122`, `:195`) until the partition consumer finished its previous batch, so rebalances that revoke partitions wait for roughly one batch of processing. franz-go: "you should ensure that you always process records quickly" (`franz-go@v1.20.5/pkg/kgo/config.go:1760-1781`). Any in-batch waiting (backoff, blocking retry) eats into the rebalance timeout, default 60 s (`config.go:595`), after which the member is kicked |
| One partition consumer, sequential batches | `consumer.go:51-73,111-130` | a blocked partition blocks only itself, but also delays the poll loop's dispatch to every other partition (head-of-line through the unbuffered send, `:190-201`) |
| Up to 10 000 records per poll, one goroutine each, no limit | `consumer.go:168`; `processor.go:38-44` (`errgroup.Group{}`, no `SetLimit` anywhere: `grep -rn SetLimit events-processor` = 0 hits) | a DB blip fails thousands of records at once; DB pool default 200 (`processors/main_processor.go:134`), Redis pool 10 (`config/redis/redis.go:38`). Measured: a pool above the database's connection budget loses most of one burst (ledger case 15: 164-170 of 200), so the SYSTEMIC detector must see refused connections as a dependency failure, not as 200 TRANSIENT records for the retry topic |
| Produce is synchronous with unbounded retries | `config/kafka/producer.go:62`; franz-go `recordRetries: math.MaxInt64` (`config.go:563`); events-processor sets no producer retry/timeout option (`config/kafka/producer.go:33-35`) | a broker outage blocks (does not lose); only non-retriable broker errors (ledger case 6) and, by franz-go's defaults, a topic that stays UNKNOWN_TOPIC_OR_PARTITION after 4 tries (`maxUnknownFailures: 4`, `config.go:564`; code-read, not probed) reach the DLQ path |
| 12 h horizon from `ingested_at` | `processor.go:74`; zero `ingested_at` = immediate DLQ | measured in case 3. Raising it changes nothing in case 1 (the record is never re-polled). ADR-001 keeps 12 h as the default retry max age (DECIDED OD-2 (owner, 2026-10-02)) |
| `SetOffsets` caveats | `franz-go@v1.20.5/pkg/kgo/consumer.go:665-681`: with group consuming, call it "outside of the context of a PollFetches loop", not concurrent with revokes or commits | a seek-back cannot be issued from a partition goroutine as the code is structured today |
| History | chain A (`failure-archaeology`): `4100da0` (#474, committed every record, DLQ'd every failure) -> `cec0eb2` (#502, withhold retryable failures) -> `656c829` (#511) -> `600e195` (#628, introduced an infinite poll loop) -> `b604769` (#629, hotfix 3 days later) -> `b6d3616` (#608) -> `9acd83e` (#735, ING-15 "segfaulting the pod inside franz-go") | change-control N7: kfake test + ADR (ADR-001 referenced in the PR) before any change here. Going back to "commit every record" turns REDELIVERED into LOST (ledger UNACCOUNTED 5 -> 7, measured with a build overlay: SKILL.md Phase 4) |

## 3. Historical options menu (2026-10-01, superseded by ADR-001 on 2026-10-02)

Kept as the record of what was weighed. ADR-001 is a combination: option 1's small in-place budget and
option 2's retry topic for TRANSIENT failures, option 3's pause (without a seek-back) for SYSTEMIC
failures only, option 4's immediate DLQ for PERMANENT failures only.

<!-- evidence-check: off historical menu; evidence per row in the cells and sections 1-2 -->
| Rank (2026-10-01) | Option | How | Under ADR-001 |
|---|---|---|---|
| 1 | In-process bounded retry, then DLQ | retry the failed step N times with capped backoff inside `processEvent`; on exhaustion DLQ (`retry_exhausted:<code>`) | **CHOSEN in part**: the in-place budget for TRANSIENT; exhaustion goes to the retry topic, not straight to the DLQ |
| 2 | Retry topic with bounded attempts, then DLQ | produce the raw record to a retry topic (attempt + not-before headers), commit; a retry consumer re-processes; after N attempts or 12 h -> DLQ | **CHOSEN** for TRANSIENT after the in-place budget (Uber/Confluent/Spring practice, section 0.2) |
| 3 | Seek back / pause the partition | rewind with `SetOffsets` and pause with backoff until success or 12 h | **CHOSEN only for SYSTEMIC** (pause without seek-back: the held batch stays in memory); rejected for single records (poison-record stall) |
| 4 | Commit and DLQ immediately | treat every failure as non-retryable | **CHOSEN only for PERMANENT**; rejected for retryable failures (every blip becomes DLQ volume) |
| — | Commit every record (no withhold) | the `4100da0` origin design | REJECTED: silent loss, `UNACCOUNTED` 5 -> 7 |
<!-- evidence-check: on -->

Still true and binding for the implementation (from the 2026-10-01 analysis):
- Do NOT turn the DLQ-produce failure (case 7) into a bare "withhold" while the old commit rule
  (`processor.go:74-78`, `consumer.go:89-104`) is in place: withhold + a later commit is exactly case 1, so SENTRY_ONLY would become LOST. ADR-001 point 2
  (commit rule) and the SYSTEMIC pause must land in the same change as the case-7 handling.
- Undecodable records (cases 4, 5): a DLQ entry needs the raw bytes. `FailedEvent`
  (`events-processor/models/event.go:50-56`) has no field for them, and the ClickHouse DLQ MV extracts
  `event.*` fields: a cross-repo payload change (K6, paired lago-api PR, section 0.4). Case 5 alone is
  better fixed by accepting a number (`value-and-time.md` s.5).
- Side-effect order today: enriched and in-advance are produced concurrently in an errgroup
  (`processor.go:110-126`), so an enriched failure still emits the in-advance event (case 6: in_adv=1) and any
  retry re-produces both (case 9: enriched=2, in_adv=2). ADR-001 point 3 changes this order.

## 4. Downstream duplicate handling (what a retry may rely on)

| Mechanism | Evidence | Caveat |
|---|---|---|
| `events_enriched` is `ReplacingMergeTree(timestamp)` ordered by `(organization_id, code, external_subscription_id, toDate(timestamp), timestamp, transaction_id)` | `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:6-20` | collapses only at merge time |
| Query-time `FINAL` dedup | `$API/app/services/events/stores/clickhouse_store.rb:92-111`; gated by `deduplicate?` = CH store AND `clickhouse_deduplication_enabled?` (`$API/app/services/billable_metrics/aggregations/base_service.rb:161-169`) | the only env-driven setter is org creation with `LAGO_CLICKHOUSE_ENABLED` and `LAGO_DEFAULT_EVENT_STORE=clickhouse` (`$API/app/services/organizations/create_service.rb:17-19`); also set by `$API/lib/tasks/recipes/clickhouse.rake:109` and the enriched-store migration (`comparison_service.rb:61-64`); production state per org UNKNOWN |
| Pay-in-advance idempotency | `$API/app/services/events/pay_in_advance_service.rb:15,55-56` (`already_processed?` on `pay_in_advance_event_transaction_id`) | per fee; a duplicate in-advance message is ignored |
| `Events::Stores::Clickhouse::CleanDuplicatedService` | `$API/app/services/events/stores/clickhouse/clean_duplicated_service.rb:54` (`having("count() > 1")`) | no caller in `app/`, `lib/`, `config/` or `clock.rb` at `591ae90` (only its spec): do not count on it. Do not confuse it with `CleanDuplicatedEnrichedExpandedService` (called from `$API/lib/tasks/events.rake:44` and the enriched-store migration orchestrator), which deletes from `events_enriched_expanded`, not `events_enriched` |

So: redelivery duplicates are tolerated by the CH read path when dedup is on and by pay-in-advance. ADR-001
point 3 makes this a REQUIREMENT: CH-store orgs need `clickhouse_deduplication_enabled` (FINAL) before
retries or a replay may duplicate their enriched rows (lago-api config/data work, allowed by
DECIDED OD-3 (owner, 2026-10-02); which production orgs have it: UNVERIFIED, owner). A test that proves dedup end to end
does not exist here (UNVERIFIED).

## 5. PR checklist for an ADR-001 implementation (change-control N7: an ADR in the PR)

The ADR exists (section 0); the PR body references it and adds what only the PR knows.

<!-- evidence-check: off checklist, not claims -->
1. "Implements ADR-001 (ACCEPTED (delegated by owner 2026-10-02)), steps <4x>"; any deviation named, with the owner's sign-off.
2. Ledger before/after in BOTH modes (`run.sh accounting-probe`, `run.sh accounting-probe -mode cache`):
   every fault row against section 0.6, 3 runs + one `GOFLAGS=-race` run each.
3. The in-repo kfake test (section 6, test design) with its output; it drives `processRecordsAndCommit`.
4. Interaction answers: `BlockRebalanceOnPoll`, rebalance timeout, unbuffered dispatch, 10k batches,
   produce retries, max age, duplicates (sections 2 and 4, each row answered).
5. Parameters used (in-place budget, backoff cap, SYSTEMIC detector, retry schedule) and why.
6. Observability: which counters and log fields show each class in production (`observability-and-production.md` s.5).
7. Deploy order and rollback (section 6, step 4b/4c), topic provisioning evidence (dev compose diff,
   helm PR link), paired lago-api PR link when K6 changes.
<!-- evidence-check: on -->

## 6. Implementation plan (Phase 4 in SKILL.md is the short form)

<!-- evidence-check: off implementation plan (CANDIDATE steps and gates); facts it relies on are cited in sections 0-4 -->
**Step 4a - make the probe see ADR-001 (C1 to this skill + `diagnostics-and-tooling` harness).**
Before any events-processor change: add the retry topic to the kfake topic list and read it back; add
outcomes RETRIED (finally ENRICHED/DLQ after a retry-topic hop) and RETRY_PARKED (on the retry topic at the
end, `not_before` inside the max age: accounted, bounded); add a repeat count to the DB and Redis faults;
add cases 11-14 (section 0.6) with today's measured outcome as `expected`. The harness `pipeline` package
must start the retry consumer once the binary has one (same PR as step 4c, both skills). Gate:
`scoreboard.sh --check-baseline` moves only `ledger_rows`/`cache_ledger_rows` and the LOST/UNACCOUNTED rows
the new cases add, each explained; baselines updated in the same PR.

**Step 4b - provisioning first (C4 + C6; deploy order: topic before binary).** Add `events-raw-retry` (name
CANDIDATE) to `docker-compose.dev.yml:398-405` and its env var to `.env.development.default:78-86`; paired
lago-helm-charts PR (topic + env), production topic by owner/ops. No behaviour change, so the ledger and
scoreboard must not move (`--check-baseline` exit 0). Rollback: leave the empty topic.

**Step 4c - the Go contract (C4, change-control N7; one PR, after Phase 1 signals and with Phase 5a).**
Classification (section 0.3 point 1), in-place budget, retry producer + retry consumer (same binary, own
group), DLQ after N attempts or max age, SYSTEMIC pause/backoff/resume, the commit rule (point 2), DLQ and
retry produce failures as SYSTEMIC, side-effect order (point 3), counters (point 4). Implementation
constraints the kfake test must pin:
- the backoff loop runs in the partition goroutine, selects on its `quit` channel (revokes wait for `done`,
  `consumer.go:132-150`) and never on the SIGTERM context (change-control N5: records use the batch context
  `consumer.go:83`);
- the poll loop must never block on a paused partition's unbuffered channel (`consumer.go:122,195`): hold
  or queue the next batch in order instead, or `AllowRebalance` (`:203`) stalls for the whole outage;
- what franz-go does with already-buffered fetches of a partition you pause is UNVERIFIED here: the test
  proves that no record after the held one is processed or committed before resume, and none is skipped;
- `SetOffsets` is not needed (no seek-back) and must not be called from the partition goroutine (section 2).

Gates (all in the PR; commands from the repo root, `S=.claude/skills/event-accounting-campaign/scripts`):

| Gate | Command | Expected after step 4c |
|---|---|---|
| ledger, DB mode | `$S/run.sh accounting-probe` (x3, + once with `GOFLAGS=-race`) | every row as section 0.6 except cases 4/5; `LOST=0 SKIPPED_RETRY=0 PENDING=0`, `SENTRY_ONLY=2` (cases 4, 5), exit 2 |
| ledger, cache mode | `$S/run.sh accounting-probe -mode cache` (x3 + race) | same rows as section 0.6; `SENTRY_ONLY=2`, exit 2 |
| scoreboard | `$S/scoreboard.sh --check-baseline` | exit 3; moved exactly: `unaccounted_records` 5->2, `lost` 1->0, `skipped_retry` 1->0, `sentry_only` 3->2, `cache_unaccounted_records` 4->2 (+ ledger rows from step 4a, coverage rows from Phase 5a) |
| in-repo kfake test | `.claude/skills/build-and-env/scripts/ep-test.sh -race -count=1 ./config/kafka/... ./processors/...` | ok; includes a revoke-during-pause case that finishes well below the 60 s rebalance timeout with no commit past the held record |
| N9 | change-control "Pre-PR gate for events-processor code" | as stated there |
| throughput | `.claude/skills/diagnostics-and-tooling/scripts/kfake-run.sh happy-path -n 50000 -partitions 4` (cache mode by default; also `-store db`) before and after | PASS; relative elapsed reported; more than 10 % slower needs an explanation (CANDIDATE threshold) |
| connection exhaustion | `$S/run.sh accounting-probe -case db-connection-exhaustion` (x3) | `LOST=0`, every burst row ENRICHED (today 164-170 LOST) |
| kit gate (second gate) | `.claude/skills/events-processor-spec/scripts/run-suite.sh --impl-cmd <candidate binary> --impl-env LD_LIBRARY_PATH=... --profile corrected`, `--mode db` and `--mode cache` (`ledger-and-matrix.md` s.7) | EPC-10..19 and EPC-30 PASS (DB), EPC-17..19 PASS (cache); EPC-20 may stay UNRULED (RBD-7 proposed); after step 4d also EPC-08 and EPC-09 |

Deploy order: step 4b everywhere first. Rollback: redeploy the previous image; offsets stay compatible;
records parked on the retry topic are not consumed by the old binary, so drain the retry topic (or accept a
re-feed later) before rolling back.

**Step 4d - unmarshal failures to the DLQ with the raw bytes (C4, K6, paired lago-api PR).** Additive field
in `FailedEvent` (e.g. `raw_event` string, `event` left empty); the lago-api DLQ queue/MV accepts it first,
then Go writes it (section 0.4). Gate: case 4 -> DLQ (and case 5 -> DLQ unless Phase 2 item 3 already made
it ENRICHED); then `unaccounted_records=0` and `cache_unaccounted_records=0`; `--check-targets` passes for
the ledger rows.

**Step 4e - replay tool (later; C4, operator-gated).** Only after downstream idempotency is confirmed for the
affected orgs (point 3): a command that reads `events_dead_letter` (or the DLQ topic) by org, `error_code`
and time window, re-produces the ORIGINAL raw record to the raw topic with a replay header (run id,
attempt), defaults to dry-run, refuses PERMANENT causes unless forced, and logs counts only (no payloads:
`security-and-supply-chain`). A ledger case proves a replayed DLQ record ends ENRICHED exactly once
downstream of dedup. Until then: no DLQ replay tool exists.

**Test design (Phase 5a, required by change-control N7 for steps 4c/4d):**
- `events-processor/config/kafka/consumer_kfake_test.go`: kfake cluster with the raw and retry topics, the
  REAL `NewConsumerGroup` with a scripted `ProcessRecords` (per offset: enriched / retry / dlq / systemic);
  assert with `kadm` committed offsets that no commit ever passes an un-dispositioned record; assert pause and
  resume on SYSTEMIC; a revoke during a pause.
- `events-processor/processors/events_processor/processor_kfake_test.go`: real producers on kfake; DB faults
  through a gorm callback or sqlmock, Redis faults through miniredis, produce faults through
  `ControlKey(kmsg.Produce)`; table-driven over section 0.6 in both data-source modes (memory cache seeded
  like the harness fixture); assert the disposition, output topics, retry headers and `in_adv` counts.
- Deterministic: inject the clock and the backoff/retry schedule (milliseconds in tests); wait on
  observable conditions (committed offsets, topic high watermarks); no sleeps (`ledger-and-matrix.md` s.5).
- kfake becomes a test dependency in `events-processor/go.mod` (C5, change-control N3): pin the pseudo-version
  that keeps franz-go at the events-processor version (`v0.0.0-20251123185109-2b5c574e9ddd` for v1.20.5;
  version trap: `diagnostics-and-tooling`).
<!-- evidence-check: on -->
