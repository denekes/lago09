# REPORT crc-7 (wallets, progressive, alerts)

Final kitrun results (from the repository root, adapter `python3.12 impl/crc-7/adapter.py`):

- profile compat:
  `SUMMARY kitrun: areas=3 pass=3 fail=0 vectors=139 passed=139 skipped_ops=0 exit=0`
  wallets 73/73, progressive 45/45, alerts 21/21 (100 %, CORE 100 %).
- profile corrected (informational):
  `SUMMARY kitrun: areas=3 pass=3 fail=0 vectors=140 passed=134 skipped_ops=0 exit=0`
  wallets 72/72 graded, progressive 45/45, alerts 17/17 graded; 4 UNRULED alerts twins and 2 UNRULED wallet twins
  (2 wallet twins pass; alerts.crossed.013x/014x and alerts.measure.002x/003x fail: RBD-77/78 not implemented).

Thresholds (95 % each, core 100 %) are met on the shipped vectors.

Time spent: about 30 minutes, one implementation pass (every shipped compat vector passed on the first run).

Next: implement the corrected twins (RBD-77 sum over metric fees, RBD-78 recurring steps, RBD-104/105) behind
`ctx.profile == "corrected"`; review float islands (binary division) against more hidden-style inputs;
fuzz boundary cases of the interval anchor rules; see KIT-GAPS.md for the assumptions.

## v1.2

Wall-clock: start Mon Oct  5 14:42:26 UTC 2026, end Mon Oct  5 14:42:49 UTC 2026.

Final kitrun (areas wallets,progressive,alerts):
- compat: `SUMMARY kitrun: areas=3 pass=3 fail=0 vectors=146 passed=146 skipped_ops=0 exit=0` — wallets 100.0 % (78/78), progressive 100.0 % (46/46), alerts 100.0 % (22/22); all core vectors pass.
- corrected (informational): `SUMMARY kitrun: areas=3 pass=3 fail=0 vectors=147 passed=141 skipped_ops=0 exit=0` — wallets 100.0 %, progressive 100.0 %, alerts 100.0 % of ruled vectors; 6 UNRULED corrected twins (4 alerts, 2 wallets) not counted; 4 of them differ (alerts.crossed.013x/014x, alerts.measure.002x/003x), left as is.

Changed: BE-WL-2 / BE-WL-4 credit division is now decimal (32 digits) for currencies with minor units (e > 0) and stays binary64 for zero-exponent currencies (fixes wallets.credits.012, .013); applied to all credit divisions (top-up, allocate, ongoing balance, limits in credits).
