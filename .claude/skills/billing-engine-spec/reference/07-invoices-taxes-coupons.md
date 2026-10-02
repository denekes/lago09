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
round half away from zero (BE-DM-23). "binary64" marks the documented float islands (RBD-68): the compat profile
reproduces them, the corrected profile uses exact decimals.

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
- **BE-IV-11** Fee taxes are computed once per fee, **after** coupons (so on `amount_cents − precise_coupons_amount_cents`), with the formulas of BE-DM-27..29: each tax row rounded separately, the fee's tax total rounded once from the unrounded rows, the precise variant on the precise amount. Each row's division by 100 is binary64. A fee that already carries tax rows is left untouched. [vec: invoice.totals.002, invoice.totals.016, invoice.totals.020, invoice.totals.024, invoice.apply_taxes.004, invoice.apply_taxes.006]
- **BE-IV-12** Invoice tax rows: one row per tax code present on any fee, holding the tax's code, name and rate (a snapshot); `fees_amount_cents` of the row = Σ over the fees carrying that tax of `(amount_cents − precise_coupons_amount_cents)`, **truncated** to whole cents; the row's `amount_cents` = round(Σ base × rate / 100) computed from the untruncated sum (binary64 division). [vec: invoice.apply_taxes.001, invoice.apply_taxes.004, invoice.apply_taxes.005, invoice.apply_taxes.008, invoice.apply_taxes.010, invoice.totals.001]
- **BE-IV-13** Invoice `taxes_amount_cents` = round(Σ over tax codes of Σ base × rate / 100) using the **unrounded** per-code contributions: it differs from the sum of the rounded fee taxes (four 1-cent fees at 40 %: fee taxes 0 each, invoice tax 2) and can differ from the sum of the rounded invoice rows (two rows 1411 + 479 on an invoice tax of 1889). RBD-69 keeps this. [vec: invoice.totals.001, invoice.totals.015, invoice.totals.016, invoice.totals.024, invoice.apply_taxes.001, invoice.apply_taxes.004, invoice.apply_taxes.008]
- **BE-IV-14** Invoice `taxes_rate` (informational, never used to compute amounts) = Σ over tax codes of `rate × share`, rounded to 5 decimals, where `share` = the code's untruncated taxable base ÷ the invoice's `sub_total_excluding_taxes`, or, when that sub-total is ≤ 0, (number of fees carrying the code ÷ number of fees). The reference computes shares and products in binary64 and rounds the binary64 result, so an exact tie can round down (0.240625 → 0.24062; RBD-68, corrected: exact decimal, 0.24063). [vec: invoice.apply_taxes.001, invoice.apply_taxes.003, invoice.apply_taxes.003x, invoice.apply_taxes.007]
- **BE-IV-15** When the customer is connected to an external tax provider (out of scope, chapter 14), local taxes are not computed: the invoice gets `tax_status = pending` and, when finalizing, status `pending` (`open` when payment-gated); provider results later fill the per-fee rows (possibly with whole-invoice exemption codes) and a provider error sets `tax_status`/`status` to `failed` (a draft stays draft). A pending tax-identifier check behaves the same way. [vec: none (prose only: depends on out-of-scope tax providers; the interface is chapter 14)]
- **BE-IV-16** Updating or deleting a tax, or changing customer or billing-entity taxes, flags the customer's draft invoices for refresh; finalized invoices keep their tax snapshots. [vec: none (prose only: a catalogue side effect on stored drafts; observable only through the API scenario tier)]

Invoice taxes, as fresh pseudocode (the fee rows are BE-DM-27..29):

```
invoice_taxes(fees, sub_total):
    rows = []; unrounded_total = 0; rate = 0
    for code in tax codes of all fees:
        taxed = [f for f in fees if code in f.taxes]
        base = sum(f.amount_cents - f.precise_coupons for f in taxed)           # exact
        contrib = base * rate_of(code) / 100                                    # binary64 in compat
        rows.append({code, fees_amount_cents: trunc(base), amount_cents: round(contrib)})
        unrounded_total += contrib
        share = base / sub_total if sub_total > 0 else len(taxed) / len(fees)    # binary64 in compat
        rate += share * rate_of(code)
    return rows, round(unrounded_total), round(rate, 5)
```

## 4. Coupons

