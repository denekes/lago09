# REPORT — crc-6a (invoice, credit_notes)

Adapter: `python3.12 impl/crc-6a/adapter.py` (standard library only).

## Final kitrun results (shipped vectors)

Profile compat:

    SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=145 passed=145 skipped_ops=0 exit=0

| area | total | pass | rate | core | threshold |
|---|---|---|---|---|---|
| invoice | 114 | 114 | 100.0 % | 100.0 % | 95 % |
| credit_notes | 31 | 31 | 100.0 % | 100.0 % | 95 % |

Profile corrected (information; 6 proposed twins are UNRULED, all of them also PASS):

    SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=145 passed=139 skipped_ops=0 exit=0

| area | total | pass | unruled | rate | core |
|---|---|---|---|---|---|
| invoice | 114 | 111 | 3 | 100.0 % | 100.0 % |
| credit_notes | 31 | 28 | 3 | 100.0 % | 100.0 % |

Thresholds (compat: both areas >= 95 %, core 100 %) are met.

## Time spent

About one working session (roughly 1.5 hours): reading the kit and chapters 07, 08 (and the parts of 05/06 needed),
then implementing the ops in order totals/taxes/coupons, lifecycle, credit notes, void, coupon create/apply, and last
the commitment true-up simulator. Most ops passed on the first run; the failures were an eligibility error that had to be
reported (not raised) by `credit_notes.validate`, and the missing ops.

## Notes on approach

- Exact `Decimal` everywhere; binary64 only in the documented islands (coupon percentage, tax rate shares, creditable
  amount, credit-note tax, single-day price, commitment proration), switched off under the corrected profile.
- Credit notes reuse the totals pipeline to build the invoice, then replay `previous_credit_notes` through the same
  note builder, so the residue rule (BE-CN-9) and fee creditable amounts need no extra input.
- The commitment true-up is a small simulator of billing runs (period algebra, subscription-fee bases, yearly gate,
  usage charge) written from chapters 06 and 07 only; see KIT-GAPS.md items 13.

## What I would do next

- Read chapters 09 and 10 to model wallet allocation order/traceability and progressive-billing over-credit exactly
  (only the amounts in the shipped vectors are covered now).
- Extend the commitment simulator: trials, plan changes (upgrade/downgrade), zone-change continuity, fixed charges,
  payment-gated invoices; cross-check against the `periods` and `pricing` areas' rules.
- Add property tests of the rounding islands (compat vs corrected) and a self-written vector set for hidden-vector
  risks listed in KIT-GAPS.md (zero-credit coupon rows, skipped-coupon output, error-field mapping).

## v1.1

Final kitrun SUMMARY lines (areas invoice,credit_notes):

- compat: `SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=178 passed=178 skipped_ops=0 exit=0` — invoice 137/137 (100 %), credit_notes 41/41 (100 %), core 100 %.
- corrected (informational): `SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=178 passed=169 skipped_ops=0 exit=0` — invoice 132 pass + 5 unruled, credit_notes 37 pass + 4 unruled, 0 fail.

Before: compat invoice 93.4 %, credit_notes 92.7 %.

What changed:
- Coupon creation/application re-done per BE-IV-17/18: check order (expiration, plans, metrics, both kinds, then amount, currency, rate, duration), `base` fields, currency validation against the 142-code table (`common.CURRENCIES`), no rate range check, amount > 0 on create / ≥ 0 on apply, overlap checked before reusability, `applied_before` entries without `coupon` treated as the same coupon.
- Void with credit note (BE-IV-42): item values stored by `round5` (binary64) in compat, half-up at 5 places in corrected.
- Termination (BE-CN-18): voided invoice via `status: voided` exits with no note; upgrade with refund/offset raises `server_error`.

Time spent: about 15 minutes.

## v1.2

Kit 1.2.0, areas invoice,credit_notes.

Final kitrun lines:

- compat: `SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=187 passed=187 skipped_ops=0 exit=0` (credit_notes 45/45 = 100.0 %, core 100 %; invoice 142/142 = 100.0 %, core 100 %)
- corrected: `SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=187 passed=177 skipped_ops=0 exit=0` (credit_notes 40 pass + 5 unruled, 100.0 %; invoice 137 pass + 5 unruled, 100.0 %)

What changed:

- `dec16` (BE-CN-6, BE-CN-7, BE-IV-11 reading): now a cut of the shortest repr text after 16 significant digits, never a rounding (`common.cut16`, used by `d16` and `pct16`). Fixes `credit_notes.compute.019`. The stored sum of the note's precise taxes (BE-CN-7) keeps its 16-digit rounding before the 5-place store (`compute.009` needs it).
- BE-CN-18 exit order: upgrade combined with refund or offset now answers `server_error` right after the zero-fee/voided exit, before any amount is computed. Fixes `credit_notes.termination.013`, `.014`.

Wall clock: start 2026-10-05 15:13:36 UTC, end 2026-10-05 15:14:24 UTC (`date -u`).

## v1.3

Kit 1.3.0 (verified in kit.json). Started 2026-10-05 15:34:31 UTC, finished Mon Oct  5 15:34:58 UTC 2026 (about a minute of wall-clock).

Final kitrun (areas invoice,credit_notes):

- compat: `SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=189 passed=189 skipped_ops=0 exit=0` (invoice 143/143, 100 %; credit_notes 46/46, 100 %; core 100 %)
- corrected: `SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=189 passed=177 skipped_ops=0 exit=0` (invoice 137 pass + 6 unruled of 143; credit_notes 40 pass + 6 unruled of 46; no failures)

Changes (rule ids BE-IV-42, BE-CN-7, chapter 07 column rule): new `col5` in common.py implements the column rule for a binary64 stored in a 5-place column: `round5`, then the exact binary64 value rounded to nearest at 16 significant digits, then half-away to 5 places. Used for void-note item amounts (BE-IV-42, voiding.py; fixes invoice.void.010) and for a note's precise taxes in compat (BE-CN-7, credit_notes.py). The corrected profile (exact decimals) is unchanged.
