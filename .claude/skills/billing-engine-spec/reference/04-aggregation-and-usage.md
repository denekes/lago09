# 04 — Aggregation and usage (BE-AG)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08).
> It is a behavioural specification written fresh from executed vectors and probes, not source code. Proprietary
> clean-room rebuilds should have it reviewed (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90`. This chapter specifies how the billing engine turns the stored usage events of one
subscription into **units** for one charge: which events are selected for a billing window, the formula of every
aggregation type, configurable and built-in rounding, charge filters and grouping, the running state kept for
charges billed in advance, proration of recurring metrics, and the differences of the columnar event store. Pricing
those units (charge models, fees) is chapter 05; the billing windows themselves come from chapter 06; event
acceptance and the stored form of event properties is chapter 02; day counting and rounding primitives are
chapter 01.

Two event stores exist (chapter 02 explains which organization uses which):

- **relational store** (vector input `store: "pg"`): the normative variant. Every rule of sections 1-8 describes it.
- **columnar store** (`store: "ch"`): reads the rows the events-processor writes (`events-processor-spec`). Section 9
  lists every place where it answers differently. The corrected profile asks a rebuild to give both stores the
  relational semantics (RBD-25..31, proposed).

Reading guide: rules are numbered `BE-AG-n`; every rule line ends with `[vec: …]` naming the vectors that pin it,
or a prose-only marker with the reason. Vector files: `aggregation.core.jsonl` (selection, formulas, rounding),
`aggregation.filters.jsonl` (filters and groups), `aggregation.in_advance.jsonl` (running state),
`aggregation.prorated.jsonl` (proration) and `aggregation.store_ch.jsonl` (columnar variant). Ops:
`aggregation.aggregate`, `aggregation.in_advance_units`, `aggregation.current_usage_in_advance`,
`aggregation.matching_and_ignored`, `aggregation.select_events`, `aggregation.event_filter`,
`aggregation.group_keys`; schemas in `reimplementation-kit/schemas/ops/aggregation.*.schema.json`. Vector inputs leave
schema defaults out: `store` `pg`; the metric `code` `kit_metric` (an event without `code` carries the metric's code, so an
event with any other `code` is not selected); the window 2024-03-01T00:00:00Z to 2024-03-31T23:59:59.999999Z (`aggregate`,
`in_advance_units`); `charges_duration_days` = the calendar days from the UTC date of `from` to that of `to`,
inclusive; ingestion order = list order; event ids `e1`, `e2`, … by position (ids are written out when a vector
refers to them or when their text order matters).

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun against the oracle -->

## 1. Concepts and the inputs of an aggregation

| Term | Meaning |
|---|---|
| metric | billable metric: `code`, `aggregation_type` (`count_agg`, `sum_agg`, `max_agg`, `unique_count_agg`, `weighted_sum_agg`, `latest_agg`; `custom_agg` is out of scope, RBD-98), `field_name` (the event property read; ignored by count), `recurring` (state carries across periods), optional `rounding_function` (`round`, `ceil`, `floor`) and `rounding_precision` |
| bucket | what one fee is computed for: the whole charge, or one charge filter of the charge, or the charge's default bucket (section 6) |
| window | `[from, to]` charges window of one billing period, both bounds inclusive, plus `charges_duration_days` (days of the full, unclipped period) and the customer's effective time zone. Chapter 06 produces it: `from` is local midnight of the first day (never before the subscription start), `to` is local `23:59:59.999999` of the last day, or the termination instant |
| event | `transaction_id`, `timestamp` (relational store: microseconds), `properties` (object, as stored by chapter 02), `external_subscription_id`, `code`, ingestion order |
| value v(e) | the number read from `properties[field_name]` (section 2.2) |
| S | the selected events of the bucket for the window (section 2) |
| result | `aggregation` (the units priced by chapter 05), `count` (events counted), `current_usage_units` (units shown in current usage), `full_units_number` (unprorated units), `running_total` (free-unit helper), per-event values, weighted-sum fields, groups and breakdowns (section 3) |

- **BE-AG-7** The window is an input: this chapter never derives billing periods. A rebuild passes chapter 06's boundaries unchanged (local midnight start, local end of day with microseconds, `charges_duration_days` of the full period even when the window is clipped by a start or a termination). [vec: none (prose only: input contract; the boundaries are pinned by the periods.boundaries vectors of chapter 06)]

## 2. Selecting events

### 2.1 Scope and bounds

- **BE-AG-1** Base scope: same organization, `external_subscription_id` equal to the subscription's external id, `code` equal to the metric code, not soft-deleted. Events are matched by the external id, not by the internal subscription: events received while a previous subscription with the same external id was active are selected whenever their time falls in the window. [vec: aggregation.core.count.001, aggregation.core.count.004, aggregation.core.count.005, aggregation.core.count.006, aggregation.core.sum.004, aggregation.prorated.sum.004]
- **BE-AG-2** Lower bound: `timestamp ≥ from`, where `from` is first truncated (floored) to the millisecond. An event one microsecond before a whole-second `from` is excluded; an event at `.000` is kept when `from` is `.000285`. [vec: aggregation.core.count.003, aggregation.core.count.018, aggregation.core.unique.005, aggregation.core.window.002]
- **BE-AG-3** Upper bound: `timestamp ≤ to` (exact; no truncation). Pricing one event in advance replaces `to` by that event's time with a tie-break (BE-AG-42). [vec: aggregation.core.count.002, aggregation.core.count.003, aggregation.core.window.001, aggregation.in_advance.boundary.001, aggregation.store_ch.precision.002]
- **BE-AG-4** Recurring `sum_agg` and recurring `unique_count_agg` have **no lower bound**: every event up to `to` counts, including events dated before the subscription started. (Recurring weighted sums use an initial value instead, BE-AG-18; recurring prorated sums, section 8.) [vec: aggregation.core.sum.003, aggregation.core.sum.004, aggregation.core.unique.004, aggregation.store_ch.unique.006]
- **BE-AG-6** Upgrades: the terminated subscription's window ends at its termination instant and the new subscription's window starts at the same instant (chapter 06), both inclusive. An event at exactly that instant is therefore counted by both subscriptions (verified end to end through the upgrade path and the period service: 2 + 2 events for 3 events). Rebuild decision RBD-35 (proposed: count it only for the new subscription). [vec: aggregation.core.window.001, aggregation.core.window.001x, aggregation.core.window.002]

### 2.2 Reading a value: the numeric gate

The **property text** of an event for key `k` is: absent when the key is missing or its value is JSON null; the
string itself for a string; `true`/`false` for booleans; for a number, its JSON text as stored by the ingestion API
(chapter 02, BE-EV-3: integers exact, non-integers through binary64, printed in shortest form with at least one
fractional digit — `1.0`, `12.5`, `1000.0` for `1e3`); for an object or array, its JSON text (spelling store-specific; no vector relies on it).

- **BE-AG-5** For `sum_agg`, `max_agg`, `latest_agg`, `weighted_sum_agg` (and prorated sums) an event is kept only if the property text of `field_name` exists and matches `^-?[0-9]+(\.[0-9]+)?$`. Rejected events count neither in the value nor in `count`. Kept: `12`, `12.5`, `-3`, `"12"`, `"12.50"`, `"-0.0"`, JSON numbers written with an exponent (stored as `1000.0`). Rejected: `"1e3"`, `"+5"`, `".5"`, `"5."`, `" 5"`, booleans, null, missing, `"abc"`. v(e) is the exact decimal of the kept text. `count_agg` and `unique_count_agg` apply no gate. [vec: aggregation.core.sum.005, aggregation.core.sum.007, aggregation.core.sum.008, aggregation.core.max.004, aggregation.core.max.007, aggregation.core.latest.005, aggregation.core.count.007]

## 3. Formulas per aggregation type

N = number of events in S; values are exact decimals; results are canonical decimals.

| Type | aggregation | count | current_usage_units | per-event values (BE-AG-21) |
|---|---|---|---|---|
| `count_agg` | N | N | N | 1 per event |
| `sum_agg` | Σ v(e) (may be negative) | N | not produced (see BE-AG-44) | v(e) in time order |
| `max_agg` | max v(e), 0 when S is empty (negative maxima kept) | N | not produced | the first event carrying the maximum keeps it, all others 0 |
| `latest_agg` | v of the event with the greatest time, 0 when S is empty, 0 when that value is negative | N | not produced | — |
| `unique_count_agg` | ceil₅(Σ adjusted values) (BE-AG-14) | = aggregation | — | 1 per event of the window |
| `weighted_sum_agg` | ceil₂₀ of the time-weighted level (BE-AG-17) | N | — | — |

ceilₙ = round towards +∞ at n decimal places.

- **BE-AG-10** `count_agg`: aggregation = count = current_usage_units = N; values are ignored entirely. [vec: aggregation.core.count.001, aggregation.core.count.002, aggregation.core.count.003, aggregation.core.count.007, aggregation.core.count.011, aggregation.store_ch.count.001]
- **BE-AG-11** `sum_agg`: aggregation = Σ v(e) over S with exact decimal addition (0.1 + 0.2 = 0.3; 15+ integer digits and 9+ fraction digits are kept); no clamping in arrears; an empty S gives 0. [vec: aggregation.core.sum.001, aggregation.core.sum.003, aggregation.core.sum.005, aggregation.core.sum.006, aggregation.core.sum.009, aggregation.core.sum.010, aggregation.core.sum.012]
- **BE-AG-12** `max_agg`: the largest v(e); when every value is negative the result is the negative maximum (RBD-39, kept); empty S gives 0. [vec: aggregation.core.max.001, aggregation.core.max.002, aggregation.core.max.003, aggregation.core.max.004, aggregation.core.max.006, aggregation.core.max.007, aggregation.store_ch.gate.004, aggregation.store_ch.gate.004x]
- **BE-AG-13** `latest_agg`: the value of the event with the greatest timestamp (not the last ingested); among events with the same greatest timestamp, the one ingested last; a negative result is reported as 0 (RBD-39, kept); `count` = N. [vec: aggregation.core.latest.001, aggregation.core.latest.002, aggregation.core.latest.003, aggregation.core.latest.005, aggregation.core.latest.006, aggregation.store_ch.gate.005, aggregation.store_ch.gate.005x, aggregation.store_ch.latest.001, aggregation.store_ch.latest.002, aggregation.store_ch.latest.002x]
- **BE-AG-14** `unique_count_agg`: partition S by the property text p(e) of `field_name`. Within a partition, order by time; op(e) = the `operation_type` property, `"add"` when missing. The first event's "previous operation" is `"remove"`. adjusted(e) = 0 when op(e) equals the previous operation, else +1 when op(e) = `"add"` and −1 otherwise. aggregation = ceil₅(Σ adjusted(e)); count = aggregation. With only add/remove each value contributes 0 or 1 (`add, add, remove, add` → 1; `remove, add` → 1; `add, remove` → 0; a lone `remove` → 0). [vec: aggregation.core.unique.001, aggregation.core.unique.002, aggregation.core.unique.004, aggregation.core.unique.005, aggregation.core.unique.006, aggregation.core.unique.008, aggregation.core.unique.011, aggregation.store_ch.unique.004, aggregation.store_ch.unique.006]
- **BE-AG-15** Unique identity is the property **text**: number `1` and string `"1"` are the same value, number `1.0` is another; events lacking the property form one more value of their own (they are not excluded). [vec: aggregation.core.unique.003, aggregation.core.unique.007, aggregation.store_ch.unique.005]
- **BE-AG-16** `operation_type` is not validated. Any value other than `"add"` (including `""`, `"delete"`, `"ADD"`) behaves as a removal that is never a no-op on first occurrence, so a value can contribute −1 and the total can be negative (`delete` → −1; `add, delete, delete` → 0; `""` → −1; `ADD` → −1). Rebuild decision RBD-28 (proposed: reject unknown operation types at ingestion). [vec: aggregation.core.unique.012]
- **BE-AG-17** `weighted_sum_agg` (time-weighted average level): build the rows `(from, I)`, then every event of S as `(t, v)` in time order (events at the same instant are all applied), then `(T, 0)` where `T` = `to` rounded up to a whole second (`23:59:59.999999` becomes the next midnight, a whole-second `23:59:59` stays). The level after a row is the running sum of the row values. aggregation = ceil₂₀( Σᵢ shareᵢ ) with shareᵢ = (levelᵢ × (tᵢ₊₁ − tᵢ)) / (charges_duration_days × 86 400): the level is multiplied by the duration in exact (fractional) seconds first and the product is divided last; a zero-length segment contributes 0. count = N; variation = Σ v(e) (net change in the period); I = 0 unless recurring (BE-AG-18). The relational store rounds each quotient half away from zero to at least 16 significant digits and to no fewer decimal places than the product carries (the duration in seconds has 6 decimals, so at least 6, and 7 for a level with one decimal): a level of 10¹⁸ for one day of 31 gives 32258064516129032.258065. Results are normative to that precision; vectors compare at 12 decimal places (6 for a level of 10¹⁵, where dividing first would already differ in the sixth decimal). [vec: aggregation.core.weighted.001, aggregation.core.weighted.002, aggregation.core.weighted.003, aggregation.core.weighted.009, aggregation.core.weighted.010, aggregation.core.weighted.017, aggregation.store_ch.weighted.001]
- **BE-AG-18** Recurring weighted sum: I = the `current_aggregation` of the latest cached state of the bucket and group whose timestamp is strictly before `from` (latest timestamp, then latest written; a state stamped exactly at `from`, which is what the op's `cached` input means when it gives no timestamp, is ignored); without one, if the subscription has a previous subscription, I = Σ v(e) of every gated event up to `from − 1 s`; else I = 0. Outputs: total_aggregated_units = I + variation (the level at the end of the period; = variation when not recurring); recurring_updated_at = the time of the last event of S, else `from`. At invoicing the engine stores a new cached state `{timestamp: recurring_updated_at, current_aggregation: total_aggregated_units}` for the next period. A cached state is ignored by non-recurring metrics. [vec: aggregation.core.weighted.004, aggregation.core.weighted.005, aggregation.core.weighted.006, aggregation.core.weighted.014, aggregation.core.weighted.016]
- **BE-AG-19** Null result: aggregation 0, count 0, current_usage_units 0, running_total `[]`; for a grouped bucket, a single group whose keys are all null. It is returned for an empty S and, without reading any event, when the period pre-pass (BE-AG-71) found no event for a bucket of a **non-recurring** metric ("bypass"); recurring metrics always aggregate. [vec: aggregation.core.count.012, aggregation.core.count.016, aggregation.core.null.001, aggregation.core.null.002, aggregation.core.null.003, aggregation.core.max.002]
- **BE-AG-20** Running totals (input to the percentage charge model's free units, chapter 05). Let K = `free_units_per_events` (integer) and A = `free_units_per_total_aggregation` (decimal) of the bucket's charge properties. If both are 0: `[]`. `sum_agg`: if K > 0, the cumulative sums of the first K values of S in time order (recurring: S has no lower bound); else walk the values in time order and, while the running total so far is ≤ A, append the running total after adding the value (the first total above A is included, then stop). `count_agg`, `unique_count_agg`: `[1, 2, …, aggregation]`. [vec: aggregation.core.count.008, aggregation.core.count.009, aggregation.core.sum.001, aggregation.core.sum.002, aggregation.core.sum.016, aggregation.core.unique.009, aggregation.core.ties.001]
- **BE-AG-21** Per-event values (used by per-event pricing, chapter 05) are taken over the window's events only (lower bound applied even for recurring metrics) in time order: see the table above. When an event is being priced in advance, the list stops at that event (BE-AG-42). Prorated sums (section 8) differ: with C = Σ v(e) over the carried events (time < `from`, gated), `per_event` = [C] followed by the window values and `per_event_prorated` = [C × p₁₆(P)] followed by v(e) × q(n(e), D) for the window events, in time order (BE-AG-50/51/56); the leading entries are present only when C ≠ 0 (carried events summing to 0 give none). [vec: aggregation.core.count.015, aggregation.core.max.005, aggregation.core.sum.015, aggregation.core.unique.010, aggregation.in_advance.boundary.003, aggregation.prorated.sum.009, aggregation.prorated.sum.013, aggregation.prorated.island.006, aggregation.prorated.island.006x]
- **BE-AG-27** Dynamic charges (chapter 05; sum metrics only) also need the events' own amounts: the bucket reports `precise_total_amount_cents` = Σ of the `precise_total_amount_cents` (chapter 02) of the same selection S as the units, numeric gate included (an event dropped by BE-AG-5 drops its amount too), events without an amount adding 0; per group when grouped. While one event is priced in advance, the total stops at that event (BE-AG-42) and `pay_in_advance_precise_total_amount_cents` is that event's own amount (0 when absent). [vec: aggregation.core.dynamic.001, aggregation.core.dynamic.002, aggregation.core.dynamic.003]

## 4. Rounding

- **BE-AG-25** When the metric has a `rounding_function`, it is applied with `rounding_precision` (null = 0; negative = tens, hundreds; chapter 01 BE-DM-23/25: `round` half away from zero, `ceil` towards +∞, `floor` towards −∞) to `aggregation`, `full_units_number` and `current_usage_units`, per group when grouped. It is NOT applied when pricing a single event in advance. 123.456 → round 123.46 / 123 / 100, ceil 123.46 / 124 / 200, floor 123.45 / 123 / 100 for precisions 2 / none / −2; −2.5 rounds to −3. [vec: aggregation.core.rounding.*, aggregation.core.sum.011, aggregation.in_advance.boundary.004, aggregation.prorated.sum.003]
- **BE-AG-26** Built-in roundings, always applied: unique count ceil₅; prorated results ceil₅; weighted sum ceil₂₀ (normative precision in BE-AG-17; per-group weighted sums are reported without that ceiling, a difference beyond the normative digits). [vec: aggregation.core.unique.011, aggregation.prorated.sum.001, aggregation.core.weighted.001]

## 5. Equal timestamps

- **BE-AG-73** The reference defines no order among events with the same timestamp when it lists values in time order: running totals and per-event values of equal-time events may come in any order (only order-free results, such as the last running total, are fixed); the columnar store also has no tie-break for `latest_agg` (BE-AG-65). A rebuild orders ties by ingestion order, then `transaction_id` (RBD-30, proposed); the relational store's `latest_agg` (BE-AG-13) and in-advance boundary (BE-AG-42) already use ingestion order. Vectors avoid ties or mark the undefined part `ignore`. [vec: aggregation.core.ties.001, aggregation.core.ties.001x, aggregation.store_ch.latest.002, aggregation.store_ch.latest.002x]

## 6. Charge filters, buckets and groups

Metric filters declare, per key, the allowed string values. A charge filter selects, per key, a non-empty subset
of those values or `ALL` (every declared value, expanded when evaluated). A filter's **expanded values** are its
values with `ALL` replaced by the declared list.

- **BE-AG-30** Store-level selection of a bucket from `matching` (key → values) and `ignored` (a list of key → values combinations): keep an event iff for every matching key its property text is one of the values (a missing key never matches), AND for no ignored combination every one of its keys has a property text — a missing key reading as `""` — among that combination's values. Ignored combinations that are empty or whose value lists are all empty are skipped (an empty value list inside a combination is skipped too). Values compare as text: number `512` matches `"512"`, `true` matches `"true"`, `512.0` does not match `"512"` (BE-AG-69 for the columnar store). An ignored value `""` therefore also ignores events lacking the key. [vec: aggregation.core.count.017, aggregation.filters.select.001, aggregation.filters.select.002, aggregation.filters.select.003, aggregation.filters.select.005, aggregation.filters.select.006]
- **BE-AG-31** A charge without filters has one bucket. A charge with filters has one bucket per filter, listed in ascending order of the filter's last update, plus a **default bucket** that uses the charge's own properties. [vec: aggregation.filters.event.002]
- **BE-AG-32** `matching` and `ignored` of the bucket of filter F: matching = F's expanded values. The **children** of F are the other filters G of the charge that, for every key of F, hold at least one of F's values for that key (a G lacking one of F's keys is not a child). For each child, with G's expanded values: if G has exactly F's keys and the same value set on every key → see BE-AG-33; else if G's values are a subset of F's on every key → G is ignored as is; else if G has exactly F's keys → for every key where F is not `ALL`, G's values minus F's values are ignored (lists may become empty); a child with other keys than F is ignored as is. ignored = the resulting list (order irrelevant). [vec: aggregation.filters.mi.001, aggregation.filters.mi.002, aggregation.filters.mi.003, aggregation.filters.mi.004, aggregation.filters.mi.005, aggregation.filters.mi.007, aggregation.filters.mi.008, aggregation.filters.mi.012, aggregation.filters.mi.013, aggregation.filters.mi.014, aggregation.filters.mi.015]
- **BE-AG-33** Identical filters (same keys, same value sets): a child identical to F is ignored only if it is older than F (creation time, then id); otherwise it is dropped. Effect: among identical filters the oldest bills the events, every newer duplicate bills 0. [vec: aggregation.filters.mi.009, aggregation.filters.mi.010]
- **BE-AG-34** Default bucket: matching = {} and every filter of the charge (expanded) is an ignored combination, so it receives exactly the events no filter matches, including events lacking the keys and events whose value is not a declared value. [vec: aggregation.filters.mi.006, aggregation.filters.select.002]
- **BE-AG-35** Single-event choice (pay-in-advance pricing, cache invalidation): restrict the event's properties to the metric's filter keys; a filter matches when every one of its keys is present with a property text among its expanded values; among matching filters the one with the most keys wins, ties go to the first in list order (BE-AG-31); none → default bucket. A value outside the declared values never matches, even under `ALL`. [vec: aggregation.filters.event.001, aggregation.filters.event.002, aggregation.filters.event.004, aggregation.filters.event.006, aggregation.filters.event.007, aggregation.filters.event.008]
- **BE-AG-36** Grouping (pricing group keys of the bucket: the filter's, else the charge's): one result per distinct tuple of the keys' property texts, reported as `grouped_by` {key → text}; a missing key and an empty-string value are both reported as null but form **two different groups** (the store groups by raw text); a null JSON value joins the missing-key group. Group values are the property texts (`1.0`, `true`, `12.5` for an input `12.50`). Each group carries the type's aggregation and count; rounding applies per group. [vec: aggregation.core.count.011, aggregation.core.count.012, aggregation.core.count.013, aggregation.core.sum.012, aggregation.core.sum.013, aggregation.core.max.006, aggregation.core.latest.006, aggregation.core.unique.008, aggregation.core.weighted.010, aggregation.core.rounding.011, aggregation.filters.group.001, aggregation.filters.group.002, aggregation.filters.group.004, aggregation.in_advance.current.006, aggregation.prorated.sum.011]
- **BE-AG-37** Presentation keys produce `breakdowns`: one entry per distinct tuple of (grouping keys ∪ presentation keys) with the type's value for that tuple (count, sum, weighted level, …). They are for display only and never change units or prices. [vec: aggregation.core.count.014, aggregation.core.sum.014, aggregation.core.weighted.009]
- **BE-AG-38** Overlapping filters: two filters with the same key and partly shared values (`region ∈ {us, eu}` and `region ∈ {us, asia}`) are accepted by the filter-management service, and an event with the shared value is selected by BOTH buckets, so it is billed twice (verified through current usage: 4 events → 5 units). The single-event choice (BE-AG-35) picks only the first. Rebuild decision RBD-36 (proposed: bill such an event once, under the filter BE-AG-35 picks). The correction acts on the bucket definition of BE-AG-32: a child G with exactly F's keys that the single-event choice ranks before F (same number of keys, so: G comes first in list order, BE-AG-31) is ignored as is, with all its expanded values, so F's bucket loses the shared values (filters `{us, eu}` then `{us, asia}`: the second bucket keeps `asia` only). The store-level selection (BE-AG-30) is the same in both profiles for the same matching and ignored filters. [vec: aggregation.filters.mi.014, aggregation.filters.mi.015, aggregation.filters.mi.015x, aggregation.filters.select.007, aggregation.filters.select.007x, aggregation.filters.select.008, aggregation.filters.select.008x, aggregation.filters.event.008]
- **BE-AG-39** A charge that accepts a target wallet (chapter 09) groups by one more key, `target_wallet_code`, appended to the bucket's pricing group keys; when one event is priced in advance and carries that property, the selection is restricted to events with the same `target_wallet_code`. [vec: none (prose only: the mechanics are plain grouping and group restriction, pinned by the BE-AG-36 and BE-AG-42 vectors; which charges add the key is charge configuration owned by chapter 09)]

## 7. Charges billed in advance: the running state

Charges billed in advance (`count_agg`, `sum_agg`, `unique_count_agg`; never `max_agg`, `latest_agg`,
`weighted_sum_agg`) are priced event by event. A **cached state** `{current_aggregation c, max_aggregation m,
max_aggregation_with_proration, units_applied}` is stored per charge, bucket, group and event; "the cache" for an
event is the latest state of its bucket and group whose timestamp lies in the window (bounds compared at whole
seconds), latest timestamp then latest written, excluding the event's own transaction. Rounding is not applied.

- **BE-AG-40** `sum_agg`, event value x: no cache → units = max(x, 0); new state c = m = units_applied = x. Cache (c, m): c′ = c + x; if c′ > m → units = c′ − m, new state c = c′ and m = max(c′, c′ − m), which is c′ unless the cached maximum is negative (cache c = m = −5, x = 3 → units 3, new m = 3, not −2); else units = 0, new state c = c′, m unchanged, units_applied = x. An event without properties adds 0 units. After a negative cached maximum the event therefore bills units the period total never reaches (events −5 then +3 bill 0 then 3 while the period total is −2): rebuild decision RBD-100 (compat keeps it; proposed: bill the rise of max(running total, 0) over its previous maximum, so the example bills 0 then 0). [vec: aggregation.in_advance.sum.001, aggregation.in_advance.sum.002, aggregation.in_advance.sum.003, aggregation.in_advance.sum.004, aggregation.in_advance.sum.006, aggregation.in_advance.sum.007, aggregation.in_advance.sum.008, aggregation.in_advance.boundary.004]
- **BE-AG-41** `unique_count_agg`, event e with value p: e is **active-before** when the latest strictly earlier event with the same value (within the selection of section 2) exists and its operation is `add` or missing. Strictly earlier means an earlier timestamp, in both stores: an event at the same instant as e never counts, whatever its ingestion order, so an `add` at the same instant as a stored `add` of the same value is billed again (RBD-30, proposed: order equal timestamps by ingestion, then `transaction_id`, which makes the stored `add` active-before and bills nothing); among several earlier events at the latest earlier timestamp the reference picks any. "Same value" here is, in the relational store, JSON value equality, not the property text of BE-AG-15: a string never equals a number (`"1"` after `1` is a new value) and numbers compare by value (`1` after `1.0` is the same value); the columnar store compares the property-map text of BE-AG-69 instead (`"1"` after `1` is the same value there). This disagrees with the period count, which bills on text identity: rebuild decision RBD-101 (compat keeps JSON equality; proposed: the text identity of BE-AG-15 for both, so `"1"` after `1` is not new and `1` after `1.0` is). newly = 1 for an `add` that is not active-before, else 0. No cache → units = newly; state c = m = units_applied = newly. Cache (c, m): c′ = c + newly for an add, c − (1 if active-before else 0) for a removal; c′ > m → units 1, state c = m = c′; else units 0, state c = c′, m kept, units_applied = newly. [vec: aggregation.in_advance.unique.001, aggregation.in_advance.unique.002, aggregation.in_advance.unique.003, aggregation.in_advance.unique.004, aggregation.in_advance.unique.005, aggregation.in_advance.unique.006, aggregation.in_advance.unique.007, aggregation.in_advance.unique.008, aggregation.in_advance.unique.010, aggregation.in_advance.unique.010x, aggregation.in_advance.unique.011, aggregation.in_advance.unique.011x, aggregation.prorated.in_advance.004]
- **BE-AG-42** While pricing event e, the window's upper bound is e's time, and events with the same time are ordered by ingestion (relational store: an equal-time event counts only if ingested no later than e; columnar store: by `transaction_id`, BE-AG-65). This bounds the aggregation and the per-event values used by the charge model. [vec: aggregation.in_advance.boundary.001, aggregation.in_advance.boundary.003]
- **BE-AG-43** `count_agg` in advance: every event adds exactly 1 unit and writes no running state. `max_agg`, `latest_agg` and `weighted_sum_agg` charges cannot be billed in advance (charge validation, chapter 05). [vec: aggregation.in_advance.count.001]
- **BE-AG-44** Current usage of a charge billed in advance (`sum_agg`, `unique_count_agg`), period total T (BE-AG-11 or BE-AG-14) and the bucket's cache (c, m): aggregation = T − c + m (already billed at its peak plus anything above it), current_usage_units = T, each clamped at 0; without cache aggregation = T. Grouped: per group with the group's cache. `count`: N for `sum_agg`; for `unique_count_agg` the reported aggregation (after the adjustment and the clamp) when the bucket is not grouped, but the group's own period unique count T (unadjusted) per group (T = 2, c = 1, m = 3: ungrouped count 4, grouped count 2). [vec: aggregation.in_advance.current.001, aggregation.in_advance.current.002, aggregation.in_advance.current.004, aggregation.in_advance.current.005, aggregation.in_advance.current.006, aggregation.in_advance.current.007]

## 8. Proration (recurring metrics, prorated charges)

A prorated charge requires a recurring `sum_agg` or `unique_count_agg` metric (chapter 05). D =
`charges_duration_days`; days(a, b) = the day count of chapter 01 (BE-DM-15..18: local days, rounded up, one less
when the subscription was terminated by an upgrade); localdate(t) = the calendar date of t in the customer's zone.
Three number forms carry the reference's precision (BE-AG-56); products and sums of decimals are exact:

- q(n, D) = n / D as a decimal quotient rounded half away from zero to 20 decimal places (0 ≤ n ≤ D), used before any
  multiplication: q(11, 31) = 0.35483870967741935484;
- p₁₇(x) = the binary64 quotient x of two day counts, written as its shortest round-trip decimal text with every digit
  of that text (up to 17 significant digits): p₁₇(5/28) = 0.17857142857142858, p₁₇(3/30) = 0.1;
- p₁₆(x) = p₁₇(x) cut (not rounded) to 16 significant digits: p₁₆(5/28) = 0.1785714285714285, p₁₆(15/31) =
  0.4838709677419355.

- **BE-AG-50** Prorated sum, events of the window: each contributes v(e) × q(n(e), D) with n(e) = localdate(to) − localdate(t) + 1 (the ratio is rounded first, then multiplied: 3.1 × q(11, 31) = 1.100000000000000000004, not (3.1 × 11) / 31 = 1.1). [vec: aggregation.prorated.sum.001, aggregation.prorated.sum.005, aggregation.prorated.sum.007, aggregation.prorated.sum.009, aggregation.prorated.sum.011, aggregation.prorated.sum.011x, aggregation.prorated.island.001, aggregation.store_ch.prorated.001]
- **BE-AG-51** Prorated sum, carried events (time < `from`, no lower bound, gated): together they contribute (Σ v(e)) × p₁₇(P) with P = days(from, to) / D (P = 1 for a full period, less for a period clipped by a termination, one day less after an upgrade). aggregation = ceil₅(carried + Σ window contributions); full_units_number = the unprorated total; count = all contributing events. An event exactly at `from` is counted once, as a window event. [vec: aggregation.prorated.sum.001, aggregation.prorated.sum.004, aggregation.prorated.sum.005, aggregation.prorated.sum.006, aggregation.prorated.island.002, aggregation.store_ch.prorated.001]
- **BE-AG-52** Prorated unique count, per value (all history): (1) a removal is dropped when a later event of the same value on the same local day is an `add`; (2) adjusted values as in BE-AG-14 over the remaining events, and events adjusted to 0 are dropped; (3) each remaining `add` at time t, followed by the next remaining event n of the same value (or none), contributes q(localdate(end) − localdate(max(t, from)), D) where end = `from` when n is before `from` (no contribution), n + 1 day when n exists, else `to` + 1 day; removals contribute 0. aggregation = ceil₅(Σ); count = aggregation; full_units_number = the unprorated unique count. Net effect: added before the window → whole period; added and removed the same day → 1 day; added on day a and removed on day b → b − a + 1 days. Grouped computation quirk (relational store): every remaining `add` whose next remaining event lies before `from` contributes q(1, D), one day, instead of nothing; this counts per such add/remove pair, not per value (a value added and removed twice before the window adds two days, two values once each also two) (RBD-31, proposed: same as ungrouped). [vec: aggregation.prorated.unique.*, aggregation.store_ch.prorated.002, aggregation.store_ch.prorated.004]
- **BE-AG-53** Current usage of a prorated charge: billed in arrears → aggregation = the prorated value (≥ 0), current_usage_units = the unprorated value (≥ 0). Billed in advance, with the bucket's cache (c, m, mp = max_aggregation_with_proration) and U = unprorated units: if P < 1 → aggregation = ceil₅((U − max(c, 0)) × p₁₆(P)) + mp; if P = 1 → aggregation = U − max(c, 0) + mp; without cache → the prorated value if P < 1, else U; current_usage_units = U; all clamped at 0. [vec: aggregation.prorated.sum.002, aggregation.prorated.sum.003, aggregation.prorated.sum.012, aggregation.prorated.sum.014, aggregation.prorated.unique.011]
- **BE-AG-54** Pricing one event of a prorated charge in advance: units = ceil₅(u × p₁₆(days(t, to) / D)) with u = the unprorated units of BE-AG-40/41 (days without the upgrade adjustment; 31 units at 15 of 31 days → 15.00001, 28 units at 5 of 28 days → 5); full_units_number = the unprorated units; the new state keeps max_aggregation_with_proration = (no cache) units, else the cached value plus units when the unprorated maximum grew, else the cached value. [vec: aggregation.prorated.in_advance.001, aggregation.prorated.in_advance.002, aggregation.prorated.in_advance.003, aggregation.prorated.in_advance.004, aggregation.prorated.in_advance.005, aggregation.prorated.in_advance.005x, aggregation.prorated.in_advance.006]
- **BE-AG-55** A prorated charge billed in advance, aggregated for its billing run (no event, not current usage), bills the full unprorated units. [vec: aggregation.prorated.sum.010]
- **BE-AG-56** Precision islands (compat; RBD-96 proposes exact decimals), each with its evaluation order: (1) window ratios of prorated sums and prorated unique counts (BE-AG-50/52): q(n, D), rounded at 20 places, then multiplied; (2) the carried ratio of the period aggregation (BE-AG-51): (Σ v) × p₁₇(P), every digit of the binary64 ratio's shortest text — not the exact binary value and not a 16-digit form (15/31 → `0.4838709677419355`, so 31 × 15/31 → 15.00001; 3/30 → `0.1`, so 30 × 3/30 stays 3; 5/28 → `0.17857142857142858`, so 28 × 5/28 → 5.00001; 5/30 → `0.16666666666666666`, so 30 × 5/30 stays 5); (3) the carried per-event entry (BE-AG-21), in-advance current usage (BE-AG-53) and in-advance units (BE-AG-54): the same binary64 ratio cut to 16 digits, p₁₆ (28 × 5/28 → 4.999999999999998, so a ceiled result stays 5); (4) weighted-sum shares (BE-AG-17): (level × seconds) / (D × 86 400), divided last. Because results are then ceiled to 5 places, a product that is exactly on the 0.00001 grid can come out 0.00001 higher (3.1 × 11/31 → 1.10001; 31 × 15/31 → 15.00001), per group as well as ungrouped. [vec: aggregation.prorated.island.001, aggregation.prorated.island.001x, aggregation.prorated.island.002, aggregation.prorated.island.002x, aggregation.prorated.island.004, aggregation.prorated.island.004x, aggregation.prorated.island.006, aggregation.prorated.island.006x, aggregation.prorated.sum.011, aggregation.prorated.sum.011x, aggregation.prorated.sum.014, aggregation.prorated.in_advance.005, aggregation.prorated.in_advance.005x, aggregation.prorated.in_advance.006, aggregation.core.weighted.017]

## 9. The columnar store variant

The columnar store reads one row per event written by the events-processor: `timestamp` in milliseconds, the
`value` text (`events-processor-spec` EP-F1..F2: integers without fraction, large numbers in exponent form `1e+06`,
`"<nil>"` for a missing property, `"1"` for count metrics), `properties` read as a text map, and a decimal derived
from `value`. Selection, bounds and formulas are those of sections 2-8 except as listed below. A third, per-organization opt-in store variant that reads per-charge pre-expanded rows (and a matching pre-filtered pre-pass, BE-AG-71) also exists at the pin; it is out of scope of this chapter and of the vectors (which production organizations use it is an open owner question).

Differences of the columnar store:

- **BE-AG-60** No numeric gate: every selected row counts, with value = the decimal reading of its `value` text (exponent forms, a leading `+`, `.5` and `5.` are numbers; anything unparsable — `"<nil>"`, `"abc"`, a leading space — reads as 0 and still counts). This changes sums of counts, running totals (a 0 in the list), maxima (max of −5 and "abc" is 0), latest (a non-numeric last value gives 0) and weighted sums (a 0-delta row counts as an event). RBD-25 (proposed: relational semantics). [vec: aggregation.store_ch.gate.001, aggregation.store_ch.gate.001x, aggregation.store_ch.gate.002, aggregation.store_ch.gate.002x, aggregation.store_ch.gate.003, aggregation.store_ch.gate.003x, aggregation.store_ch.gate.004, aggregation.store_ch.gate.005, aggregation.store_ch.gate.007, aggregation.store_ch.gate.007x, aggregation.store_ch.count.001]
- **BE-AG-61** Values whose magnitude is 10¹² or more read as 0 (the derived decimal has 12 integer digits); 999999999999.99 is exact. RBD-26 (proposed: exact). [vec: aggregation.store_ch.big.001, aggregation.store_ch.big.001x, aggregation.store_ch.big.002, aggregation.store_ch.big.003, aggregation.store_ch.big.003x]
- **BE-AG-62** Unique identity is the `value` text: number `1`, string `"1"` and number `1.0` are one value (`"1"`); number 1000000 (`"1e+06"`) and string `"1000000"` are two; a missing property is the value `"<nil>"`. RBD-27 (proposed: relational text). [vec: aggregation.store_ch.unique.002, aggregation.store_ch.unique.002x, aggregation.store_ch.unique.004, aggregation.store_ch.unique.005]
- **BE-AG-63** Operation types: an empty or missing `operation_type` is `add`. An `add` adds 1 unless the previous event of the value was an `add`; any other text removes 1 unless the previous event's text was exactly `remove` (the first event's previous text counts as `remove`). Hence `delete` alone → 0, `add, delete, delete` → −1, `""` → +1, `ADD` alone → 0 (compare BE-AG-16). RBD-28. [vec: aggregation.store_ch.unique.003]
- **BE-AG-64** Weighted-sum durations count whole-second boundaries crossed (the difference of the times truncated to seconds): 0.000 → 1.500 lasts 1 s, 0.900 → 1.100 lasts 1 s. RBD-29 (proposed: exact durations). [vec: aggregation.store_ch.weighted.001, aggregation.store_ch.weighted.002, aggregation.store_ch.weighted.002x, aggregation.store_ch.weighted.003, aggregation.store_ch.weighted.003x]
- **BE-AG-65** Ties: `latest_agg` has no tie-break among equal greatest timestamps; while pricing an event in advance, equal-time events count when their `transaction_id` is ≤ the priced event's (text order), whatever the ingestion order. RBD-30 (proposed: ingestion order). [vec: aggregation.store_ch.latest.002, aggregation.store_ch.latest.002x]
- **BE-AG-66** Prorated unique count: a removal is dropped unless it is the last event of its value on that local day (instead of BE-AG-52 step 1; the day-granular result is the same in every case tried), the grouped variant has no extra day, and day ratios are computed as decimals with 10 fractional digits. RBD-31. [vec: aggregation.store_ch.prorated.002, aggregation.store_ch.prorated.004]
- **BE-AG-74** Prorated sums (BE-AG-50/51) are evaluated inside the store in binary floating point, not with the decimal forms q and p₁₇ of BE-AG-56: the day ratio `n ⊘ D` (a binary64 division of two integers) and the carried ratio P (the binary64 of BE-AG-51, passed as its shortest text and read back unchanged) are binary64, and each value v contributes `c(v) ⊗ ratio`. **Conversion** `c(v)`: the store keeps v at 26 decimal places as the integer `x = v × 10^26`, takes x to binary64 through a 64-bit significand and divides by `b(10^26)`: with `h` and `l` the high and low 64-bit halves of |x|, `y = r₆₄(r₆₄(r₆₄(h × (2^64 − 1)) + h) + l)`, where r₆₄ rounds to 64 significant bits (ties to even), and `c(v) = ±b(y) ⊘ b(10^26)` with the sign of v. c(v) is often not the nearest binary64 of v (3.1 → 3.0999999999999996, 28 → 27.999999999999996, 31 → 30.999999999999996) and occasionally not `b(x) ⊘ b(10^26)` either (8.3 → 8.3, not 8.299999999999999). **Sums**: the carried part and the window part are two binary64 sums of contributions; each is read through its shortest round-trip text, they are added as decimals, and the aggregation is ceil₅ of the total. The store adds the contributions of one part in an order it does not define, so a part with three or more contributions is not reproducible to the last bit (window events 1 at 25, 0.6 at 14 and 2 at 4 of 30 days gave 1.38 on one run and 1.38001 on an identical one); a part with at most two contributions is order-free (binary64 addition is commutative), and vectors stay there. The per-event prorated values of window events are the binary64 contributions. Examples (relational store, BE-AG-56, in parentheses): 31 carried at P = 15/31 → 15 (15.00001); 28 carried at P = 5/28 → 5 (5.00001); 3 carried at P = 3/30 → 0.30001, from 0.30000000000000004 (0.3); one window event 3.1 at 11 of 31 days → per-event 1.0999999999999999 and aggregation 1.1 (1.100000000000000000004 and 1.10001); 12 at 9 of 30 days → per-event 3.5999999999999996 (3.6). The carried per-event entry of BE-AG-21 and the in-advance current usage of BE-AG-53 are computed outside the store and match the relational store. RBD-96 (proposed: exact decimals). [vec: aggregation.store_ch.prorated.005, aggregation.store_ch.prorated.005x, aggregation.store_ch.prorated.006, aggregation.store_ch.prorated.006x]
- **BE-AG-67** Precision: event times are kept to the millisecond (truncated); the relational store keeps microseconds. An event at `23:59:59.9995` is inside a window ending at `23:59:59.999` in the columnar store and outside it in the relational store. RBD-40 (kept). [vec: aggregation.store_ch.precision.001, aggregation.store_ch.precision.002]
- **BE-AG-68** Duplicates: rows re-sent with the same `transaction_id` and the same timestamp collapse to one only when the organization enables query-time de-duplication (or once the store merges them, which is not deterministic, hence no vector without the flag); the same `transaction_id` at two timestamps is always two events. RBD-32 (ingestion idempotency, chapter 02). [vec: aggregation.store_ch.dedup.002, aggregation.store_ch.dedup.003]
- **BE-AG-69** Property map: a missing key reads as `""` (so `matching {k: [""]}` selects events lacking `k`), JSON numbers read as their normalized number text (`512.0` → `"512"`, `1.0` → `"1"`), booleans as `true`/`false`; group values `""` and missing are null. RBD-25/RBD-27 (proposed: relational text). [vec: aggregation.store_ch.filters.001, aggregation.store_ch.filters.001x, aggregation.store_ch.filters.002, aggregation.store_ch.filters.002x, aggregation.store_ch.group.001, aggregation.store_ch.group.001x]

## 10. Usage views (interface level)

- **BE-AG-70** Current usage of a subscription: for every charge of its plan (optionally restricted by charge, charge code or metric code), the window is the current period's charges window up to its end; every bucket is aggregated (sections 2-9) with `is_current_usage`, priced by chapter 05 and, unless disabled, taxed by chapter 07; results are sorted by metric name (case-insensitive) and cached per charge until a new event arrives or the period ends. Zero-unit filter fees can be hidden on request. [vec: none (prose only: composition is pinned end to end by the scn.usage.* scenarios of the scenario tier)]
- **BE-AG-71** Period pre-pass: the distinct combinations of filter-key properties of the period's events (all history for recurring metrics) are matched to buckets with the matching test of BE-AG-35, keeping every matching filter (not only the one BE-AG-35 picks), and a combination matching no filter marks the default bucket; buckets without events of non-recurring metrics get the null result without reading events (BE-AG-19). The result is identical to aggregating every bucket; only the cost differs. [vec: none (prose only: an optimisation with no observable effect beyond BE-AG-19, whose bypass vectors pin it)]
- **BE-AG-72** Lifetime usage (progressive billing and alerts) is the sum of historical, invoiced and current usage amounts; it is specified in chapter 10 (BE-PB). Daily usage (revenue analytics) is out of scope. [vec: none (prose only: owned by chapter 10)]

## 11. Algorithm (fresh pseudocode)

```
aggregate(store, metric, window, subscription, events, matching, ignored, grouped_by, options, cached, boundary):
  sel = [e for e in events
         if e.code == metric.code and e.external_subscription_id == subscription.external_id
         and not e.deleted and e.timestamp <= upper(window, boundary)            # BE-AG-3, BE-AG-42
         and (lower_bound_free(metric) or e.timestamp >= floor_ms(window.from))]  # BE-AG-2, BE-AG-4
  sel = [e for e in sel if selected(e, matching, ignored)]                        # BE-AG-30
  if metric.type in (sum, max, latest, weighted_sum):
      sel = [e for e in sel if gate(text(e, metric.field_name))]                  # BE-AG-5
  if options.bypass and not metric.recurring: return null_result(grouped_by)      # BE-AG-19
  groups = partition(sel, key = [text(e, k) for k in grouped_by]) if grouped_by else {(): sel}
  results = {g: formula(metric.type, events_g, window, cached_for(g), options)    # section 3, 7, 8
             for g, events_g in groups}
  return round_each(results, metric.rounding) unless boundary                     # BE-AG-25

formula(sum):          aggregation = Σ v;   count = len
formula(unique_count): per value p: prev = "remove"; for e in time order:
                          adj = 0 if op(e) == prev else (+1 if op(e) == "add" else -1); prev = op(e)
                       aggregation = ceil(Σ adj, 5); count = aggregation
formula(weighted_sum): rows = [(from, I)] + [(t, v) ...] + [(ceil_seconds(to), 0)]
                       level = 0; acc = 0
                       for (t_i, d_i), (t_next, _) in pairs(rows): level += d_i; acc += level * (t_next - t_i)
                       aggregation = ceil(acc / (D * 86400), 20)
```

## 12. Edge cases (people get these wrong)

| Pitfall | Rule |
|---|---|
| A numeric string `"1e3"` or `"+5"` is not a number for sum/max/latest/weighted sum (relational store) | BE-AG-5 |
| Non-numeric values are dropped from `count` too, not just from the value | BE-AG-5 |
| `latest` clamps a negative value to 0, `max` does not | BE-AG-12, BE-AG-13 |
| Unique values are compared as text: `1` = `"1"` ≠ `1.0` | BE-AG-15 |
| Events without the unique property count as one more value | BE-AG-15 |
| An unknown `operation_type` can make a unique count negative | BE-AG-16 |
| The weighted-sum end is `to` rounded UP to a whole second | BE-AG-17 |
| Recurring sums and unique counts read all history, even before the subscription start | BE-AG-4 |
| An event at the exact upgrade instant is billed by both subscriptions | BE-AG-6 |
| Missing key and `""` are two groups that are both labelled null | BE-AG-36 |
| Newer identical filters bill 0; overlapping non-identical filters bill twice | BE-AG-33, BE-AG-38 |
| Rounding is per group and also rounds current-usage units, but never an in-advance event | BE-AG-25 |
| Proration ceils to 5 places after a rounded quotient: 1.1 can become 1.10001 | BE-AG-56 |
| The columnar store counts a non-numeric value as an event worth 0 | BE-AG-60 |
| In advance, "same unique value" is JSON equality (`1` = `1.0` ≠ `"1"`), the opposite of the period count | BE-AG-41 (RBD-101) |
| After a negative cached maximum, the new maximum is the billed excess, not the running total | BE-AG-40 (RBD-100) |
| The carried proration ratio keeps all 17 digits of its shortest text: 28 × 5/28 → 5.00001 | BE-AG-56 |
| In-advance proration and the carried per-event entry cut the same ratio to 16 digits: 28 × 5/28 → 5 | BE-AG-56 |
| Prorated per-event lists start with the carried total, only when it is not 0 | BE-AG-21 |
| An `add` at the same instant as a stored `add` of the value is not active-before: billed again in advance | BE-AG-41 |
| Grouped unique current usage in advance reports the group's raw unique count as `count` | BE-AG-44 |
| A weighted-sum cache must be stamped strictly before the window start | BE-AG-18 |
| Weighted shares multiply level × seconds first, then divide | BE-AG-17 |

## 13. Vectors

| File | Op(s) | Vectors | Rules |
|---|---|---|---|
| `aggregation.core.jsonl` | `aggregate` | 105 (incl. 2 corrected twins) | BE-AG-1..21, 25..27, 36, 37, 73 |
| `aggregation.filters.jsonl` | `matching_and_ignored`, `select_events`, `event_filter`, `group_keys` | 38 (3 twins) | BE-AG-30..38 (39 prose only) |
| `aggregation.in_advance.jsonl` | `in_advance_units`, `current_usage_in_advance`, `aggregate` | 35 (3 twins) | BE-AG-40..44 |
| `aggregation.prorated.jsonl` | `aggregate`, `in_advance_units` | 49 (8 twins) | BE-AG-50..56 |
| `aggregation.store_ch.jsonl` | all of the above with `store: "ch"` | 61 (20 twins) | BE-AG-60..69, BE-AG-74 |

Counts include the maintainers' holdout. Corrected twins (`…x`) express proposed rebuild decisions (RBD-25..31, 35, 36,
96, 101) and are graded only when the owner rules them; `aggregation.filters.select.007x` and `.008x` expect the same
selection as their compat pair (the selection primitive is profile-independent; RBD-36 acts through `mi.015x`). The RBD-100 vectors (`aggregation.in_advance.sum.008`, `.009`) are compat vectors without a
twin until the owner rules; their notes give the corrected value. The columnar vectors take a few hundred
milliseconds each on the oracle (tag `slow`).

## Provenance (maintainers)

| Rules | Reference behaviour at the pin |
|---|---|
| BE-AG-1..4 | `$API/app/services/events/stores/postgres_store.rb:6-23`, `:449-466`; `$API/app/services/events/stores/base_store.rb:177-187`; `$API/app/services/billable_metrics/aggregations/sum_service.rb:11-17`; `$API/app/services/billable_metrics/aggregations/unique_count_service.rb:6-11` |
| BE-AG-5 | `$API/app/services/events/stores/postgres_store.rb:16-19`, `:515-524` (gate expression at `:521`) |
| BE-AG-6 | `$API/app/services/subscriptions/plan_upgrade_service.rb:18-45`; `$API/app/services/subscriptions/dates_service.rb:95-126` (probe below) |
| BE-AG-10..16 | `$API/app/services/billable_metrics/aggregations/{count,sum,max,latest,unique_count}_service.rb`; `$API/app/services/events/stores/postgres/unique_count_query.rb:11-35`, `:276-287` |
| BE-AG-17..18 | `$API/app/services/events/stores/postgres/weighted_sum_query.rb:11-119`; `$API/app/services/billable_metrics/aggregations/weighted_sum_service.rb:13-167`; `$API/app/services/fees/charge_service.rb:450-476` |
| BE-AG-27 | `$API/app/services/billable_metrics/aggregations/sum_service.rb:82-97`; `$API/app/services/billable_metrics/aggregations/base_service.rb:73-90`; `$API/app/services/events/stores/postgres_store.rb:271-282` |
| BE-AG-19..21 | `$API/app/services/billable_metrics/aggregations/base_service.rb:38-49`, `:113-127`, `:217-221`; `$API/app/services/fees/charge_service.rb:130-136`, `:431-447` |
| BE-AG-25..26 | `$API/app/services/billable_metrics/aggregations/base_service.rb:73-90`, `:246-265`; `$API/app/services/billable_metrics/aggregations/apply_rounding_service.rb:15-29` |
| BE-AG-30..39 | `$API/app/services/fees/charge_service/sources/charge.rb:59-67`; `$API/app/services/charges/pay_in_advance_aggregation_service.rb:48-55`; `$API/app/services/events/stores/postgres_store.rb:468-507`; `$API/app/services/events/billing_period_filters/matching_and_ignored_service.rb:13-65`; `$API/app/services/events/billing_period_filters/event_matching_service.rb:15-43`; `$API/app/models/charge_filter.rb:22`, `:72-90`; `$API/app/services/fees/charge_service.rb:74-97`, `:478-518`; `$API/app/services/charge_filters/create_or_update_batch_service.rb:18-31` |
| BE-AG-40..44 | `$API/app/services/billable_metrics/aggregations/sum_service.rb:139-174`; `$API/app/services/billable_metrics/aggregations/unique_count_service.rb:72-120`; `$API/app/services/billable_metrics/aggregations/base_service.rb:194-243`; `$API/app/services/charges/pay_in_advance_aggregation_service.rb:17-68`; `$API/app/models/cached_aggregation.rb:14-15` |
| BE-AG-50..56 | `$API/app/services/billable_metrics/prorated_aggregations/{base,sum,unique_count}_service.rb`; `$API/app/services/events/stores/postgres_store.rb:308-322`, `:537-544`; `$API/app/services/events/stores/postgres/unique_count_query.rb:37-75`, `:302-419` |
| BE-AG-60..69 | `$API/app/services/events/stores/clickhouse_store.rb:13-44`, `:449-467`, `:538-549`, `:772-830` (property map filters and group values `:820-830`); `$API/app/services/events/stores/clickhouse/unique_count_query.rb:38-110`, `:305-325`, `:350-369`, `:393-503`; `$API/app/services/events/stores/clickhouse/weighted_sum_query.rb:11-49`, `:120-135`; `$API/app/services/events/stores/utils/clickhouse_sql_helpers.rb:47-64`; `$API/db/clickhouse_migrate/20240705080709_create_events_enriched.rb:5-35`, `20240705085501_create_events_enriched_mv.rb:5-17` |
| BE-AG-74 | `$API/app/services/events/stores/utils/clickhouse_sql_helpers.rb:12-17` (day ratio `(date_diff + 1) / duration`); `$API/app/services/events/stores/clickhouse_store.rb:220-227`, `:573-605` (decimal value times the ratio, the carried ratio a binary64 literal); `$API/app/services/billable_metrics/prorated_aggregations/sum_service.rb:24`, `:164-180` (carried part plus window part, then `ceil(5)`); probe below |
| BE-AG-70..72 | `$API/app/services/invoices/customer_usage_service.rb:50-176`; `$API/app/services/events/billing_period_filters/charges_resolver.rb:48-110`; `$API/app/services/lifetime_usages/calculate_service.rb:13-69` |

Executions on the pinned toolchain (ruby-4.0.6, 2026-10-02, a dedicated oracle database, ClickHouse 26.2 under the
shared lock):

- `oracle.sh run spec/services/billable_metrics/aggregations spec/services/billable_metrics/prorated_aggregations
  spec/services/events/stores/postgres_store_spec.rb spec/services/events/stores/clickhouse_store_spec.rb
  spec/services/charge_filters/matching_and_ignored_service_spec.rb spec/services/charge_filters/event_matching_service_spec.rb
  spec/services/events/billing_period_filters spec/services/billable_metrics/aggregation_factory_spec.rb
  spec/services/fees/charge_service_spec.rb` → `{"example_count":871,"failure_count":2,…}`; the two failures
  (`sum_service_spec.rb:549`, `:617`: equal-timestamp running totals, BE-AG-73) pass when rerun alone (3/3 with `:310`).
- Oracle module `scripts/maintainer/oracle-adapter/ops/aggregation.rb`: builds a throw-away tenant in a rolled-back
  transaction and calls the real aggregation factory, pay-in-advance aggregation service, filter services and
  stores; columnar rows are inserted with the enriched materialized view's own column transform. Every vector built from
  a reference spec example carries that example's asserted values, and the oracle reproduced all of them.
- RBD-35 probe (upgrade through the real upgrade service, windows from the real period service, real aggregator):
  terminated window `[03-01, upgrade]`, new window `[upgrade, 03-31 23:59:59.999999]`, the event at the upgrade
  instant in both → 2 + 2 for 3 events.
- RBD-36 probe (filters created through the filter-management service, current usage through the customer-usage
  service): filters `{us, eu}` and `{us, asia}` accepted; units f1 = 2, f2 = 2, default = 1 for 4 events.
- Independent verification (2026-10-02): 19 vectors re-derived through direct event-store and aggregation-service calls on a separately built tenant (filters created through the filter-management service, columnar rows inserted directly), all equal to the vectors; probes through the oracle added BE-AG-27 (dynamic amounts) and corrected BE-AG-40 (negative cached maximum) and BE-AG-41 (JSON value identity of active-before).
- Fix round of 2026-10-02 (oracle re-run of every aggregation vector, 240/240 compat-graded PASS): the RBD-100 and
  RBD-101 quirks found by the independent verification became rebuild decisions (compat kept, corrections proposed);
  the BE-AG-56 conversion was pinned by four discriminating carried ratios (3/30 → 3 excludes the exact binary value;
  5/28 → 5.00001 excludes truncation to 16 digits; 5/30 → 5 excludes rounding to 16 digits), all through
  `$API/app/services/billable_metrics/prorated_aggregations/sum_service.rb:126` and
  `$API/app/services/billable_metrics/prorated_aggregations/base_service.rb:103-105`; the vector inputs were trimmed to
  the schema defaults (store, window, durations, ingestion order, event ids) without changing any expected value.
- Exploration that shaped BE-AG-66: ten add/remove sequences with same-day removals gave identical results in both
  stores; the grouped relational computation adds one day for a value added and removed before the window
  (0.74194 vs 0.70968), the columnar one does not.
- Probes of 2026-10-05 (the fix round's oracle database; the added vectors 10/10 PASS through `kitrun`): prorated per-event
  lists with carried sums of 0 and without carried events, and the carried entry through the binary ratio cut to 16 digits
  (`$API/app/services/billable_metrics/prorated_aggregations/sum_service.rb:126`, `:210`; bigdecimal 4.1.2 converts a
  binary64 factor through its shortest text cut to 16 digits, while the SQL path interpolates every digit); in-advance
  units and current usage through the same 16-digit cut (`$API/app/services/billable_metrics/prorated_aggregations/base_service.rb:18-24`,
  `:77`); the window ratio as a PostgreSQL numeric quotient at 20 places (`$API/app/services/events/stores/postgres_store.rb:539-544`);
  the grouped prorated unique count's extra day per closed pair (`$API/app/services/events/stores/postgres/unique_count_query.rb:331-357`,
  the `+ 1` outside the period-start branch); equal-time active-before (`$API/app/services/events/stores/postgres_store.rb:124-135`,
  `$API/app/services/events/stores/clickhouse_store.rb:287-300`: strict timestamp comparison in both stores); the grouped
  unique count of in-advance current usage (`$API/app/services/billable_metrics/aggregations/unique_count_service.rb:32`, `:60`);
  the weighted-sum cache bound (`$API/app/services/billable_metrics/aggregations/weighted_sum_service.rb:140`) and share order
  (`$API/app/services/events/stores/postgres/weighted_sum_query.rb:103-118`, level 10¹⁵ → …642.771804).
- Verification probes of 2026-10-05 (independent oracle database): weighted shares keep at least the product's
  decimals (level 10¹⁸ for one day of 31 → 32258064516129032.258065; level 1500000000000000.5 → 7 decimals), the
  quotient scale floor of the relational store's numeric division; equal-time active-before and the grouped `count`
  of in-advance current usage repeated on the columnar store (same results as the relational store); in-advance unique
  identity on the columnar store: a prior `1` makes a later `"1"` active-before (units 0; relational store: units 1).
- Columnar prorated sums (BE-AG-74), probed on 2026-10-05 through `oracle.sh adapter` op `aggregation.aggregate` with
  `store: ch` and the same inputs on the relational store: the inputs of `aggregation.prorated.island.002`, `.004`,
  `.006`, `aggregation.prorated.sum.013` and `.014` give 15, 5, `4.999999999999998` (per-event entry), per-event
  `3.5999999999999996` and 5 (relational: 15.00001, 5.00001, the same entry, 3.6 and 5); 3 carried at P = 1/10 gives
  0.30001 (relational 0.3); one window event 3.1 at 11 of 31 days gives per-event 1.0999999999999999 and aggregation
  1.1 (relational 1.100000000000000000004 and 1.10001); 31 carried at P = 15/31 plus that window event gives 16.1
  (relational 16.10001), so the total is ceiled from decimal texts, not as a binary64 (`16.1.ceil(5)` is 16.10001 in
  the pinned Ruby).
- Columnar conversion and summation order (BE-AG-74), second pass of 2026-10-05 (database `lago_api_test_fr3a`, ClickHouse
  26.2 x86-64 server, read-only queries under `ch.lock`): `toFloat64(toDecimal128(v, 26))` for 4,009 random decimals (0 to
  26 places, both signs, up to 12 integer digits) matched the 64-bit-significand model of BE-AG-74 in every case, while the
  single-rounding model `b(x) ⊘ b(10^26)` missed 4 (8.3, 555873811.487 and their variants); `Decimal(38,26) × Float64`
  uses the same conversion (8.3 × 1.0 = 8.3). Order: `aggregation.aggregate` with `store: ch`, window events 1 (June 6),
  2 (June 27) and 0.6 (June 17) of June 2023, inserted in each of the six orders, twice: 1.38 or 1.38001 with no stable
  relation to the insertion order (the same order gave both values on two runs); the relational store gave 1.38 every
  time. New vectors `aggregation.store_ch.prorated.005` (3 carried at P = 3/30 → 0.30001; relational 0.3) and `.006`
  (3.1 at 11 of 31 days → per-event 1.0999999999999999, aggregation 1.1) executed through `oracle.sh adapter` (PASS,
  twice); their corrected twins are RECOMPUTED with exact decimals (RBD-96).
- Update triggers: a pin bump; any change to the aggregation services, the event stores and their query classes,
  the filter services, the pay-in-advance aggregation service or the enriched table definition.