A **coupon** is a catalogue object; an **applied coupon** is a coupon attached to a customer, with its own copy of
the amount, currency, percentage rate, frequency and duration (BE-DM entity card), its own status and the remaining
number of periods. Invoices consume applied coupons.

- **BE-IV-17** Creating a coupon: a fixed-amount coupon needs an amount > 0 and a currency, a percentage coupon a rate, a recurring coupon a duration > 0 (`value_is_mandatory` when missing, `value_is_out_of_range` when not positive, on the field); a time-limited expiration must lie in the future (`invalid_date` on `expiration_at`); `reusable` defaults to true; a coupon is limited to plans or to billable metrics, never both (`only_one_limitation_type_per_coupon_allowed`), and every limitation code must exist (`plans_not_found`, `billable_metrics_not_found`); the coupon is stored with one target per limiting plan or metric. [vec: invoice.coupon_create.*, scn.invoice.coupons.001]
- **BE-IV-18** Applying a coupon to a customer (under a per-customer lock): the catalogue coupon must be active (`coupon_not_found`); a non-reusable coupon is refused once the customer holds any applied coupon of it, whatever that one's status (`coupon_is_not_reusable` on `coupon`); a limited coupon is refused (`plan_overlapping`) when an **active** limited applied coupon of the customer shares a target with it — the same plan, the same metric, a plan of one that has a charge on a metric of the other — while unlimited coupons and ended applied coupons never block. The applied coupon copies the coupon's amount, currency, rate, frequency and duration unless the request overrides them, its remaining periods = that duration, and it is validated like a coupon (a recurring override without duration: `value_is_mandatory` on `frequency_duration`). A fixed-amount coupon gives its currency to a customer that has none; a customer with a currency keeps it. [vec: invoice.coupon_apply.*, scn.invoice.coupons.001]
- **BE-IV-19** Application order on an invoice: the customer's **active** applied coupons (the catalogue coupon's own status is ignored, BE-IV-28), metric-limited first, then plan-limited, then unlimited; within each group by application time (oldest first). Coupons are applied under a per-customer lock. [vec: invoice.coupon_order.001, invoice.coupon_order.002, invoice.coupon_order.003, invoice.totals.001, invoice.totals.012]
- **BE-IV-20** Coupons are attempted only when `fees_amount_cents > 0` (subscription and pay-in-advance invoices), and the loop stops as soon as the running sub-total is ≤ 0: later coupons are not touched (not consumed, no period used). [vec: invoice.totals.003, invoice.totals.011, invoice.totals.013, invoice.totals.018]
- **BE-IV-21** One coupon is skipped (no credit, no consumption) when it is fixed-amount in another currency than the invoice, when it already credited this invoice, or when it has no target fee. [vec: invoice.totals.017]
- **BE-IV-22** Targets and base: a metric-limited coupon targets the **charge** fees of its metrics; a plan-limited coupon targets every fee attached to a subscription of its plans (subscription, charge and other subscription fees); an unlimited coupon targets all fees. The base of a limited coupon is Σ over targets of `(amount_cents − precise_coupons_amount_cents)` (exact, may be fractional); the base of an unlimited coupon is the running invoice sub-total (after progressive credits and earlier coupons). [vec: invoice.coupon_distribution.003, invoice.coupon_distribution.004, invoice.coupon_distribution.005, invoice.coupon_distribution.006, invoice.coupon_distribution.009, invoice.totals.001, invoice.totals.017]
- **BE-IV-23** Coupon amount from the base `B`, using the applied coupon's own values: **percentage** → `v = B × rate / 100` (binary64 when `B` is an integer; with a fractional `B` the product is exact, `rate / 100` being taken at 16 significant digits), amount = `B` when `v ≥ B`, else round(v); **fixed recurring or forever** → min(amount, B); **fixed once** → min(remaining, B) with remaining = amount − Σ credits this applied coupon made on invoices that are not voided, closed or deleted. A binary64 product can fall just under a half: 17.5 % of 180 cents is 31 in the reference (RBD-68, corrected 32). [vec: invoice.coupon_amount.001, invoice.coupon_amount.002, invoice.coupon_amount.003, invoice.coupon_amount.004, invoice.coupon_amount.005, invoice.coupon_amount.007, invoice.coupon_amount.008, invoice.coupon_amount.010, invoice.coupon_amount.010x, invoice.totals.003, invoice.totals.011, invoice.totals.019, invoice.totals.020]
- **BE-IV-24** The credit row stores the amount as integer cents: a fractional amount (a limited coupon whose base is fractional and smaller than its value) is **truncated** toward zero in the credit and in the invoice's coupon total, while the distribution of BE-IV-25 uses the untruncated amount. [vec: invoice.coupon_amount.009]
- **BE-IV-25** Distribution: for each target fee, `share = amount × (amount_cents − precise_coupons) / B` (binary64), added to the fee's `precise_coupons_amount_cents`, which is stored at 5 decimal places (half away) after each coupon and capped at the fee's `amount_cents`; nothing is distributed when `B = 0` (a limited coupon whose targets are fully discounted credits 0). [vec: invoice.coupon_distribution.001, invoice.coupon_distribution.003, invoice.coupon_distribution.005, invoice.coupon_distribution.009, invoice.coupon_distribution.010, invoice.totals.001, invoice.totals.002, invoice.totals.003, invoice.totals.024]
- **BE-IV-26** After each coupon: invoice `coupons_amount_cents += credit`, running sub-total `−= credit`; the credit row is a before-tax credit. [vec: invoice.coupon_distribution.001, invoice.totals.003]
- **BE-IV-27** Consumption after a credit: **recurring** → remaining periods − 1 (not below 0), terminated when 0; **once** → terminated when percentage, or when the credit ≥ the remaining amount (a fixed once coupon larger than the invoice stays active and continues on the next invoice); **forever** → never terminated. [vec: invoice.coupon_distribution.001, invoice.coupon_distribution.004, invoice.coupon_distribution.008, invoice.coupon_distribution.011, invoice.totals.011, invoice.totals.018, invoice.totals.019, invoice.totals.020]
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
        if B != 0: f.precise_coupons = round5(f.precise_coupons + amount * (f.amount_cents - f.precise_coupons) / B)
        f.precise_coupons = min(f.precise_coupons, f.amount_cents)
    consume(c, amount)                                                        # BE-IV-27
    return trunc(amount)
