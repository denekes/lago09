# 07 — Invoices, taxes and coupons (BE-IV)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08).
> It is a behavioural specification written fresh from executed vectors and probes, not source code. Proprietary
> clean-room rebuilds should have it reviewed (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90`. This chapter specifies how the engine turns fees that are already priced (subscription
fees: chapter 06; charge, true-up, fixed-charge fees: chapter 05) into an invoice: the invoice types and what triggers
them, the **totals pipeline** (progressive-billing credits, coupons, taxes, credit-note credits, prepaid credits), tax
selection and the tax formulas at fee and invoice level, coupons from ordering to consumption, the invoice lifecycle
(grace period, final status, issuing and due dates, void), the amounts that bound later credit notes, and the plan's
minimum-commitment true-up (section 9). Credit notes
themselves are chapter 08; wallets and their allocation chapter 09; progressive billing thresholds chapter 10;
numbering BE-DM-37..48; fee tax rows BE-DM-27..30.

Reading guide: rules are numbered `BE-IV-n`; every rule line ends with `[vec: …]` naming the vectors that pin it (files
`billing-engine-spec/vectors/invoice.{totals,taxes,coupons,lifecycle,commitment}.jsonl`, scenarios `scn.*`), or a prose-only
marker with the reason. Op schemas: `reimplementation-kit/schemas/ops/invoice.*.schema.json` (their descriptions
restate each op in one paragraph; shared input definitions live in `invoice.totals.schema.json`). All money is in
integer minor units ("cents") of the invoice currency unless named `precise_*` (decimal, unrounded). `round` means
round half away from zero (BE-DM-23) to whole cents unless a scale is given. "binary64" marks the documented float
islands (RBD-68): the compat profile reproduces them, the corrected profile evaluates the same formulas with exact
decimals.

Notation for the islands. `a ⊗ b`, `a ⊘ b` and `a ⊕ b` are binary64 multiplication, division and addition of the
binary64 values nearest to `a` and `b`; `×`, `/`, `+` and `Σ` without a circle are exact. Parentheses give the
evaluation order exactly. A binary64 result is read through its shortest round-trip decimal text (what a binary64
print gives, for example 27.499999999999996): `dec16(x)` cuts that text after its first 16 significant digits, a
truncation that never rounds, neither the text nor the exact binary64 value (27.49999999999999; 0.026041666666666668
gives 0.02604166666666666 where rounding would give 0.02604166666666667, `credit_notes.compute.019`); this is how a
binary64 value enters an exact product or sum (a share added to a stored share included); rounding a binary64 value
to cents rounds that text half away from zero (27.499999999999996 → 27 cents).
A binary64 value stored directly in a 5-place column is rounded by `round5` of BE-IV-14 (27.499999999999996 → 27.5),
which equals rounding its text half away except just below a tie, where `x ⊗ 100000` lands on the half:
11.659374999999999 is stored as 11.65938, not the 11.65937 its text would round to (`invoice.void.009`). Section 10.1 lists every island of
this chapter with its discriminating vector.

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun against the oracle -->

## 1. Invoice types and triggers

| Type (`invoice_type`) | Created when | Pipeline (section 2 variants) |
|---|---|---|
| `subscription` | a billing run of one or more subscriptions (start, periodic, termination, upgrade; chapter 06); also one invoice per invoiceable pay-in-advance charge event (invoicing reason `in_advance_charge`) | full pipeline; pay-in-advance-charge variant for event invoices |
| `one_off` | the API creates an invoice of add-on lines | fees and taxes only |
| `credit` | paid credits are bought on a wallet (chapter 09) | one credit fee, no tax |
| `progressive_billing` | lifetime usage crosses a usage threshold (chapter 10) | progressive variant, always finalized |
| `advance_charges` | a billing run regroups pay-in-advance fees already paid outside invoices | sums existing fee taxes, marked paid |
| `add_on` | legacy; not created any more | — |

- **BE-IV-1** Every invoice belongs to one customer and one billing entity, has one currency, records the customer's effective time zone at creation (BE-DM-13) and starts in the invisible status `generating`; a customer that is a partner account produces self-billed invoices (numbered per customer, BE-DM-40). [vec: scn.invoice.numbering.001]
- **BE-IV-2** Several subscriptions of one customer are billed on one invoice only when they share the billing entity and the purchase-order number; otherwise the run fails validation (mixed billing entities / mixed purchase-order numbers). An invoice records per subscription its billed boundaries and invoicing reason (`subscription_starting`, `subscription_periodic`, `subscription_terminating`, `in_advance_charge`, `in_advance_charge_periodic`, `progressive_billing`); only `subscription_periodic` counts as *recurring* below. [vec: scn.invoice.lifecycle.003, scn.subscription.downgrade.001]
- **BE-IV-3** The fee types an invoice can carry are `subscription`, `charge` (incl. true-up fees), `fixed_charge`, `commitment` (minimum-commitment true-up), `add_on` (one-off lines) and `credit` (wallet purchase); subscription, charge and fixed-charge amounts come from chapters 05 and 06 and are not recomputed here, the commitment true-up is section 9, one-off lines BE-IV-51 and credit fees BE-IV-52. [vec: none (prose only: a classification; each fee type's amount is pinned by its own rule's vectors)]

## 2. The totals pipeline

The pipeline runs over the invoice's fees once they exist. In the **finalize** context it computes the final
amounts; in the **draft** context (an invoice that will wait for its grace period) it computes a provisional version.

- **BE-IV-4** `fees_amount_cents` = Σ fee `amount_cents` (rounded fee amounts, never precise ones); the running sub-total starts at that value. [vec: invoice.totals.001, invoice.totals.002, invoice.totals.015]
- **BE-IV-5** Order of the steps for a subscription invoice in the finalize context: (1) progressive-billing credits (BE-IV-32), (2) coupons (BE-IV-19..27), only when `fees_amount_cents > 0`, (3) fee taxes (BE-IV-11), (4) invoice taxes (BE-IV-12..14), (5) sub-totals, (6) credit-note credits (BE-IV-30), after taxes, (7) prepaid credits from wallets (BE-IV-31), only when the total is still positive, (8) payment status (BE-IV-9). [vec: invoice.totals.001, invoice.totals.002, invoice.totals.008, invoice.totals.010]
- **BE-IV-6** Draft context (grace period > 0): steps 1, 3, 4, 5 and 8 only — no coupon, no credit-note credit, no prepaid credit is applied, so a draft's total can drop at finalization (RBD-71 keeps this). [vec: invoice.totals.005, scn.invoice.lifecycle.002]
- **BE-IV-7** Variants by invoice type (each step as in BE-IV-5 when present): **pay-in-advance charge invoice** — coupons when `fees_amount_cents > 0` (no context condition), taxes, credit notes, prepaid when the total is positive; no progressive-billing credit, no grace period. **Progressive-billing invoice** — progressive credits, coupons (always attempted), taxes, credit notes, prepaid; always finalized. **One-off invoice** — taxes only (its lines carry explicit tax codes, BE-IV-10); no coupon, credit note or prepaid credit. **Credit invoice** — `fees_amount = sub-total = total` = the credit fee, taxes 0 (chapter 09). **Advance-charges invoice** — attaches already-paid fees, sums their existing taxes (and, per tax code, their existing rounded tax rows) without recomputing them, `taxes_rate = round(taxes × 100 / fees, 2)` (0 when fees are 0), payment status `succeeded`. [vec: invoice.totals.007, invoice.totals.022, scn.invoice.one_off.001, scn.wallet.topup.001, scn.wallet.traceability.003]
- **BE-IV-8** Formulas after the steps: `sub_total_excluding_taxes = fees_amount − progressive_billing_credit − coupons_amount`; `sub_total_including_taxes = sub_total_excluding_taxes + taxes_amount`; `total = sub_total_including_taxes − credit_notes_amount − prepaid_credit_amount`; the total is never negative (each credit is capped by what remains). [vec: invoice.totals.002, invoice.totals.008, invoice.totals.009, invoice.totals.010]
- **BE-IV-9** `payment_status = pending` when the total is > 0, else `succeeded` (an invoice paid entirely by coupons, credit notes or wallets is born paid). [vec: invoice.totals.009, invoice.totals.013]

The subscription-invoice pipeline, as fresh pseudocode:

```
totals(invoice, context):
    invoice.fees_amount = sum(f.amount_cents for f in fees)
    sub = invoice.fees_amount
    sub -= progressive_credits(invoice)                       # BE-IV-32, also adds to fee coupon shares
    if context == finalize and invoice.fees_amount > 0:
        for c in ordered_active_coupons(customer):            # BE-IV-19
            if sub <= 0: break
            sub -= apply_coupon(c, invoice)                   # BE-IV-21..27
    for f in fees: f.taxes = fee_taxes(f)                     # BE-IV-11 / BE-DM-27..29
    rows, taxes, rate = invoice_taxes(fees, sub)              # BE-IV-12..14
    total = sub + taxes
    if context == finalize:
        total -= consume_credit_notes(invoice, total)         # BE-IV-30
        if total > 0: total -= allocate_wallets(invoice, total)   # BE-IV-31, chapter 09
    payment_status = pending if total > 0 else succeeded
```

## 3. Taxes

- **BE-IV-10** Tax selection for a fee — the first non-empty source wins: explicit tax codes (one-off lines) → add-on taxes (add-on fee) → charge taxes (charge fee) → fixed-charge taxes (fixed-charge fee) → commitment taxes (commitment fee) → plan taxes (charge, subscription, commitment and fixed-charge fees) → customer taxes → billing-entity default taxes. A plan tax therefore never reaches a charge fee that has its own taxes, and an add-on fee never takes plan taxes. Credit fees never get a tax. [vec: invoice.fee_tax_selection.001, invoice.fee_tax_selection.002, invoice.fee_tax_selection.003, invoice.fee_tax_selection.004, invoice.fee_tax_selection.005, invoice.fee_tax_selection.006, invoice.fee_tax_selection.007, invoice.fee_tax_selection.010, invoice.totals.002]
- **BE-IV-11** Fee taxes are computed once per fee, **after** coupons (so on `base = amount_cents − precise_coupons_amount_cents`), with the formulas of BE-DM-27..29. Each unrounded row is `t = (base × rate) ⊘ 100`: the product of the exact base and the rate is exact (the rate as given; the reference keeps it in binary64 and reads it back at 16 significant digits), and only the division by 100 is binary64. The row's `amount_cents = round(t)`; the fee's `taxes_amount_cents = round(t_1 ⊕ t_2 ⊕ …)` (rounded once from the unrounded rows); the precise row is `((precise_amount_cents − precise_coupons_amount_cents) × rate) / 100`. The order matters: 180 cents at 17.5 % give 3150 ⊘ 100 = 31.5 → 32, whereas `180 ⊗ (17.5 ⊘ 100)` would be 31.499999999999996 → 31. A fee that already carries tax rows is left untouched. [vec: invoice.apply_taxes.011, invoice.totals.002, invoice.totals.016, invoice.totals.020, invoice.totals.024, invoice.apply_taxes.004, invoice.apply_taxes.006]
- **BE-IV-12** Invoice tax rows: one row per tax code present on any fee, holding the tax's code, name and rate (a snapshot); `fees_amount_cents` of the row = Σ over the fees carrying that tax of `(amount_cents − precise_coupons_amount_cents)`, **truncated** to whole cents; the row's unrounded amount is `c = (Σ_fees (base_f × rate)) ⊘ 100` — the same formula as BE-IV-11 on the untruncated sum of the exact products, only the division being binary64 — and its `amount_cents = round(c)` (two fees of 90 cents at 17.5 %: 3150 ⊘ 100 = 31.5 → 32, while each fee tax is 15.75 → 16). [vec: invoice.apply_taxes.011, invoice.apply_taxes.012, invoice.apply_taxes.001, invoice.apply_taxes.004, invoice.apply_taxes.005, invoice.apply_taxes.008, invoice.apply_taxes.010, invoice.totals.001]
- **BE-IV-13** Invoice `taxes_amount_cents` = `round(c_1 ⊕ c_2 ⊕ …)` over the **unrounded** per-code rows `c` of BE-IV-12: it differs from the sum of the rounded fee taxes (four 1-cent fees at 40 %: fee taxes 0 each, invoice tax 2) and can differ from the sum of the rounded invoice rows (two rows 1411 + 479 on an invoice tax of 1889). RBD-69 keeps this. [vec: invoice.totals.001, invoice.totals.015, invoice.totals.016, invoice.totals.024, invoice.apply_taxes.001, invoice.apply_taxes.004, invoice.apply_taxes.008]
- **BE-IV-14** Invoice `taxes_rate` (informational, never used to compute amounts) = `round5((share_1 ⊗ rate_1) ⊕ (share_2 ⊗ rate_2) ⊕ …)` over the tax codes, where `share = base_code ⊘ sub_total` — the code's untruncated taxable base divided by the invoice's `sub_total_excluding_taxes` — or, when that sub-total is ≤ 0, `share = (number of fees carrying the code) ⊘ (number of fees)`. The share is divided **before** it is multiplied: `(7 ⊘ 160) ⊗ 5.5` = 0.24062499999999998, whereas `(7 × 5.5) ⊘ 160` would be 0.240625. `round5(x)` of a binary64 `x > 0` is: `f = round(x ⊗ 100000)`; if `(f + 0.5) ⊘ 100000 ≤ x` then `f = f + 1`; result `f ⊘ 100000` — so 0.24062499999999998 gives 0.24062 (RBD-68; corrected: exact decimal, 0.240625 → 0.24063). [vec: invoice.apply_taxes.001, invoice.apply_taxes.003, invoice.apply_taxes.003x, invoice.apply_taxes.007]
- **BE-IV-15** When the customer is connected to an external tax provider (out of scope, chapter 14), local taxes are not computed: the invoice gets `tax_status = pending` and, when finalizing, status `pending` (`open` when payment-gated); provider results later fill the per-fee rows (possibly with whole-invoice exemption codes) and a provider error sets `tax_status`/`status` to `failed` (a draft stays draft). A pending tax-identifier check behaves the same way. [vec: none (prose only: depends on out-of-scope tax providers; the interface is chapter 14)]
- **BE-IV-16** Updating or deleting a tax, or changing customer or billing-entity taxes, flags the customer's draft invoices for refresh; finalized invoices keep their tax snapshots. [vec: none (prose only: a catalogue side effect on stored drafts; observable only through the API scenario tier)]

Invoice taxes, as fresh pseudocode (the fee rows are BE-DM-27..29):

```
invoice_taxes(fees, sub_total):
    rows = []; unrounded_total = 0; rate = 0
    for code in tax codes of all fees:
        taxed = [f for f in fees if code in f.taxes]
        base = sum(f.amount_cents - f.precise_coupons for f in taxed)           # exact
        product = sum((f.amount_cents - f.precise_coupons) * rate_of(code) for f in taxed)   # exact
        contrib = product ⊘ 100                                                 # binary64 in compat
        rows.append({code, fees_amount_cents: trunc(base), amount_cents: round(contrib)})
        unrounded_total = unrounded_total ⊕ contrib
        share = base ⊘ sub_total if sub_total > 0 else len(taxed) ⊘ len(fees)    # binary64 in compat
        rate = rate ⊕ (share ⊗ rate_of(code))
    return rows, round(unrounded_total), round5(rate)                           # round5: BE-IV-14
```

## 4. Coupons

A **coupon** is a catalogue object; an **applied coupon** is a coupon attached to a customer, with its own copy of
the amount, currency, percentage rate, frequency and duration (BE-DM entity card), its own status and the remaining
number of periods. Invoices consume applied coupons.

- **BE-IV-17** Creating a coupon: a fixed-amount coupon needs an amount and a currency, a percentage coupon a rate, a recurring coupon a duration (`value_is_mandatory` when missing, on the field); whatever the coupon type, an amount that is given must be > 0 and a currency that is given must be known (a percentage coupon with currency `XXX` is refused), and a recurring coupon's duration must be > 0 (`value_is_out_of_range` when not positive, `value_is_invalid` for an unknown currency, on the field); the percentage rate is not range-checked (150 is accepted); a frequency duration given to a once or forever coupon is kept as given; an expiration instant, when given, must lie in the future whatever `expiration` says (`invalid_date` on `expiration_at`, a `no_expiration` coupon included), and a time-limited coupon without one is accepted; `reusable` defaults to true; a coupon is limited to plans or to billable metrics, never both (`only_one_limitation_type_per_coupon_allowed`), and every limitation code must exist (`plans_not_found`, `billable_metrics_not_found`, field `base`); the coupon is stored with one target per distinct limiting plan or metric. When several checks fail, the first in this order is reported: expiration, unknown plans, unknown metrics, both limitation kinds, then the value checks in the order amount_cents, amount_currency, percentage_rate, frequency_duration. [vec: invoice.coupon_create.*, scn.invoice.coupons.001]
- **BE-IV-18** Applying a coupon to a customer (under a per-customer lock), checks in this order (the first failure is reported): the catalogue coupon must be active (`coupon_not_found`, field `base`); a limited coupon is refused (`plan_overlapping`, field `base`) when an **active** limited applied coupon of the customer shares a target with it — the same plan, the same metric, a plan of one that has a charge on a metric of the other — while unlimited coupons and ended applied coupons never block; a non-reusable coupon is refused once the customer holds any applied coupon of it, whatever that one's status (`coupon_is_not_reusable` on `coupon`). The applied coupon takes each of amount, currency, rate, frequency and duration from the request when given, else from the coupon — so a frequency override without a duration takes the coupon's duration — and its remaining periods = that duration. Its own value checks, whatever the coupon type (a percentage coupon applied with an amount or a currency override is checked like a fixed one), then run in the order amount_cents (≥ 0: an amount of 0 is accepted, a negative one is `value_is_out_of_range`), amount_currency (`value_is_invalid`), frequency_duration (a recurring applied coupon without one: `value_is_mandatory`; ≤ 0: `value_is_out_of_range`); the rate is not range-checked. A fixed-amount coupon gives its currency to a customer that has none; a customer with a currency keeps it. [vec: invoice.coupon_apply.*, scn.invoice.coupons.001]
- **BE-IV-19** Application order on an invoice: the customer's **active** applied coupons (the catalogue coupon's own status is ignored, BE-IV-28), metric-limited first, then plan-limited, then unlimited; within each group by application time (oldest first). Coupons are applied under a per-customer lock. [vec: invoice.coupon_order.001, invoice.coupon_order.002, invoice.coupon_order.003, invoice.totals.001, invoice.totals.012]
- **BE-IV-20** Coupons are attempted only when `fees_amount_cents > 0` (subscription and pay-in-advance invoices), and the loop stops as soon as the running sub-total is ≤ 0: later coupons are not touched (not consumed, no period used). [vec: invoice.totals.003, invoice.totals.011, invoice.totals.013, invoice.totals.018]
- **BE-IV-21** One coupon is skipped — no credit line, no share, no consumption, the applied coupon unchanged — when it is fixed-amount in another currency than the invoice, when it already credited this invoice, or when it has no target fee. A coupon that is not skipped always creates its credit line, even when its amount is 0 (BE-IV-25). [vec: invoice.totals.017, invoice.totals.026]
- **BE-IV-22** Targets and base: a metric-limited coupon targets the **charge** fees of its metrics; a plan-limited coupon targets every fee attached to a subscription of its plans (subscription, charge and other subscription fees); an unlimited coupon targets all fees. The base of a limited coupon is Σ over targets of `(amount_cents − precise_coupons_amount_cents)` (exact, may be fractional); the base of an unlimited coupon is the running invoice sub-total (after progressive credits and earlier coupons). [vec: invoice.coupon_distribution.003, invoice.coupon_distribution.004, invoice.coupon_distribution.005, invoice.coupon_distribution.006, invoice.coupon_distribution.009, invoice.totals.001, invoice.totals.017]
- **BE-IV-23** Coupon amount from the base `B`, using the applied coupon's own values: **percentage** → the rate is divided first, `q = rate ⊘ 100` (binary64); for an **unlimited** coupon `B` is the invoice's integer sub-total and `v = B ⊗ q` (binary64 product), for a **limited** coupon `B` is the decimal sum of BE-IV-22 — a decimal even when its value is whole — and `v = B × dec16(q)` (exact product); amount = `B` when `v ≥ B`, else round(v) to whole cents. Unlike a tax row (BE-IV-11), the rate is divided by 100 **before** the multiplication; **fixed recurring or forever** → min(amount, B); **fixed once** → min(remaining, B) with remaining = amount − Σ credits this applied coupon made on invoices that are not voided, closed or deleted. A binary64 product can fall just under a half: 17.5 % of 180 cents is `180 ⊗ 0.175` = 31.499999999999996 → 31 for an unlimited coupon (RBD-68, corrected 32), while a metric-limited coupon on a 180-cent fee gives `180 × 0.175` = 31.5 → 32 (`invoice.coupon_distribution.013`), as does a 17.5 % tax on the same 180 cents (`invoice.apply_taxes.011`). [vec: invoice.coupon_distribution.013, invoice.coupon_amount.001, invoice.coupon_amount.002, invoice.coupon_amount.003, invoice.coupon_amount.004, invoice.coupon_amount.005, invoice.coupon_amount.007, invoice.coupon_amount.008, invoice.coupon_amount.010, invoice.coupon_amount.010x, invoice.totals.003, invoice.totals.011, invoice.totals.019, invoice.totals.020]
- **BE-IV-24** The credit row stores the amount as integer cents: a fractional amount (a limited coupon whose base is fractional and smaller than its value) is **truncated** toward zero in the credit and in the invoice's coupon total, while the distribution of BE-IV-25 uses the untruncated amount. [vec: invoice.coupon_amount.009]
- **BE-IV-25** Distribution: for each target fee, `share = (amount × (amount_cents − precise_coupons)) ⊘ B` — the product is exact and is divided by the base afterwards (binary64 for an unlimited coupon, whose `B` is the integer sub-total; a decimal division for a limited coupon, whose `B` is a decimal): 27 cents over fees of 13 and 179 give `351 ⊘ 192` = 1.828125 → 1.82813, whereas `27 ⊗ (13 ⊘ 192)` = 1.8281249999999998 would store 1.82812. The share is added to the fee's `precise_coupons_amount_cents` (as `dec16(share)` when it is binary64), the sum stored at 5 decimal places (half away) after each coupon and capped at the fee's `amount_cents`. Nothing is distributed when `B = 0`, yet the coupon still credits 0 and is consumed (BE-IV-27: a once percentage coupon is terminated by its zero credit, a fixed once coupon stays active). [vec: invoice.coupon_distribution.001, invoice.coupon_distribution.003, invoice.coupon_distribution.005, invoice.coupon_distribution.009, invoice.coupon_distribution.010, invoice.coupon_distribution.012, invoice.totals.001, invoice.totals.002, invoice.totals.003, invoice.totals.024, invoice.totals.026]
- **BE-IV-26** After each coupon: invoice `coupons_amount_cents += credit`, running sub-total `−= credit`; the credit row is a before-tax credit. [vec: invoice.coupon_distribution.001, invoice.totals.003]
- **BE-IV-27** Consumption after a credit: **recurring** → remaining periods − 1 (not below 0), terminated when 0; **once** → terminated when percentage, or when the credit ≥ the remaining amount (a fixed once coupon larger than the invoice stays active and continues on the next invoice); **forever** → never terminated. A credit of 0 (BE-IV-25) consumes like any other: a once percentage coupon is terminated by it. [vec: invoice.coupon_distribution.001, invoice.coupon_distribution.004, invoice.coupon_distribution.008, invoice.coupon_distribution.011, invoice.totals.011, invoice.totals.018, invoice.totals.019, invoice.totals.020, invoice.totals.026]
- **BE-IV-28** Expiry: a time-limited coupon whose expiration has passed is terminated by the clock, but its applied coupons stay **active** and keep applying (only the applied coupon's own status is checked; RBD-72, verified). [vec: invoice.totals.012]
- **BE-IV-29** Re-credit on void: for each coupon credit of a voided invoice, an applied coupon that is terminated, not `forever`, and whose catalogue coupon is still active is re-activated; independently, every `recurring` applied coupon gets one period back (remaining + 1, also when it was still active); a fixed once coupon regains its amount implicitly because credits on voided invoices no longer count (BE-IV-23). [vec: invoice.void.003]
- **BE-IV-58** Coupon catalogue side effects: a plan limitation also covers the plan's overrides (child plans) when targets are chosen (BE-IV-22); once a coupon has been applied to anyone only its name, description and expiration can change; deleting a coupon terminates its active applied coupons. [vec: none (prose only: catalogue updates and deletions; no vector or scenario exercises them)]

One coupon on an invoice, as fresh pseudocode:

```
apply_coupon(c, invoice):
    if c.type == fixed and c.currency != invoice.currency: return 0          # BE-IV-21
    if invoice already holds a credit of c: return 0
    targets = metric_fees(c) if c.metric_limited else plan_fees(c) if c.plan_limited else invoice.fees
    if not targets: return 0
    B = sum(f.amount_cents - f.precise_coupons for f in targets) if c.limited else invoice.sub_total
    amount = coupon_amount(c, B)                                              # BE-IV-23
    credit_row(amount_cents = trunc(amount))                                  # BE-IV-24
    for f in targets:
        # ⊘ below is binary64 for an unlimited coupon (integer B), a decimal division for a limited one (BE-IV-25)
        if B != 0: f.precise_coupons = round5(f.precise_coupons + dec16((amount * (f.amount_cents - f.precise_coupons)) ⊘ B))
        f.precise_coupons = min(f.precise_coupons, f.amount_cents)
    consume(c, amount)                                                        # BE-IV-27
    return trunc(amount)
```

## 5. Credits applied after taxes

- **BE-IV-30** Credit-note credits (finalize context): the customer's finalized credit notes with an `available` credit status, in the invoice currency, issued on **other** invoices, oldest first; each takes `min(balance, remaining)` where `remaining` starts at the post-tax total; its balance decreases and the note becomes `consumed` at 0; each fee then gets `precise_credit_notes_amount_cents += dec16((credit × (amount_cents − precise_coupons_amount_cents + taxes_amount_cents − precise_credit_notes_amount_cents)) ⊘ remaining)`, where `taxes_amount_cents` is the fee's **rounded** tax (a 1-cent fee whose precise tax is 0.56 adds no tax), the product is exact, the division by `remaining` (the amount still to cover before this note) is binary64 (27 over fees of 13 and 179 gives 1.82813 and 25.17188), and the sum is stored at 5 places and capped at the fee's after-tax amount; applied at most once per invoice. A note in another currency is not used. [vec: invoice.totals.009, invoice.totals.010, invoice.totals.023, invoice.totals.027, invoice.totals.028]
- **BE-IV-31** Prepaid credits come last, only when the total is still positive: the customer's active wallets in the invoice currency with a positive balance, in application order (priority ascending, then creation time, BE-WL-40), cover the remaining total (allocation by fee type and metric, traceability and the granted/purchased split: chapter 09). [vec: invoice.totals.007, invoice.totals.010, invoice.totals.015, scn.invoice.prepaid.001]
- **BE-IV-32** Progressive-billing credits (subscription and progressive invoices): the amount already billed for the period by the latest progressive-billing invoice of the subscription — its fees amount minus its own coupons, minus what earlier invoices already took from it and its credit notes (BE-PB-21; BE-PB-20..24 decide the amount and the over-credit note) — is credited before coupons, capped at the current invoice's fees of the same charges; each matching charge fee (same charge, filter and grouping) gets the progressive fee's amount added to its coupon share (capped at its amount), so it also leaves the tax base. [vec: invoice.totals.008, scn.invoice.progressive.001]

## 6. Lifecycle

| From | Event | To |
|---|---|---|
| `generating` | grace period > 0 and not payment-gated | `draft` |
| `generating` | payment-gated and (total > 0 or tax pending) | `open` |
| `generating` | tax provider pending | `pending` |
| `generating` | otherwise: fees ≠ 0, or zero-amount finalization allowed | `finalized` |
| `generating` | fees = 0 and zero-amount finalization disabled | `closed` (invisible, no webhook) |
| `draft` | finalize (API, or clock when the expected finalization date is reached) | `finalized` (recomputed) |
| `draft` | delete | `deleted` |
| `finalized` | void | `voided` |
| `open` | payment succeeds / gating fails | `finalized` / `closed` |
| `failed` | retry | `pending` / `open` |

- **BE-IV-33** Generated status of a subscription invoice: `draft` when the customer's effective grace period (BE-DM-11) is > 0 and the invoice is not payment-gated; otherwise the final-status rule BE-IV-34. [vec: invoice.final_status.006, invoice.final_status.007, invoice.final_status.011]
- **BE-IV-34** Final-status rule: a payment-gated invoice with a total > 0 or pending tax stays `open`; otherwise the invoice is `finalized` when `fees_amount_cents ≠ 0` — the rule looks at the fees, not the total, so a fully discounted invoice is still finalized — and with zero fees it is finalized when the customer setting is `finalize`, or `inherit` and the billing entity allows zero-amount finalization (default), else `closed` (RBD-70 keeps this). [vec: invoice.final_status.001, invoice.final_status.003, invoice.final_status.004, invoice.final_status.005, invoice.final_status.006, invoice.final_status.007, invoice.final_status.009, invoice.final_status.010, invoice.final_status.011]
- **BE-IV-35** Finalization assigns the number (BE-DM-37..42), sets `finalized_at` once, finalizes the draft credit notes of the invoice and emits `invoice.created` (not for `closed`). [vec: scn.invoice.numbering.001]
- **BE-IV-36** Issuing date at generation: `date` = the local date (customer's zone) of the billing instant. For subscription invoices that are neither payment-gated nor pay-in-advance-charge invoices, `issuing_date = date + adjustment`: non-recurring → the grace period; recurring → by (anchor, adjustment): (`current_period_end`, `keep_anchor`) −1 day; (`current_period_end`, `align_with_finalization_date`) + grace, or −1 when the grace is 0; (`next_period_start`, `keep_anchor`) 0; (`next_period_start`, `align_with_finalization_date`) + grace. Customer values win over billing-entity values (defaults `next_period_start` + `align_with_finalization_date`). Other invoices: `issuing_date = date`. [vec: invoice.issuing_date.001, invoice.issuing_date.002, invoice.issuing_date.003, invoice.issuing_date.004, invoice.issuing_date.005, invoice.issuing_date.006, invoice.issuing_date.008, invoice.issuing_date.009, invoice.issuing_date.010]
- **BE-IV-37** At generation, `expected_finalization_date = date + grace period` for the same subscription invoices (else `date`), and `payment_due_date = issuing_date + net payment term` (effective customer → billing-entity value). [vec: invoice.issuing_date.001, invoice.issuing_date.002, invoice.issuing_date.003, invoice.issuing_date.004, invoice.issuing_date.005, invoice.issuing_date.006, invoice.issuing_date.012]
- **BE-IV-38** At finalization of a draft: the issuing date becomes **today** (local date in the customer's zone) unless the invoice is recurring and the effective adjustment is `keep_anchor` (then the drafted date stays); `payment_due_date = issuing_date + net payment term`. [vec: invoice.payment_due_date.001, invoice.payment_due_date.002, invoice.payment_due_date.004]
- **BE-IV-39** Drafts are **not** refreshed by new events: they are recomputed (fees rebuilt from the billing boundaries) when refreshed through the API, when a manual fee adjustment is created or removed, when the clock sweeps drafts flagged by catalogue changes (every 5 minutes), and at finalization. The finalize clock (hourly) picks drafts whose expected finalization date (else issuing date) is on or before today, refuses tax-pending drafts, recomputes in the finalize context and applies BE-IV-34. [vec: scn.invoice.lifecycle.002, scn.invoice.numbering.001]
- **BE-IV-40** An invoice is numbered only when it becomes finalized (BE-DM-37..42); drafts show `<prefix>-DRAFT`. [vec: domain.numbering.invoice_number.*, scn.invoice.numbering.001]
- **BE-IV-41** Void: any `finalized` invoice can be voided — the model predicate "voidable" (finalized, payment pending or failed, nothing paid, no lost dispute, no live credit note) is **not** enforced (RBD-73, verified: a fully paid invoice is voided). Voiding sets `voided_at`, clears the overdue flag, flags lifetime usage for recomputation, re-credits coupons (BE-IV-29), and without credit-note generation returns wallet usage of the invoice to the wallets as granted credits (chapter 09). A non-finalized invoice cannot be voided (`not_voidable`). [vec: invoice.void.001, invoice.void.003, scn.invoice.void.001]
- **BE-IV-42** Void with credit-note generation (premium): requested `credit` and `refund` must satisfy credit ≤ creditable, refund ≤ refundable and credit + refund ≤ creditable (BE-IV-48), else `total_amount_exceeds_invoice_amount` on `credit_refund_amount`; when credit + refund > 0 a note is created with the requested credit and refund whose items are every fee's remaining creditable amount `c_f` scaled as `c_f ⊗ ((credit + refund) ⊘ T)`, where `T` is the maximum creditable amount of an estimate (BE-CN-14) over all those items; the item is kept fractional (BE-CN-5), its binary64 value stored at 5 places by `round5` (BE-IV-14; notation paragraph above) (999 ⊗ (500 ⊘ 1199) → 416.59716, cents 417; 267 ⊗ (7 ⊘ 320) = 5.840624999999999 → 5.84062, where the exact 5.840625 would store 5.84063, RBD-68; just below a tie, 533 ⊗ (14 ⊘ 640) = 11.659374999999999 → 11.65938, cents 12, where rounding the text would store 11.65937: `invoice.void.009`); then, when the invoice's creditable amount (BE-IV-48) rounded is still > 0, a second note is created with the items and the maximum creditable amount (as credit) of a fresh estimate over the remaining items, and immediately voided (BE-CN-20). The amount checks compare with the creditable and refundable values as BE-IV-47/48 compute them (binary64 in compat). [vec: invoice.void.002, invoice.void.004, invoice.void.006, invoice.void.007, invoice.void.008, invoice.void.008x, invoice.void.009]
- **BE-IV-43** Only drafts can be deleted (status `deleted`, their draft credit notes deleted too). [vec: none (prose only: an API state change without amounts)]
- **BE-IV-44** A voided invoice can be regenerated: a new invoice of the same type, customer, currency and billing entity, linked to the voided one, receives copies of the voided invoice's subscription lines and of the fees named in the request only (each copy with its tax and coupon shares reset, optionally with new units or a new unit amount through the manual fee-adjustment path); it then runs the finalize-context pipeline (progressive credits, coupons when fees > 0, taxes, credit-note and prepaid credits when the total is positive), takes today's local date as issuing date (due date = issuing date + net payment term) and gets its status by BE-IV-34. [vec: none (prose only: needs a voided invoice plus the manual fee-adjustment machinery, which this kit does not specify; no vector or scenario exercises it)]
- **BE-IV-45** Overdue: hourly, a finalized invoice that is not paid, not disputed and whose due date is before now is flagged overdue and emits a webhook (chapter 13). [vec: none (prose only: clock behaviour, chapter 13)]

## 7. Amounts that bound credit notes

- **BE-IV-46** `total_due = 0` when voided, else `total − total_paid − Σ offsets of finalized credit notes` (it can go negative when offsets exceed what is unpaid). [vec: invoice.available_to_credit.007, invoice.available_to_credit.009, invoice.available_to_credit.010]
- **BE-IV-47** Available to credit = 0 for invoices of version < 2 and for drafts; else with `F` = Σ fee creditable amounts `c_f` (amount − earlier credit-note items on the fee), `adj = ((coupons + progressive credit) ⊘ fees_amount) ⊗ F` (0 for version < 3) and `vat = round((Σ⊕_fee ((c_f − adj ⊗ (c_f ⊘ F)) ⊗ r_f)) ⊘ 100)` with `r_f` the fee's `taxes_rate` and `Σ⊕` a binary64 sum: available = `(F − adj) + vat` in binary64, so it can be non-integer: `(14 ⊘ 25) ⊗ 25` = 14.000000000000002 gives 12.999999999999998 (RBD-68, corrected 13). The tax part divides the summed products by 100 last, as a tax row does (180 at 17.5 % → 3150 ⊘ 100 = 31.5 → 32). 0 when `F = 0`. [vec: invoice.available_to_credit.001, invoice.available_to_credit.003, invoice.available_to_credit.005, invoice.available_to_credit.006, invoice.available_to_credit.006x, invoice.available_to_credit.012]
- **BE-IV-48** `creditable = 0` for credit invoices, else available-to-credit; `offsettable = total` for a credit invoice with a positive due whose payment is `pending` or `failed`, else `min(due, creditable)`; `refundable = 0` for version < 2, drafts, and invoices whose payment is not `succeeded` while fully paid; else, with `R` = Σ refunds of **all** the invoice's notes whatever their status and credit status (a voided note's refund still counts, while BE-IV-46 counts the offsets of finalized notes only): for a credit invoice `min(wallet-backed amount, total_paid − R)` — the wallet-backed amount is 0 unless the purchase's wallet is active, then the purchase's remaining amount on a traceable wallet, else the wallet balance (chapter 09) —, otherwise `min(total_paid − R, creditable)`, not below 0. [vec: invoice.available_to_credit.006, invoice.available_to_credit.006x, invoice.available_to_credit.007, invoice.available_to_credit.008, invoice.available_to_credit.009, invoice.available_to_credit.011]
- **BE-IV-49** `fee_total = Σ fee amount_cents + round((Σ⊕_fee (amount_cents ⊗ r_f)) ⊘ 100)` with `r_f` the fee's `taxes_rate` — products summed first, divided by 100 last (180 at 17.5 % → 212) — used by credit-note validation. [vec: invoice.available_to_credit.007, invoice.available_to_credit.012]
- **BE-IV-50** The voidable predicate (informational): finalized, payment pending or failed, nothing paid, no lost dispute and no credit note that is not voided. [vec: invoice.available_to_credit.007, invoice.available_to_credit.008, invoice.available_to_credit.009, invoice.void.001]

## 8. Fees as the invoice sees them

- **BE-IV-51** One-off (add-on) fee: `unit = line unit amount, else the add-on amount`; `units = line units, else 1`; `amount_cents = round(unit × units)`, precise = `unit × units`; taxes from the line's explicit codes, else BE-IV-10; boundaries default to the creation instant. [vec: scn.invoice.one_off.001, scn.invoice.one_off.002]
- **BE-IV-52** Credit (wallet purchase) fee: amount = the purchase amount, units = credits, unit amount = the wallet rate; never taxed, so its credit invoice has `fees_amount = sub_total = total` (chapter 09). [vec: scn.wallet.topup.001, scn.wallet.traceability.003]
- **BE-IV-53** A fee's taxable sub-total is `amount_cents − precise_coupons_amount_cents` (integer minus decimal) and its precise variant `precise_amount_cents − precise_coupons_amount_cents`; fee total = amount + taxes. [vec: invoice.apply_taxes.005, invoice.apply_taxes.006]

## 9. Minimum commitment (plan)

A plan may carry one **minimum commitment**: an amount in cents (> 0) per full plan period, with its own optional taxes;
the API stores it only with the premium licence and silently drops it otherwise (RBD-97). When the fees billed for a
period stay below the prorated commitment, the subscription invoice receives a `commitment` fee for the difference.
A *subscription line* below is what BE-IV-2 records per subscription on an invoice: its billed boundaries (subscription,
charges and fixed-charges windows) and its invoicing reason. Worked example (weekly calendar plan of 1,000 EUR in
arrears, commitment 10,000 EUR, start on Wednesday 1 February 2023): the first period covers 5 of 7 days, so the
commitment is 1,000,000 × 5/7 = 714,285.71 → 714,286 cents; the subscription fee of those 5 days is 71,429; the true-up
is 714,286 − 71,429 = 642,857 cents.

- **BE-IV-54** Reconciled period and prorated commitment: for each subscription of a subscription invoice, the *reconciled line* is the invoice's own subscription line for an arrears plan, and for an advance plan the subscription's previous line (the latest earlier line that billed a subscription fee, i.e. the period paid in advance on the previous invoice). The *commitment period* is the full plan period (BE-SP-10, customer zone; the whole year of a yearly plan even when its charges are billed monthly) that contains the reconciled line. `C = round(amount_cents ⊗ (covered ⊘ length))` — the day ratio first, then the product, both binary64, rounded half away from the result's text — where `length` = the BE-DM-15 day count of the whole commitment period and `covered` = the BE-DM-15 day count from the start of the subscription's earliest line inside the commitment period (lines ordered by their end; normally the subscription's start or the period start) to the end of the reconciled line, or to the termination instant (capped at the period end) when the subscription is terminated. The binary64 ratio can fall under a half: 75 cents over 11 of 30 days is `75 ⊗ (11 ⊘ 30)` = 27.499999999999996 → 27, where exact arithmetic gives 27.5 → 28 (RBD-52). Days are local calendar days of the customer's zone: a Tokyo customer starting on 16 March covers 16 of 31 days. [vec: invoice.commitment.001, invoice.commitment.005, invoice.commitment.006, invoice.commitment.008, invoice.commitment.009, invoice.commitment.010, invoice.commitment.010x, scn.commitment.arrears.001, scn.commitment.advance.001]
- **BE-IV-55** Fees counted and true-up: `F` = Σ `amount_cents` of the subscription's fees billed for a window that lies inside the commitment period (starts at or after its start and ends at or before its end), whatever invoice carries them: subscription fees, charge fees (arrears, pay in advance, recurring pay-in-advance fees without invoice, charge true-ups) and fixed-charge fees (arrears and pay in advance); earlier commitment fees are not counted. When `F < C` the true-up is `amount_cents = C − F` and `precise_amount_cents = C − Σ precise_amount_cents` of the same fees; when `F ≥ C` nothing is billed (fees equal to the commitment bill nothing). [vec: invoice.commitment.001, invoice.commitment.003, invoice.commitment.004, invoice.commitment.008, scn.commitment.arrears.001, scn.commitment.termination.001]
- **BE-IV-56** When it is billed: on subscription invoices of billing runs (start, periodic, termination; a starting run exists only for advance plans, BE-SP-49 and BE-SP-61, and by (b) never carries one), never on progressive-billing or one-off invoices nor in current usage, and only when (a) the plan has a commitment; (b) for an advance plan, the subscription has a previous line (nothing on its first invoice); (c) for a yearly or semiannual plan, the invoice also bills the subscription fee (BE-SP-47), so the monthly invoices of monthly-billed charges carry none and the yearly invoice reconciles the whole year; (d) the true-up is > 0; (e) the invoice holds no commitment fee for this subscription yet. An advance plan therefore pays the commitment of a period on the next period's invoice, and its termination invoice reconciles the period cut short by the termination, the subscription fee already paid in advance for that period counting in `F`. [vec: invoice.commitment.008, scn.commitment.advance.001]
- **BE-IV-57** The commitment fee: `fee_type = commitment`, linked to the plan's commitment (its invoice display name), `units = 1`, `unit_amount_cents = amount_cents`, `precise_unit_amount = amount_cents / 10^e` (binary64 division), no events, boundaries = the reconciled line's start and end (for an advance plan, the previous line's full period, also on termination). It is taxed like any fee (BE-IV-10: commitment taxes, else plan taxes, then customer and billing-entity taxes; BE-IV-11), counts in `fees_amount_cents` and goes through every later step of the pipeline (a plan-limited coupon targets it, BE-IV-22). [vec: invoice.commitment.001, invoice.commitment.004, invoice.fee_tax_selection.006, invoice.fee_tax_selection.010]

The true-up of one subscription line, as fresh pseudocode:

```
commitment_true_up(invoice, line):
    plan = line.subscription.plan
    if plan.commitment is none: return none
    rec = line if plan.in_arrears else previous_line_with_subscription_fee(line)       # BE-IV-54
    if rec is none: return none                                                        # BE-IV-56 (b)
    if plan.interval in (yearly, semiannual) and not bills_subscription_fee(invoice, line): return none
    P = full_plan_period_containing(rec)                                                # customer zone
    first = earliest line of the subscription whose start is inside P
    stop = min(termination, P.end) if line.subscription.terminated else rec.end
    C = round(plan.commitment.amount_cents ⊗ (days(first.start, stop) ⊘ days(P.start, P.end)))        # binary64 (RBD-52)
    counted = [f for f in subscription fees billed for a window inside P if f.type != commitment]
    F = sum(f.amount_cents for f in counted)
    if F >= C or invoice already holds a commitment fee of this subscription: return none
    return fee(type = commitment, amount_cents = C - F, precise_amount_cents = C - sum(f.precise for f in counted),
               units = 1, unit_amount_cents = C - F, bounds = (rec.start, rec.end))
```

## 10. Rebuild decisions touching this chapter

| RBD | Behaviour at the pin | Compat | Corrected |
|---|---|---|---|
| RBD-68 | tax rate shares, coupon percentages, coupon/credit-note shares, void items and the creditable amount use binary64 (section 10.1) | `invoice.apply_taxes.003`, `invoice.coupon_amount.010`, `invoice.available_to_credit.006`, `invoice.void.008` | exact decimal (twins `…x`, ruling proposed); the tax rows of BE-IV-11/12 already divide exact products, so their vectors are `both` |
| RBD-69 | invoice tax ≠ Σ fee taxes ≠ Σ rounded rows | KEEP | KEEP |
| RBD-70 | zero-amount rule tested on fees, not total | KEEP | KEEP |
| RBD-71 | coupons, credit notes, wallets only at finalization | KEEP | KEEP |
| RBD-72 | expired coupons' applied coupons keep applying (verified) | KEEP | owner |
| RBD-73 | void does not enforce the voidable predicate (verified) | KEEP | owner |
| RBD-52 | the commitment proration is a binary64 ratio, rounded half up (BE-IV-54; the charge-minimum true-up of chapter 05 is the main case) | `invoice.commitment.010` (75 ⊗ (11 ⊘ 30) → 27); `invoice.commitment.005` is exact in binary64 (15 ⊘ 30 = 0.5) and stays `both` | exact decimal (proposed): twin `invoice.commitment.010x` (28) |

### 10.1 Binary64 islands at a glance

Each island with its exact evaluation order (notation: reading guide) and the vector that tells the order apart from
the obvious alternatives. The corrected profile evaluates the same formulas exactly.

| Rule | Island (compat) | Discriminating vector |
|---|---|---|
| BE-IV-11, BE-DM-27 | fee tax row `(base × rate) ⊘ 100`; fee tax `round(t_1 ⊕ t_2 ⊕ …)` | `invoice.apply_taxes.011` (180 at 17.5 % → 32, not 31) |
| BE-IV-12, BE-IV-13 | invoice tax row `(Σ_fees (base_f × rate)) ⊘ 100`; invoice tax `round(c_1 ⊕ c_2 ⊕ …)` | `invoice.apply_taxes.012` |
| BE-IV-14 | `round5(Σ⊕ ((base_code ⊘ sub_total) ⊗ rate))` | `invoice.apply_taxes.003` (0.24062, not 0.24063) |
| BE-IV-23 | unlimited coupon `B ⊗ (rate ⊘ 100)` on the integer sub-total; a limited coupon multiplies its decimal base exactly by `dec16(rate ⊘ 100)` | `invoice.coupon_amount.010` (31, not 32); `invoice.coupon_distribution.013` (limited: 32) |
| BE-IV-25 | coupon share `dec16((amount × fee_base) ⊘ B)` (unlimited coupon; a decimal division for a limited one) | `invoice.coupon_distribution.012` (1.82813, not 1.82812) |
| BE-IV-30 | credit-note share `dec16((credit × fee_rest) ⊘ remaining)`, fee rest with the rounded fee tax | `invoice.totals.027`, `invoice.totals.028` |
| BE-IV-42 | void items `c_f ⊗ ((credit + refund) ⊘ T)`, stored at 5 places | `invoice.void.008` (5.84062, not 5.84063); `invoice.void.007` pins the 5-place storage (416.59716); `invoice.void.009` pins `round5` just below a tie (11.65938, not 11.65937) |
| BE-IV-47 | `adj = ((coupons + progressive credit) ⊘ fees_amount) ⊗ F`; tax part divides summed products by 100 last | `invoice.available_to_credit.006` (12.999999999999998), `invoice.available_to_credit.012` |
| BE-IV-49 | `round((Σ⊕ (amount ⊗ r_f)) ⊘ 100)` | `invoice.available_to_credit.012` (212) |
| BE-IV-54 | `round(amount ⊗ (covered ⊘ length))` | `invoice.commitment.010` (27, not 28) |
| BE-IV-57 | `precise_unit_amount = amount_cents ⊘ 10^e` | `invoice.commitment.001` (pins it; a whole number of cents divided by 10^e reads back exactly, so no input tells it from exact division) |

## 11. Edge cases (people get these wrong)

| Case | Rule |
|---|---|
| Invoice tax is not the sum of fee taxes, nor of the rounded invoice rows | BE-IV-13 |
| An invoice tax row's taxable base is truncated, its amount is not | BE-IV-12 |
| Coupons, credit notes and wallets never touch a draft; the total drops at finalization | BE-IV-6 |
| A fully discounted invoice with fees > 0 is finalized, not closed | BE-IV-34 |
| The second coupon is skipped entirely once the sub-total reaches 0 (no period used) | BE-IV-20 |
| Limited coupon base excludes earlier coupon shares; unlimited base is the running sub-total | BE-IV-22 |
| A fractional limited-coupon amount is truncated in the credit but distributed in full | BE-IV-24 |
| 17.5 % of 180 cents is 31 cents as an unlimited coupon (rate divided first, binary64 product) but 32 as a limited coupon (exact product of a decimal base) and 32 as a tax (product divided last) | BE-IV-23, BE-IV-11 |
| A limited coupon whose targets total 0 still writes a credit line of 0 and is consumed | BE-IV-21, BE-IV-25 |
| Credit-note shares use the fee's rounded tax, not its precise tax | BE-IV-30 |
| A voided credit note's refund still lowers the refundable amount | BE-IV-48 |
| 75 cents over 11 of 30 days is a 27-cent commitment (binary64), not 28 | BE-IV-54 |
| An expired coupon keeps applying through its applied coupon | BE-IV-28 |
| A non-reusable coupon stays refused after its first applied coupon ended; a metric-limited coupon overlaps a plan-limited one through the plan's charges | BE-IV-18 |
| A paid invoice can be voided | BE-IV-41 |
| `current_period_end` + `keep_anchor` dates a recurring invoice the day before the billing day | BE-IV-36 |
| The available-to-credit amount can be a non-integer | BE-IV-47 |
| An advance plan's commitment is billed on the next period's invoice, never on the first one | BE-IV-56 |
| Fees exactly equal to the commitment bill no true-up; the commitment is prorated over local days of the customer's zone | BE-IV-54, BE-IV-55 |
| A yearly plan with monthly charges reconciles the commitment once a year, counting the monthly charge fees | BE-IV-56 |

## 12. Vectors

| File | Ops | Vectors |
|---|---|---|
| `invoice.totals.jsonl` | `invoice.totals` | 28 |
| `invoice.taxes.jsonl` | `invoice.apply_taxes`, `invoice.fee_tax_selection` | 23 (one corrected twin) |
| `invoice.coupons.jsonl` | `invoice.coupon_amount`, `invoice.coupon_order`, `invoice.coupon_distribution`, `invoice.coupon_create`, `invoice.coupon_apply` | 63 (one corrected twin) |
| `invoice.lifecycle.jsonl` | `invoice.final_status`, `invoice.issuing_date`, `invoice.payment_due_date`, `invoice.available_to_credit`, `invoice.void` | 50 (two corrected twins) |
| `invoice.commitment.jsonl` | `invoice.commitment_true_up` | 11 (one corrected twin) |

Evidence: every `both`/`compat` vector is EXECUTED through the oracle adapter at the pin (spec-derived values were
first checked against the reference examples); the five corrected twins are RECOMPUTED with exact decimals (`ruling:
proposed`; RBD-68 for four, RBD-52 for `invoice.commitment.010x`). Run them with `python3 reimplementation-kit/scripts/kitrun.py --impl-cmd "<adapter>" --areas
invoice`.

## Provenance (maintainers)

Executed 2026-10-02 on the pinned toolchain (Ruby 4.0.6, database `lago_api_test_a7`): `oracle.sh run` over the
coupon-breakdown, taxes-on-invoice, credit-note, credit-note-rounding, invoice-numbering, void-invoice and one-off
scenario specs and 21 service specs of invoices, credits, credit notes, fees and applied coupons →
`{"example_count":354,"failure_count":0}`; `spec/models/{invoice,credit_note,fee,applied_coupon}_spec.rb` with
ClickHouse (under the shared lock) → `{"example_count":450,"failure_count":0}`. kitrun of the invoice and credit-note
vectors against `oracle.sh adapter` → `SUMMARY kitrun: areas=2 pass=2 fail=0 vectors=151 passed=151 skipped_ops=0
exit=0` (compat); the independent model `scripts/maintainer/recompute-invoicing.py` → 151/151 compat and the three
corrected twins PASS. Oracle modules: `reimplementation-kit/scripts/maintainer/oracle-adapter/ops/{invoice,credit_note}.rb`.

Fix round of 2026-10-02 (database `lago_api_test_fr5`): `oracle.sh run -j 1` over
`spec/scenarios/commitments/minimum/{in_arrears,in_advance}_spec.rb`, `spec/scenarios/commitments/minimum/in_arrears/calendar/yearly_spec.rb`,
`spec/services/coupons/create_service_spec.rb`, `spec/services/applied_coupons/create_service_spec.rb` and
`spec/services/credit_notes/adjust_amounts_with_rounding_service_spec.rb` → `{"example_count":137,"failure_count":0}`.
Three ops added. `invoice.commitment_true_up` runs real billing
runs through the subscription invoice service (no stand-in); its values reproduce the reference examples
`$API/spec/scenarios/commitments/minimum/in_arrears_spec.rb:83` (642,857) and
`$API/spec/scenarios/commitments/minimum/in_advance_spec.rb:131` (642,857, 900,000, 328,571), and the other cases were
hand-checked against BE-IV-54..56 (for example 1,000,000 × 302/366 − 8,251 − 200 = 816,686 for the yearly plan).
`invoice.coupon_create` and `invoice.coupon_apply` call the coupon and applied-coupon creation services; their error
codes match `$API/spec/services/coupons/create_service_spec.rb:104` and `:285` and
`$API/spec/services/applied_coupons/create_service_spec.rb:136`, `:167`, `:185`, `:211`, `:221`, `:233`, `:246`. kitrun of
the invoice and credit-note vectors against `oracle.sh adapter` → `invoice 142 PASS`, `credit_notes 39 PASS` (all
`both`/`compat` vectors, run twice for the new ones); `recompute-invoicing.py` → 172/172 compat and the six corrected
twins PASS (`--only '^(?!invoice\.commitment\.)'`: the model does not run billing periods). Evidence caveat: the
`invoice.totals` vectors whose point is the orchestration (`invoice.totals.005`, `.006`, `.007`, `.013`, `.022`) are
executed by the module's mirror of the invoice services' step order, every step being the reference service.

Fix round of 2026-10-05 (database `lago_api_test_fr2g4`; every new vector below run through `oracle.sh adapter` at least
twice). Island orders read from `$API/app/services/fees/apply_taxes_service.rb:37` (tax row: exact product, then a
binary64 division), `$API/app/services/invoices/apply_taxes_service.rb:78-101` (invoice row and rate share),
`$API/app/services/applied_coupons/amount_service.rb:27` (coupon: rate divided first), `$API/app/models/fee.rb:232-236`
(coupon share), `$API/app/services/credits/credit_note_service.rb:104-114` (credit-note share with the rounded fee tax),
`$API/app/models/invoice.rb:244-248` and `:368-390`, `$API/app/services/invoices/void_service.rb:137-150`,
`$API/app/services/commitments/calculate_prorated_coefficient_service.rb:57` with
`$API/app/services/commitments/calculate_amount_service.rb:25-34`; each was then pinned by an executed discriminating
input: 180 cents at 17.5 % → tax 32 but coupon 31 (`invoice.apply_taxes.011`, `invoice.coupon_amount.010`), 27 over 13
and 179 → 1.82813 (`invoice.coupon_distribution.012`, `invoice.totals.028`), 75 × 11/30 → commitment 27 (also probed:
45 × 13/90 → 6 and 225 × 23/90 → 57 on quarterly plans). Conversion rules probed on the pinned Ruby/BigDecimal 4.1.2:
a binary64 entering a decimal product or sum keeps its shortest text cut to 16 digits (27.499999999999996 →
27.49999999999999, 0.30000000000000004 → 0.3); a binary64 stored in a 5-place column is rounded by the runtime's
float rounding to 5 places (`round5` of BE-IV-14) before the decimal cast (0.015624999999999999 → 0.01562,
27.499999999999996 → 27.5; just below a tie 1.5443449999999999 → 1.54435 and 11.659374999999999 → 11.65938, where
rounding the text would give 1.54434 and 11.65937: probed on 2026-10-05 with the pinned Ruby 4.0.6 and the
decimal-column cast of activemodel 8.0.5.1, and through `oracle.sh adapter` op `invoice.void`, one 533-cent fee at
20 % voided with credit 14, item precise amount 11.65938); the money rounding of a binary64 cent amount gives
27.499999999999996 → 27; a decimal divided by a decimal through the float-division helper stays decimal. Coupon checks
probed through the coupon and applied-coupon creation services: expiration before limitations before value checks;
a time-limited coupon without an instant, a 150 % rate and a once coupon with a duration are accepted; on application
inactive → overlap → reusability → value checks (an override amount of 0 accepted, −5 `value_is_out_of_range`, an
unknown currency `value_is_invalid`, a recurring override without a duration takes the coupon's, duration 0
`value_is_out_of_range`). Refundable: refunds of every note of the invoice count (`$API/app/models/invoice.rb:415`),
probed with a voided and with a draft note. Zero coupon credits: a limited coupon on fully discounted targets writes a
0 credit and a once percentage coupon is terminated by it. A starting run of an arrears plan, which the reference
never schedules (BE-SP-49), makes the true-up op bill a commitment fee on a one-day line: the op schema leaves that
input out of its domain. kitrun of the five billing areas of chapters 07-10 (shipped and holdout) against the oracle →
`SUMMARY kitrun: areas=10 pass=10 fail=0 vectors=392 passed=392 skipped_ops=0 exit=0`; `recompute-invoicing.py`
(updated for BE-IV-17/18, BE-IV-42, BE-CN-8, BE-CN-14, BE-CN-18) → 201/201 compat and every corrected twin PASS
(`--only '^(?!invoice\.commitment\.)'`). Independent verification the same day (database `lago_api_test_v2g4`): the
void-item order was pinned by a searched discriminating input, a 267-cent fee at 20 % voided with a credit of 7
(`invoice.void.008`: 5.84062 at the pin; the exact 5.840625 gives 5.84063, twin `invoice.void.008x` recomputed by the
model's corrected profile); the coupon value checks of `$API/app/models/coupon.rb:55-61` apply to any coupon type.
The base of a limited coupon is summed from integer amounts minus decimal coupon shares
(`$API/app/services/credits/applied_coupon_service.rb:93-103`), so it is a decimal even when whole, while an
unlimited coupon receives the invoice's integer sub-total: executed, 17.5 % of a 180-cent fee is 32 for a
metric-limited coupon (`invoice.coupon_distribution.013`) and 31 for an unlimited one (`invoice.coupon_amount.010`);
the model `recompute-invoicing.py` was corrected accordingly (it had turned a whole limited base into an integer).

Later pass of 2026-10-05 (database `lago_api_test_fr3b`; each new vector run twice through `oracle.sh adapter`). The
expiration check is unconditional: `$API/app/services/coupons/validate_service.rb:18-22` with
`$API/app/services/validators/expiration_date_validator.rb:5-9` test any given instant, whatever `expiration` says
(`invoice.coupon_create.017`). The amount and currency checks of `$API/app/models/coupon.rb:56` and `:59` and of
`$API/app/models/applied_coupon.rb:29-30` carry no type condition: a percentage coupon with an amount of 0
(`invoice.coupon_create.016`) and percentage coupons applied with an amount override of −1 or a currency override `XXX`
(`invoice.coupon_apply.016`, `.017`) are refused; a percentage coupon applied with a currency override leaves a
customer without currency unchanged (`$API/app/services/applied_coupons/create_service.rb:55-59`). The void near-tie of
the conversion paragraph above is now the vector `invoice.void.009` (both profiles: the exact 11.659375 also stores
11.65938); the model `recompute-invoicing.py` had rounded the void item's text (11.65937) and now applies `round5`, and
applies the 16-digit cut of `dec16` wherever this chapter and chapter 08 write it; it passes every invoice and
credit-note vector, shipped and holdout, in both profiles.

| Rules | Reference code @591ae90 |
|---|---|
| BE-IV-1..3 | `$API/app/models/invoice.rb:92-111`, `$API/app/services/invoices/create_generating_service.rb:27-43`, `$API/app/services/invoices/subscription_service.rb:40-46`, `$API/app/models/invoice_subscription.rb:18-27` |
| BE-IV-4..9 | `$API/app/services/invoices/calculate_fees_service.rb:49-65`, `$API/app/services/invoices/calculate_fees_service.rb:362-394`, `$API/app/services/invoices/compute_amounts_from_fees.rb:14-45`, `$API/app/services/invoices/create_pay_in_advance_charge_service.rb:15-47`, `$API/app/services/invoices/progressive_billing_service.rb:15-48`, `$API/app/services/invoices/create_one_off_service.rb:40-75`, `$API/app/services/invoices/paid_credit_service.rb:66-78`, `$API/app/services/invoices/aggregate_amounts_and_taxes_from_fees.rb:14-50` |
| BE-IV-10, BE-IV-11 | `$API/app/services/fees/apply_taxes_service.rb:15-78` |
| BE-IV-12..14 | `$API/app/services/invoices/apply_taxes_service.rb:13-101` |
| BE-IV-15, BE-IV-16 | `$API/app/services/invoices/compute_taxes_and_totals_service.rb:14-40`, `$API/app/services/taxes/update_service.rb:30` |
| BE-IV-17, BE-IV-18, BE-IV-58 | `$API/app/models/coupon.rb:52-94`, `$API/app/services/coupons/create_service.rb:17-68`, `$API/app/services/coupons/validate_service.rb:5-24`, `$API/app/services/applied_coupons/create_service.rb:20-109`, `$API/app/services/customers/update_currency_service.rb:14-21`, `$API/app/services/coupons/destroy_service.rb:17-29` |
| BE-IV-19..27 | `$API/app/services/credits/applied_coupons_service.rb:12-55`, `$API/app/services/credits/applied_coupon_service.rb:15-128`, `$API/app/services/applied_coupons/amount_service.rb:25-41`, `$API/app/models/applied_coupon.rb:39-44`, `$API/app/models/fee.rb:231-244`, `$API/app/models/credit.rb:23` |
| BE-IV-28, BE-IV-29 | `$API/app/services/coupons/terminate_service.rb:7-13`, `$API/app/services/applied_coupons/recredit_service.rb:15-52` |
| BE-IV-30..32 | `$API/app/services/credits/credit_note_service.rb:39-111`, `$API/app/services/credits/applied_prepaid_credits_service.rb:13-46`, `$API/app/services/credits/progressive_billing_service.rb:13-81` |
| BE-IV-33..39 | `$API/app/services/invoices/subscription_service.rb:215-237`, `$API/app/services/invoices/transition_to_final_status_service.rb:14-38`, `$API/app/services/invoices/create_generating_service.rb:62-87`, `$API/app/services/invoices/issuing_date_service.rb:11-50`, `$API/app/services/invoices/refresh_draft_and_finalize_service.rb:11-83`, `$API/app/models/invoice.rb:144` |
| BE-IV-41..45 | `$API/app/services/invoices/void_service.rb:21-163`, `$API/app/models/invoice.rb:124-135`, `$API/app/models/invoice.rb:452-458`, `$API/app/services/invoices/delete_service.rb`, `$API/app/services/invoices/regenerate_from_voided_service.rb:17-60` |
| BE-IV-46..50 | `$API/app/models/invoice.rb:244-248`, `$API/app/models/invoice.rb:352-458`, `$API/app/models/fee.rb:257-282` |
| BE-IV-51..53 | `$API/app/services/fees/one_off_service.rb:20-66`, `$API/app/services/fees/paid_credit_service.rb:21-41`, `$API/app/models/fee.rb:238-248` |
| BE-IV-54..57 | `$API/app/services/commitments/calculate_amount_service.rb:25-44`, `$API/app/services/commitments/calculate_prorated_coefficient_service.rb:29-68`, `$API/app/services/commitments/minimum/calculate_true_up_fee_service.rb:37-74`, `$API/app/services/commitments/minimum/in_arrears/calculate_true_up_fee_service.rb:9-151`, `$API/app/services/commitments/minimum/in_advance/calculate_true_up_fee_service.rb:9-134`, `$API/app/services/fees/commitments/minimum/build_fee_base_service.rb:23-74`, `$API/app/services/fees/commitments/minimum/create_service.rb:7-34`, `$API/app/services/invoices/calculate_fees_service.rb:245-266`, `$API/app/models/invoice_subscription.rb:86-93`, `$API/config/initializers/money.rb` (half-up rounding) |

Spec examples behind the explicit expectations (all green on the pinned toolchain):
`$API/spec/scenarios/coupons_breakdown_spec.rb:13`, `$API/spec/scenarios/taxes_on_invoice_spec.rb:14`,
`$API/spec/scenarios/taxes_on_invoice_spec.rb:162`, `$API/spec/scenarios/credit_notes/credit_note_spec.rb:57`,
`$API/spec/models/invoice_spec.rb:1952`, `$API/spec/services/applied_coupons/amount_service_spec.rb:16`,
`$API/spec/services/invoices/apply_taxes_service_spec.rb:25`, `$API/spec/services/invoices/issuing_date_service_spec.rb:21`,
`$API/spec/scenarios/invoices/negative_total_with_prepaid_credits_spec.rb:55`, `$API/spec/scenarios/invoices/void_invoice_spec.rb:16`.
Probes of 2026-10-02 (scratch op modules, not shipped): RBD-72 — a time-limited coupon terminated by the expiry job
leaves its applied coupon active and still credited on the next invoice; RBD-73 — a fully paid invoice
(`voidable?` false) is voided, with or without credit-note generation.

Update triggers: a pin bump (re-run the oracle over all `invoice.*` vectors), any change of the invoice services named
above, an owner ruling on RBD-68/72/73.
