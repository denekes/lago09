# Delivery and failures: batches, commits, retries, loss (compat vs corrected)

Part of `events-processor-spec` (re-implementation kit v1.0.0). Read when you implement consumption, commits,
retries and the dead-letter path, or when you decide which profile a deployment needs. The compat profile
reproduces the reference at events-processor tree `83e012866f29`, INCLUDING its silent-loss modes (useful only
for migration testing against existing data). The corrected profile is the delivery contract ADR-001 (owner
decision OD-2, 2026-10-02) plus the decided rebuild decisions; a greenfield rebuild implements the corrected
profile.

> **Licence.** The Lago events-processor and lago-api are AGPL-3.0. This chapter states observable behaviour in
> neutral words, tables and fresh pseudocode; it contains no copied source. A clean-room rebuild that will not be
> AGPL needs legal review (`reimplementation-kit` reference/legal-and-provenance.md).

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun and run-suite.sh against the Go reference -->

## 1. Consumption and commit (reference)

- **EP-B1** [vec: EPC-21, EPC-22]
  The consumer polls up to 10 000 records at a time and hands each partition's records, in offset order,
  to that partition's worker as one batch. All records of a batch are processed concurrently; the batch completes
  when every record finished. Partitions progress independently.
- **EP-B2** [vec: ep.commit_offset.001, ep.commit_offset.002, ep.commit_offset.003, ep.commit_offset.004, ep.commit_offset.005, ep.commit_offset.009, ep.commit_offset.010, EPC-10, EPC-12, EPC-13]
  Each record ends as PROCESSED or UNPROCESSED. PROCESSED: outputs produced; or a non-retryable failure
  (dead-letter attempted, whether or not that produce succeeded); or a retryable failure whose `ingested_at` is 12 h
  old or older, or unknown (dead-letter attempted); or an undecodable record (nothing produced). UNPROCESSED: a
  retryable failure younger than 12 h.
- **EP-B3** [vec: ep.commit_offset.001, ep.commit_offset.002, ep.commit_offset.003, ep.commit_offset.004, ep.commit_offset.005, ep.commit_offset.009, ep.commit_offset.010, EPC-10, EPC-15]
  Commit after a batch: if every record is PROCESSED, commit the offset after the last record;
  otherwise commit the offset after the highest PROCESSED record that lies below the lowest UNPROCESSED record; if
  there is none, commit nothing for this batch.
- **EP-B4** [vec: ep.commit_offset.009, ep.commit_offset.010, ep.commit_offset.009x, ep.commit_offset.010x, EPC-10, EPC-11, EPC-14, EPC-15, EPC-16]
  UNPROCESSED records are not fetched again by the running process: they come back only after a restart
  or a partition reassignment, and only if no later batch of the same partition committed past them first. With
  continued traffic the next batch commits past them: SILENT LOSS. Corrected (RBD-1): never commit past a record
  without a durable disposition (the unit op models this with `pending_before`).
- **EP-B5** [vec: EPC-22]
  A dead-lettered or failing record in one partition does not delay or affect other partitions.
- **EP-B6** [vec: EPC-22]
  Output order inside a batch is not defined (records are processed concurrently); consumers must not
  rely on it.

## 2. Failure classes and outcomes (reference)

| Failure | Code | Retryable | Outcome in the reference |
|---|---|---|---|
| undecodable bytes / wrong field types | — | — | nothing produced, committed (EP-C2) |
| invalid timestamp, the `null` literal | `build_enriched_event` | no | dead letter |
| non-finite timestamp (`NaN`, `Inf`) | — | — | nothing produced, committed (EP-D6) |
| metric not found | `fetch_billable_metric` | no | dead letter |
| expression failure | `evaluate_expression` | no | dead letter |
| metric / subscription / charge lookup error | `fetch_billable_metric` / `fetch_subscription` / `fetch_pay_in_advance_charge` | yes | EP-L1 |
| `organization_id` not UUID text (DB mode; EP-E4) | `fetch_billable_metric` | yes (database type error) | EP-L1 (cache mode: not found, dead letter at once) |
| refresh-flag write error | `flag_subscription_refresh` | yes | EP-L1 (enriched and in-advance already produced) |
| broker rejects the enriched produce | `""` | — | EP-L2 |
| broker rejects the in-advance produce | `""` | — | EP-L3 |
| broker rejects the dead-letter produce | — | — | EP-L4 |
| database connection limit reached | lookup error codes | yes | EP-L6 |

