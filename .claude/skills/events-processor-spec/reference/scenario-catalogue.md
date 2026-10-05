# Scenario catalogue EPC-00 .. EPC-34

Part of `events-processor-spec` (re-implementation kit v1.5.0). One card per conformance scenario: what it pins,
how it runs, what the reference produces (compat golden) and what the corrected profile asserts. Read when a
scenario fails and you need to know what it is about. Files: `conformance/scenarios/<name>.json`, goldens
`conformance/golden/compat-{db,cache}/<name>.golden`, assertions `conformance/golden/corrected/<name>.assert.json`.

> **Licence.** The Lago events-processor and lago-api are AGPL-3.0. Scenarios and goldens are behavioural data
> written for the kit; no source code. A clean-room rebuild that will not be AGPL needs legal review
> (`reimplementation-kit` reference/legal-and-provenance.md).

## Fixture tenant (`conformance/fixtures/catalog-base.sql`)

Organizations O1 `11111111-…-111111111111` and O2 `99999999-…-999999999999`. Plans P1 `22222222-…-222222222222`,
P0 `22222222-…-000000000000` (O1), P2 `22222222-…-999999999999` (O2). Every event defaults to O1,
`external_subscription_id: "sub_ext_1"`, `timestamp: "1759320000"` (2025-10-01T12:00:00Z), `ingested_at` = now.

| Metric code (O1) | Type | Field | Notes |
|---|---|---|---|
| `api_calls` | sum (1) | `amount` | pay-in-advance charge on P1; normal charge on P0 |
| `count_calls` | count (0) | — | normal charge on P1 |
| `count_field` | count | `amount` | field ignored |
| `expr_metric` | sum | `total` | expression `event.properties.a * 2` |
| `expr_round` | sum | `total_value` | `round(event.properties.value * event.properties.units)` |
| `expr_ts` | sum | `ts_value` | `event.timestamp` |
| `max_amount` | max (2) | `amount` | its pay-in-advance charge is soft-deleted |
| `unique_users` | unique_count (3) | `user_id` | pay-in-advance |
| `storage_gb` | weighted_sum (5) | `gb` | recurring |
| `latest_level` | latest (6) | `level` | |
| `custom_metric` | custom (7) | none | |
| `legacy_type4` | retired code 4 | `amount` | |
| `seats` | sum, recurring | `seats` | pay-in-advance |
| `filtered_calls` | sum | `amount` | metric and charge filters exist (never read) |
| `deleted_metric` | sum | `amount` | soft-deleted |
| O2 `api_calls` | count | — | pay-in-advance on P2 |

| External id (O1 unless noted) | Subscription | Window (UTC) | Plan |
|---|---|---|---|
| `sub_ext_1` | …001 | from 2025-01-01 00:00:00.000500 | P1 |
| `sub_ext_term` | …002 | 2025-01-01 → 2025-06-01 00:00:00.000700 | P1 |
| `sub_ext_multi` | …003 / …004 | 2025-01-01 → 2025-03-01 / from 2025-03-01 | P0 / P1 |
| `sub_ext_future` | …005 | from 2030-01-01 (pending) | P1 |
| `sub_ext_late` | …006 | from 2025-09-01 | P1 |
| `sub_ext_incomplete` | …007 | from 2025-01-01, status incomplete | P1 |
| `acme`, `acme:eu` | …008, …009 | from 2025-01-01 | P1, P0 |
| `sub_ext_ms` | …010 | from 2025-03-03 13:03:29.123 | P1 |
| O2 `sub_ext_1` | …0f1 | from 2025-01-01 | P2 |

Memory-cache mode holds only subscriptions open or terminated within one month before the run, so …002 and
…003 are invisible there (EP-H7) and the cache goldens differ from the DB goldens accordingly.

## Cards

Notation: "DB" / "cache" = reference golden per mode; "C:" = corrected assertions (`d` decided, `p` proposed).

**EPC-00 smoke-parity** (both modes; EP-C2, EP-D1, EP-E1, EP-G1, EP-G3, EP-H4, EP-H5, EP-J1). Nine mixed records in
one batch: tiny `amount` (value `1e-07`, in-advance), unknown code (DLQ `fetch_billable_metric`), space-separated
timestamp (DLQ `build_enriched_event`), `{not json` (committed, no output), expression with a boolean property
(DLQ `evaluate_expression`), unknown subscription (enriched, empty ids), API-post-processed (enriched only),
event in the `started_at` millisecond (DB: matched; cache: not), expression success. C: none.

**EPC-01 aggregation-types** (both; EP-F1, EP-F2, EP-F4, EP-J2). One event per type: labels, `"1"` for count,
`12.5`, `"12"` verbatim, `<nil>` for a missing field, `1e+06` for unique_count 1000000, `""` label for code 4.
C: none (values covered by EPC-07).

**EPC-02 filters-pass-through** (both; EP-E3). Filter properties pass unchanged, including nested values. C: none.

