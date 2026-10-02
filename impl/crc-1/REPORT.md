# REPORT crc-1 (domain)

Final kitrun runs (`--impl-cmd "python3.12 impl/crc-1/adapter.py" --areas domain`):

- profile compat: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=119 passed=119 skipped_ops=0 exit=0` (domain 119/119, 100.0 %, CORE 100.0 %)
- profile corrected: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=119 passed=118 skipped_ops=0 exit=0` (118/118 graded, 1 UNRULED: proposed tax-code reuse twin, RBD-80)

Time spent: about 30 minutes. One bug found during grading: the day-count offset sign (KIT-GAPS 1).

Next: property tests for DST edge cases (days_between at gaps/overlaps), validation of malformed inputs (clear `bad_input`), and implementing the corrected twin for tax code reuse once the owner rules on RBD-80.
