# crc-3 report

Implementation: Python 3.12, standard library only. Time spent: about 1 hour (reading the kit ~25 min, code ~25 min, checks ~10 min).

## kitrun, profile compat

    AREA        TOTAL  PASS  FAIL ERROR TIMEOUT  SKIP UNRULED   RATE   CORE THRESH  VERDICT
    events         60    60     0     0       0     0       0 100.0% 100.0%  98.0%  PASS
    expression     71    71     0     0       0     0       0 100.0% 100.0%  98.0%  PASS
    SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=131 passed=131 skipped_ops=0 exit=0

## kitrun, profile corrected (informational)

    events         61    54     0     0       0     0       7 100.0% 100.0%  98.0%  PASS
    expression     73    70     0     0       0     0       3 100.0% 100.0%  98.0%  PASS
    SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=134 passed=124 skipped_ops=0 exit=0

(The 10 UNRULED vectors are the `x` corrected-profile vectors; all of them also pass.)

## Next

- Hidden-vector risks are the assumptions in KIT-GAPS.md (batch duplicate flagging, text of integer
  `precise_total_amount_cents`, ep-surface corner cases).
- Add unit tests for the number text forms and the division rule; fuzz the timestamp grammar.
