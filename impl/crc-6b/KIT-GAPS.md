# KIT-GAPS (crc-6b)

1. **Tax row division order (BE-IV-11/12).** "division by 100 is binary64" does not say whether `base*rate/100` or
   `base*(rate/100)`. Looked: ch. 07, BE-DM-30. Assumption: exact product, then float division by 100.0. For coupons
   (BE-IV-23) the only reading that gives 31 for 17.5 % of 180 is `B * (rate/100.0)`, used there.
2. **Termination by upgrade (BE-SP-58) wording.** The text says "one day fewer" yet the vector credits one day more
   (F moves one day earlier, so E-F grows). Assumption: F = F - 1 day, i.e. one more remaining day.
3. **Ruby-style Float#round for tax rate (BE-IV-14).** Rounding mode for the binary64 value is not stated; I mimic
   round-half-away with the pre/post-scale correction, which gives 0.24062 for the pinned tie.
4. **First error of credit_notes.compute.** Which field/code is reported when several checks fail is not stated.
   Assumption: order base, amount_cents, refund, credit, offset; item errors short-circuit BE-CN-12 checks.
5. **`progressive_billing.coupons_amount_cents`** (input field) is never mentioned in ch. 07; ignored. Fee matching
   `same_charge_as` is by fee id.
6. **Void with credit note (BE-IV-42):** rounding of scaled items kept to 5 places; validation of credit/refund
   against creditable/refundable done in binary64 in compat. Voiding a non-finalized invoice raises `not_voidable`.
7. **Commitment true-up op** needs billing runs, proration and charge fees (ch. 06, partly out of my chapters). I wrote
   a small simulator (arrears/advance, calendar/anniversary, monthly-split charges, termination) covering the
   shipped vectors; advance-plan and termination paths follow BE-IV-54..56 but are unverified by vectors.
8. **Termination note validation (BE-CN-18):** the note is created without BE-CN-12 validation; no vector says
   otherwise. Plan amount for `sdp` = `plan.amount_cents` (else the fee amount).
9. **Wallet order:** priority then input order (age); allocation per fee type (ch. 09) not needed for the totals op.

## v1.1

- Q: Is `status: voided` the only voided-invoice marker in the termination input (BE-CN-18), or can `payment_status`/other fields signal it? Looked: BE-CN-18, `credit_notes.termination.011/.012`. Assumption: `invoice.status == "voided"`.
- Q: Coupon create (BE-IV-17): does `expiration_at` in the past fail even when `expiration` is not `time_limit`? Looked: BE-IV-17 ("when given"). Assumption: yes, whenever given.
- Q: Exactly how `dec16` rounds (half-up vs shortest repr) for the binary64 item rate (BE-CN-6). Looked: chapter 07 reading guide. Assumption: 16 significant digits, half up of the exact binary64 value.
- Q: Apply-coupon reusability when `applied_before` entries lack a `coupon` key. Looked: BE-IV-18. Assumption: such entries are of the same coupon.

## v1.2

- Question: BE-CN-7 says the note's precise taxes are "stored by rounding its text to 5 places", but `credit_notes.compute.009` (precise tax 15466.66666 × 25 ⁄ 100 = 3866.666665) only passes when the sum is stored with `round5` (BE-IV-14, the x ⊗ 100000 tie rule), not by rounding the text 3866.6666649999997. Where I looked: BE-CN-7, chapter 07 notation paragraph (round5 vs text). Assumption: round5 applies to the binary64 sum of the note's precise taxes.

## v1.4

No open questions. One interpretation: the column rule's "16 significant digits, rounded to nearest" is applied to the exact binary64 value, not its shortest text (looked at: ch.07 lines on the column rule, vector diff for invoice.void.010); assumption kept because it passes all shipped vectors.
