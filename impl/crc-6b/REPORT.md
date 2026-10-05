# REPORT (crc-6b)

Final kitrun results (shipped vectors, from repository root):

    profile compat:    SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=145 passed=145 skipped_ops=0 exit=0
      invoice 114/114 (100 %, core 100 %), credit_notes 31/31 (100 %, core 100 %)
    profile corrected: SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=145 passed=139 skipped_ops=0 exit=0
      invoice 111 pass + 3 unruled, credit_notes 28 pass + 3 unruled (all six corrected twins PASS)

Thresholds (invoice, credit_notes >= 95 %, core 100 %) are met in compat.

Time spent: about one session (reading ch. 07/08 and 06 excerpts, one implementation pass, one debugging pass).

Next steps: hidden vectors will probe the commitment simulator (advance plans, terminations, semiannual) and the
termination note with trials and coupons; I would add vectors-by-hand for those from BE-IV-54..56 / BE-SP-58..60,
review the float-island choices in KIT-GAPS 1 and 3, and split `adapter.py` into smaller modules.

## v1.1

Final kitrun (areas invoice,credit_notes):
- compat: `SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=178 passed=178 skipped_ops=0 exit=0` — invoice 137/137 (100 %), credit_notes 41/41 (100 %), core 100 %.
- corrected: `SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=178 passed=169 skipped_ops=0 exit=0` — invoice 132 pass + 5 unruled twins, credit_notes 37 pass + 4 unruled twins, 0 fail.

v1.0 code on v1.1 failed 10 vectors (invoice 131/137, credit_notes 37/41). Changes:
- BE-CN-6: coupon share uses the binary64 item rate at 16 digits times the exact coupon amount (compute.016).
- BE-CN-18: voided invoice / zero fee exit before the upgrade+refund/offset check; that case is now `server_error`.
- BE-IV-17: coupon create check order (expiration, unknown plans, unknown metrics, both kinds, then amount, currency, rate, duration), currency validated against the 142-code table, past `expiration_at` refused whenever given, distinct targets counted.
- BE-IV-18: apply order (not found, overlap, non-reusable, then amount ≥ 0, currency, duration), `base` field on overlap/not found.
- BE-IV-23/25: limited percentage coupons use the decimal path; distribution share divides the exact product (binary64 for unlimited, decimal for limited).

Time spent: about 1 minutes.

## v1.2

Kit 1.2.0, started 2026-10-05 15:13:36 UTC, finished 15:15 UTC (wall clock from `date -u`; roughly 2 minutes).

Final kitrun (areas invoice,credit_notes):

- compat: `SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=187 passed=187 skipped_ops=0 exit=0` — invoice 142/142 (100 %, core 100 %), credit_notes 45/45 (100 %, core 100 %).
- corrected: `SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=187 passed=177 skipped_ops=0 exit=0` — invoice 137 pass + 5 unruled, credit_notes 40 pass + 5 unruled, no failures.

Changes:

- BE-CN-6 / dec16 (`credit_notes.compute.019`): `sig16` now cuts the shortest text after 16 significant digits (ROUND_DOWN) instead of rounding.
- BE-IV-42 (`invoice.void.009`): void-note items scaled by the ratio are stored with `round5` (BE-IV-14) rather than rounding the text.
- BE-CN-7 (kept `credit_notes.compute.009` passing after the dec16 change): per-code base is exact, tax is exact product then one binary64 ÷100, note precise taxes stored with `round5`. See KIT-GAPS.md v1.2 for the text-vs-round5 wording question.
