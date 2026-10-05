# Processing rules: from one raw record to its outputs

Part of `events-processor-spec` (re-implementation kit v1.3.0). Read when you implement or grade the per-record
pipeline: decoding, time, metric resolution, the `value` string, expressions, subscription matching, the
pay-in-advance split and the refresh flag. Behaviour facts: reference events-processor tree `83e012866f29`
("compat" profile) and the kit's corrected profile (ADR-001 plus the rebuild decisions RBD-n of
`reimplementation-kit` reference/rebuild-decisions.md). Delivery, commit and failure handling: `delivery-and-failures.md`.

> **Licence.** The Lago events-processor and lago-api are AGPL-3.0. This chapter states observable behaviour in
> neutral words, tables and fresh pseudocode; it contains no copied source. A clean-room rebuild that will not be
> AGPL needs legal review of the kit and of the process (`reimplementation-kit` reference/legal-and-provenance.md).

Conventions. "Reference" = the observed behaviour at the pin (compat profile). "Corrected" = what the corrected
profile requires where it differs. Rule lines end with a "vec" tag listing unit vectors (`ep.<op>.<nnn>`, twin `…x`,
ranges `a-b` inclusive) in `vectors/ep.units.jsonl` and conformance scenarios `EPC-NN`. "Mode" = DB mode
(catalog read from Postgres per event) or memory-cache mode (catalog held in memory, fed by a snapshot and CDC;
the PRODUCTION mode, see `memory-cache-mode.md`).

## 1. Pipeline at a glance

```
raw bytes ──decode──▶ event ──time──▶ (emitted timestamp, matching instant)
   │ undecodable                │ invalid → DLQ build_enriched_event
   ▼                            ▼
 (§2 C2)              metric lookup (org, code) ──not found──▶ DLQ fetch_billable_metric
                                │
                    expression (if metric has one and source ≠ "http_ruby") ──fails──▶ DLQ evaluate_expression
                                │
                    value string (count → "1", else text of properties[field_name])
                                │
                    subscription lookup at the matching instant (+ recurring fallback at "now")
                                │
                    ENRICHED record produced (always, with or without subscription)
                                │ subscription found AND not API-post-processed?
                    ┌───────────┴─────────────┐
            charge lookup: pay-in-advance?   refresh flag (Redis sorted set)
                    │ yes
            IN-ADVANCE record produced (same bytes as the enriched record)
```

Retryable lookup errors (connection, query, Redis) do not produce a DLQ record directly: they make the record
"unprocessed" or dead-letter it depending on its age (`delivery-and-failures.md` §2).

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun and run-suite.sh against the Go reference -->

## 2. Decoding (EP-C)

- **EP-C1** [vec: ep.decode.001, ep.decode.005, ep.decode.006, ep.decode.007, ep.decode.008, ep.decode.009, ep.decode.010, ep.decode.011, ep.decode.014, ep.decode.019, ep.decode.023, EPC-09]
  The record value must be one JSON object. Recognised top-level fields and the JSON types they accept:
  `organization_id`, `external_subscription_id`, `transaction_id`, `code`, `source` (strings; JSON `null` reads as
  the empty string), `precise_total_amount_cents` (string only), `properties` (object or null), `timestamp` (any
  JSON value; validated later, EP-D1), `source_metadata` (object `{"api_post_processed": boolean}` or null),
  `ingested_at` (EP-D5). Any other JSON type for a recognised field makes the record undecodable.
  Recognised names match IGNORING CASE, in both profiles: `Code`, `CODE` and `code` are the same field, and so are
  `API_POST_PROCESSED` and `api_post_processed` inside `source_metadata`; keys inside `properties` keep their case.
  The reference folds case per Unicode simple case folding (the long s `ſ` also matches `s`); only ASCII case
  differences are part of the contract.
- **EP-C2** [vec: ep.decode.005, ep.decode.006, ep.decode.007, ep.decode.008, ep.decode.009, ep.decode.010, ep.decode.011, ep.decode.014, EPC-00, EPC-09]
  An undecodable record (invalid JSON, empty value, a JSON array or scalar, a field of the wrong type, an
  unparsable `ingested_at`) produces nothing on any topic. Reference: the record counts as processed and is
  committed (silent loss). Corrected: PERMANENT failure, dead-lettered with the raw bytes and the parse error,
  never a silent commit (RBD-4).
