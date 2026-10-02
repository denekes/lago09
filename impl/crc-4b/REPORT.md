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
