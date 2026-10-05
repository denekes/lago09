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

## v1.1

kitrun (areas webhooks,api,clock), final SUMMARY lines:

- compat: `SUMMARY kitrun: areas=3 pass=3 fail=0 vectors=107 passed=107 skipped_ops=0 exit=0`
- corrected: `SUMMARY kitrun: areas=3 pass=3 fail=0 vectors=107 passed=103 skipped_ops=0 exit=0` (4 vectors are compat-only, unruled for this profile)

Per-area rate (both profiles): api 100 %, clock 100 %, webhooks 100 %.

Changes:
- webhooks.type_info (BE-WH-11): catalogue rebuilt from section 3 of chapter 12 — all 75 names with their object types (provider error/checkout-url/payment-error types, `payment.succeeded`, `payment_request.payment_status_updated`, `quote.approved/voided`, `order.executed`, `order_form.voided`).
- clock.jobs_due (BE-CK-2, BE-CK-12, RBD-94): one-second ticks from the start instant; interval jobs run at tick 0 and every period after; pinned jobs run at the first tick in their minute that is >= one period after the previous run (daily `clean_webhooks` at 01:00); environment readings: switches only on exact `true`, events validation off for any non-empty text except 0/f/F/false/FALSE/off/OFF, blank-aware configured checks, period parsing with leading integer, sign and single underscores, periods < 1 s run at every tick.
- api: no change needed.

Time spent: about 1 minutes.