- **EP-C3** [vec: ep.decode.004, EPC-09]
  The JSON literal `null` decodes to an event whose fields are all empty; it then fails at EP-D1 and is
  dead-lettered with code `build_enriched_event` and an empty `transaction_id` (not attributable to a sender).
- **EP-C4** [vec: ep.decode.002, ep.decode.003, ep.decode.023, EPC-09]
  Unknown top-level fields are dropped from every output. A key repeated in the same object keeps its last
  value; spellings that differ only in case are the same key (EP-C1), so the last of them wins
  (`{"Transaction_Id":"first","TRANSACTION_ID":"tx_ci"}` → `tx_ci`).
- **EP-C5** [vec: ep.decode.017, ep.decode.018, ep.decode.017x, EPC-07]
  Reference: number literals inside `properties` (and a numeric `timestamp`) are read as IEEE-754 binary64
  and written back in the outputs with the shortest text that reads back to the same binary64 value: integers
  above 2^53 lose digits (`9007199254740993` → `9007199254740992`, `12345678901234567890` →
  `12345678901234567000`), `2.0` → `2`, and magnitudes below 1e-6 or at least 1e21 use exponent form without a plus
  sign or leading exponent zeros for negative exponents (`0.0000001` → `1e-7`, `1e21` → `1e+21`), `0.00001` stays
  `0.00001`. Corrected (RBD-14, proposed): the literal text is preserved byte for byte. String values are never
  altered.

## 3. Time (EP-D)

Two values are derived from `timestamp`: the **emitted timestamp** (a JSON number of seconds written into the
enriched and in-advance records) and the **matching instant** (used only to choose the subscription, EP-H).

- **EP-D1** [vec: ep.parse_timestamp.*, ep.match_subscription.026, EPC-00, EPC-08]
  Accepted shapes: a JSON number (seconds since the epoch); a string that parses as a decimal number of
  seconds (sign, fraction and exponent notation allowed: `"1741007009.123"`, `"1.741007009e9"`, `"-1"`,
  `"1741007009123"` read as seconds, i.e. year 57140); an RFC 3339 date-time string with seconds and `Z` or an
  offset (fraction optional). Rejected with DLQ code `build_enriched_event` (non-retryable): any other string
  (`"2025-03-03 13:03:29"`, `""`), `true`/`false`, `null` or absent, objects and arrays. Spellings the reference
  float parser also accepts (hexadecimal floats, `NaN`, `Inf`) are not part of the contract (EP-D6).
- **EP-D2** [vec: ep.parse_timestamp.*, EPC-08]
  Emitted timestamp. String decimal input: the value truncated toward zero to whole milliseconds
  (`"1741007009.123456"` → `1741007009.123`; negative values too: `"-1.0005"` → `-1`; a value strictly between
  −0.001 and 0, and a negative zero such as `"-0"`, is written `-0` by the reference, and the sign of that zero has
  no corrected contract). There is no range check: any finite value is accepted (`"1e19"` →
  `10000000000000000000`). JSON number input, reference: passed through untruncated
  (`1741007009.123456` → `1741007009.123456`); corrected (RBD-18, proposed): truncated to milliseconds like
  strings. RFC 3339 input: the instant in UTC truncated to milliseconds (`"2025-03-03T15:03:29.123456+02:00"` →
  `1741007009.123`). The number is written with the shortest round-trip text, no trailing zeros
  (`"1735689600.000"` → `1735689600`), in plain decimal notation below 1e21 and in exponent form from 1e21
  (`"1e21"` → `1e+21`), the same text form as EP-C5. For values beyond the year 9999 only the acceptance and that
  notation are part of the contract: the reference truncates to milliseconds in binary64 arithmetic, which alters
  the digits of such large values (`"1e20"` → `99999999999999980000`).
