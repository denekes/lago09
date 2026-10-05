# REPORT — crc-2b (pricing)

Final kitrun results (from the repository root, shipped vectors):

    --profile compat
    pricing  249  249  0 0 0 0 0  100.0%  CORE 100.0%  THRESH 98.0%  PASS
    SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=249 passed=249 skipped_ops=0 exit=0

    --profile corrected (information)
    pricing  248  229  0 0 0 0 19 (UNRULED)  100.0%  CORE 100.0%  PASS
    SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=248 passed=229 skipped_ops=0 exit=0
    (UNRULED corrected twins still failing: pricing.pricing_unit.002x, 003x — contradicted by the `both` vector
    pricing.pricing_unit.006, see KIT-GAPS 1)

Per-area pass rate: pricing 100 % (compat), core 100 %.

Time spent: about one working session (reading ~1/3, implementing ~1/3, fixing 7 first-run failures ~1/3).

Notes: the 7 first-run failures were all representation details not spelled out in the chapter (integer 0 vs "0.0"
in details, 15-decimal storage of precise fields for in-advance fees, true-up precise unit amount); see KIT-GAPS 3-4.

Next steps: fuzz the validators for check-order/edge inputs the shipped vectors do not cover (hidden vectors), review
the grouping + projection combination (`groups` with `calculate_projected_usage`), settle the corrected-profile
semantics (RBD-41/42/46) once the owner rules, and add unit tests of the permissive decimal reader (BE-PR-73).

## v1.1

Kit v1.1 (graded from the repository root, shipped vectors):

    --profile compat
    pricing  263  263  0 0 0 0 0  100.0%  CORE 100.0%  THRESH 98.0%  PASS
    SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=263 passed=263 skipped_ops=0 exit=0

    --profile corrected (information)
    pricing  262  238  0 0 0 0 24 (UNRULED)  100.0%  CORE 100.0%  PASS
    SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=262 passed=238 skipped_ops=0 exit=0

Per-area rate: pricing 100 % (compat), core 100 %. Start of the session: 255/263 (97.0 %, 8 failures).

What changed (rules): BE-PR-87 — pricing-unit conversion rate stored and applied at 15 places, pricing-unit usage
precise fields at 15 places, fixed-charge units (events, billed, new) at 10 places; BE-PR-41/39 — period ratio is the
binary64 quotient days(from,now) ⊘ days(from,to), kept as its full shortest text; BE-PR-19/85 — graduated-percentage
float bound computed `(b(to) ⊖ x) ⊕ 1` in binary64; BE-PR-78 — validator keeps repeated codes per field, the record
list is grouped by field in order of first failure then de-duplicated, package check order amount/free_units/
package_size, presentation keys report too_many_keys and value_is_duplicated together.

Time spent: about 30 minutes.
