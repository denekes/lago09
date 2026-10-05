# REPORT — crc-5 (periods)

Final kitrun lines (repository root):

```
profile compat:
periods                  189   189     0     0       0     0       0 100.0% 100.0%  98.0%  PASS
SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=189 passed=189 skipped_ops=0 exit=0
profile corrected (informational):
periods                  189   173     0     0       0     0      16 100.0% 100.0%  98.0%  PASS
SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=189 passed=173 skipped_ops=0 exit=0
```

Per-area pass rate: periods 189/189 compat (100 %, core 100 %; threshold 98 %); corrected 173 graded passed + 16 UNRULED (twin vectors; 0 failures, the compat-only vectors are not graded in that profile).

Time spent: roughly one hour (reading chapter 06/01 and the op schemas, one implementation pass, two small fix rounds).

Next: write extra self-made vectors for the less-covered rules (zone-change continuity, semiannual anniversary first-month gating,
fractional-trial credit days, DST-gap midnights) since hidden vectors resemble the shipped ones; review KIT-GAPS items 1, 2, 5, 8 first; extend the corrected profile once the owner rules the proposed RBDs.

## v1.2

Final kitrun lines (repository root, kit 1.2.0):

```
profile compat:
periods                  196   196     0     0       0     0       0 100.0% 100.0%  98.0%  PASS
SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=196 passed=196 skipped_ops=0 exit=0
profile corrected (informational):
periods                  196   179     0     0       0     0      17 100.0% 100.0%  98.0%  PASS
SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=196 passed=179 skipped_ops=0 exit=0
```

Per-area: periods 196/196 compat (core 100 %, threshold 98 %); corrected 179 passed + 17 UNRULED, 0 failures.

Changes:
- BE-SP-23: the zone-change 26 h window is strict (`|charges_from - C| < 26 h`; exactly 26 h keeps the computed start) — `periods.boundaries.tzchange.007`.
- BE-SP-49/50: the clamp of `started_at` to an invoiced termination applies only to the backdated (past) creation path, not a creation dated today — `periods.create_status.010`.

Wall-clock time: start 2026-10-05 14:42:21 UTC, end 2026-10-05 14:43:30 UTC (`date -u`).
