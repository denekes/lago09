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

## v1.1 (kit 1.1.0)

Time spent: about 0 minutes (the earlier gaps were mostly closed by three rules).

### kitrun, profile compat

    events         62    62     0     0       0     0       0 100.0% 100.0%  98.0%  PASS
    expression     85    85     0     0       0     0       0 100.0% 100.0%  98.0%  PASS
    SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=147 passed=147 skipped_ops=0 exit=0

### kitrun, profile corrected (informational)

    events         63    56     0     0       0     0       7 100.0% 100.0%  98.0%  PASS
    expression     87    84     0     0       0     0       3 100.0% 100.0%  98.0%  PASS
    SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=150 passed=140 skipped_ops=0 exit=0

### What changed (v1.0 failures: 8 of 147)

- BE-EV-43/44: compat batch duplicates per transaction_id with "new key" semantics (stored and earlier-batch keys).
- BE-EX-15: subtraction corner (zero subtrahend returns minuend; zero minuend returns negated subtrahend).
- BE-EX-21 (d)/BE-EX-41: ep-build zero prints by the general rules (0E-7, 00, 0e+16).
- BE-EX-40: ep surface requires string code, non-null timestamp and an object properties (absent fails).