- **EP-D3** [vec: ep.parse_timestamp.001x, ep.parse_timestamp.018x, ep.parse_timestamp.020x, ep.parse_timestamp.021x, ep.parse_timestamp.024, ep.match_subscription.018, ep.match_subscription.019, ep.match_subscription.020, ep.match_subscription.021, EPC-04]
  Matching instant, reference: for numeric and decimal-string input the fractional part is computed in
  binary64 arithmetic, scaled to nanoseconds, truncated, then truncated to milliseconds, so about half of all
  millisecond values land 1 ms early (`"1741007009.123"` → `…29.122`, `"1748736000.001"` → `…00.000`); RFC 3339
  input keeps its offset and all sub-millisecond digits. Corrected (RBD-15): the exact decimal value truncated to
  whole milliseconds, as a UTC instant (`"1741007009.123"` → `…29.123Z`). In both profiles "truncated" means
  FLOORED toward the past, which differs from the emitted number for negative values: `"-1.0005"` → instant
  −1.001 s = `1969-12-31T23:59:58.999Z` while the emitted number is `-1` (EP-D2). Instants beyond the year 9999 are
  not part of the contract (the reference's instant arithmetic overflows beyond about ±9.2e18 s).
- **EP-D4** [vec: ep.parse_timestamp.009, ep.parse_timestamp.023, ep.match_subscription.016, ep.match_subscription.017, ep.match_subscription.016x, EPC-04]
  Reference DB mode compares the matching instant against subscription bounds by its wall clock in its
  own offset (an RFC 3339 offset is ignored: `"2025-03-01T00:30:00+01:00"` is compared as 2025-03-01 00:30);
  reference cache mode compares instants. Corrected (RBD-16): UTC instants in both modes.
- **EP-D5** [vec: ep.decode.001, ep.decode.011, ep.decode.015, ep.decode.016, ep.decode.021, ep.decode.022, EPC-09, EPC-12, EPC-13]
  `ingested_at`: a string `YYYY-MM-DDTHH:MM:SS` with optional fraction is read as UTC; otherwise the
  value is read like a timestamp (decimal seconds as a string or a JSON number, or RFC 3339); `null`, `""` or
  absent mean "unknown" (treated as infinitely old by the retry horizon, `delivery-and-failures.md` EP-L1); anything
  else makes the record undecodable (EP-C2). In a dead-letter record it is written back as `YYYY-MM-DDTHH:MM:SS`
  (fraction dropped; an RFC 3339 input keeps the wall clock of its own offset) or `null`.
- **EP-D6** [vec: EPC-08]
  Reference: the strings `NaN` and `Inf` pass EP-D1 but the enriched record cannot be serialised; nothing
  is produced, no dead-letter record is written and the offset is committed (silent loss). Hexadecimal float
  strings are accepted as seconds. Corrected (RBD-4): a non-finite timestamp is a PERMANENT failure and is
  dead-lettered with a cause.

## 4. Billable-metric resolution (EP-E)

- **EP-E1** [vec: EPC-00, EPC-03]
  The metric is the non-deleted billable metric with exactly (`organization_id`, `code`): byte-equal,
  case-sensitive, no trimming. Unknown organization, unknown or empty code, a code that exists only in another
  organization, or a soft-deleted metric: DLQ `fetch_billable_metric` ("Error fetching billable metric"),
  non-retryable; `initial_error_message` is `record not found` (DB mode) or `Key not found` (cache mode).
- **EP-E2** [vec: EPC-15, EPC-03]
  Any other lookup failure (connection, query, timeout, a value the database rejects, EP-E4) is retryable
  (`delivery-and-failures.md` §2).
- **EP-E3** [vec: EPC-02]
  Billable-metric filters and charge filters are neither read nor applied: `properties` pass through
  unchanged whatever their keys.
- **EP-E4** [vec: EPC-03]
  Organization id text. DB mode hands `organization_id` to the database as a UUID value. Any text the database
  accepts as a UUID (upper case, no hyphens `11111111111111111111111111111111`, braces) finds the organization,
  and every output carries the text AS RECEIVED (record key, `organization_id`, refresh member). Any other text,
  `""` included, makes the metric lookup fail with a database type error, not "not found": the reference treats
  it as a retryable lookup failure (EP-E2), so the record is dead-lettered `fetch_billable_metric` only past the
  retry horizon (EP-L1) and is otherwise left unprocessed and lost once a later batch commits (EP-B4). Memory-cache
  mode looks the text up as is: anything but the stored canonical text (lower case, hyphenated) is "not found",
  dead-lettered at once. Corrected (proposed, RBD-1): an organization id that is not UUID text is a PERMANENT
  failure (EP-R1), dead-lettered `fetch_billable_metric` at once in both modes, never retried or lost;
  non-canonical UUID spellings have no corrected contract (senders use the canonical text).

## 5. The `value` string (EP-F)

- **EP-F1** [vec: ep.value_string.028, ep.value_string.030, EPC-01]
  Metric type `count`: `value` is `"1"`, whatever `properties` or `field_name` contain (also when
  `properties` is null).
- **EP-F2** [vec: ep.value_string.*, EPC-01, EPC-07]
  Any other type (including the retired code 4, unknown codes and `custom`): `value` is the text of
  `properties[field_name]`, where `field_name` is one literal key (a dotted name is not a path). Reference text
  rules: a JSON string is copied verbatim (`"1e6"` stays `1e6`, `"abc"` stays `abc`); a JSON number is read as
  binary64 and written with its shortest round-trip digits, in exponent form `d.ddde±XX` (at least two exponent
  digits) when the decimal exponent is below −4 or at least 6, else in plain notation without trailing zeros
  (`999999` → `999999`, `1000000` → `1e+06`, `1234567.5` → `1.2345675e+06`, `0.0001` → `0.0001`, `0.00001` →
  `1e-05`, `2.0` → `2`); `true`/`false` → `true`/`false`; an object or array → the reference's internal
  rendering (`map[x:1]`, `[1 2]`); a missing key, `null` value or null `properties` → `<nil>`. Corrected
  (RBD-13): the exact plain decimal of the number, classified by its LITERAL: an integer literal (no fraction,
  no exponent) is written exactly at any size (`9007199254740993` stays `9007199254740993`); any other number
  literal is read as binary64 and written as its shortest round-trip digits in plain notation (`2.0` → `2`,
  `1e21` → `1000000000000000000000`, `0.123456789012345678` → `0.12345678901234568`); `"0"` when the key is
  missing or null; strings verbatim; booleans, objects and arrays have no corrected contract. Full table:
  `value-corpus.md`.
- **EP-F3** `value` is taken after expression evaluation (EP-G2). [vec: EPC-05]
- **EP-F4** [vec: ep.value_string.031, ep.value_string.032, ep.value_string.033, ep.value_string.035, ep.value_string.036, ep.value_string.037, ep.value_string.038, EPC-01]
  `aggregation_type` label from the stored type code: 0 `count`, 1 `sum`, 2 `max`, 3 `unique_count`,
  5 `weighted_sum`, 6 `latest`, 7 `custom`; 4 (retired) and any other code → `""` (KEEP, RBD-22).
- **EP-F5** [vec: ep.decode.014, ep.decode.014x, EPC-09]
  `precise_total_amount_cents` is copied as received (a string); absent → `""`. A JSON number is
  undecodable in the reference (EP-C2); corrected (RBD-4, proposed): accepted and copied as its literal text, or
  dead-lettered with a cause.

## 6. Custom expressions (EP-G)

The expression language itself (grammar, functions, decimal semantics, rounding) is specified in
`billing-engine-spec` reference/03-expression-language.md (mode `ep`); this section fixes only how the processor
uses it.

- **EP-G1** [vec: EPC-00, EPC-05]
  An expression is evaluated only when the metric has one AND `source` is not exactly `http_ruby`
  (events already evaluated by the billing API).
- **EP-G2** [vec: EPC-05]
  Input: the enriched record as built so far (subscription and plan ids still empty, `value` null,
  `timestamp` = the emitted timestamp, so `event.timestamp` of `"1741007009.123"` is `1741007009.123`). The result
  is stored as a JSON **string** in `properties[field_name]`, replacing any value sent (`a=2`, `a*2` → `"4"`;
  `a=0.1` → `"0.2"`; `a="3"` → `"6"`; `round(value*units)` with `"12.0"`, `3` → `"36"`). Corrected: same (the
  billing engine stores a decimal; documented divergence KEEP, RBD-22).
- **EP-G3** [vec: EPC-00, EPC-05]
  Evaluation failure (a missing variable, `properties` null, or a boolean anywhere in `properties` with
  the reference engine): DLQ `evaluate_expression` ("Error evaluating custom expression"), non-retryable; the
  `initial_error_message` embeds the expression and the full input JSON. Evaluation happens before the
  subscription lookup, so a failing event is never attached to a subscription.

## 7. Subscription resolution (EP-H)

- **EP-H1** [vec: ep.match_subscription.0*, EPC-04, EPC-34]
  Candidates: subscriptions of the event's organization whose external id equals
  `external_subscription_id` exactly, with `started_at ≤ t` and (`terminated_at` absent or `terminated_at ≥ t`),
  where `t` is the matching instant (EP-D3). Order: open subscriptions (no `terminated_at`) first, then by
  `terminated_at` descending, then by `started_at` descending; the first wins. Ties beyond that are unspecified.
- **EP-H2** [vec: ep.match_subscription.031, EPC-04]
  Subscription `status` is not read: a pending-activation, `incomplete` or canceled subscription with a
  matching window is attached (KEEP in compat; corrected: open owner question, RBD-19).
- **EP-H3** [vec: ep.match_subscription.012, ep.match_subscription.013, ep.match_subscription.014, EPC-04]
  If the metric is `recurring` and no candidate exists at `t`, the lookup is repeated at "now" (the
  processing time; the unit op passes it as `now`). No fallback for non-recurring metrics.
- **EP-H4** [vec: ep.match_subscription.014, EPC-00, EPC-04]
  No subscription is not an error: the event is enriched with `subscription_id: ""` and `plan_id: ""`, and
  neither the in-advance record nor the refresh flag is produced.
- **EP-H5** [vec: ep.match_subscription.009, ep.match_subscription.010, ep.match_subscription.010x, ep.match_subscription.018, ep.match_subscription.019, ep.match_subscription.020, ep.match_subscription.021, ep.match_subscription.022, EPC-00, EPC-04]
  Bound precision, reference: DB mode compares `started_at` and `terminated_at` truncated to milliseconds;
  cache mode compares them at full microsecond precision (an event in the `started_at` millisecond misses a
  subscription that started 500 µs into it). Corrected (RBD-17): both bounds truncated to milliseconds in both
  modes.
- **EP-H6** [vec: ep.match_subscription.002, ep.match_subscription.003, ep.match_subscription.004, ep.match_subscription.003x, ep.match_subscription.028, ep.match_subscription.029, ep.match_subscription.028x, EPC-04]
  Consequence of EP-D3 at the upper bound, reference: an event 1 ms after the `terminated_at`
  millisecond is still attached to the terminated subscription. Corrected: not attached; an RFC 3339 event time
  with sub-millisecond digits is truncated to the millisecond before comparing, so it IS attached when its
  millisecond equals the truncated `terminated_at` (RBD-15, RBD-17).
- **EP-H7** [vec: EPC-04, EPC-06]
  Reference cache mode only holds subscriptions that were open or terminated within one calendar month
  before the snapshot (plus CDC updates); an event for an older terminated subscription finds none. DB mode has
  no window. Corrected: owner question (RBD-20, proposal: the same documented window in both modes).
- **EP-H8** [vec: ep.match_subscription.032, ep.match_subscription.033, ep.match_subscription.033x]
  Reference cache mode finds candidates by the key prefix `sub:<organization_id>:<external_id>:`, so when
  another external id of the organization starts with the looked-up id followed by `:` (`acme` and `acme:eu`),
  both subscriptions are candidates and the EP-H1 order may pick the other one; DB mode uses exact equality.
  Corrected (RBD-99, proposed): exact external-id equality in both modes, as in EP-H1 (`acme` never matches the
  `acme:eu` subscription).

## 8. Outputs (EP-I)

- **EP-I1** [vec: EPC-23]
  Every successfully enriched event (with or without subscription) produces one enriched record keyed
  `<organization_id>-<transaction_id>`; JSON fields per `wire-formats.md` §2.
- **EP-I2** The in-advance record has the same key and the same bytes as the enriched record. [vec: EPC-06]
- **EP-I3** A dead-letter record has no key; JSON per `wire-formats.md` §4. [vec: EPC-03, EPC-09]
- **EP-I4** [vec: EPC-25]
  The processor does not deduplicate: the same raw record consumed twice yields two identical enriched
  (and in-advance) records. Downstream consumers deduplicate on `transaction_id` (KEEP, RBD-11; required by the
  corrected profile).
- **EP-I5** [vec: ep.match_subscription.023, EPC-23]
  Keys and lookups are organization-scoped: the same `transaction_id`, code and external id in two
  organizations give two distinct records, metrics and subscriptions.

## 9. Pay-in-advance and refresh flag (EP-J, EP-K)

- **EP-J1** [vec: EPC-00, EPC-06, EPC-24]
  The in-advance record and the refresh flag are produced only when a subscription was found AND the
  event is not API-post-processed. API-post-processed = `source` is exactly `http_ruby` AND
  `source_metadata.api_post_processed` is true; other sources ignore the flag.
- **EP-J2** [vec: EPC-01, EPC-06]
  The in-advance record is produced iff a non-deleted charge with `pay_in_advance = true` exists for
  (organization, the subscription's plan, the metric). The property named by `field_name` need not be present.
- **EP-J3** [vec: EPC-16, EPC-17]
  Side-effect order, reference: the enriched produce starts first and runs concurrently with the charge
  lookup; the in-advance produce runs concurrently with the flag write; the record completes when all finished.
  A failing charge lookup keeps the enriched record and drops the in-advance record and the flag; a failing flag
  write keeps both records and drops the flag. Corrected (ADR-001 point 3): enriched first; only after it
  succeeded the in-advance record and the flag; a failed side effect is retried alone (RBD-8, RBD-9).
- **EP-K1** [vec: ep.refresh_member.001, ep.refresh_member.003, ep.refresh_member.004, EPC-06, EPC-24]
  Refresh flag: sorted set `subscription_refreshed_v2`, member `<organization_id>:<subscription_id>|<b>`
  where `b = floor(now / 10) × 10` (Unix seconds), score `now` (Unix seconds); written with "add or update score".
- **EP-K2** [vec: ep.refresh_member.001, ep.refresh_member.003, ep.refresh_member.004, EPC-24]
  Hence one member per (organization, subscription, 10-second bucket); events in the same bucket only
  move the score.

<!-- evidence-check: on -->

## 10. Reference pseudocode (fresh; describes the compat profile)

```
process(record):
  ev ← decode_json_object(record.value)            on failure: return PROCESSED_NO_OUTPUT      # EP-C2
  (emit_ts, t) ← parse_time(ev.timestamp)           on failure: return FAIL(build_enriched_event, retryable=false)
  m ← metric(ev.organization_id, ev.code)           not found: FAIL(fetch_billable_metric, false); error: FAIL(…, true)
  if m.expression and ev.source ≠ "http_ruby":
      r ← evaluate(m.expression, enriched_so_far)   failure: FAIL(evaluate_expression, false)
      ev.properties[m.field_name] ← r (string)
  value ← "1" if m.type = count else text(ev.properties[m.field_name])
  s ← subscription_at(ev, t);  if none and m.recurring: s ← subscription_at(ev, now)
                                                   error: FAIL(fetch_subscription, true)
  start produce(ENRICHED, key, json)
  if s and not api_post_processed(ev):
      adv ← has_pay_in_advance_charge(org, s.plan, m)   error: FAIL(fetch_pay_in_advance_charge, true)
      if adv: start produce(IN_ADVANCE, key, json)
      flag(org, s.id)                                   error: FAIL(flag_subscription_refresh, true)
  wait for produces   # a rejected produce writes a DLQ record with error_code "" (EP-L2, EP-L3)
  return OK
```
What happens to a `FAIL` (dead-letter now, or leave unprocessed) is `delivery-and-failures.md` §2.

## 11. Unit ops (`ep.*`, run with kitrun against `--impl-cmd`)

The unit ops isolate the pure parts of the pipeline so an implementation gets fast feedback before the Kafka
suite. Envelope, transport and grading: `reimplementation-kit` (vector-format, adapter-protocol). Fields below
are the kit v1 contract for area `ep`; extra output fields are ignored unless a vector is `strict`. The
machine-readable form (final; optional inputs with their defaults, domain error codes under `x-kit-errors`) is
`reimplementation-kit` schemas/ops/ep.<op>.schema.json.

| Op | Input | Output (expected subset) | Notes |
|---|---|---|---|
| `ep.decode` | `raw_b64`: the exact record bytes, base64 | `event_json`: the dead-letter copy of the decoded event (`wire-formats.md` §4 field `event`) in the suite's canonical form (§7 there: sorted keys, literal number text, no HTML escaping), compared as text; or error `undecodable` | `event` (same content as an object) may also be returned |
| `ep.parse_timestamp` | `timestamp_json`: the JSON text of the `timestamp` field (`null` = absent) | `emitted_text` (text of the emitted JSON number), `match_instant` (UTC instant), `match_time` (reference: the instant with the zone kept for wall-clock comparison); or error `invalid_timestamp` field `timestamp` | `match_instant` omitted when beyond year 9999 |
| `ep.value_string` | `aggregation_type`: the STORED type code as a decimal string (`"1"`), `field_name` (string or null), `properties_json` (JSON text, may be `"null"`) | `value` (text), `aggregation_label` (EP-F4) | count, retired and unknown codes included |
| `ep.match_subscription` | `mode` (`db`/`cache`), `external_subscription_id`, `timestamp_json`, `subscriptions[]` (`id`, `external_id`, `started_at`, optional `terminated_at`, `plan_id`, `status` (stored integer code), `organization_id`), optional `organization_id` (default `11111111-1111-1111-1111-111111111111`), `recurring` (default false), `now` (read only when `recurring`) | `subscription_id` (`""` = none); or error `build_enriched_event` for an invalid timestamp | all listed subscriptions are visible (the cache-mode snapshot window EP-H7 is out of scope of the op) |
| `ep.commit_offset` | `records[]` (`offset`, `processed`) of one batch of one partition, optional `pending_before[]` (offsets of earlier batches of the partition still without a disposition) | `commit`: the offset to commit (next offset to read) or `null` = commit nothing | reference ignores `pending_before` (that is the loss, RBD-1) |
| `ep.refresh_member` | `organization_id`, `subscription_id`, `now_unix` | `member`, `score` | EP-K1 |

## 12. Edge cases worth a test of their own

1. `"1741007009123"` (milliseconds sent as a seconds string) is accepted as the year 57140; nothing rejects it.
2. Negative times (`"-1"`) are accepted.
3. A boolean anywhere in `properties` makes the reference expression evaluation fail, even if unused.
4. `ingested_at` with an offset is aged by its instant but written back as its local wall clock.
5. An event whose subscription was created moments ago may not see it in cache mode (CDC lag): it is enriched
   without subscription (EP-H4), so no in-advance record and no refresh flag.
6. A metric code or external id with surrounding spaces is a different code or id.
7. An `organization_id` that is not UUID text is silently lost in DB mode when it is fresh and a later batch
   follows (EP-E4); in cache mode it is dead-lettered at once.
8. Field names are case-insensitive (EP-C1): `{"CODE": "api_calls"}` is a valid event.

## Provenance (maintainers)

Reference source, events-processor tree `83e012866f29` (paths relative to the lago repository):
EP-C1 `events-processor/models/event.go:12`; EP-C2 `events-processor/processors/events_processor/processor.go:49`;
EP-C5/EP-D2 `events-processor/utils/time.go:51`; EP-D3 `events-processor/utils/time.go:14`; EP-D4
`events-processor/models/subscriptions.go:26`, `events-processor/cache/subscriptions.go:45`; EP-D5
`events-processor/utils/time.go:82` and `:103`; EP-D6 `events-processor/processors/events_processor/event_producer_service.go:76`;
EP-E1 `events-processor/models/billable_metrics.go:59`, `events-processor/cache/billable_metrics.go:27`; EP-F1/F2
`events-processor/processors/events_processor/enrichment_service.go:111`; EP-F4
`events-processor/models/billable_metrics.go:22`; EP-G1..G3 `enrichment_service.go:105` and `:122`; EP-H1/H3
`enrichment_service.go:53`, `events-processor/models/subscriptions.go:26`; EP-H5/H8
`events-processor/cache/subscriptions.go:45`; EP-H7 `events-processor/models/subscriptions.go:56`; EP-I1..I3
`event_producer_service.go:29`; EP-J1 `events-processor/models/event.go:86`, `processor.go:115`; EP-J2
`events-processor/models/charges.go:47`, `events-processor/cache/charges.go:89`; EP-J3 `processor.go:99`; EP-K1
`events-processor/models/stores.go:54`. Billing-engine side of RBD-13 and RBD-15 (decimal parsing of the
timestamp, `date_trunc('millisecond', …)` bounds): `$API/app/services/events/create_service.rb:53`,
`$API/app/services/events/post_process_service.rb:50` @591ae90 (the billing side also excludes `incomplete` subscriptions there, `:46`). Unit vectors are minted by
`scripts/maintainer/mint-ep-units.py` (expected values from the ep-oracle, i.e. the reference packages; corrected
twins recomputed from the cited RBD).

Additions of 2026-10-05 (kit v1.1). EP-C1/EP-C4 case-insensitive field names: the raw record is decoded into a
typed structure by a case-insensitive name matcher (`events-processor/models/event.go:12` with
`events-processor/processors/events_processor/processor.go:49`); ep-oracle probe and `ep.decode.023` (the long s
`ſ` was observed to match `source` in the same probe; the dotless `ı` did not match `transaction_id`). EP-D2/EP-D3
negative and large values: `events-processor/utils/time.go:14` (whole seconds by truncation, the fraction as a
signed nanosecond count, then a floor to the millisecond) and `:51` (emitted number truncated toward zero);
ep-oracle `ep.parse_timestamp.024..026` (`"1e19"` and `"-1e19"` both gave the instant
`292277026304-08-26T15:42:51.145Z`, an overflow). EP-D2 notation and large-value digits, ep-oracle probe of
2026-10-05 (independent verification): `"1e20"` → `99999999999999980000`, `"9.99e20"` → `999000000000000000000`,
`"1e21"` → `1e+21`, `"-1e21"` → `-1e+21`, `"-0"` and `"-1e-7"` → `-0`; 9,000 decimal strings with 3 or 4
fractional digits around 2025 and 2100 all matched exact truncation to milliseconds. EP-E4: DB-mode metric lookup
`events-processor/models/billable_metrics.go:59` (a non-UUID parameter fails with SQLSTATE 22P02, initial error
`ERROR: invalid input syntax for type uuid: "org-not-a-uuid" (SQLSTATE 22P02)`), cache lookup
`events-processor/cache/billable_metrics.go:27`; EPC-03 compat goldens of both modes re-minted with
`scripts/maintainer/regen-goldens.sh --only EPC-03 --passes 3` (three agreeing passes per mode); five more MATCH passes per
mode in the independent verification of the same day. Ad-hoc runner probe of that verification (Go reference, both
modes): DB mode enriched `{11111111-1111-1111-1111-111111111111}` and `1111-1111-1111-1111-1111-1111-1111-1111` under
the raw text (record key, `organization_id`, refresh member), lost a fresh `" 11111111-…-111111111111 "` (surrounding
spaces) like other non-UUID text, and dead-lettered a 13 h old `null` organization id with `organization_id` `""`;
cache mode dead-lettered all four. Upper-case hex was not probed end to end (the fixture ids are digits only); the
database's uuid input, which accepted the probed spellings, also accepts it (PostgreSQL 16.14 on 2026-10-05:
`'AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE'::uuid` and `'{AAAAAAAABBBB4CCC8DDDEEEEEEEEEEEE}'::uuid` both parse to the
lower-case canonical text).
