# KIT-GAPS (crc-2b, pricing)

Entries: question; where I looked; assumption made.

## 1. pricing_unit op: corrected twins contradict a `both` vector
- Question: under `--profile corrected`, `pricing.pricing_unit.002x/003x` (single rounding from A x rate) and the `both`
  vector `pricing.pricing_unit.006` (fiat derived from the ROUNDED pricing-unit cents: 246, not 246.9) cannot both hold
  for the same op/input shape.
- Where I looked: billing-engine-spec ch.05 BE-PR-63, RBD-46; the three vectors.
- Assumption: the graded `both` vector wins; `pricing.pricing_unit` keeps double rounding in both profiles. The corrected
  single rounding is applied only inside `pricing.pay_in_advance` and `pricing.true_up` (where twins pass).

## 2. Rule order of validation errors
- Question: order of codes in `property_messages` when several fields fail (BE-PR-78 says "check order" without listing it).
- Assumption: model checks in the order the chapter lists them (metric check, rate, fixed_amount, free units per events,
  free units per total aggregation, per-transaction bounds; ranges: amounts then bounds), grouping keys last.

## 3. Details number types
- Question: some detail values are compared as JSON integers (`0`), others as decimal strings (`"0.0"`).
- Observed from failing vectors (not stated in the chapter): percentage `per_unit_total_amount` is the integer 0 when free
  units exceed the units; graduated-percentage flat/total are integer 0 under exclude_event with zero units, while plain
  graduated keeps its computed flats in the details (only `amount` is 0).

## 4. Pay-in-advance / fixed in-advance stored precision
- Precise fee fields are stored with 15 decimals (BE-PR-53) - the chapter does not say that this also applies to the
  in-advance and fixed-charge in-advance fees; vectors require it. True-up `precise_unit_amount` is
  q15(unrounded binary64 prorated minimum - used precise) / subunit (vector true_up.006), not the 16-digit-truncated value.

## 5. Corrected profile (informational)
- RBD-41 twin implemented as "first FE events free" in per-transaction mode; RBD-42 twin implemented as the graduated
  adjacency rule with exact decimals. Both only guided by the single twin vector each.

## v1.1

1. Warning `NUM-OUT amount_details.graduated_percentage_ranges[0].to_value: JSON number 0.1` — the details echo the
   input bound; vectors with a JSON-float bound compare equal either way. Looked in: BE-PR-58, vector-format.md
   (number forms). Assumption: echo the bound exactly as given (JSON number stays a number); the comparator accepts it.
2. BE-PR-41 when `days(from, to) <= 0` (degenerate period): not stated. Assumption: ratio 0, projection 0.
3. BE-PR-87 for the `pricing_unit` op's `pricing_unit_usage` block: rate/precise fields rounded to 15 places by
   analogy with the fee_money op (the spec names the stored record, not this op's output). Assumption: round.
