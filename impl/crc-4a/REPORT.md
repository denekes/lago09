# REPORT (crc-4a, aggregation)

Final kitrun runs from the repository root (`--impl-cmd "python3.12 impl/crc-4a/adapter.py" --areas aggregation`):

- profile compat: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=194 passed=194 skipped_ops=0 exit=0` (aggregation 100.0 %, core 100.0 %, threshold 95 %)
- profile corrected: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=190 passed=167 skipped_ops=0 exit=0` (100.0 % of ruled vectors; 23 unruled; two unruled twins still fail: select.008x, store_ch.gate.007x)

Time spent: about one working session (read the chapter, wrote the adapter in one pass, two fix rounds).

Next: probe edge cases beyond the shipped vectors (timezone/DST proration, grouped weighted sums with cached state,
ties in the columnar store, per-event prorated lists without carried events), and implement RBD-36 for the corrected profile.
See KIT-GAPS.md for the assumptions made.
