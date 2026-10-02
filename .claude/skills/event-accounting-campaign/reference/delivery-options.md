# W1 delivery semantics: mechanism, constraints, ranked solution menu, ADR checklist

Read when you prepare Phase 4: the ADR, the owner question OPEN DECISION OD-2 (owner), or a review of any
change to `events-processor/config/kafka/consumer.go` or the disposition block of `processor.go`.
Code facts as of 5308258 (events-processor tree 83e012866f29); the working branch may carry skills-only
commits on top. franz-go v1.20.5 (module cache source); lago-api at the pin `591ae90` (2026-09-08).
Verified 2026-10-01. Nothing in this file is implemented; every option is a CANDIDATE.

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
   partition (case 2 control -> REDELIVERED). With steady traffic that window is one batch.

Related accounting holes that are not the retry path (cases 4, 5, 7): `processor.go:50-59` commits
undecodable records with no DLQ; `event_producer_service.go:70-73` only logs and captures a failed DLQ produce
and the record is still committed.

## 2. Constraints any fix must respect

| Constraint | Evidence | Consequence for a fix |
|---|---|---|
| `BlockRebalanceOnPoll` | `consumer.go:245`; `AllowRebalance` at `:203` runs after dispatch | dispatch blocks on an unbuffered channel (`:122`, `:195`) until the partition consumer finished its previous batch, so rebalances that revoke partitions wait for roughly one batch of processing. franz-go: "you should ensure that you always process records quickly" (`franz-go@v1.20.5/pkg/kgo/config.go:1760-1781`). Any in-batch waiting (backoff, blocking retry) eats into the rebalance timeout, default 60 s (`config.go:595`), after which the member is kicked |
| One partition consumer, sequential batches | `consumer.go:51-73,111-130` | a blocked partition blocks only itself, but also delays the poll loop's dispatch to every other partition (head-of-line through the unbuffered send, `:190-201`) |
| Up to 10 000 records per poll, one goroutine each, no limit | `consumer.go:168`; `processor.go:38-44` (`errgroup.Group{}`, no `SetLimit` anywhere: `grep -rn SetLimit events-processor` = 0 hits) | a DB blip fails thousands of records at once; DB pool default 200 (`processors/main_processor.go:134`), Redis pool 10 (`config/redis/redis.go:38`) |
| Produce is synchronous with unbounded retries | `config/kafka/producer.go:62`; franz-go `recordRetries: math.MaxInt64` (`config.go:563`); events-processor sets no producer retry/timeout option (`config/kafka/producer.go:33-35`) | a broker outage blocks (does not lose); only non-retriable broker errors (ledger case 6) and, by franz-go's defaults, a topic that stays UNKNOWN_TOPIC_OR_PARTITION after 4 tries (`maxUnknownFailures: 4`, `config.go:564`; code-read, not probed) reach the DLQ path |
| 12 h horizon from `ingested_at` | `processor.go:74`; zero `ingested_at` = immediate DLQ | measured in case 3. Raising it changes nothing in case 1 (the record is never re-polled). Whether 12 h is a product rule: OD-2 |
| `SetOffsets` caveats | `franz-go@v1.20.5/pkg/kgo/consumer.go:665-681`: with group consuming, call it "outside of the context of a PollFetches loop", not concurrent with revokes or commits | a seek-back cannot be issued from a partition goroutine as the code is structured today |
| History | chain A (`failure-archaeology`): `4100da0` (#474, committed every record, DLQ'd every failure) -> `cec0eb2` (#502, withhold retryable failures) -> `656c829` (#511) -> `600e195` (#628, introduced an infinite poll loop) -> `b604769` (#629, hotfix 3 days later) -> `b6d3616` (#608) -> `9acd83e` (#735, ING-15 "segfaulting the pod inside franz-go") | change-control N7: kfake test + ADR + owner sign-off before any change here. Going back to "commit every record" turns REDELIVERED into LOST (ledger UNACCOUNTED 5 -> 7, measured with a build overlay: SKILL.md Phase 4) |

## 3. Ranked solution menu (CANDIDATE; the choice is OPEN DECISION OD-2 (owner))

| Rank | Option | How | Ledger target (what the probe must show after) | Pros | Cons / risks | Class |
|---|---|---|---|---|---|---|
| 1 (recommended default) | **In-process bounded retry, then DLQ** | retry only the failed step (BM, subscription, pay-in-advance lookup, Redis flag) N times with capped backoff inside `processEvent`; on exhaustion DLQ with a distinct cause (e.g. `retry_exhausted:<code>`) and commit | case 1 -> ENRICHED (blip shorter than the budget) or DLQ; case 8 -> ENRICHED with flag; nothing withheld, so no LOST by construction | `processRecordsAndCommit` untouched (chain A risk avoided); small diff; accounted by construction; bounded latency | a long outage turns into DLQ volume, and no DLQ replay tool exists (at the pin only `$API/app/models/clickhouse/events_dead_letter.rb` reads the DLQ; `rake events:reprocess` is re-enrichment, not DLQ replay): a manual re-feed is CANDIDATE and needs OPEN DECISION OD-2 (owner), so ship it in the same campaign; total backoff must stay far below the 60 s rebalance timeout; the 12 h intent becomes seconds-to-minutes | C4 |
| 2 | **Retry topic with bounded attempts, then DLQ** | on retryable failure produce the raw record to a retry topic (attempt count + not-before in headers) and commit; a second consumer group in the same binary re-processes after the delay; after N attempts or 12 h -> DLQ | case 1 -> REDELIVERED via retry topic; case 7 -> retry-topic, never SENTRY_ONLY if the retry produce must succeed before commit | never blocks the main partition; keeps a long (12 h) horizon; commit rule stays "commit once the record is on exactly one topic" | new topic = new contract: dev topic list (`docker-compose.dev.yml:398-405`, `.env.development.default:78-86`), production provisioning outside this repo (invisible from here), deploy order (topic before binary); reordering of retried events (enrichment is per event; impact on Rails consumers UNVERIFIED); most code | C4 + C6 |
| 3 | **Seek back / pause the partition** | on a withheld record, commit the prefix, then rewind the fetch position to it (`SetOffsets`, `franz-go@v1.20.5/pkg/kgo/consumer.go:682`) and pause the partition with backoff (`PauseFetchPartitions` `:617` / `ResumeFetchPartitions` `:651`), coordinated through the poll loop | case 1 -> REDELIVERED; per-partition order kept | no new topic; keeps today's intent (retry until 12 h) | head-of-line blocking up to 12 h behind one record; must drop already-fetched records of that partition; `SetOffsets` caveats (section 2); re-processes successful records behind the failed one (duplicates); touches exactly the code of chain A | C4 |
| 4 | **Commit and DLQ immediately** | treat every failure as non-retryable | case 1 -> DLQ; case 8 would become ENRICHED+DLQ (predicted, not run) | trivial; accounted | every transient blip becomes DLQ volume and no DLQ replay tool exists; case 8 would double-account (enriched AND DLQ) unless side effects are reordered | C4 |

Decision guide for the owner (OD-2), to put in the ADR:
<!-- evidence-check: off decision guide (owner input), not claims -->

| If the owner says | Pick |
|---|---|
| "Retry for minutes is enough; DLQ + a manual re-feed (to be built) is acceptable" | 1 |
| "The 12 h horizon is a product requirement" and new topics are acceptable | 2 |
| "12 h, no new topics, per-partition order matters" | 3 (accept the blocking risk explicitly) |
| "Never retry" | 4, plus a DLQ re-feed tool first (none exists) |
<!-- evidence-check: on -->

Independent of OD-2 (still C4, still change-control N7):
- Do NOT turn the DLQ-produce failure (case 7) into "withhold" before W1 is fixed: withhold + later commit
  is exactly case 1, so SENTRY_ONLY would become LOST. Order: W1 fix, then case 7.
- Undecodable records (cases 4, 5): a DLQ entry needs the raw bytes. `FailedEvent`
  (`events-processor/models/event.go:50-56`) has no field for them, and the ClickHouse DLQ MV extracts
  `event.*` fields (rails-go-parity, payload schemas): adding a field is a cross-repo payload change
  (change-control N6, paired lago-api PR, OPEN DECISION OD-4 (owner)). Case 5 alone is better fixed by
  accepting a number (`value-and-time.md` s.5).
- Side-effect order: enriched is produced before the in-advance lookup and the Redis flag
  (`processor.go:110-131`). Any retry re-produces it (case 9: enriched=2, in_adv=2).

## 4. Downstream duplicate handling (what a retry may rely on)

| Mechanism | Evidence | Caveat |
|---|---|---|
| `events_enriched` is `ReplacingMergeTree(timestamp)` ordered by `(organization_id, code, external_subscription_id, toDate(timestamp), timestamp, transaction_id)` | `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:6-20` | collapses only at merge time |
| Query-time `FINAL` dedup | `$API/app/services/events/stores/clickhouse_store.rb:92-111`; gated by `deduplicate?` = CH store AND `clickhouse_deduplication_enabled?` (`$API/app/services/billable_metrics/aggregations/base_service.rb:161-169`) | the only env-driven setter is org creation with `LAGO_CLICKHOUSE_ENABLED` and `LAGO_DEFAULT_EVENT_STORE=clickhouse` (`$API/app/services/organizations/create_service.rb:17-19`); also set by `$API/lib/tasks/recipes/clickhouse.rake:109` and the enriched-store migration (`comparison_service.rb:61-64`); production state per org UNKNOWN |
| Pay-in-advance idempotency | `$API/app/services/events/pay_in_advance_service.rb:15,55-56` (`already_processed?` on `pay_in_advance_event_transaction_id`) | per fee; a duplicate in-advance message is ignored |
| `Events::Stores::Clickhouse::CleanDuplicatedService` | `$API/app/services/events/stores/clickhouse/clean_duplicated_service.rb:54` (`having("count() > 1")`) | no caller in `app/`, `lib/`, `config/` or `clock.rb` at `591ae90` (only its spec): do not count on it. Do not confuse it with `CleanDuplicatedEnrichedExpandedService` (called from `$API/lib/tasks/events.rake:44` and the enriched-store migration orchestrator), which deletes from `events_enriched_expanded`, not `events_enriched` |

So: redelivery duplicates are tolerated by the CH read path when dedup is on and by pay-in-advance; this is
what makes options 1-3 safe in principle. A test that proves it end to end does not exist here (UNVERIFIED).

## 5. ADR checklist (change-control N7 requires an ADR in the PR)

<!-- evidence-check: off checklist, not claims -->

1. Problem with the ledger before (`run.sh accounting-probe`, case table) and the scoreboard line.
2. The owner's OD-2 answer (quote it) and the option chosen from section 3, with the rejected ones and why.
3. Interaction analysis: `BlockRebalanceOnPoll`, rebalance timeout, unbuffered dispatch, 10k batches,
   produce retries, 12 h horizon, duplicates (section 2 and 4 rows, each answered).
4. Ledger after: every case's fault row, `UNACCOUNTED=0`, run 3x plus `GOFLAGS=-race`.
5. A kfake test inside the PR that drives `processRecordsAndCommit` (change-control N7), not only this skill's probe.
6. Observability (Phase 1 signals) that will show the new behaviour in production, and the rollback switch.
7. Deploy order and rollback (and topic provisioning for option 2).
<!-- evidence-check: on -->
