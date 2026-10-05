# 08 — Credit notes (BE-CN)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08).
> It is a behavioural specification written fresh from executed vectors and probes, not source code. Proprietary
> clean-room rebuilds should have it reviewed (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90`. A **credit note** gives back part of an invoice: as **credit** (a balance consumed by
the customer's later invoices, chapter 07 BE-IV-30), as a **refund** (money returned through the payment provider) or
as an **offset** (settles the same invoice's unpaid amount). This chapter specifies eligibility, items, the coupon
adjustment and taxes of a note, the rounding corrections, validation, the estimate, and the automatic note issued when
a pay-in-advance subscription is terminated. The bounds a note must respect (creditable, refundable, offsettable
amounts) are BE-IV-46..50; numbering is BE-DM-44/45; the day counts of a termination are BE-SP-58/59.

Reading guide: rules are numbered `BE-CN-n` and end with `[vec: …]` (file `billing-engine-spec/vectors/credit_notes.jsonl`,
scenarios `scn.*`) or a prose-only marker. Op schemas: `reimplementation-kit/schemas/ops/credit_notes.*.schema.json`;
the invoice a note refers to is described with the `invoice.totals` input plus a status and payment state. Money is in
integer minor units; `precise_*` values are decimals stored with 5 places; `round` = half away from zero (BE-DM-23);
"binary64" marks float islands (RBD-68). Notation `⊗ ⊘ ⊕` (binary64 operations), `dec16` and the reading of binary64
results as their shortest decimal text are those of chapter 07 (reading guide); the islands of this chapter are listed
in section 6.

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun against the oracle -->

## 1. Kinds, statuses, eligibility

- **BE-CN-1** A note carries three non-negative amounts, `credit`, `refund` and `offset`; the requested `total = credit + refund + offset` and `balance = credit`, both after the correction of BE-CN-11 (which can break the sum, RBD-106). At creation `credit_status` is `available` (even for a note without credit) and `refund_status` is `pending` when the **requested** refund is > 0 (else empty), whatever BE-CN-11 later writes into the refund. [vec: credit_notes.compute.001, credit_notes.compute.004, credit_notes.compute.005, credit_notes.termination.005]
- **BE-CN-2** A note on a `draft` invoice is a `draft` note (finalized together with the invoice, BE-IV-35); on any other invoice, including a voided one, it is `finalized`. Its issuing date is today in the customer's zone. [vec: credit_notes.compute.007]
- **BE-CN-3** Manual notes (API, invoice void) require the premium licence (`feature_unavailable`); automatic notes (termination, progressive-billing over-credit) do not. [vec: credit_notes.compute.008]
- **BE-CN-4** Eligibility: the invoice's version must be ≥ 2 (`invalid_type_or_status`). Credit invoices (wallet purchases) accept a note only while their wallet is active; while their payment is pending or failed only an offset is allowed, otherwise only after the payment succeeded. For invoices of version < 3 the coupon adjustment of BE-CN-6 is 0. [vec: credit_notes.validate.008]

## 2. Amounts of a note

- **BE-CN-5** Items: each item names a fee of the invoice (unknown fee → `fee_not_found`) and an amount in cents that may be fractional; the item keeps `precise_amount_cents` = the requested amount and `amount_cents = round(amount)`. An item whose cent amount is < 0 is `invalid_value`; an item whose cent amount is above the fee's creditable amount (its amount minus the cent amounts of earlier notes' items on it; for a credit fee also capped by the wallet-backed amount, then `higher_than_wallet_balance`) is `higher_than_remaining_fee_amount`, except on a credit invoice whose payment is pending or failed, where any amount passes this check. Items are checked in order and the first invalid one stops the request. [vec: credit_notes.compute.009, credit_notes.validate.003, credit_notes.validate.004, credit_notes.validate.009, credit_notes.validate.010]
- **BE-CN-6** Coupon adjustment: for each item, `item_rate = item.precise ⊘ fee.amount_cents` (binary64; 0 when the fee amount is 0); `adjustment = Σ (fee.precise_coupons_amount_cents × dec16(item_rate))` (exact products of the 16-digit rate), 0 for invoices of version < 3; the note stores the adjustment at 5 places (half away) and `coupons_adjustment_amount_cents = round(adjustment)`. The rate is divided first: 3 coupon cents on a 192-cent fee and an item of 1 give `3 × dec16(1 ⊘ 192)` = 0.015624999999999999 → 0.01562, where `3 × 1 / 192` = 0.015625 would store 0.01563 (RBD-68; corrected twin). `dec16` truncates the rate's shortest text after 16 significant digits (chapter 07 reading guide): an item of 5 on the same fee gives `5 ⊘ 192` = 0.026041666666666668, which enters as 0.02604166666666666, so `3 ×` it = 0.07812499999999998 → 0.07812; the uncut text, or the exact binary64 value rounded to 16 digits (0.02604166666666667), would store 0.07813. [vec: credit_notes.compute.003, credit_notes.compute.016, credit_notes.compute.016x, credit_notes.compute.019, credit_notes.compute.019x, credit_notes.estimate.002]
- **BE-CN-7** Taxes, per tax code present on the items' fees (rows take code, name and rate from the invoice's tax snapshot): `base = Σ (item.precise − fee.precise_coupons × item_rate)` over the items whose fee carries the code — the coupon share leaves the base **even for version < 3 invoices**, whose adjustment is 0; `taxes_base_rate` = the invoice row's taxable amount ⊘ its fees amount (1 for locally computed taxes); `precise_tax = ((base × taxes_base_rate) × rate) ⊘ 100` — the product is exact (`taxes_base_rate` and `rate` entering it at 16 digits) and only the division by 100 is binary64, as for a tax row (BE-IV-11): an item of 180 at 17.5 % gives 3150 ⊘ 100 = 31.5 → 32; row `amount_cents = round(precise_tax)`, row `base_amount_cents = round(base × taxes_base_rate)`. The note's precise taxes = `precise_tax_1 ⊕ precise_tax_2 ⊕ …` (binary64 sum), stored by rounding its text to 5 places, and `taxes_amount_cents = round(precise taxes)` after BE-CN-9. [vec: credit_notes.compute.001, credit_notes.compute.002, credit_notes.compute.003, credit_notes.compute.015]
- **BE-CN-8** `taxes_rate` of the note = round(Σ over codes of `(base_code / (Σ item.precise − adjustment)) × rate`, 5 places, half away), computed in **decimal** (exact quotient, the rate at 16 digits) — unlike the invoice's binary64 rate (BE-IV-14): items of 7 (at 5.5 %) and 153 give 7 / 160 × 5.5 = 0.240625 → 0.24063 on the note where the invoice shows 0.24062; 0 when the divisor is 0. [vec: credit_notes.compute.018, credit_notes.estimate.003]
- **BE-CN-9** Last-note tax residue: when, once this note's items are counted, the invoice's creditable amount (BE-IV-47) is 0, the note's precise taxes are reduced by Σ (taxes_amount − precise taxes) over the invoice's existing notes, so the notes' taxes add up to the invoice's taxes (two notes of 1367 and 1366 on a 2733 invoice tax). The per-code rows are **not** adjusted. RBD-75 keeps this. [vec: credit_notes.compute.002, credit_notes.estimate.004]
- **BE-CN-10** `sub_total_excluding_taxes = round(Σ item.precise − stored precise adjustment)`. [vec: credit_notes.compute.003, credit_notes.compute.009]
- **BE-CN-11** Rounding correction (RBD-75 keeps it): if `total − taxes_amount ≠ sub_total_excluding_taxes`, the total moves by one cent towards it (−1 when larger, +1 when smaller); then, when `credit > 0`, `credit = total − refund`; otherwise `refund = total`; `balance = credit`. The offset is never part of this step, so on a note with an offset the three amounts no longer add up to the total: credit 5000 + offset 6667 requested becomes credit 11666 + offset 6667 on a total of 11666, refund 5000 + offset 6667 becomes refund 11666 + offset 6667, and an offset-only note of 11667 gets refund 11666 next to its offset 11667 (RBD-106; corrected profile, proposed: the cent moves onto one requested field — the credit when credit > 0, else the offset when offset > 0, else the refund — so that credit + refund + offset = total). [vec: credit_notes.compute.001, credit_notes.compute.005, credit_notes.compute.009, credit_notes.compute.013, credit_notes.compute.013x, credit_notes.compute.014, credit_notes.compute.014x, credit_notes.termination.001, credit_notes.termination.002, credit_notes.termination.005, credit_notes.termination.005x]
- **BE-CN-12** Validation (every failing check is recorded under its field, a field failing several checks listing their codes in check order; an op that reports one error reports the first failing check in the order below, after the eligibility errors of BE-CN-3/4 and the item errors of BE-CN-5, which end the request before these checks; amounts compared with a one-cent tolerance where stated; "other notes" are the invoice's other **finalized** notes, and `remaining_credit = fee_total − other notes' credits − other notes' offsets` with `fee_total` of BE-IV-49): (a) refund > 0 on an invoice whose payment did not succeed although it is fully paid (paid = total > 0) → `cannot_refund_unpaid_invoice` (refund); (b) `|total − round(Σ item.precise − adjustment + precise taxes)| > 1` → `does_not_match_item_amounts` (base); (c) refund > 0 with nothing paid → `cannot_refund_unpaid_invoice`, refund > paid − refunds of the invoice's other finalized notes → `higher_than_remaining_invoice_amount` (refund); (d) credit > 0 on a credit invoice → `cannot_credit_invoice` (credit); credit above `remaining_credit` by more than 1 → `higher_than_remaining_invoice_amount` (credit); (e) offset > 0: on a credit invoice nothing may be paid (`cannot_apply_to_paid_invoice`) and the offset must equal the invoice total (`not_equal_to_total_amount`), the first failure ending check (e); then, on any invoice, offset ≤ min(invoice total − paid − other notes' offsets, `remaining_credit`) else `higher_than_remaining_invoice_amount` (offset); (f) total above `fee_total − (other notes' credits + refunds + offsets)` by more than 1 → `higher_than_remaining_invoice_amount` (base); (g) total ≤ 0 → `total_amount_must_be_positive` (base). Field names as reported: `refund_amount_cents`, `base`, `credit_amount_cents`, `offset_amount_cents`; items use `amount_cents`, an unknown fee and the eligibility errors use `base`. [vec: credit_notes.compute.012, credit_notes.compute.017, credit_notes.validate.001, credit_notes.validate.005, credit_notes.validate.007, credit_notes.validate.010, credit_notes.validate.011, credit_notes.validate.012]
- **BE-CN-13** An offset creates a settlement of the invoice for the offset amount; when the invoice's amount due (BE-IV-46) reaches 0 or less its payment status becomes `succeeded`. [vec: credit_notes.compute.004]

A manual note, as fresh pseudocode:

```
create_note(invoice, items, credit, refund, offset):
    check eligibility (BE-CN-3, BE-CN-4); build items (BE-CN-5)
    adj = 0 if invoice.version < 3 else sum(f.precise_coupons * (i.precise / f.amount) for i, f in items)
    rows = []; ptax = 0
    for code in tax codes of the items' fees:
        base = sum(i.precise - f.precise_coupons * (i.precise / f.amount) for i, f in items if code in f.taxes)
        t = base * base_rate(code) * rate(code) / 100                  # binary64
        rows.append({code, amount_cents: round(t), base_amount_cents: round(base)})
        ptax += t
    ptax = store5(ptax)
    if creditable_after_items(invoice) == 0: ptax -= sum(n.taxes - n.precise_taxes for n in invoice.notes)   # BE-CN-9
    taxes = round(ptax); sub = round(sum(i.precise) - store5(adj))
    validate (BE-CN-12)
    total = credit + refund + offset; balance = credit
    refund_status = pending if refund > 0 else none                     # from the requested refund
    if total - taxes != sub:                                            # BE-CN-11
        total += -1 if total - taxes > sub else 1
        if credit > 0: credit = total - refund                          # offset ignored (RBD-106)
        else: refund = total                                            # requested refund and offset ignored
        balance = credit
```

## 3. Estimate

- **BE-CN-14** Estimate (premium, invoice version ≥ 2; credit invoices only when paid and backed by an active wallet): items are taken as whole cents (a fraction is truncated toward zero: 500.7 → 500), then BE-CN-5..8 apply; the residue of BE-CN-9 applies when the items' total equals the sum of the fees' remaining creditable amounts; `max_creditable = round(Σ item cents − adjustment + precise taxes)` (0 for a credit invoice); `max_refundable = min(max_creditable, the invoice's refundable amount)` stored as integer cents (a fractional refundable is truncated); then if `max_creditable − taxes > sub_total` the creditable amount loses one cent, else if taxes > 0 and `max_creditable − taxes < sub_total` the taxes lose one cent. [vec: credit_notes.estimate.001, credit_notes.estimate.002, credit_notes.estimate.003, credit_notes.estimate.004, credit_notes.estimate.005, credit_notes.estimate.007]

## 4. The termination note

When a subscription of a plan **paid in advance** is terminated (not as a downgrade rotation, BE-SP-53) with
`on_termination_credit_note` ∈ {`credit`, `refund`, `offset`}, an automatic note returns the unused part of the last
subscription fee.

- **BE-CN-15** Unused amount: `sdp ⊗ remaining` (BE-SP-58: `sdp` is the binary64 single-day price of the plan amount recorded on the last subscription fee, else the plan's amount); nothing when ≤ 0; capped at the last subscription fee's `amount_cents`; minus the items of earlier notes on that fee; nothing when ≤ 0. The single item is that amount **truncated** to 5 decimals (e.g. 15466.66666), so its cent amount rounds and the totals are re-rounded (BE-CN-11). [vec: credit_notes.termination.001, credit_notes.termination.002, credit_notes.termination.003, credit_notes.termination.015]
- **BE-CN-16** The day counts are those of BE-SP-58/59: remaining days from the end of the termination's local day to the end of the period (one day more when terminated by an upgrade: the end point `F` moves one day earlier, so the termination day itself is credited back, BE-SP-58; trial-aware), both taken as UTC calendar dates of local day ends; this equals local-date arithmetic when both local day ends have negative UTC offsets or both have zero or positive ones (always true except in a zone whose offset crosses UTC during the period, such as one at −01:00 in winter and +00:00 in summer: `periods.termination_credit_days.010`). [vec: credit_notes.termination.001, credit_notes.termination.003, credit_notes.termination.006]
- **BE-CN-17** Amounts: `T = round(item − adjustment + precise taxes)` with BE-CN-6/7 applied to the single item on the paid invoice. `refund = round(min(paid_share − used, T))`, 0 when `paid_share − used` is not positive, where `paid_share = ((fee precise sub-total + fee precise taxes) ⊘ invoice sub_total_including_taxes) ⊗ invoice total_paid` (0 when that sub-total is 0) and `used` = the same chain as `T` applied to `sdp ⊗ used days` (BE-SP-59): truncated to 5 decimals like the item, then `round(x − adjustment + precise taxes)`. Split: `credit` → (T, 0, 0); `refund` → (T − refund, refund, 0); `offset` → (0, refund, T − refund). The note is then created as an automatic note (BE-CN-1, BE-CN-5..12 apply). [vec: credit_notes.termination.001, credit_notes.termination.002, credit_notes.termination.003, credit_notes.termination.004, credit_notes.termination.005]
- **BE-CN-18** No termination note when the last subscription fee is 0 or its invoice is voided (the invoice's `status` is `voided`; its payment status plays no part), or when the three amounts are all 0. Termination by upgrade combined with `refund` or `offset` is not supported: the reference fails with an unhandled error that has no code (kit domain error `server_error`). The exits are taken in this order: (1) a zero fee or a voided invoice → no note, without an error; (2) upgrade with `refund` or `offset` → `server_error`, before any amount is computed, so the error is raised even when nothing would be credited (no remaining day, an unused amount of 0, earlier notes covering the fee); (3) nothing left to credit after BE-CN-15 → no note; (4) the three amounts of BE-CN-17 all 0 → no note. [vec: credit_notes.termination.007, credit_notes.termination.010, credit_notes.termination.011, credit_notes.termination.012, credit_notes.termination.013, credit_notes.termination.014, credit_notes.termination.015]

## 5. After creation

- **BE-CN-19** A note's credit is consumed by the customer's later invoices after taxes, oldest note first (BE-IV-30); it becomes `consumed` when its balance reaches 0. [vec: invoice.totals.009, invoice.totals.023]
- **BE-CN-20** A finalized note whose balance is > 0 can be voided: `credit_status = voided`, balance 0, `voided_at` set; a note with balance 0 cannot. [vec: invoice.void.002]
- **BE-CN-21** Progressive-billing over-credit: when a period invoice's progressive credit exceeds its charge fees, the excess is returned by an automatic note on the progressive-billing invoice (items taken from its fees by descending amount; chapter 10). [vec: scn.invoice.progressive.002]
- **BE-CN-22** After commit, a refund on an invoice paid through a payment provider triggers a provider refund (interface, chapter 14); a refund note on a credit invoice voids the matching wallet credits (chapter 09). [vec: none (prose only: out-of-scope providers and wallet side effects)]
- **BE-CN-23** Notes attached to a draft invoice are rescaled (new fee ÷ old fee) and recomputed whenever the draft is refreshed. [vec: none (prose only: draft refresh is exercised by the scenario tier)]
- **BE-CN-24** Numbering and dates: the note number is `<invoice number>-CN<sequence>` (BE-DM-44/45), recomputed when a draft note is finalized. [vec: domain.numbering.credit_note_number.001]

## 6. Rebuild decisions touching this chapter

| RBD | Behaviour at the pin | Compat | Corrected |
|---|---|---|---|
| RBD-75 | ±1-cent total correction, termination items truncated to 5 places, last note absorbs the tax residue | KEEP | KEEP: the `both` vectors that cite it (`credit_notes.compute.002`, `.009`, `.011`, `credit_notes.termination.001..003`) carry no offset, so the RBD-106 correction leaves them unchanged |
| RBD-106 | the ±1-cent correction ignores the offset: on a note with an offset, credit + refund + offset ≠ total (BE-CN-11) | `credit_notes.compute.013`, `credit_notes.compute.014`, `credit_notes.termination.005` | proposed: the cent lands on one requested field (credit, else offset, else refund); twins `…x` |
| RBD-68 | item rates and the paid share in binary64 (the note's tax rate is decimal, BE-CN-8) | `credit_notes.compute.016` (0.01562), `credit_notes.compute.019` (0.07812) | exact decimal (proposed): twins `credit_notes.compute.016x` (0.01563), `credit_notes.compute.019x` (0.07813) |

Binary64 islands of this chapter, with their exact evaluation order: the item rate `item ⊘ fee amount` entering the
coupon adjustment at 16 digits, its shortest text truncated (BE-CN-6, `credit_notes.compute.016`, `credit_notes.compute.019`); the tax `((base × taxes_base_rate) × rate) ⊘ 100`
with the binary64 sum of the per-code taxes (BE-CN-7, `credit_notes.compute.015`: 32, where `180 ⊗ (17.5 ⊘ 100)` would
give 31); the termination unused amount `sdp ⊗ days` and the paid share `(fee amount ⊘ invoice sub-total) ⊗ paid`
(BE-CN-15, BE-CN-17; the two orders of the paid share differ for some inputs taken alone — `(15 ⊘ 22) ⊗ 11` =
7.499999999999999 against `(15 × 11) ⊘ 22` = 7.5 — but no termination vector pins such a case yet). The note's tax rate (BE-CN-8) is not an island: it is decimal (`credit_notes.compute.018`).

## 7. Edge cases (people get these wrong)

| Case | Rule |
|---|---|
| Two notes on one invoice: taxes 1367 then 1366 (residue), while the second note's row still says 1367 | BE-CN-9 |
| A version-2 invoice: no coupon adjustment, yet the tax base still excludes the coupon share | BE-CN-6, BE-CN-7 |
| Totals one cent off are accepted and corrected | BE-CN-11, BE-CN-12 |
| A note with an offset can end with credit + refund + offset above its total (an offset-only note shows a refund equal to its total) | BE-CN-11 |
| The estimate drops item fractions (toward zero); the note itself keeps them | BE-CN-14, BE-CN-5 |
| The note's tax rate is decimal (0.24063) where the invoice's is binary64 (0.24062) for the same shares | BE-CN-8, BE-IV-14 |
| One error is reported: the first failing check in order, e.g. the item-total mismatch (base) before an unpaid refund | BE-CN-12 |
| Upgrade termination with refund or offset is an unhandled error, not a note, even when nothing would be credited | BE-CN-18 |
| Termination items are truncated, not rounded, to 5 decimals | BE-CN-15 |
| A credit note on a draft invoice stays draft until the invoice is finalized | BE-CN-2 |

## 8. Vectors

| File | Ops | Vectors |
|---|---|---|
| `credit_notes.jsonl` | `credit_notes.compute`, `credit_notes.estimate`, `credit_notes.termination`, `credit_notes.validate` | 58 (five corrected twins) |

Evidence: every `both`/`compat` vector is EXECUTED through the oracle adapter at the pin (spec-derived values were
first checked against the reference examples); the five corrected twins (three RBD-106, two RBD-68) are RECOMPUTED
with `ruling: proposed`. Run them with `python3 reimplementation-kit/scripts/kitrun.py --impl-cmd "<adapter>"
--areas credit_notes`.

## Provenance (maintainers)

Executed 2026-10-02 on the pinned toolchain (database `lago_api_test_a7`): the credit-note specs
(`spec/services/credit_notes/{adjust_amounts_with_rounding,apply_taxes,estimate,validate,validate_item,create,void}_service_spec.rb`, `spec/services/credit_notes/create_from_termination_spec.rb`,
`spec/scenarios/credit_notes/{credit_note,credit_note_rounding}_spec.rb`, `spec/models/credit_note_spec.rb`) are part of
the green runs listed in chapter 07; kitrun of `credit_notes.jsonl` against `oracle.sh adapter` → 37/37 PASS, and the
independent model `scripts/maintainer/recompute-invoicing.py` → 37/37 PASS. Fix round of 2026-10-02 (database
`lago_api_test_fr5`): the RBD-106 vectors were executed (credit 5000 + offset 6667 requested on items of 9,333.33333 at
25 % → credit 11,666, offset 6,667, total 11,666; refund 5000 + offset 6667 → refund 11,666, offset 6,667), then 39/39
`both`/`compat` PASS against the oracle and 39/39 compat plus the three corrected twins PASS with the model, whose
corrected profile moves the cent onto the requested field. Rounding rule: `$API/app/services/credit_notes/adjust_amounts_with_rounding_service.rb:26-31`.

Fix round of 2026-10-05 (database `lago_api_test_fr2g4`): item rate and tax order from
`$API/app/services/credit_notes/apply_taxes_service.rb:39` and `:77-96`; the note's tax rate divides two decimals
through the float-division helper and stays decimal (`:99-106`), executed with the inputs of `invoice.apply_taxes.003`
(note 0.24063, invoice 0.24062). Validation order and fields from `$API/app/services/credit_notes/validate_service.rb:5-21`
and `$API/app/services/credit_notes/validate_item_service.rb:5-16`, executed (`credit_notes.compute.017`,
`credit_notes.validate.011`, `.012`). Estimate fraction: `$API/app/services/credit_notes/estimate_service.rb:53` (500.7 →
500). Termination: the voided-invoice exit and the unsupported upgrade combination at
`$API/app/services/credit_notes/create_from_termination.rb:22-25` (an unhandled error with no code, answered by the
oracle module as the kit's `server_error`); `used` goes through the same 5-place truncation as the item (`:149-160`, `:175-177`). The voided-invoice exit
precedes the unsupported-combination error: upgrade with a refund on a voided invoice gives no note (executed through
`oracle.sh adapter` on 2026-10-05, database `lago_api_test_v2g4`; vector `credit_notes.termination.012`, EXECUTED at the
kit v1.1 integration).
The paid-share order `(fee ⊘ sub-total) ⊗ paid` differs from `(fee × paid) ⊘ sub-total` on isolated inputs (15, 22, 11)
but no termination vector reaches such a case. kitrun against the oracle: all `credit_notes` vectors, shipped and
holdout, PASS (part of the 392/392 run of chapter 07); the model `recompute-invoicing.py` passes them all in both profiles.

Later pass of 2026-10-05 (database `lago_api_test_fr3b`; each new vector run twice through `oracle.sh adapter`). Exit
order of the termination note from `$API/app/services/credit_notes/create_from_termination.rb:22-33`: the zero-fee and
voided-invoice exit tests the invoice status only (`:22`), the unsupported combination is raised at `:24-25`, before
the creditable amount (`:27-29`, earlier notes deducted at `:77`) and the three amounts (`:31-33`); executed: upgrade
with a refund and earlier notes covering the fee, and upgrade with an offset and a 60-day trial covering the rest of the
period, both `server_error`, while the same upgrade with `credit` and covering notes gives no note
(`credit_notes.termination.013..015`). The 16-digit cut: `$API/app/services/credit_notes/apply_taxes_service.rb:79-80`
multiplies a decimal by a binary64, which BigDecimal 4.1.2 converts from the shortest text truncated after 16
significant digits (probed on the pinned Ruby: `5 ⊘ 192` enters as 0.02604166666666666 and 3 times it gives
0.07812499999999998); executed as `credit_notes.compute.019` (0.07812), while a control vector expecting the half-up
reading for `1 × (23 ⊘ 320)` (0.07187) failed against the oracle's 0.07188. The model `recompute-invoicing.py` now
applies the same cut where the chapters write `dec16` and passes every vector of this chapter in both profiles.

| Rules | Reference code @591ae90 |
|---|---|
| BE-CN-1..4 | `$API/app/services/credit_notes/create_service.rb:26-90`, `$API/app/services/credit_notes/create_service.rb:138-178` |
| BE-CN-5 | `$API/app/services/credit_notes/create_service.rb:180-197`, `$API/app/services/credit_notes/validate_item_service.rb:5-79`, `$API/app/models/fee.rb:257-282` |
| BE-CN-6..8 | `$API/app/services/credit_notes/apply_taxes_service.rb:14-116` |
| BE-CN-9, BE-CN-10 | `$API/app/services/credit_notes/create_service.rb:278-296`, `$API/app/models/credit_note.rb:167-189` |
| BE-CN-11 | `$API/app/services/credit_notes/adjust_amounts_with_rounding_service.rb:16-37` |
| BE-CN-12 | `$API/app/services/credit_notes/validate_service.rb:5-171` |
| BE-CN-13 | `$API/app/services/invoice_settlements/create_service.rb:17-68` |
| BE-CN-14 | `$API/app/services/credit_notes/estimate_service.rb:14-144` |
| BE-CN-15..18 | `$API/app/services/credit_notes/create_from_termination.rb:23-190` |
| BE-CN-19..24 | `$API/app/services/credits/credit_note_service.rb:39-111`, `$API/app/services/credit_notes/void_service.rb`, `$API/app/services/credit_notes/create_from_progressive_billing_invoice.rb:41-82`, `$API/app/services/credit_notes/refresh_draft_service.rb:15-69`, `$API/app/models/credit_note.rb:153-199` |

Spec examples behind the explicit expectations: `$API/spec/scenarios/credit_notes/credit_note_rounding_spec.rb:17`,
`$API/spec/scenarios/credit_notes/credit_note_rounding_spec.rb:58`, `$API/spec/scenarios/credit_notes/credit_note_spec.rb:57`,
`$API/spec/scenarios/credit_notes/credit_note_spec.rb:349`.

Update triggers: a pin bump, any change of the credit-note services above, an owner ruling on RBD-75.