```

## 5. Credits applied after taxes

- **BE-IV-30** Credit-note credits (finalize context): the customer's finalized credit notes with an `available` credit status, in the invoice currency, issued on **other** invoices, oldest first; each takes `min(balance, remaining)` where `remaining` starts at the post-tax total; its balance decreases and the note becomes `consumed` at 0; each fee gets `precise_credit_notes_amount_cents += credit × (amount − coupons + taxes − credit-notes already) / remaining` (binary64, 5 places, capped at the fee's after-tax amount); applied at most once per invoice. A note in another currency is not used. [vec: invoice.totals.009, invoice.totals.010, invoice.totals.023]
- **BE-IV-31** Prepaid credits come last, only when the total is still positive: the customer's active wallets in the invoice currency with a positive balance, in application order (priority, then age), cover the remaining total (allocation by fee type and metric, traceability and the granted/purchased split: chapter 09). [vec: invoice.totals.007, invoice.totals.010, invoice.totals.015, scn.invoice.prepaid.001]
- **BE-IV-32** Progressive-billing credits (subscription and progressive invoices): the amount already billed for the period by the latest progressive-billing invoice of the subscription (BE-PB-20..24 decide the amount and the over-credit note) is credited before coupons, capped at the current invoice's fees of the same charges; each matching charge fee (same charge, filter and grouping) gets the progressive fee's amount added to its coupon share (capped at its amount), so it also leaves the tax base. [vec: invoice.totals.008, scn.invoice.progressive.001]

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
- **BE-IV-42** Void with credit-note generation (premium): requested `credit` and `refund` must satisfy credit ≤ creditable, refund ≤ refundable and credit + refund ≤ creditable (BE-IV-48), else `total_amount_exceeds_invoice_amount` on `credit_refund_amount`; when credit + refund > 0 a note is created with the requested credit and refund whose items are every fee's remaining creditable amount scaled by `(credit + refund) / T`, where `T` is the maximum creditable amount of an estimate (BE-CN-14) over all those items (binary64 ratio, items kept fractional, BE-CN-5); then, when the invoice's creditable amount (BE-IV-48) rounded is still > 0, a second note is created with the items and the maximum creditable amount (as credit) of a fresh estimate over the remaining items, and immediately voided (BE-CN-20). [vec: invoice.void.002, invoice.void.004, invoice.void.006]
- **BE-IV-43** Only drafts can be deleted (status `deleted`, their draft credit notes deleted too). [vec: none (prose only: an API state change without amounts)]
- **BE-IV-44** A voided invoice can be regenerated: a new invoice of the same type, customer, currency and billing entity, linked to the voided one, receives copies of the voided invoice's subscription lines and of the fees named in the request only (each copy with its tax and coupon shares reset, optionally with new units or a new unit amount through the manual fee-adjustment path); it then runs the finalize-context pipeline (progressive credits, coupons when fees > 0, taxes, credit-note and prepaid credits when the total is positive), takes today's local date as issuing date (due date = issuing date + net payment term) and gets its status by BE-IV-34. [vec: none (prose only: needs a voided invoice plus the manual fee-adjustment machinery, which this kit does not specify; no vector or scenario exercises it)]
- **BE-IV-45** Overdue: hourly, a finalized invoice that is not paid, not disputed and whose due date is before now is flagged overdue and emits a webhook (chapter 13). [vec: none (prose only: clock behaviour, chapter 13)]

## 7. Amounts that bound credit notes

- **BE-IV-46** `total_due = 0` when voided, else `total − total_paid − Σ offsets of finalized credit notes` (it can go negative when offsets exceed what is unpaid). [vec: invoice.available_to_credit.007, invoice.available_to_credit.009, invoice.available_to_credit.010]
- **BE-IV-47** Available to credit = 0 for invoices of version < 2 and for drafts; else with `F` = Σ fee creditable amounts (amount − earlier credit-note items on the fee) and `adj = (coupons + progressive credit) / fees_amount × F` (0 for version < 3): `F − adj + round(Σ_fee (creditable − adj × creditable / F) × fee taxes_rate / 100)`. The reference evaluates it in binary64, so it can be non-integer (12.999999999999998 for coupons 14 on 25; RBD-68, corrected 13); 0 when `F = 0`. [vec: invoice.available_to_credit.001, invoice.available_to_credit.003, invoice.available_to_credit.005, invoice.available_to_credit.006, invoice.available_to_credit.006x]
- **BE-IV-48** `creditable = 0` for credit invoices, else available-to-credit; `offsettable = total` for an unpaid credit invoice with a positive due, else `min(due, creditable)`; `refundable = 0` for version < 2, drafts, and invoices whose payment is not `succeeded` while fully paid; else `min(total_paid − Σ refunds of the invoice's notes, creditable)`, not below 0 (credit invoices: limited by the wallet-backed amount, chapter 09). [vec: invoice.available_to_credit.006, invoice.available_to_credit.006x, invoice.available_to_credit.007, invoice.available_to_credit.008, invoice.available_to_credit.009]
- **BE-IV-49** `fee_total = Σ fee amount_cents + round(Σ fee amount_cents × fee taxes_rate / 100)` (used by credit-note validation). [vec: invoice.available_to_credit.007]
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

- **BE-IV-54** Reconciled period and prorated commitment: for each subscription of a subscription invoice, the *reconciled line* is the invoice's own subscription line for an arrears plan, and for an advance plan the subscription's previous line (the latest earlier line that billed a subscription fee, i.e. the period paid in advance on the previous invoice). The *commitment period* is the full plan period (BE-SP-10, customer zone; the whole year of a yearly plan even when its charges are billed monthly) that contains the reconciled line. `C = round_half_away(amount_cents × covered / length)` where `length` = the BE-DM-15 day count of the whole commitment period and `covered` = the BE-DM-15 day count from the start of the subscription's earliest line inside the commitment period (normally the subscription's start or the period start) to the end of the reconciled line, or to the termination instant (capped at the period end) when the subscription is terminated; the ratio and the product are binary64 (RBD-52; no divergence from exact decimals found in the vectors). Days are local calendar days of the customer's zone: a Tokyo customer starting on 16 March covers 16 of 31 days. [vec: invoice.commitment.001, invoice.commitment.005, invoice.commitment.006, invoice.commitment.008, invoice.commitment.009, scn.commitment.arrears.001, scn.commitment.advance.001]
- **BE-IV-55** Fees counted and true-up: `F` = Σ `amount_cents` of the subscription's fees billed for a window inside the commitment period, whatever invoice carries them: subscription fees, charge fees (arrears, pay in advance, recurring pay-in-advance fees without invoice, charge true-ups) and fixed-charge fees (arrears and pay in advance); earlier commitment fees are not counted. When `F < C` the true-up is `amount_cents = C − F` and `precise_amount_cents = C − Σ precise_amount_cents` of the same fees; when `F ≥ C` nothing is billed (fees equal to the commitment bill nothing). [vec: invoice.commitment.001, invoice.commitment.003, invoice.commitment.004, invoice.commitment.008, scn.commitment.arrears.001, scn.commitment.termination.001]
- **BE-IV-56** When it is billed: on subscription invoices of billing runs (start, periodic, termination), never on progressive-billing or one-off invoices nor in current usage, and only when (a) the plan has a commitment; (b) for an advance plan, the subscription has a previous line (nothing on its first invoice); (c) for a yearly or semiannual plan, the invoice also bills the subscription fee (BE-SP-47), so the monthly invoices of monthly-billed charges carry none and the yearly invoice reconciles the whole year; (d) the true-up is > 0; (e) the invoice holds no commitment fee for this subscription yet. An advance plan therefore pays the commitment of a period on the next period's invoice, and its termination invoice reconciles the period cut short by the termination, the subscription fee already paid in advance for that period counting in `F`. [vec: invoice.commitment.008, scn.commitment.advance.001]
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
    C = round_half_away(plan.commitment.amount_cents * (days(first.start, stop) / days(P.start, P.end)))   # binary64 ratio
    counted = [f for f in subscription fees billed for a window inside P if f.type != commitment]
    F = sum(f.amount_cents for f in counted)
    if F >= C or invoice already holds a commitment fee of this subscription: return none
    return fee(type = commitment, amount_cents = C - F, precise_amount_cents = C - sum(f.precise for f in counted),
               units = 1, unit_amount_cents = C - F, bounds = (rec.start, rec.end))
