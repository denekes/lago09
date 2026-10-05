# Memory-cache mode (production): snapshot, CDC, and how it differs from DB mode

Part of `events-processor-spec` (re-implementation kit v1.1.0). **Production runs this mode** (owner decision
OD-1, 2026-10-02); DB mode is the development and fallback mode. Read when you implement the catalog cache or the
CDC consumers, or when a scenario behaves differently with `--mode cache`. Behaviour facts: reference
events-processor tree `83e012866f29` plus the corrected profile where stated. The production CDC connector
configuration (column list, authentication, broker list) is unknown to the kit: owner question OD-1b, kit item KQ-2.

> **Licence.** The Lago events-processor and lago-api are AGPL-3.0. This chapter states observable behaviour in
> neutral words and tables; it contains no copied source. A clean-room rebuild that will not be AGPL needs legal
> review (`reimplementation-kit` reference/legal-and-provenance.md).

## 1. What the cache holds

Enabled by `LAGO_USE_MEMORY_CACHE=true` (exact text). The process keeps, in memory, the catalog rows it needs and
never queries Postgres per event.

| Entity | Looked up by | Loaded at start (snapshot) | Kept current by |
|---|---|---|---|
| billable metrics | (organization, code) exact | rows with `deleted_at` null | CDC `…public.billable_metrics` |
| subscriptions | (organization, external id) — see EP-H8 | rows not terminated, or terminated less than one calendar month before the snapshot | CDC `…public.subscriptions` |
| charges | (organization, plan, metric) | rows with `deleted_at` null | CDC `…public.charges` |
| metric filters, charge filters, filter values | — (no rule reads them) | rows with `deleted_at` null | CDC topics of the same names |

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun and run-suite.sh against the Go reference -->

## 2. Rules

- **EP-N1** [vec: EPC-03, EPC-32]
  A metric missing from the cache gives the same dead-letter code as DB mode (`fetch_billable_metric`,
  non-retryable) with `initial_error_message` `Key not found` instead of `record not found`. An event for a metric
  created after the snapshot is dead-lettered until its CDC row arrives (no wait, no retry). Corrected: unchanged
  (whether a miss on a recently created object should be TRANSIENT is an open question of the accounting campaign,
  not graded).
- **EP-N2** [vec: ep.match_subscription.010, ep.match_subscription.017, ep.match_subscription.033, ep.match_subscription.033x, EPC-04]
  Subscription matching in cache mode compares instants at full microsecond precision (EP-H5), handles
  RFC 3339 offsets as instants (EP-D4), emulates the ordering of EP-H1 (open first, then `terminated_at`
  descending, then `started_at` descending; among exact ties the entry with the smallest id wins), and finds
  candidates by external-id key prefix (EP-H8; corrected: exact external-id equality, RBD-99, proposed).
- **EP-N3** [vec: EPC-31, EPC-32]
  Applying a CDC row (not a delete): the row is decoded into an EMPTY record (columns absent from the row
  take their zero value: false, empty, null); if the cache already holds an entry with the same key whose
  `updated_at`, truncated to milliseconds, is equal to or newer than the row's, the row is ignored; otherwise the
  entry is REPLACED WHOLE.
- **EP-N4** [vec: EPC-31]
  Consequence of EP-N3 with a CDC row that lacks a column: the cached value of that column is reset.
  The reference deployment's CDC column list omits `charges.pay_in_advance` and `billable_metrics.recurring`, so
  any edit of a charge switches its in-advance records off and any edit of a metric switches its recurring
  fallback off, until the next process start re-reads the snapshot. Corrected (RBD-21, proposed pending OD-1b): a
  missing column never resets a cached value (or the column list includes every column the processor reads).
- **EP-N5** [vec: EPC-21, EPC-31, EPC-32, EPC-33, EPC-34]
  Every process start creates six NEW CDC consumer groups (`lago_evp_<table>_<random UUID>`) that read
  every CDC topic from its earliest retained offset; old groups are left behind (six per start per replica).
  Replayed rows older than the snapshot are ignored by EP-N3.
