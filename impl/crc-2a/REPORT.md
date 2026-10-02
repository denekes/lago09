# REPORT (crc-2a, pricing)

## kitrun results (python3 .claude/skills/reimplementation-kit/scripts/kitrun.py --impl-cmd "impl/crc-2a/run.sh" --areas pricing)

profile compat:
    pricing   249  PASS 249  FAIL 0  RATE 100.0%  CORE 100.0%  THRESH 98.0%  PASS
    SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=249 passed=249 skipped_ops=0 exit=0

profile corrected (information):
    pricing   248  PASS 229  FAIL 0  UNRULED 19 (17 pass, 2 fail: pricing_unit.002x/003x)  RATE 100.0%  CORE 100.0%
    SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=248 passed=229 skipped_ops=0 exit=0

Thresholds met (>= 98 %, core 100 %). Time spent: about 1.5 hours (reading ~30 min, implementation ~45 min, fixes ~15 min).

## Next steps
- Hidden vectors: harden validators for exotic inputs (JSON types in ranges, nested presentation keys), error
  de-duplication, projection with groups, fixed charges with empty prorated events.
- Resolve the KIT-GAPS items with the maintainers (pricing_unit corrected rule, detail integer-vs-string spelling).
- Add unit tests for the float-island helpers (`float_to_dec`) and the day counting across DST.
