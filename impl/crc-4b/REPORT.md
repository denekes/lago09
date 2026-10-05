# REPORT — crc-4b (aggregation)

Final kitrun summary lines (run from the repo root, `--areas aggregation`):

profile compat:

    aggregation  194  194 pass  0 fail  100.0%  core 100.0%  (threshold 95 %)  PASS
    SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=194 passed=194 skipped_ops=0 exit=0

profile corrected (information):

    aggregation  190  167 pass  0 fail  23 unruled  100.0%  core 100.0%  PASS
    SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=190 passed=167 skipped_ops=0 exit=0

Of the 23 unruled corrected twins, 21 pass; `filters.select.008x` and `store_ch.gate.007x` fail (see KIT-GAPS 5).

Time spent: about one hour, mostly reading chapter 04 and the op schemas; the first full run already passed.

Next: write extra probes for paths the shipped vectors barely touch (grouped in-advance with `grouped_by_values`,
dynamic charges with a boundary, ch prorated unique ties), settle KIT-GAPS 3/6 with the maintainers, and implement the
corrected overlapping-filter selection if it gets ruled.

## v1.2

Kit v1.2.0. Start 2026-10-05 14:42:21 UTC, end 2026-10-05 14:43:21 UTC (`date -u`), about 1 minute wall clock.

Final kitrun (areas aggregation):

    compat:    aggregation  206  206 pass  0 fail  100.0%  core 100.0%  (threshold 95 %)  PASS
    SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=206 passed=206 skipped_ops=0 exit=0
    corrected: aggregation  202  171 pass  0 fail  31 unruled  100.0%  core 100.0%  PASS
    SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=202 passed=171 skipped_ops=0 exit=0

Before: 199/206 on compat (the seven vectors named in the task).

What changed:
- BE-AG-56 (3), BE-AG-21, BE-AG-53, BE-AG-54: new `p16` (shortest text of the binary64 ratio, cut to 16 digits) for the carried per-event entry, in-advance current usage and in-advance units; the period aggregation keeps p17. In corrected, exact ratios. (`island.006`, `sum.014`, `in_advance.005`)
- BE-AG-21: the leading carried entries of the prorated `per_event` / `per_event_prorated` appear only when the carried sum is not 0 (`sum.013`).
- BE-AG-44: grouped `unique_count_agg` current usage in advance reports the group's raw period count as `count` (`current.007`).
- BE-AG-74: columnar compat prorated sums use the store's decimal-to-binary64 conversion (`ch_conv`), binary64 day ratios and carried ratio, per-part binary64 sums read back as shortest text, then added as decimals and ceil5 (`store_ch.prorated.005`, `.006`).

No new KIT-GAPS entries.