- **EP-N6** [vec: EPC-33, EPC-34]
  Deletes: a metric, charge or filter row with `deleted_at` set removes the cached entry, but only when
  the cached entry has the same id (a re-created code is not removed by an old delete); a subscription row with
  `terminated_at` set REPLACES the cached entry with that row (so events before `terminated_at` still match) and
  expires it after 30 days. A row whose key is not cached is ignored by the delete path. Hard deletes (the CDC
  `__deleted` marker) are not honoured.
- **EP-N7** [vec: EPC-28]
  Start-up (reference): the snapshot is read once with its own small connection pool (10) and closed;
  if the database cannot be reached the process exits non-zero; if one table fails to load (missing table, query
  error) the failure is only logged and that part of the cache stays empty. CDC consumers take the broker list
  unsplit and without SASL/TLS settings (a comma-separated list or a secured cluster leaves them silently
  disconnected). Corrected: any snapshot load failure is fatal; CDC consumers use the same connection settings as
  the main consumer (proposals; not graded by the suite).

<!-- evidence-check: on -->

## 3. DB mode vs memory-cache mode (behaviour deltas)

| Aspect | DB mode (development) | Memory-cache mode (production) | Corrected |
|---|---|---|---|
| metric not found text | `record not found` | `Key not found` | text not a contract (RBD-24) |
| bound precision | milliseconds (truncated) | microseconds | milliseconds in both (RBD-17) |
| RFC 3339 offset | compared as wall clock | compared as instant | instant (RBD-16) |
| terminated subscriptions | all | ≤ 1 calendar month before snapshot (+ CDC) | owner (RBD-20) |
| external id with `:` | exact | prefix leak (EP-H8) | exact in both (RBD-99, proposed) |
| `organization_id` text (EP-E4) | any UUID spelling the database accepts matches; other text = retryable database error (lost when fresh) | exact canonical text, anything else not found (dead letter at once) | not UUID text: PERMANENT in both (RBD-1, proposed) |
| freshness | read-your-writes | snapshot + CDC lag | — |
| per-event database load | 2-4 queries | none | — |
| column gap | n/a | edit resets omitted columns (EP-N4) | proposed: never reset (RBD-21) |
| retryable lookup errors | connection/query errors (EP-E2) | essentially none (in-memory), so EPC-10..16 apply to DB mode only | — |

The conformance suite runs both modes: `--mode cache` seeds the six CDC topics with prefix `epconf_cdc`, sets
`LAGO_USE_MEMORY_CACHE=true` and `LAGO_DEBEZIUM_TOPIC_PREFIX`, and the CDC scenarios EPC-31..34 produce rows and
wait until a non-raw consumer group has committed the CDC topic to its end (the only black-box signal that a row
was applied).

## 4. Implementer notes

1. Keep the per-process CDC group (every replica needs every change) and the earliest-offset start (it closes the
   gap between snapshot read and consumer start); both are load-bearing. Deleting stale groups is an operations
   concern.
2. Decode CDC rows by column NAME; tolerate extra keys; decide explicitly what an absent column means (EP-N4).
3. Use exact (organization, external id) equality for subscriptions; do not build lookups by string prefix over
   ids that may contain the separator.
4. A rebuild may hold the catalog in any structure (maps, an embedded database); only the observable rules above
   are graded.
5. Consume CDC topics in a consumer group and commit only AFTER the polled rows are applied to the cache: the
   suite's `wait_cdc_applied` step treats "a non-raw group committed the CDC topic to its end" as the signal that a
   row is live, so a rebuild that reads CDC without a group (or commits before applying) never signals or signals
   too early, and EPC-31..34 fail or flake.

## Provenance (maintainers)

Reference events-processor tree `83e012866f29`: switch `events-processor/main.go:67`; snapshot
`events-processor/cache/cache.go:63` (pool of 10 at `:66`), loaders ignore errors `:78`; snapshot filters
`events-processor/models/subscriptions.go:56`, `events-processor/models/billable_metrics.go:85`,
`events-processor/models/charges.go:21`; CDC consumer `events-processor/cache/consumer.go:27` (group id) and
`:92` (apply), millisecond `updated_at` comparison `events-processor/cache/billable_metrics.go:68`,
`events-processor/cache/charges.go:73`, `events-processor/cache/subscriptions.go:168`; subscription TTL
`events-processor/cache/subscriptions.go:126`; prefix search `:46`. Reference CDC column list:
`extra/debezium_config.json:2` in the lago repository.