**EPC-03 billable-metric-resolution** (both; EP-E1, EP-E2, EP-E4, EP-N1, EP-B4, EP-L1). Unknown, soft-deleted,
other-organization, unknown organization, empty and case-mismatched codes → DLQ `fetch_billable_metric`
(`record not found` / `Key not found`); control enriched. Then four organization ids that are not canonical UUID
text, and a later batch: DB mode: `org-not-a-uuid` and `""` fresh → lost (NO_OUTPUT_COMMITTED after the later batch
commits past them), `org-not-a-uuid` 13 h old → DLQ `fetch_billable_metric` with the database type error, the
UUID without hyphens → enriched, in-advance and refresh flag under that text; cache mode: all four → DLQ
`Key not found`. C: none (proposal in EP-E4: PERMANENT, dead letter at once; no assertion until the owner rules).

**EPC-04 subscription-matching** (both; EP-D3, EP-D4, EP-H1..H7). 18 events against the fixture windows: ordering,
both bounds, future start, recurring fallback (…006 with in-advance), no fallback for non-recurring, incomplete status
matched, exact external id, RFC 3339 offset (`2025-02-28T23:30:00-01:00`, the instant 00:30Z on 1 March: DB …003 by
wall clock; cache …004 as an instant), millisecond precision (`"1741007009.123"` and the number `1741007009.123` miss
…010; the RFC 3339 form matches). C (d): `sm_ms_exact_str` and `sm_ms_exact_num` → …010 (RBD-15), `sm_ts_offset` →
…004 (RBD-16), `sm_started_ms` → …001 (RBD-17), `sm_term_after` → none (RBD-15). The reference fails four in DB mode
(it passes `sm_started_ms`) and three in cache mode (it passes `sm_ts_offset`, which it already reads as an instant,
and `sm_term_after` only because …002 lies outside its snapshot window).

**EPC-05 expressions** (both; EP-G1..G3, EP-F3). Success (`"4"`), override of a sent field, skip for
`http_ruby`, failures (boolean property, missing variable, null properties), `round` → `"36"`, `event.timestamp`
→ `"1741007009.123"` / `"1741007009"`, decimal `0.1*2` → `"0.2"`, string operand. C: none.

**EPC-06 pay-in-advance** (both; EP-J1, EP-J2, EP-K1, EP-H7). The post-processing split (`http_ruby` + true →
no in-advance; false, missing metadata or another source → in-advance), no subscription, soft-deleted charge,
normal charge, other plan, missing property (still in-advance), O2, recurring metric. C: none.

**EPC-07 value-corpus** (both; EP-C5, EP-F2). The 27 corpus literals of `value-corpus.md` through `api_calls`
without subscription. C (d, RBD-13): 25 `value` assertions with the corpus `want_value`; the reference fails 13.

**EPC-08 time-formats** (both; EP-D1, EP-D2, EP-D6). 21 timestamp shapes: accepted ones with their emitted
number, rejected ones dead-lettered, `NaN` and `Inf` silently committed with no output, a hexadecimal float
accepted. C (d, RBD-4): `on_dlq` for `t_nan` and `t_inf`, `all_done`. Reference fails.

**EPC-09 undecodable-records** (both; EP-C1..C4, EP-D5). 15 records: invalid JSON, empty, array, `null` (an
unattributable DLQ record), numeric `precise_total_amount_cents`, string amount, array properties, bad / epoch /
millisecond `ingested_at`, numeric `transaction_id`, string `source_metadata`, extra fields, duplicate keys. DB and
cache: 9 records committed with no output. C (d, RBD-4): `all_done`; `done_with_cause` for the numeric amount.

**EPC-10 retry-lost-db-fault** (DB only; EP-B2..B4, EP-L1). One-shot database error on the subscription lookup of
`f_retry`; two good records later. Reference: `f_retry` committed with no output (silent loss). C (d, RBD-1):
`all_done`, `enriched f_retry`.

**EPC-11 retry-only-batch-restart** (DB only; EP-B4, EP-M1). Same fault, nothing follows, graceful restart:
`f_retry` re-delivered and enriched once (with in-advance). C (d, RBD-1, RBD-2): `all_done`, `no_dup` (reference passes).

**EPC-12 retry-stale-13h** (DB only; EP-L1, EP-D5). Same fault, `ingested_at` 13 h ago → DLQ `fetch_subscription`
at once. C (d, RBD-3): `all_done`, `done_with_cause` (reference passes).

**EPC-13 retry-no-ingested-at** (DB only; EP-L1, EP-D5). Same fault, no `ingested_at` → DLQ at once.
C (d, RBD-3): `all_done`, `done_with_cause` (reference passes; KQ-4 decides between DLQ and retry).

**EPC-14 retry-11h-pending** (DB only; EP-B4, EP-L1). Same fault, `ingested_at` 11 h ago, nothing follows, no
restart: the record stays uncommitted (pending). C (d, RBD-1): `all_done`, `enriched f_pending`. Reference fails.