- **EP-L1** [vec: EPC-10, EPC-12, EPC-13, EPC-14]
  Retry horizon: a retryable failure whose `ingested_at` is less than 12 h before now leaves the record
  UNPROCESSED (EP-B2); at 12 h or more, or when `ingested_at` is unknown, the record is dead-lettered at once with its
  code. There is no in-process retry.
- **EP-L2** [vec: EPC-18] The broker rejects the enriched produce (non-retriable error): a dead-letter record with
  `error_code: ""`, `error_message: ""`, `initial_error_message: "failed to push to <topic> topic"`; the in-advance
  record IS still produced; the record is PROCESSED.
- **EP-L3** [vec: EPC-20]
  The broker rejects the in-advance produce: the enriched record exists AND a dead-letter record (code
  `""`) is written for the same event; PROCESSED.
- **EP-L4** [vec: EPC-19]
  The broker rejects the dead-letter produce: the record reaches no topic and is still committed
  (silent loss).
- **EP-L5** [vec: EPC-17]
  A refresh-flag write error happens after both records were produced; the record is UNPROCESSED; a
  later batch commits past it and the flag is never written.
- **EP-L6** [vec: EPC-30]
  Database connection exhaustion: the reference pool admits 200 connections by default; when the
  database grants fewer, a burst turns into retryable lookup failures, each a candidate for EP-B4 loss. Measured on
  the reference with a 30-connection limit and a 201-record burst: 168, 133, 168, 170, 164, 170, 85, 167 and 164 records
  lost in nine runs (timing-dependent; assertions only).

Loss modes of the reference, by scenario: EPC-10 / EPC-15 (transient lookup error, later batch), EPC-03
(an `organization_id` that is not UUID text, DB mode, later batch), EPC-16
(in-advance and flag lost), EPC-17 (flag lost), EPC-19 (dead-letter produce rejected), EPC-09 (undecodable
records), EPC-08 (non-finite timestamps), EPC-30 (connection exhaustion). Duplicates of the reference:
restart after an UNPROCESSED record whose enriched record was already produced (EPC-16 class), and any
re-delivery (EPC-25).

## 3. Corrected profile: the delivery contract (ADR-001)

- **EP-R1** [vec: EPC-09, EPC-18, EPC-19, EPC-30]
  Classify every failure. SYSTEMIC: a dependency is unavailable (catalog store or cache source, Redis,
  produce to the dead-letter or retry topic), or most of a batch fails with the same retryable error. TRANSIENT: a
  retryable error on one record while its neighbours succeed. PERMANENT: not retryable (unknown metric, invalid
  payload or timestamp, undecodable bytes, expression failure, a record-specific broker rejection; proposed: an
  `organization_id` that is not UUID text, EP-E4).
- **EP-R2** [vec: ep.commit_offset.009x, ep.commit_offset.010x, EPC-10, EPC-14, EPC-15, EPC-19, EPC-30]
  Commit rule: commit offset N only when every record at or below N has a DURABLE disposition
  acknowledged by all in-sync replicas: enriched (and, where due, in-advance) produced; or published to the retry
  topic; or dead-lettered. A failed dead-letter or retry-topic produce is SYSTEMIC, never "log and continue".
