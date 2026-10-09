# 02 — Events ingestion (BE-EV)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08).
> It is a behavioural specification written fresh from executed vectors and probes, not source code. Proprietary
> clean-room rebuilds should have it reviewed (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90`. This chapter specifies how the billing API accepts usage events: the request
surface (`POST /api/v1/events` for one event, `POST /api/v1/events/batch` for many), how the event time is read,
what is validated and in which order, the idempotency key per event store, how a metric expression rewrites the
event before it is stored (the expression language itself is chapter 03), the message published for the
events-processor, and what happens after acceptance (interface level; the consumers are chapters 04, 05, 09, 10).

Two **event stores** exist per organization (chapter 04 owns the query semantics):

- **relational store** (vector input `store: "pg"`, the normative variant): every accepted event is persisted in the
  billing database, post-processed asynchronously by the billing engine, and also published to the raw topic;
- **columnar store** (`store: "ch"`): the API persists nothing; it only publishes the event to the raw topic, which
  the events-processor enriches into the columnar store (see `events-processor-spec`).

Which store an organization uses is fixed when the organization is created: it gets the columnar store (with
query-time deduplication switched on, chapter 04) when the deployment enables the columnar store and names it the
default event store, and the relational store otherwise; no API endpoint changes it afterwards. Reading usage from
the columnar store additionally requires the deployment to enable it (chapter 04).

Reading guide: rules are numbered `BE-EV-n`; every rule line ends with `[vec: …]` naming the vectors (in
`billing-engine-spec/vectors/events.ingest.jsonl`) that pin it, or a prose-only marker with the reason. The vector
ops are `events.parse_timestamp`, `events.validate` (one event), `events.validate_batch`, `events.raw_message` and
`events.duplicate_key`; their schemas are in `reimplementation-kit/schemas/ops/events.*.schema.json`. Error-body
envelopes are chapter 11 (BE-API); this chapter fixes the `error_details` member.

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun against the oracle -->

## 1. The submission surface

Request: `POST /api/v1/events` with a JSON body `{"event": {…}}` (single) or `POST /api/v1/events/batch` with
`{"events": [{…}, …]}` (batch), authenticated by the organization's API key. Success answers HTTP 200 with the
accepted event(s); validation failures answer 422.

- **BE-EV-1** Accepted event members: `transaction_id`, `code` (the billable-metric code), `timestamp`, `external_subscription_id`, `precise_total_amount_cents` and `properties`. Every other member (for example `external_customer_id`, `lago_id`) is silently ignored and never stored or published. [vec: events.validate.001, events.validate.002]
- **BE-EV-2** The members other than `properties` accept only scalar JSON values (string, number, boolean, null). An object or array value is discarded as if the member were absent (for `timestamp` this means "use the reception time", BE-EV-10). A number or boolean given for a text member (`transaction_id`, `code`, `external_subscription_id`) is stored, echoed and published as text: an integer as its digits (`123` → `"123"`), a non-integer number as its binary64 value's shortest text in the reference's float notation (`1.5` → `"1.5"`, `1e20` → `"1.0e+20"`), `true` as `"t"` and `false` as `"f"` (not `"true"`/`"false"`; `false` is therefore present, not blank). [vec: events.validate.002, events.validate.026, events.parse_timestamp.004]
- **BE-EV-3** `properties` must be a JSON object; any other value (array, string, number) is discarded and the event is stored with `{}`; absent or null also gives `{}`. Inside the object every value is kept as sent, nested objects and arrays included, with its JSON type (numbers stay numbers, numeric strings stay strings; non-integer numbers have binary64 precision, integers are exact at any size). [vec: events.validate.003, events.validate.004]
- **BE-EV-4** A body without an `event` member, or with an empty `event` object, answers HTTP 400 (missing parameter) instead of 422. [vec: events.validate.007]
- **BE-EV-5** The 200 answer of a single event is `{"event": {…}}` echoing the accepted event (after expression evaluation): `lago_id`, `transaction_id`, `lago_customer_id`, `code`, `timestamp` as an ISO-8601 UTC string with exactly three fractional digits (the event time truncated to milliseconds, e.g. `2024-01-01T01:02:03.123Z`), `precise_total_amount_cents` as decimal text or null, `properties`, `lago_subscription_id`, `external_subscription_id`, `created_at`. `lago_customer_id` and `lago_subscription_id` are null at ingestion (nothing is resolved yet); for a columnar-store organization `lago_id` and `created_at` are null too (nothing is stored). The batch answer is `{"events": [ … ]}` in request order. [vec: events.validate.001]

## 2. Event time

Let `received_at` be the API wall clock when the request arrives.

- **BE-EV-10** When `timestamp` is absent, null, `false`, or a discarded non-scalar value (BE-EV-2), the event time is `received_at`. [vec: events.parse_timestamp.001, events.parse_timestamp.004]
- **BE-EV-11** Otherwise the value's text (a JSON string's content, or a JSON number's value) must be a decimal number of seconds since 1970-01-01T00:00:00Z: optional surrounding whitespace (spaces, tabs, line breaks), an optional sign, digits with an optional fraction where either the integer part or the fraction may be empty but not both (`5.`, `.5`, `+.5`), single underscores allowed between digits (`1_000`; a single trailing underscore is tolerated; a doubled or leading underscore is invalid), and an optional exponent `e`/`E` with optional sign (`1e9`, `1e+3`). Anything else — ISO-8601 or other date strings, the empty string, hexadecimal, trailing characters (`12abc`), and the JSON value `true` — is rejected with 422 `{"timestamp": ["invalid_format"]}`. The number is used with arbitrary precision (no binary floating point for strings). [vec: events.parse_timestamp.005, events.parse_timestamp.006, events.parse_timestamp.007, events.parse_timestamp.011, events.parse_timestamp.013, events.parse_timestamp.017, events.parse_timestamp.019, events.parse_timestamp.020, events.parse_timestamp.021, events.parse_timestamp.022, events.parse_timestamp.023]
- **BE-EV-12** A JSON **number** that is not an integer is first read as an IEEE-754 binary64 value and then used as its shortest round-trip decimal text, so digits beyond binary64 precision are lost (`1693842312.123456789` becomes `1693842312.1234567`); JSON integers and JSON strings keep every digit (`"1780586634.1"` is exactly .1 s, not the binary64 neighbour). [vec: events.parse_timestamp.006, events.parse_timestamp.007, events.parse_timestamp.010]
- **BE-EV-13** The relational store keeps the event time at microsecond precision, truncated toward the past (floor): `.9999999` s keeps `.999999`, `-0.5` s is `23:59:59.5` of the previous day. The unrounded parsed value is what the raw message carries (BE-EV-61). [vec: events.parse_timestamp.008, events.parse_timestamp.009, events.parse_timestamp.010, events.parse_timestamp.016, events.raw_message.003]
- **BE-EV-14** Times before 1970 (negative seconds) are accepted. [vec: events.parse_timestamp.015, events.parse_timestamp.016]
- **BE-EV-15** Values that pass the grammar but are not finite or not storable fail with an internal error (HTTP 500), not with `invalid_format`: the texts `NaN`, `Infinity` and `-Infinity` in both stores, and in the relational store any time outside the range the store keeps, which is −210866803200 s (4714-11-24T00:00:00Z before the common era) through 9224318015999.999999 s (294276-12-31T23:59:59.999999Z); `9224318016000` s and `1e13` s fail, as does −210866803201 s. Inside that range every time is accepted, including years 0 and 10000 and later; a columnar-store organization accepts any finite value (`1e20`) because nothing is stored. Graded vectors stay within four-digit years (the kit's instant format); beyond them the kit grades nothing. A rebuild should answer `invalid_format` for the non-finite and unstorable values (open question KQ-31; the compat answer is ungraded). [vec: none (prose only: the reference answers an internal error, which the kit does not grade until a rebuild decision is ruled)]
- **BE-EV-16** Downstream precision: the events-processor and the columnar store keep milliseconds (`events-processor-spec` EP-D2), the relational store microseconds (RBD-40). [vec: events.raw_message.003, events.raw_message.004]

## 3. Validating one event

Checks run in this order; the first failing step decides the answer:

1. event time (BE-EV-11) → 422 `{"timestamp": ["invalid_format"]}`;
2. metric expression (BE-EV-50..54) → 422 with a text detail;
3. relational store only: presence (BE-EV-21) then uniqueness (BE-EV-30) when the event is written.

- **BE-EV-20** The order above is observable: an invalid timestamp is reported alone even when `transaction_id` and `code` are missing; an expression failure is reported instead of a duplicate key. [vec: events.validate.014]
- **BE-EV-21** Relational store: `transaction_id` and `code` must be present and not blank (empty or whitespace-only text is blank). Each missing member is listed: `{"transaction_id": ["value_is_mandatory"], "code": ["value_is_mandatory"]}`. [vec: events.validate.001, events.validate.005, events.validate.006]
- **BE-EV-22** `external_subscription_id` is optional, and nothing is checked against the catalog or the subscriptions: an unknown `code`, an unknown subscription id or no subscription id is accepted and stored; such events simply never match a billing query (chapter 04) and are reported by the hourly validation webhook (BE-EV-73). [vec: events.validate.008]
- **BE-EV-23** Columnar store, single event: no presence and no uniqueness validation at all; the event (after its expression) is only published and the answer is 200 with `persisted` false (RBD-32: compat keeps this; the corrected profile validates presence). Batches are different (BE-EV-41). [vec: events.validate.018, events.validate.019, events.validate.019x]
- **BE-EV-24** A 422 answer carries `error_details`: an object `{member: [codes]}` for timestamp, presence and uniqueness errors, or a text for expression failures (BE-EV-52); the surrounding envelope is BE-API. [vec: events.validate.005, events.validate.006, events.validate.009]
- **BE-EV-25** `precise_total_amount_cents` (optional) is stored as a decimal with 15 fractional digits (more digits are rounded half away from zero: `-0.0000000000000005` → `-0.000000000000001`): a JSON number gives its value; a text gives the value of its longest leading numeric prefix, exponent notation included (`"12abc"` → 12, `"1e3"` → 1000), and 0 when there is none (`"asdfa"`); an empty text counts as absent (null); `true`/`false` give 1/0. Only the dynamic charge model reads it (chapter 05). [vec: events.validate.024]

## 4. Idempotency

- **BE-EV-30** Relational store: the idempotency key is (organization, `external_subscription_id`, `transaction_id`). A new event whose key equals a stored event's key is rejected with 422 `{"transaction_id": ["value_already_exist"]}`. `code`, `timestamp`, `properties` and `precise_total_amount_cents` are not part of the key: re-sending a key with any of them changed is still a duplicate, while the same `transaction_id` under another subscription is a different event. [vec: events.duplicate_key.001, events.validate.009]
- **BE-EV-31** Soft-deleted stored events (for example the events of a deleted billable metric) still hold their key: re-sending them is rejected (RBD-34, KEEP). [vec: events.validate.011]
- **BE-EV-32** An event without `external_subscription_id` has no idempotency in the single-event path: the same `transaction_id` can be stored any number of times (two absent ids never collide). In a batch it is still rejected (BE-EV-44). [vec: events.validate.012]
- **BE-EV-33** Columnar store: no idempotency at ingestion; every repeat is published again (RBD-32). Query-time deduplication, when enabled, is chapter 04. [vec: events.duplicate_key.003, events.duplicate_key.003x, events.validate.020, events.validate.020x]
- **BE-EV-34** Downstream consumers must not rely on ingestion idempotency alone: pay-in-advance fees are idempotent per (organization, `transaction_id`) (BE-EV-71) and the events-processor forwards duplicates (RBD-11, `events-processor-spec` EPC-25). [vec: none (prose only: cross-reference; graded by the pricing area's pay-in-advance vectors and the events-processor suite)]

## 5. Batches

- **BE-EV-40** `events` absent, null or empty → 422 `{"events": ["no_events"]}`. More events than the configured maximum (deployment setting, default 100) → 422 `{"events": ["too_many_events"]}`; exactly the maximum is accepted. These two checks run before any per-event check. [vec: events.validate_batch.002, events.validate_batch.004, events.validate_batch.005]
- **BE-EV-41** Each event is checked as a single event would be (time, expression, presence) — in BOTH stores, so a columnar-store batch rejects a missing `transaction_id` that a single columnar-store event would accept. Any error rejects the whole batch: nothing is stored and nothing is published. [vec: events.validate_batch.001, events.validate_batch.006, events.validate_batch.016]
- **BE-EV-42** `error_details` maps the zero-based index of each failing event (as a JSON object key `"0"`, `"1"`, …) to: `{"timestamp": ["invalid_format"]}` (the other checks of that event are skipped); or the presence errors `{member: ["value_is_mandatory"]}`; or, for an expression failure, the text `expression_evaluation_failed: <message>` — replaced by the presence errors when the same event also lacks `transaction_id` or `code`. [vec: events.validate_batch.010]
- **BE-EV-43** Relational store: duplicates are detected only after every event passed its own checks (a batch with any per-event error reports only those). Then each flagged event gets `{"transaction_id": ["value_already_exist"]}` at its index. Call an event's key (`external_subscription_id`, `transaction_id`) **new** when no stored event (soft-deleted ones included) and no earlier event of the batch carries the same key; a key without a subscription id is always new. The events that repeat a stored key, or an earlier event's key, are flagged; the first occurrence of a key inside the batch is not flagged unless it repeats a stored key. Example: one stored key and two batch events repeating it → both indexes are flagged. This is the corrected rule; the reference flags per BE-EV-44, which agrees with it whenever the events sharing a `transaction_id` all carry the same (non-null) subscription id. [vec: events.validate_batch.006, events.validate_batch.007, events.validate_batch.008, events.validate_batch.011, events.validate_batch.018]
- **BE-EV-44** Reference quirk (RBD-33): inside a batch, repeats are matched on `transaction_id` alone. Compat rule, for each `transaction_id` t of the batch, with the events carrying t in index order: if at least one of them has a new key (BE-EV-43), every one of them except the first (lowest index) is flagged; otherwise (all of them repeat stored keys) every one of them is flagged. Consequences: two events with the same `transaction_id` for different subscriptions, or twice without a subscription id, are rejected at the later index (the single-event path accepts both); when a batch holds a stored key and a new key with the same `transaction_id`, the error is reported at the later index whichever event is the real duplicate; two events that both repeat one stored key are both rejected. Corrected (proposed): batches use the single-event key, and exactly the events whose key is not new are flagged. [vec: events.validate_batch.012, events.validate_batch.012x, events.validate_batch.014, events.validate_batch.014x, events.validate_batch.018]
- **BE-EV-45** Columnar store: no duplicate detection in batches; accepted events are published, not stored (RBD-32). [vec: events.validate_batch.015, events.validate_batch.015x, events.validate_batch.017]
- **BE-EV-46** An accepted relational-store batch is stored atomically, then post-processing is scheduled for every event, then every event is published (BE-EV-60). [vec: events.validate_batch.001, events.validate_batch.005]

## 6. Metric expression at ingestion

- **BE-EV-50** If the organization has a non-deleted billable metric whose `code` equals the event's `code` and whose `expression` is not blank, the expression is evaluated on the event (chapter 03, surface "ingestion", BE-EX-30) before storage and publication, and its result is written into `properties[field_name]` of that metric, replacing any value the client sent. This happens in both stores and in single and batch submissions. [vec: events.validate.015, events.validate.018, events.validate_batch.001, events.validate_batch.017]
- **BE-EV-51** The written value is a JSON string: a number result as plain decimal text with at least one fractional digit (`"3.0"`, `"6.0"`, `"0.2"`, `"1200.0"`, `"0.0000001"`), a string result as is (BE-EX-31). [vec: events.validate.015, events.validate.018, events.raw_message.007, events.validate_batch.001, events.validate_batch.017]
- **BE-EV-52** An evaluation failure rejects the event with 422 whose `error_details` is the TEXT `expression_evaluation_failed: <message>` (messages of BE-EX-13/14, e.g. `Variable: a not found`, `Expected a decimal`). [vec: events.validate.014, events.validate.016, events.validate_batch.010]
- **BE-EV-53** Metrics without an expression (null, empty or whitespace-only), and deleted metrics, leave the properties untouched. [vec: events.validate.017, events.validate.028]
- **BE-EV-54** A division by zero inside the expression is not an evaluation failure in the reference: the request fails with an internal error (HTTP 500, single event and batch alike), nothing is stored or published, and the server keeps serving other requests (RBD-37). The corrected profile (RBD-37, proposed) rejects it with an expression evaluation failure (422). An event earlier than 1970-01-01T00:00:00Z (its seconds rounded down are negative, so `-0.5` qualifies) whose metric has an expression also fails with an internal error (HTTP 500), in both stores; that case is not part of RBD-37: the kit's proposal is to evaluate it like any other event (BE-EX-32, open question KQ-31). The internal-error side of both cases is not graded (as BE-EV-15). [vec: events.validate.025x]

## 7. The raw-topic message

- **BE-EV-60** For every accepted event, in both stores, the API publishes one message without a key on the configured raw topic (nothing is published when no raw topic or no broker is configured). The value is a JSON object with exactly these members: `organization_id`, `external_customer_id` (always null), `external_subscription_id`, `transaction_id`, `timestamp`, `code`, `precise_total_amount_cents`, `properties` (after expression evaluation, BE-EV-51), `ingested_at`, `source`, `source_metadata`. This is the input contract of the events-processor (`events-processor-spec` wire formats). [vec: events.raw_message.001, events.raw_message.007]
- **BE-EV-61** `timestamp` is a JSON string: the parsed event time converted to a binary64 number of seconds and printed in its shortest round-trip decimal form, always with a fractional part (`"1700000000.0"`, `"1693842312.344"`, and `"1704070923.1234567"` for the input `"1704070923.123456789"`, whose stored value is `.123456`). Magnitudes below 10^-4 (and from 10^16 up) switch to exponent form in the reference's float notation (`"1.0e-05"` for 0.00001 s). [vec: events.raw_message.001, events.raw_message.003, events.raw_message.004]
- **BE-EV-62** `precise_total_amount_cents` is the stored decimal as text in plain notation with at least one fractional digit (`"123.45"`, `"12.0"`, `"0.0"` for a stored 0) and `"0.0"` when the member was absent or null. [vec: events.raw_message.001, events.raw_message.005]
- **BE-EV-63** `ingested_at` is the API wall clock at acceptance in UTC as `YYYY-MM-DDTHH:MM:SS.mmm` without a zone designator. [vec: events.raw_message.001]
- **BE-EV-64** `source` is `"http_ruby"`; `source_metadata` is `{"api_post_processed": true}` for a relational-store organization (the billing engine post-processes the event itself) and `false` for a columnar-store organization (the events-processor's in-advance output drives it). [vec: events.raw_message.001, events.raw_message.002]
- **BE-EV-65** Ordering: a relational-store event is published after it is stored and its post-processing is scheduled; if scheduling fails the stored event is removed again (so the client can retry the same key) and nothing is published. [vec: none (prose only: failure injection of the job queue is not an op; the order is pinned by the reference specs listed in Provenance)]

## 8. After acceptance (interface level)

These steps belong to other chapters; they are listed so a rebuild wires them.

- **BE-EV-70** Subscription resolution for an event (post-processing, pay-in-advance): among the organization's subscriptions whose external id equals `external_subscription_id` (status `incomplete` excluded in post-processing), keep those with `started_at` ≤ event time and (`terminated_at` absent or ≥ event time), both bounds truncated to milliseconds; order open subscriptions first, then `terminated_at` descending, then `started_at` descending; take the first. If none matches and the metric is recurring, fall back to the most recently started active subscription with that external id. [vec: none (prose only: subscription matching is graded by the aggregation and pricing areas and by the scenario tier)]
- **BE-EV-71** Pay-in-advance trigger: when the matched subscription's plan has pay-in-advance charges on the event's metric, a job prices the event (chapter 05). It is skipped when the metric is missing, when the metric is not count (or custom) and `properties[field_name]` is absent, and when an in-advance fee already exists for the organization and `transaction_id`. With a raw topic configured, relational-store organizations price only API events and columnar-store organizations only the processor's in-advance records. Non-invoiceable charges create a fee, invoiceable ones an invoice. [vec: none (prose only: priced by the pricing area's pay-in-advance vectors and the scenario tier)]
- **BE-EV-72** Other post-processing of a relational-store event: expire the cached current usage of the matched active subscription's charges for this metric, track subscription activity (usage alerts, progressive billing; chapter 10), flag the customer's wallets for a balance refresh (chapter 09), and emit webhook `event.error` when a duplicate surfaces at this stage or a targeted wallet does not exist. [vec: none (prose only: side effects are observable only through the scenario tier)]
- **BE-EV-73** Hourly validation (minute 05, relational store, organizations with a webhook endpoint, unless disabled by deployment setting): over the events created in the previous full hour, one webhook `events.errors` lists the transaction ids whose code matches no metric, whose metric needs a field that is missing (or non-numeric for sum, max, weighted sum and latest), or whose filter key carries a value the metric does not declare (chapter 12, chapter 13). [vec: none (prose only: clock job; covered by the clock and webhook chapters)]
- **BE-EV-74** Lookup: `GET /api/v1/events/{transaction_id}` returns one of the organization's stored (not deleted) events with that transaction id, whatever its subscription (no order is defined when several subscriptions share it) (columnar store: from the raw copy); `GET /api/v1/events` lists stored events with filters on code, subscription id and time (chapter 11). [vec: none (prose only: REST read endpoints are graded by the scenario tier)]

## 9. Store variants at ingestion (summary)

| Aspect | Relational store (`pg`) | Columnar store (`ch`) |
|---|---|---|
| Event persisted by the API | yes (microseconds) | no (only published) |
| Single event: presence check | yes | no (RBD-32) |
| Single event: duplicate key | rejected (organization, subscription id, transaction id) | accepted (RBD-32) |
| Batch: presence check | yes | yes |
| Batch: duplicates | rejected (transaction id only, RBD-33) | accepted |
| Expression | evaluated by the API | evaluated by the API; the events-processor skips `source = http_ruby` |
| `api_post_processed` | true | false |
| Post-processing | by the billing engine | by the events-processor and its in-advance output |

## 10. Algorithm (fresh pseudocode)

```
accept_one(org, body, received_at):
    ev ← body.event ; if ev is missing or empty: return 400
    keep only the six members of BE-EV-1; drop non-scalar values of the scalar members (BE-EV-2)
    props ← ev.properties if it is an object else {}
    t ← received_at if ev.timestamp in {absent, null, false} else parse_seconds(ev.timestamp)   # BE-EV-11/12
    if t is invalid: return 422 {"timestamp": ["invalid_format"]}
    m ← org.metric(code = ev.code, not deleted, expression not blank)
    if m: r ← evaluate(m.expression, ingestion_surface(ev.code, t, props))                    # chapter 03
          if r failed: return 422 "expression_evaluation_failed: " + r.message
          props[m.field_name] ← text_of(r)                                                       # BE-EV-51
    if org.store = pg:
        if blank(transaction_id) or blank(code): return 422 presence errors                    # BE-EV-21
        if key(org, ev.external_subscription_id, ev.transaction_id) exists (deleted included)
           and ev.external_subscription_id is present: return 422 {"transaction_id": ["value_already_exist"]}
        store(event with t truncated to microseconds) ; schedule post-processing
    publish raw message (BE-EV-60..64)
    return 200 echo

accept_batch(org, body, received_at):
    if events empty: 422 no_events ; if count > max: 422 too_many_events
    errors ← {} ; for i, ev: run the per-event checks of accept_one (time, expression, presence) → errors[i]
    if errors: return 422 errors
    if org.store = pg:
        new[i] ← key(ev_i) has no subscription id, or is neither stored (deleted included)
                 nor carried by an earlier event of the batch                               # BE-EV-43
        for each transaction_id t, I ← the indexes carrying t in order:                   # BE-EV-44, RBD-33
            flagged ← I minus its first index if any new[i] for i in I, else I
            for i in flagged: errors[i] ← {"transaction_id": ["value_already_exist"]}
        (corrected: errors[i] for exactly the i with not new[i])
        if errors: store nothing; return 422 errors
        store all
        schedule post-processing for all
    publish every event ; return 200 echoes
```

## 11. Edge cases (people get these wrong)

1. `timestamp: false` and `timestamp: {}` mean "now", `timestamp: true` is invalid (BE-EV-10/11).
2. A timestamp sent as a JSON number loses digits beyond binary64; sent as a string it does not (BE-EV-12).
3. Stored times are truncated to microseconds but the raw message carries the full parsed value through binary64 (BE-EV-13/61).
4. Events without a subscription id are never deduplicated by the single-event path but are by batches (BE-EV-32/44).
5. Columnar-store organizations get no validation on single events but do on batches (BE-EV-23/41).
6. An expression failure is a TEXT `error_details`, not an object (BE-EV-52).
7. The expression result is written as a decimal STRING with a fractional digit (`"3.0"`), even when the client sent a number in that field (BE-EV-51).
8. `precise_total_amount_cents: "12abc"` is 12, not an error (BE-EV-25).
9. A division by zero in a metric expression is an internal error (HTTP 500) in the reference, not a 422 (BE-EV-54, RBD-37).
10. A boolean sent as `transaction_id`, `code` or `external_subscription_id` becomes `"t"`/`"f"` (BE-EV-2).
11. Two batch events repeating one stored key are BOTH rejected; a stored key plus a new key under one `transaction_id` flags only the later index (BE-EV-43/44).

## 12. Vectors

| Rules | Vectors |
|---|---|
| BE-EV-1..5 surface | `events.validate.001..004`, `.007`, `.026` |
| BE-EV-10..16 time | `events.parse_timestamp.001..023`, `events.raw_message.003/004` |
| BE-EV-20..25 validation | `events.validate.005/006`, `.008`, `.013`, `.014`, `.018/019(x)`, `.021..024`, `.027` |
| BE-EV-30..34 idempotency | `events.duplicate_key.*`, `events.validate.009..012`, `.020(x)` |
| BE-EV-40..46 batch | `events.validate_batch.*` |
| BE-EV-50..54 expression | `events.validate.014..018`, `.025x`, `.028`, `events.validate_batch.001/010/017`, `events.raw_message.007` |
| BE-EV-60..65 raw message | `events.raw_message.*` |

## Provenance (maintainers)

| Rules | Reference behaviour at the pin |
|---|---|
| BE-EV-1..4 | `$API/app/controllers/api/v1/events_controller.rb:12-51`, `:172-197`; `$API/app/controllers/api/base_controller.rb:16` |
| BE-EV-5 | `$API/app/serializers/v1/event_serializer.rb:5-17` |
| BE-EV-10..14 | `$API/app/services/events/create_service.rb:52-56`; `$API/app/services/events/create_batch_service.rb:52`; specs `$API/spec/services/events/create_service_spec.rb:124-188` |
| BE-EV-15 | same parse line; non-finite values and the database range raise outside the rescued error class |
| BE-EV-20..24 | `$API/app/services/events/create_service.rb:15-46`; `$API/app/models/event.rb:14-15`; `$API/app/controllers/concerns/api_errors.rb:26-36` |
| BE-EV-25 | `$API/app/services/events/create_service.rb:27`; spec `$API/spec/services/events/create_service_spec.rb:250-268` |
| BE-EV-30..33 | unique index `$API/app/models/event.rb:95`; `$API/app/services/events/create_service.rb:32`, `:44-45`, `:65-66` |
| BE-EV-40..46 | `$API/app/services/events/create_batch_service.rb:5`, `:18-110`; spec `$API/spec/services/events/create_batch_service_spec.rb:112-303` |
| BE-EV-50..54 | `$API/app/services/events/calculate_expression_service.rb:13-31`; `$API/app/services/events/create_service.rb:29-30`; specs `$API/spec/requests/api/v1/events_controller_spec.rb:88-128`, `:195-237` |
| BE-EV-60..65 | `$API/app/services/events/kafka_producer_service.rb:15-54`; `$API/app/services/events/create_service.rb:36-39`, `:62-69`; spec `$API/spec/services/events/create_batch_service_spec.rb:338-420` |
| BE-EV-70..72 | `$API/app/services/events/post_process_service.rb:13-162`; `$API/app/services/events/pay_in_advance_service.rb:12-64` |
| BE-EV-73 | `$API/app/services/events/post_validation_service.rb:13-77`; `$API/clock.rb:175-183` |
| BE-EV-74 | `$API/app/controllers/api/v1/events_controller.rb:53-60` |

Executions on the pinned toolchain (ruby-4.0.6, 2026-10-02, database `lago_api_test_a3`):

- `oracle.sh run spec/services/events/create_service_spec.rb spec/services/events/create_batch_service_spec.rb
  spec/services/billable_metrics/evaluate_expression_service_spec.rb
  spec/services/events/calculate_expression_service_spec.rb` → `{"example_count":51,"failure_count":0,…}`.
- `oracle.sh run spec/requests/api/v1/events_controller_spec.rb spec/requests/api/v1/billable_metrics_controller_spec.rb
  spec/models/billable_metric_spec.rb` (ClickHouse examples included, under the ClickHouse lock) →
  `{"example_count":128,"failure_count":0,…}`.
- Oracle module `scripts/maintainer/oracle-adapter/ops/events.rb`: every op drives the real endpoint in-process
  (request parsing, parameter filtering, services, model validations, unique index, rendering) inside a rolled-back
  transaction; the raw message is captured from the producer call. `kitrun --vectors events.ingest.jsonl` against
  the oracle: every `both`/`compat` vector PASS (see the hand-off report).
- Probes behind BE-EV-15 and BE-EV-54 (internal errors): `NaN`, `-Infinity` and (relational store) `1e20` answer 500;
  a negative timestamp with an expression answers 500. Division by zero (independent verification, 2026-10-02): the
  pinned app under its own web server (Puma 7.2.1, test env, private port) answered HTTP 500 to `POST /api/v1/events`,
  `POST /api/v1/events/batch` and the preview endpoint, stored nothing, and served the next request; the binding
  raises a `fatal` that only a process evaluating it on its main thread outside the request stack dies from.
- Probes of 2026-10-05 through the oracle op module (database of the fix round, `kitrun` on the added vectors 2/2 PASS):
  batch flagging per `transaction_id` (ten shapes: stored key repeated twice → both indexes; stored key, new key, stored key → the
  two later indexes; keys without a subscription id never collide with stored ones) follows the per-`transaction_id`
  index map of the bulk insert, `$API/app/services/events/create_batch_service.rb:78-100`; the relational-store time range
  (−210866803200 s and 9224318015999.999999 s accepted, −210866803201 s and 9224318016000 s answer 500; `NaN` answers 500 in both stores);
  pre-1970 events with an expression (`-5`, `-0.5`, both stores) answer 500 through the unsigned timestamp of the binding,
  `$API/app/services/events/calculate_expression_service.rb:22`; a whitespace-only metric expression is no expression,
  `$API/app/services/events/calculate_expression_service.rb:20`.
- Text members (BE-EV-2), `precise_total_amount_cents` corners (BE-EV-25: empty text → null, `true` → 1) and the
  raw-message exponent form (BE-EV-61) were probed through the oracle op module on 2026-10-02.
- Update triggers: a pin bump; any change to the events controller, the create/batch services, the producer
  payload or the expression binding.
