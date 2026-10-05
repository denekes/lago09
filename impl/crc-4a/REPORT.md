# REPORT (crc-4a, aggregation)

Final kitrun runs from the repository root (`--impl-cmd "python3.12 impl/crc-4a/adapter.py" --areas aggregation`):

- profile compat: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=194 passed=194 skipped_ops=0 exit=0` (aggregation 100.0 %, core 100.0 %, threshold 95 %)
- profile corrected: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=190 passed=167 skipped_ops=0 exit=0` (100.0 % of ruled vectors; 23 unruled; two unruled twins still fail: select.008x, store_ch.gate.007x)

Time spent: about one working session (read the chapter, wrote the adapter in one pass, two fix rounds).

Next: probe edge cases beyond the shipped vectors (timezone/DST proration, grouped weighted sums with cached state,
ties in the columnar store, per-event prorated lists without carried events), and implement RBD-36 for the corrected profile.
See KIT-GAPS.md for the assumptions made.

## v1.2

Started 2026-10-05 14:42:21 UTC, finished (`date -u`) see end line below.

Final kitrun runs (kit 1.2.0, `--areas aggregation`):

- profile compat: `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=206 passed=206 skipped_ops=0 exit=0` (aggregation 100.0 %, core 100.0 %, threshold 95 %)
- profile corrected (information): `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=202 passed=171 skipped_ops=0 exit=0` (100.0 % of ruled vectors; 31 unruled, whose twins mostly fail: mi.015x, in_advance.unique.011x, island.006x, sum.011x and others; exact-decimal profile, RBD-96, not worked in this round)

What changed (adapter.py):

- BE-AG-56 island 3 / BE-AG-21 / BE-AG-53 / BE-AG-54: new `p16`, the binary64 ratio cut (not rounded) to 16 significant digits, used for the carried per-event prorated entry, the in-advance current usage with cache, and the in-advance units (`aggregation.prorated.in_advance.006`, `aggregation.prorated.island.006`, `aggregation.prorated.sum.014`).
- BE-AG-21: leading per-event entries are present only when the carried sum is not 0 (`aggregation.prorated.sum.013`).
- BE-AG-44: grouped `unique_count_agg` current usage in advance reports the group's raw unique count as `count` (`aggregation.in_advance.current.007`).
- BE-AG-74: columnar store (compat) prorated sums evaluated in binary64: the 26-place, 64-bit significand conversion c(v), `c(v) ⊗ ratio` per contribution, carried and window parts summed separately, read through their shortest text, added as decimals, then ceil5 (`aggregation.store_ch.prorated.005`, `.006`).

Time spent (wall clock, `date -u`): start 14:42:21, end see commit time; the work took about 5 minutes.
Mon Oct  5 14:43:18 UTC 2026
