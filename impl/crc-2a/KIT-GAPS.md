# KIT-GAPS (crc-2a)

1. **pricing_unit.006 (`both`) vs twins 002x/003x (corrected).** Q: what does the corrected profile do for the
   `pricing.pricing_unit` op? Looked at: BE-PR-63, vectors pricing_unit.002x/003x (one rounding from A × rate) and
   pricing_unit.006 (`both`, expects fiat 246 from the double rounding 123 × 2, not 246.9). Assumption: the op keeps
   the compat double rounding in both profiles (006 is graded; the twins are UNRULED). In-advance twins 038x/039x
   still use the exact one-rounding rule.
2. **volume.008 (`both`) in corrected.** BE-PR-25/85 call the binary64 text a float island, yet vector 008 is `both`
   and expects it in the corrected profile. Assumption: the volume `per_unit_amount` detail keeps the binary64 path
   in both profiles.
3. **Detail value types.** Some vectors expect JSON integer `0` (gp exclude_event `total_with_flat_amount`,
   percentage `per_unit_total_amount` when free units exceed units) and others decimal strings `"0.0"`; the kit
   states only that stored details use strings. Assumption: integer 0 exactly in those two branches.
4. **Precise amounts stored at 15 places.** Numeric compare is exact, so `precise_amount_cents` and
   `precise_unit_amount` are rounded half up to 15 decimal places (BE-PR-53) in every fee-shaped output.
5. **Projection ratio denominator.** BE-PR-41 says `days(from,to)`; the op also has `charges_duration_days`.
   Assumption: use `charges_duration_days`.
6. **Duplicate error codes** in validators: assumed deduplicated per field; `property_messages` lists each code
   once in check order. Not pinned by a vector.
7. **validate_charge with `properties`**: property errors are merged under `properties` (BE-PR-78); not pinned.
8. **Prorated fixed charge, no events**: `per_event_full/prorated` are returned empty; not pinned.
9. **Corrected percentage per-transaction** (RBD-41): implemented as events `< FC` fully free, remaining free units
   consumed in order, bounds per paid event; only 016x pins it.
