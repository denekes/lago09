# REPORT crc-1 (domain)

Final kitrun runs (`--impl-cmd "python3.12 impl/crc-1/adapter.py" --areas domain`):

- profile compat: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=119 passed=119 skipped_ops=0 exit=0` (domain 119/119, 100.0 %, CORE 100.0 %)
- profile corrected: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=119 passed=118 skipped_ops=0 exit=0` (118/118 graded, 1 UNRULED: proposed tax-code reuse twin, RBD-80)

Time spent: about 30 minutes. One bug found during grading: the day-count offset sign (KIT-GAPS 1).

Next: property tests for DST edge cases (days_between at gaps/overlaps), validation of malformed inputs (clear `bad_input`), and implementing the corrected twin for tax code reuse once the owner rules on RBD-80.

## v1.1

Final kitrun runs (`--areas domain`, kit 1.1.0):

- profile compat: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=123 passed=123 skipped_ops=0 exit=0` (domain 123/123, 100.0 %, CORE 100.0 %)
- profile corrected: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=123 passed=122 skipped_ops=0 exit=0` (122/122 graded, 1 UNRULED, 100.0 %, CORE 100.0 %)

What changed: `invoice_number` now treats a missing `invoice_sequential_id` / `billing_entity_sequential_id` at finalization as the first of its scope (1), per BE-DM-37/38/42 (vectors `invoice_number.013..015` failed with ERROR before). The offset-sign and other v1.1 domain changes were already satisfied.

Time spent: about 10 minutes.