**EPC-15 bm-db-fault** (DB only; EP-E2, EP-B3, EP-B4). One-shot error on the metric lookup; a later batch commits
past it (silent loss). C (d, RBD-1): `all_done`. Reference fails.

**EPC-16 charges-db-fault** (DB only; EP-J3, EP-B4). One-shot error on the charge lookup after the enriched produce
started: enriched kept, in-advance and refresh flag lost, later batch commits. C (d, RBD-8): `in_advance f_charge`,
`zset_has` for O1/…001. Reference fails.

**EPC-17 redis-fault** (both; EP-L5, EP-J3). Redis errors while `f_redis` is processed: enriched and in-advance
produced, flag lost after a later batch. C (d, RBD-9): `zset_has` O1/…001, `no_dup`. Reference fails `zset_has`.

**EPC-18 produce-reject-enriched** (both; EP-L2). The broker rejects the enriched produce of `f_enr`: DLQ with
empty code AND the in-advance record. C (d, RBD-6): `on_dlq f_enr` (non-empty code), `not_in_advance f_enr`.
Reference fails both.

**EPC-19 produce-reject-dlq** (both; EP-L4). Unknown code while the dead-letter produce is rejected: the record
reaches no topic and is committed. C (d, RBD-5): `all_done`. Reference fails.

**EPC-20 produce-reject-in-advance** (both; EP-L3). The broker rejects the in-advance produce: enriched + DLQ (code
`""`) for the same event. C (p, RBD-7): `not_on_dlq f_adv`, `in_advance f_adv` (UNRULED).

**EPC-21 restart-graceful** (both; EP-M1). 200 records, SIGTERM immediately, restart (pool capped at 20): each
record enriched exactly once, all committed. C (d, RBD-12): `all_done`, `no_dup` (reference passes).

**EPC-22 multi-partition** (both; EP-B5). Three partitions × three records, one DLQ-bound record in partition 1:
every partition commits 3. C: none.

**EPC-23 org-scoping** (both; EP-I1, EP-I5). Same code, external id and `transaction_id` in O1 and O2: distinct
keys, subscriptions and plans. C: none.

**EPC-24 refresh-zset** (both; EP-K1, EP-K2, EP-J1). Eight events, three distinct masked members (O1/…001,
O1/…004, O2/…0f1); none without subscription, for API-post-processed or for dead-lettered events. C: none.

**EPC-25 duplicate-transaction** (both; EP-I4). The same record twice → two identical enriched and in-advance
records (no deduplication; KEEP, RBD-11). C: none.

**EPC-26 .. EPC-29 startup contract** (both; EP-A2). Empty enriched-topic variable / Redis unreachable / Postgres
unreachable / empty broker list → exit status 2 before joining the group. C (d, RBD-23): `startup_exit` (non-zero
before readiness, within 30 s). `--loose-errors` compares the status as NONZERO.

**EPC-30 db-connection-burst** (DB only; EP-L6). 200 records in one poll + 1 later, database limit 30 for the
IUT role, default pool 200. No golden (timing). Reference: 85-170 of 201 records lost in nine runs.
C (d, RBD-10): `all_done`, `no_dup`.

**EPC-31 cdc-charge-update-column-gap** (cache only; EP-N3, EP-N4). A CDC charge row without `pay_in_advance`
replaces the cached pay-in-advance charge: `before_cdc` has in-advance, `after_cdc` none.
C (p, RBD-21): `in_advance after_cdc` (UNRULED pending the production column list).

**EPC-32 cdc-new-metric** (cache only; EP-N1, EP-N3). A metric created after start: DLQ `Key not found` before the
CDC row, enriched after. C: none.

**EPC-33 cdc-delete-metric** (cache only; EP-N6). Soft delete through CDC: enriched before, DLQ after. C: none.

**EPC-34 cdc-terminate-subscription** (cache only; EP-N6, EP-H1). Termination through CDC: an event after
`terminated_at` no longer matches, an event inside the old window still does. C: none.

## Provenance (maintainers)

Scenarios are generated by `scripts/gen-scenarios.py` (literal-preserving); goldens minted from the reference
binary (events-processor tree `83e012866f29`) with `scripts/maintainer/regen-goldens.sh` and confirmed by three
full passes per mode on 2026-10-02. Fixture column names and integer enums follow the billing engine's catalog
tables at lago-api `591ae90`: `$API/db/structure.sql:2340` (billable_metrics), `$API/db/structure.sql:3901`
(subscriptions), `$API/db/structure.sql:2581` (charges), aggregation codes `$API/app/models/billable_metric.rb:28`,
subscription statuses `$API/app/models/subscription.rb:58`.

EPC-03 changed on 2026-10-05 (kit v1.1): four organization-id records and a later batch were appended (generator
`scripts/gen-scenarios.py`); the earlier seven records and their golden lines are unchanged. Compat goldens of both
modes re-minted with `scripts/maintainer/regen-goldens.sh --only EPC-03 --passes 3` (three agreeing passes per mode,
then `--apply`).
