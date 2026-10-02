# KIT-GAPS (crc-6a)

Each entry: question; where I looked; assumption made.

1. **Credit row for a limited coupon whose base is 0.** Does a coupon that targets fully discounted fees still create a
   (zero) credit row in `invoice.totals.credits`? Looked at BE-IV-25/26, `invoice.coupon_distribution.010`. Assumed yes:
   a zero credit row is listed and the coupon is consumed per BE-IV-27 (stays active for a fixed once coupon).
2. **`invoice.coupon_distribution` output when the coupon is skipped (BE-IV-21).** Schema allows `credit_amount_cents`
   null. Assumed `applied: false`, `credit_amount_cents: null`, fees unchanged, coupon unchanged.
3. **Percentage coupon with a fractional base.** BE-IV-23 says the product is exact with `rate/100` at 16 digits, then
   "round(v)"; scale of that rounding is not stated. Assumed rounding to whole cents half away from zero.
4. **Fee-tax division (BE-DM-27 / BE-IV-11/12).** "Binary64 division by 100" is ambiguous. Implemented as
   `base × (rate/100 as binary64 read at 16 digits)` (exact product); all shipped vectors agree.
5. **Credit-note shares in the totals pipeline (BE-IV-30).** Which tax amount enters
   `amount − coupons + taxes − credit-notes-already` (fee `taxes_amount_cents` rounded, or the precise one) is not
   stated. Assumed the rounded fee tax amount.
6. **Wallet allocation (BE-IV-31).** Only "priority, then age" and `min(balance, remaining)` are given here; ties by input
   order; wallets of another currency skipped. Chapter 09 not consulted for traceability (not graded here).
7. **`invoice.available_to_credit`: `refundable` for non-finalized notes and "unpaid credit invoice".** Only finalized
   notes are counted in refunds/offsets; a credit invoice is "unpaid" when `payment_status` is not `succeeded`.
   Credit-invoice wallet limits (BE-IV-48) are not modelled: the input schema has no wallet data.
8. **`invoice.coupon_apply`.** (a) With an override `frequency: recurring` and no override duration, the coupon's own
   duration is used; (b) percentage-rate range assumed `0 < rate <= 100` for `value_is_out_of_range`; (c) the order of
   the validation errors (amount, currency, rate, duration) is assumed.
9. **`invoice.coupon_create`.** `frequency_duration` of a non-recurring coupon echoed as given; `targets` = number of
   distinct plan or metric codes; a time-limited coupon without `expiration_at` assumed `invalid_date` on `expiration_at`.
10. **Credit-note validation order and fields.** BE-CN-12 lists checks (a)-(g) but names fields loosely; I map
    "(refund)" → `refund_amount_cents`, "(credit)" → `credit_amount_cents`, "(offset)" → `offset_amount_cents`,
    "(base)" → `base`. Eligibility errors (premium, version) and item errors stop the request before the amount checks.
11. **Termination credit note (BE-CN-17).** `used` (sdp × used days) is taken truncated to 5 decimals like the item;
    the "not supported" error for upgrade + refund/offset has no code in the kit, so the combination is not rejected.
    An already-voided invoice is read from an optional `invoice.voided` flag (not in the schema).
12. **Void with credit note (BE-IV-42).** The second, immediately voided note is shown with `credit_status: voided`
    and its own credit amount, balance 0. Which `previous_credit_notes` count (all, assumed finalized) is not stated.
13. **Commitment true-up simulator (BE-IV-54..57).** Chapter 06 is read only as far as needed: billing-run boundaries,
    the subscription-fee amount bases (terminated / full period / first period), the yearly gate and BE-SP-27. Not
    modelled: trials, plan changes, zone-change continuity (BE-SP-23), fixed charges. "Inside the commitment period"
    for counted fees is assumed to mean the fee window starts inside the period; the earliest line is chosen by its
    fee-window start. A run with reason `subscription_starting` bills only the subscription fee and never a commitment.
14. **Estimate (BE-CN-14).** "Items are taken as whole cents (fractions dropped)" is read as truncation.
