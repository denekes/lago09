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

## v1.1

Kit v1.1.0, area pricing (final kitrun runs):

profile compat:
    pricing   263  PASS 263  FAIL 0  RATE 100.0%  CORE 100.0%  THRESH 98.0%  PASS
    SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=263 passed=263 skipped_ops=0 exit=0

profile corrected (information):
    pricing   262  PASS 238  FAIL 0  UNRULED 24  RATE 100.0%  CORE 100.0%  THRESH 98.0%  PASS
    SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=262 passed=238 skipped_ops=0 exit=0

Before the fixes compat was 255/263 (97.0 %). What changed (rule ids):
- BE-PR-87: pricing-unit record (, ) stored at 15 places and the stored rate used for the
  fiat conversion; fixed-charge units (event units, new units) rounded to 10 places.
- BE-PR-41/39: projection ratio is binary64 days(from,to) quotient, projected units divide by its shortest text.
- BE-PR-69: prorated fixed-charge units with no event return  /  lists.
- BE-PR-58: graduated-percentage  is JSON integer 0 under exclude_event at zero units.
- BE-PR-78: validator keeps one code per failed check (repeats allowed); record messages are grouped by field in
  order of first failure and de-duplicated; package check order amount, free_units, package_size; presentation
  group-key  and  are independent checks.
Time spent: about 1 minutes.
