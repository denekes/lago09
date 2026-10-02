# REPORT — crc-8 (webhooks, api, clock)

## kitrun results

Profile compat:
```
api       34  34  100.0%  PASS
clock     10  10  100.0%  PASS
webhooks  37  37  100.0%  PASS
SUMMARY kitrun: areas=3 pass=3 fail=0 vectors=81 passed=81 skipped_ops=0 exit=0
```
Profile corrected (information):
```
api       34  32 (+2 unruled)  100.0%  PASS
clock     10   9 (+1 unruled)  100.0%  PASS
webhooks  37  36 (+1 unruled)  100.0%  PASS
SUMMARY kitrun: areas=3 pass=3 fail=0 vectors=81 passed=77 skipped_ops=0 exit=0
```
Thresholds (compat: 100 % per area) met on the shipped vectors.

## Time spent
About one working session (~1 h): reading chapters 11-13 and op schemas, one implementation pass, one cleanup.

## Next
- Pin the full 75-name event list (KIT-GAPS 1) when the kit provides it.
- Add unit tests for float encoding and pagination leniency (underscores, signs) beyond shipped vectors.
- Verify RS256/public-key output against an independent library in CI.