```

## 10. Rebuild decisions touching this chapter

| RBD | Behaviour at the pin | Compat | Corrected |
|---|---|---|---|
| RBD-68 | tax rate shares, coupon percentages, coupon/credit-note shares and the creditable amount use binary64 | `invoice.apply_taxes.003`, `invoice.coupon_amount.010`, `invoice.available_to_credit.006` | exact decimal (twins `…x`, ruling proposed) |
| RBD-69 | invoice tax ≠ Σ fee taxes ≠ Σ rounded rows | KEEP | KEEP |
| RBD-70 | zero-amount rule tested on fees, not total | KEEP | KEEP |
| RBD-71 | coupons, credit notes, wallets only at finalization | KEEP | KEEP |
| RBD-72 | expired coupons' applied coupons keep applying (verified) | KEEP | owner |
| RBD-73 | void does not enforce the voidable predicate (verified) | KEEP | owner |
| RBD-52 | the commitment proration is a binary64 ratio, rounded half up (BE-IV-54; the charge-minimum true-up of chapter 05 is the main case) | `invoice.commitment.005` | exact decimal (proposed); no divergence found in the commitment vectors, so no twin |

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
| 17.5 % of 180 cents is 31 cents (binary64) | BE-IV-23 |
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
| `invoice.totals.jsonl` | `invoice.totals` | 25 |
| `invoice.taxes.jsonl` | `invoice.apply_taxes`, `invoice.fee_tax_selection` | 21 (one corrected twin) |
| `invoice.coupons.jsonl` | `invoice.coupon_amount`, `invoice.coupon_order`, `invoice.coupon_distribution`, `invoice.coupon_create`, `invoice.coupon_apply` | 46 (one corrected twin) |
| `invoice.lifecycle.jsonl` | `invoice.final_status`, `invoice.issuing_date`, `invoice.payment_due_date`, `invoice.available_to_credit`, `invoice.void` | 44 (one corrected twin) |
| `invoice.commitment.jsonl` | `invoice.commitment_true_up` | 9 |

Evidence: every `both`/`compat` vector is EXECUTED through the oracle adapter at the pin (spec-derived values were
first checked against the reference examples); the three corrected twins are RECOMPUTED with exact decimals (`ruling:
proposed`, RBD-68). Run them with `python3 reimplementation-kit/scripts/kitrun.py --impl-cmd "<adapter>" --areas
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