- **EP-R3** [vec: EPC-17, EPC-19, EPC-30]
  SYSTEMIC: route nothing; pause the affected partitions; exponential backoff with jitter (default 1 s
  doubling to 60 s); probe the dependency; resume when healthy. Never commit past the first record without a
  disposition (RBD-5, RBD-10). "Pause" is observable only as "no progress past the blocked record": the mechanism
  is free (the client's partition pause and resume, or a worker that blocks on the record), provided the process
  keeps its group membership for the whole outage (heartbeats continue; a blocking worker sets the client's
  maximum poll interval above its longest backoff, or keeps polling without losing the fetched records) and never
  commits past the record. Under the conformance suite, cap every retry delay (SYSTEMIC backoff and TRANSIENT
  in-place retries) at 2 s or less: the suite ends a wait after 3 s without an observable change
  (`conformance-suite.md` EP-P3), so a retry scheduled later than that after a fault clears is judged too late
  (measured: a 1 s → 60 s schedule fails EPC-17, a 2 s cap passes). How the cap is switched on is an
  implementation choice (for example a configuration variable of the implementation's own, passed with
  `--impl-env`); it is not part of the environment contract, and production keeps the defaults above.
- **EP-R4** [vec: EPC-10, EPC-11, EPC-12, EPC-13, EPC-14, EPC-15]
  TRANSIENT: retry the failed STEP in place (default 3 attempts, 100 ms → 1 s, jittered, total far below
  the group's rebalance timeout); then publish the original record to the retry topic (candidate `<raw>-retry`,
  headers `attempt`, `first_failed_at`, `last_error_code`, `not_before`; KQ-1) — that publication is the record's
  disposition; a retry consumer re-processes it when due (candidate schedule 30 s, 2 min, 10 min, 1 h, 4 h); after N
  attempts (default 5) or a maximum age (default 12 h from `ingested_at`) → dead letter with the cause (kit
  default, proposed: the code and message of the failing step, as the reference writes past its horizon;
  `wire-formats.md` §4). Age of a record without `ingested_at`: open owner question
  (KQ-4); kit default until the owner rules (RBD-3 keeps today's behaviour): an unknown age counts as past the
  maximum age, so once the in-place budget is spent the record is dead-lettered with its cause instead of being
  published to the retry topic (dead-lettering at the first failure, as the reference does, also conforms; EPC-13
  passes with either outcome).
- **EP-R5** [vec: EPC-08, EPC-09, EPC-18]
  PERMANENT: dead letter at once with a non-empty `error_code`; undecodable bytes with the raw bytes and
  the parse error (`wire-formats.md` §4) (RBD-4, RBD-6).
- **EP-R6** [vec: EPC-16, EPC-17, EPC-18]
  Side-effect order per record: produce the enriched record first; only after it succeeded produce the
  in-advance record and write the refresh flag; a retry repeats only the side effects that have not succeeded
  (RBD-6, RBD-8, RBD-9).
- **EP-R7** [vec: EPC-25]
  Downstream idempotency on `transaction_id` is REQUIRED (retries and replays can duplicate outputs);
  the processor itself does not deduplicate (RBD-11).
- **EP-R8** [vec: prose only — no black-box observable]
  Observability is part of ADR-001 (counters per disposition, lag per partition, retry depth and age,
  dead-letter rate alert, a daily raw-vs-(enriched ∪ dead-letter) reconciliation) but is not graded by the suite.

Two consequences an implementer must design for: (1) the suite does not seed or read a retry topic (KQ-1), so its
corrected scenarios inject one-shot faults that an in-place retry absorbs; an implementation that skips the
in-place budget and goes straight to a delayed retry topic fails `all_done` in EPC-10/14/15 (the record is
committed on the raw topic but has no enriched output when the run ends). (2) In-place retries must not repeat
successful produces, or the run never becomes quiescent and `no_dup` fails (EPC-17). (3) Retry delays must fit
the suite's quiescence window (EP-R3: at most 2 s under the suite).

<!-- evidence-check: on -->

## 4. Rebuild decisions on delivery (summary; full text in `reimplementation-kit` reference/rebuild-decisions.md)

| RBD | Reference (compat golden keeps it) | Corrected target | Ruling | Scenarios |
|---|---|---|---|---|
| RBD-1 | transient failure < 12 h left unprocessed; a later batch commits past it | in-place retry, then retry topic; never commit past (an `organization_id` that is not UUID text: PERMANENT, proposed) | decided (organization id: proposed) | EPC-10, EPC-14, EPC-15, EPC-03 |
| RBD-2 | unprocessed records re-delivered only after restart | superseded by RBD-1 | decided | EPC-11 |
| RBD-3 | ≥ 12 h or unknown age → dead letter at once | dead letter after N attempts or max age; unknown age: KQ-4 | decided (KQ-4 open) | EPC-12, EPC-13 |
| RBD-4 | undecodable / non-finite timestamp → committed, no output | dead letter with raw bytes and cause | decided (field and code names KQ-5) | EPC-08, EPC-09 |
| RBD-5 | dead-letter produce rejected → committed, nowhere | SYSTEMIC pause | decided | EPC-19 |
| RBD-6 | enriched produce rejected → dead letter with empty code, in-advance still produced | non-empty code, no in-advance | decided | EPC-18 |
| RBD-7 | in-advance produce rejected → enriched + dead letter | retry in place, then pause; never dead-letter an event whose enriched record exists | proposed | EPC-20 |
| RBD-8 | charge lookup error after enriched → in-advance and flag lost | both produced | decided | EPC-16 |
| RBD-9 | flag write error → flag lost | flag eventually written, only the flag retried | decided | EPC-17 |
| RBD-10 | connection exhaustion → mass loss | 0 lost, 0 duplicates | decided | EPC-30 |
| RBD-11 | duplicates not removed | KEEP; downstream idempotency required | KEEP | EPC-25 |
| RBD-12 | graceful restart: no loss, no duplicate | KEEP | KEEP | EPC-21 |
| RBD-23 | startup failure exits 2 (a crash for an unknown SCRAM mechanism) | non-zero within 30 s, never a crash or hang | decided | EPC-26..29 |

## 5. Corrected pseudocode (fresh; one partition worker)

```
loop:
  batch ← next records of this partition (offset order)
  for each record r (concurrently, bounded):
      outcome[r] ← handle(r)            # ENRICHED | DEAD_LETTERED | RETRY_PUBLISHED | SYSTEMIC
  if any outcome = SYSTEMIC:
      pause partition; backoff; re-handle the records without a disposition; continue
  commit(offset after the longest prefix of records that all have a disposition)

handle(r):
  try PERMANENT checks (decode, timestamp, metric, expression) → on failure: dead_letter(r, code) or SYSTEMIC
  for step in [enrich-lookups, produce enriched, (lookup charge, produce in-advance), write flag]:
      skip if step already succeeded for r
      retry step in place up to the budget
      on exhaustion: publish r to the retry topic (or dead-letter if attempts/age exhausted)
```

## Provenance (maintainers)

Reference events-processor tree `83e012866f29`: poll size `events-processor/config/kafka/consumer.go:168`, commit
`:82` and prefix selection `:278`; record outcome and 12 h horizon
`events-processor/processors/events_processor/processor.go:49` (decode) and `:74` (horizon); producers
`events-processor/processors/events_processor/event_producer_service.go:51` (dead letter) and `:76`
(rejection path). ADR-001 text: `event-accounting-campaign` reference/delivery-options.md §0 (library skill). EPC-30
loss counts measured with `scripts/run-suite.sh --only EPC-30` (nine runs in three sessions, 2026-10-02, reference binary, Postgres 16
with `max_connections=100` shared with other workloads).

Additions of 2026-10-05 (kit v1.1). EP-R3 retry-delay cap under the suite: the maintainer self-test IUT
(`scripts/maintainer/selftest-iut.py`, blocking in-place retries) run with `--only 'EPC-(17|19)' --profile corrected`
passes both with its 0.1 s → 2 s schedule and fails EPC-17 `zset_has` when the schedule is changed to 1 s → 60 s (the
retry after the Redis fault cleared came after the 3 s wait had ended). The organization-id row of §2: EPC-03
goldens (see `processing-rules.md` Provenance). The KQ-4 default follows the RBD-3 row of `reimplementation-kit`
reference/rebuild-decisions.md ("today's behaviour kept").
