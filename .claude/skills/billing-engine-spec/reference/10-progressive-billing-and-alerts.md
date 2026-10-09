# 10 — Progressive billing, lifetime usage and alerts (BE-PB, BE-AL)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08).
> It is a behavioural specification written fresh from executed vectors and probes, not source code. Proprietary
> clean-room rebuilds should have it reviewed (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90`. **Lifetime usage** is the running usage amount of a subscription across billing
periods. **Progressive billing** bills usage early: when lifetime usage crosses a **usage threshold** of the plan or
subscription, a progressive-billing invoice is issued at once, and the regular period invoice later credits what
was already billed. **Alerts** watch a measured value (current usage, lifetime usage, a metric's usage, a wallet
balance) and report the thresholds it crosses. All three are premium features (RBD-97); progressive billing and
lifetime usage are additionally enabled per organization (`progressive_billing`, `lifetime_usage`).

Related chapters: current usage and its amounts (04, 05), the invoice totals pipeline and the progressive-billing
credit step (07, BE-IV-32), automatic credit notes (08, BE-CN-21), wallets and wallet alerts' measured values (09),
the clock jobs (13), the `subscription.usage_threshold_reached` and `alert.triggered` webhooks (12).

This chapter has no binary64 island: lifetime-usage and threshold amounts are integers and alert values and steps
are exact decimals (the only float of this area, the lifetime-usage `completion_ratio` shown by the API, is a display
value typed in chapter 11).

Reading guide: rules are numbered `BE-PB-n` and `BE-AL-n`; every rule line ends with `[vec: …]` naming the vectors
that pin it, or a prose-only marker with the reason. Vector files: `progressive.jsonl` (ops
`progressive.lifetime_usage`, `progressive.check_thresholds`, `progressive.passed_amount`, `progressive.to_credit`)
and `alerts.jsonl` (ops `alerts.measure`, `alerts.crossed`); schemas in
`reimplementation-kit/schemas/ops/{progressive,alerts}.*.schema.json`. End-to-end flows: `scn.invoice.progressive.*`,
`scn.lifetime.usage.001`, `scn.alert.usage.001`, `scn.wallet.alert.001`.

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun against the oracle -->

## 1. Lifetime usage

One lifetime-usage record per subscription, in the plan currency, with three integer amounts in minor units:
`historical` (set through the API, e.g. usage before a migration), `invoiced` and `current`.

- **BE-PB-1** `total = historical + invoiced + current`. [vec: progressive.lifetime_usage.001]
- **BE-PB-2** `invoiced` = Σ `amount_cents` of the **charge** fees (not subscription, fixed-charge or other fees) on invoices of type `subscription` with status `finalized` **or `draft`** (RBD-76), belonging to the measured subscription or to any subscription with the same external id and the same `subscription_at` (an upgrade or downgrade chain) that was not canceled. Voided, failed, generating, open or pending invoices and progressive-billing, one-off or advance-charges invoices do not count. [vec: progressive.lifetime_usage.001, progressive.lifetime_usage.002, progressive.lifetime_usage.003, progressive.lifetime_usage.004, progressive.lifetime_usage.005, scn.lifetime.usage.001]
- **BE-PB-3** `current` = the current-usage amount of the subscription without taxes (chapters 04-05, BE-AG-70..72). [vec: scn.lifetime.usage.001]
- **BE-PB-4** Recomputation: `invoiced` is recomputed only when flagged (any generation, refresh or void of a subscription invoice of the subscription flags it; so does a plan update), `current` on every recomputation. Recomputation runs inline when subscription activity is processed (events received, BE-AL-12) and on a clock sweep (default every 300 s, chapter 13); an inactive subscription only has its flags cleared. After each recomputation the thresholds are checked (BE-PB-14) when the organization has progressive billing. [vec: scn.lifetime.usage.001, scn.invoice.progressive.001]

## 2. Usage thresholds

A threshold has `amount_cents` (> 0), `recurring` (at most one recurring threshold per owner) and an optional display
name; its owner is a plan or a subscription (exactly one). On a plan, amounts are unique per kind (a recurring and
a one-time threshold may share an amount). Threshold currency = the plan currency.

- **BE-PB-5** Applicable thresholds of a subscription: none when progressive billing is disabled on the subscription; else the subscription's own thresholds when it has any; else the plan's; else, for a child plan (plan override), the parent plan's — so a child plan with thresholds of its own ignores the parent's entirely. [vec: progressive.check_thresholds.001, progressive.check_thresholds.036, progressive.check_thresholds.037, progressive.check_thresholds.038, progressive.check_thresholds.040]

### 2.1 The threshold check

Inputs: lifetime usage (`H` historical, `I` invoiced, `C` current) and `P` = the amount already progressively billed in
the current period (BE-PB-11). Fixed thresholds `t1 < t2 < … < tk`, `L = tk` (0 when there is none), optional
recurring threshold `r`.

- **BE-PB-6** `A = C − P` (actual usage not yet billed). When `A < 0` nothing passes. [vec: progressive.check_thresholds.022, progressive.check_thresholds.023, progressive.check_thresholds.039]
- **BE-PB-7** `B = H + I + P` (already billed usage) and `T = B + A`. [vec: progressive.check_thresholds.003, progressive.check_thresholds.024, progressive.check_thresholds.033]
- **BE-PB-8** When `B < L`: every fixed threshold with `B < t ≤ T` passes (ascending), and `r` passes (once, however many steps were crossed) when `T − L ≥ r`. [vec: progressive.check_thresholds.002, progressive.check_thresholds.005, progressive.check_thresholds.013, progressive.check_thresholds.014, progressive.check_thresholds.019, progressive.check_thresholds.030]
- **BE-PB-9** When `B ≥ L` (also when there is no fixed threshold): only `r` can pass (once), when `A + (B mod r) ≥ r`. [vec: progressive.check_thresholds.008, progressive.check_thresholds.009, progressive.check_thresholds.010, progressive.check_thresholds.011, progressive.check_thresholds.012, progressive.check_thresholds.016, progressive.check_thresholds.020, progressive.check_thresholds.021, progressive.check_thresholds.026, progressive.check_thresholds.027, progressive.check_thresholds.031, progressive.check_thresholds.032]
- **BE-PB-10** The passed list is ordered: fixed thresholds ascending, then the recurring one. [vec: progressive.check_thresholds.019, progressive.check_thresholds.030]

Worked example (fixed 10, 20, 31, 40; recurring 5; P = 0): I = 21, C = 24 → B = 21, T = 45 → 31 and 40 pass,
T − L = 5 ≥ 5 → the recurring threshold passes too (`progressive.check_thresholds.019`).

### 2.2 Already billed in the period

- **BE-PB-11** `P` = `fees_amount_cents` of the **latest** progressive-billing invoice of the subscription that is `finalized` or `failed` and whose charges window contains the reference instant (`charges_from ≤ t < charges_to`); latest = greatest issuing date, then latest creation. 0 when none. (The wallet ongoing balance also counts `generating` ones, chapter 09.) [vec: progressive.to_credit.001, progressive.to_credit.003]
- **BE-PB-12** Thresholds only bill usage of invoiceable charges billed in arrears; fees of in-advance or non-invoiceable charges never enter a progressive-billing invoice. [vec: scn.invoice.progressive.001]
- **BE-PB-13** The amount recorded as passed for an applied threshold: a fixed threshold → its own amount; the recurring one → `total − (total mod r)` where `total` is the lifetime usage total at invoicing time. [vec: progressive.passed_amount.001, progressive.passed_amount.003, progressive.passed_amount.004]

## 3. Progressive-billing invoices

- **BE-PB-14** When the check passes at least one threshold (and the subscription is active), ONE progressive-billing invoice is created for all of them at the check instant: it carries one invoice-subscription with reason `progressive_billing` and the current period boundaries; its fees are the cumulative usage of the period for every invoiceable in-arrears charge (current-usage computation, finalize context); one applied-threshold row per passed threshold records the lifetime total (BE-PB-13). [vec: scn.invoice.progressive.001, scn.invoice.progressive.002]
- **BE-PB-15** The invoice then follows the progressive variant of the totals pipeline (chapter 07, BE-IV-7): progressive credits for earlier progressive invoices of the period (BE-PB-20..24, so its total is the usage since the previous one), coupons, taxes, credit notes, prepaid credits; it is finalized at once (never a draft), payment status `pending` when the total is positive, else `succeeded`. Webhooks: `invoice.created`, then one `subscription.usage_threshold_reached` per passed threshold. [vec: scn.invoice.progressive.002]
- **BE-PB-16** Idempotency: one invoice per (organization, external subscription id, invoiced usage, last passed threshold amount), plus the previous progressive invoice for a recurring threshold; a concurrent duplicate check is a no-op. A tax-provider failure leaves the invoice `failed` (retried manually). [vec: none (prose only: concurrency and provider behaviour)]

## 4. Credit on the period invoice

Applies to the subscription invoice of a period (and to the next progressive invoice of the same period), before
coupons (chapter 07, BE-IV-32). `pb` = the latest progressive invoice of BE-PB-11, taken at the invoice's
`charges_from` instant.

- **BE-PB-20** No progressive invoice → no credit. A draft progressive invoice never counts. [vec: progressive.to_credit.003]
- **BE-PB-21** `to_credit = pb.fees_amount − pb.coupons_amount − Σ credits already taken from pb on invoices that are not voided, closed or deleted − Σ credit amounts of pb's credit notes that are available or consumed`, floored at 0. [vec: progressive.to_credit.004, progressive.to_credit.005]
- **BE-PB-22** `charges_total` = Σ `amount_cents` of the current invoice's charge fees of this subscription whose charge also has a fee on `pb`. When `to_credit > charges_total`, an automatic credit note on `pb` returns the excess (chapter 08, BE-CN-21) and the credit is capped at `charges_total`. [vec: progressive.to_credit.001, progressive.to_credit.002, progressive.to_credit.006, scn.invoice.progressive.001]
- **BE-PB-23** A positive credit creates a before-tax credit row linked to `pb`; the invoice's `sub_total_excluding_taxes` decreases and `progressive_billing_credit_amount` increases by it. [vec: progressive.to_credit.001]
- **BE-PB-24** Fee-level effect: for each charge fee of `pb`, the current invoice's charge fee with the same charge, filter and grouping gets `pb`'s fee **amount** added to its coupon share, capped at its own amount (so it leaves the tax base); fees without a match are unchanged. The added amounts are the progressive fees' amounts, not the credited total. [vec: progressive.to_credit.001, progressive.to_credit.002, progressive.to_credit.006]

## 5. Alerts

### 5.1 Types and measured values

An alert has a type, a `direction` (increasing, default; decreasing), a code, a `previous_value` (decimal, 5 places,
initially 0) and up to 20 thresholds `{value, code, recurring}` (at most one recurring; duplicate values are rejected at creation). Subscription alerts are keyed
by the subscription external id; wallet alerts by the wallet. One alert per (subscription, type[, metric]) or
(wallet, type).

- **BE-AL-1** Types: `current_usage_amount`, `billable_metric_current_usage_amount`, `billable_metric_current_usage_units`, `lifetime_usage_amount`, `billable_metric_lifetime_usage_units` (subscription alerts; the three metric types require a billable metric, the others forbid one) and `wallet_balance_amount`, `wallet_credits_balance`, `wallet_ongoing_balance_amount`, `wallet_credits_ongoing_balance` (wallet alerts). [vec: none (prose only: enumeration; every type is measured in alerts.measure.*)]
- **BE-AL-2** Measured value: current usage amount without taxes; lifetime usage total (BE-PB-1); wallet `balance_cents`, `credits_balance`, `ongoing_balance_cents` or `credits_ongoing_balance`. [vec: alerts.measure.001, alerts.measure.008, alerts.measure.009, alerts.measure.010]
- **BE-AL-3** Metric alerts measure the **largest** `amount_cents` (amount types) or `units` (unit types) among the current-usage fees of charges of that metric — not their sum, so a metric split by filters or groups is measured by its largest bucket (RBD-77). No matching fee → no value, and the alert is skipped without updating its previous value. [vec: alerts.measure.002, alerts.measure.002x, alerts.measure.003, alerts.measure.003x, alerts.measure.004, alerts.measure.006]
- **BE-AL-4** `billable_metric_lifetime_usage_units` uses the usage of the metric's charges since the subscription started (full-usage mode) and is processed after a delay (the activity processing interval) instead of inline. [vec: alerts.measure.006]

### 5.2 Crossing

Let `prev` = the stored previous value, `cur` = the measured value, `O` = the sorted distinct one-time threshold
values, `r` = the recurring step.

- **BE-AL-5** Increasing: nothing when `cur ≤ prev`; nothing when one-time thresholds exist and `cur < min(O)`. [vec: alerts.crossed.002, alerts.crossed.015]
- **BE-AL-6** Increasing, one-time: when `prev < max(O)`, every `v ∈ O` with `prev < v ≤ cur`. [vec: alerts.crossed.001, alerts.crossed.003, alerts.crossed.016]
- **BE-AL-7** Increasing, recurring: base `b = max(O)` (0 without one-time thresholds); first value `b + max(1, ceil((prev − b) ÷ r)) × r`, last value `b + floor((cur − b) ÷ r) × r`; every multiple step from first to last (none when first > last, e.g. `cur` still below `b`). A `prev` lying exactly on a step is therefore reported again, and the base itself is never a recurring value (from −50 up to 150 with only a step of 100 reports 100, not 0) (RBD-78). The step counts are computed in exact decimal, not binary64: from 0 to 0.3 by 0.1 is 0.3 / 0.1 = 3 steps (0.1, 0.2, 0.3). [vec: alerts.crossed.001, alerts.crossed.014, alerts.crossed.014x, alerts.crossed.016, alerts.crossed.018]
- **BE-AL-8** Decreasing mirrors it: nothing when `cur ≥ prev` or when one-time thresholds exist and `cur > max(O)`; one-time `v` with `cur ≤ v < prev` when `prev > min(O)`; recurring base `b = min(O)` (0 without), values from `b − floor((b − cur) ÷ r) × r` up to `b − max(1, ceil((b − prev) ÷ r)) × r` in steps of `r` — the base itself is never a recurring value (from 50 down to −150 with only a step of 100 reports −100, not 0); a `prev` exactly on a step is reported again, as in BE-AL-7 (both quirks: RBD-78). [vec: alerts.crossed.006, alerts.crossed.007, alerts.crossed.008, alerts.crossed.010, alerts.crossed.011, alerts.crossed.013, alerts.crossed.013x]
- **BE-AL-9** The crossed values are de-duplicated and sorted ascending (both directions). [vec: alerts.crossed.001, alerts.crossed.007, alerts.crossed.011, alerts.crossed.016]
- **BE-AL-10** Reported rows: first the one-time rows — every one-time threshold whose value was crossed, as `{code, value, recurring: false}`, in the order the reference reads the alert's thresholds, which it does not define (storage order, in practice creation order, not value order: a rebuild may use any order, and vectors compare these rows as a set) — then each other crossed value, ascending, as `{code of the recurring threshold, value, recurring: true}`. [vec: alerts.crossed.001, alerts.crossed.008, alerts.crossed.017]

### 5.3 Processing

- **BE-AL-11** For each alert: measure (BE-AL-2..4; skip when there is no value); compute the crossed values; when any, store a triggered-alert row (current value, previous value, reported rows, time) and send `alert.triggered`; in every processed case set `previous_value = cur`. [vec: alerts.crossed.002, alerts.crossed.003, alerts.crossed.017, alerts.measure.004]
- **BE-AL-12** When: an accepted event of an active subscription (premium licence) marks the subscription as active-with-activity when the organization uses lifetime usage or the subscription has alerts; a clock sweep (default every 60 s, chapter 13) processes each marked subscription once — lifetime usage recomputation and threshold check first (BE-PB-4), then its lifetime and current-usage alerts with one shared current-usage computation (without taxes). Wallet alerts are processed after every wallet balance or ongoing-balance change. [vec: scn.alert.usage.001, scn.wallet.alert.001]

## 6. Edge cases

| Case | Behaviour | Vectors |
|---|---|---|
| draft subscription invoice | its charge fees count as invoiced lifetime usage | progressive.lifetime_usage.002 |
| usage dropped below the billed amount | no threshold passes; the period invoice returns the excess by credit note | progressive.check_thresholds.039, progressive.to_credit.002 |
| invoiced usage exactly on the largest fixed threshold | only the recurring rule applies | progressive.check_thresholds.008 |
| recurring 10, invoiced 202, current 8 | passes (remainder 2 + 8) | progressive.check_thresholds.012 |
| subscription thresholds and plan thresholds | the subscription's replace the plan's entirely | progressive.check_thresholds.037 |
| metric alert over filtered fees | largest fee, not the sum | alerts.measure.002 |
| previous value exactly on a recurring step | reported again | alerts.crossed.014 |
| decreasing, recurring only, crossing 0 | 0 is not reported (RBD-78) | alerts.crossed.013, alerts.crossed.013x |
| two one-time thresholds crossed at once | their rows come in an undefined order (compared as a set) | alerts.crossed.017 |

## 7. Vectors

| File / op | Count | Rules |
|---|---|---|
| `progressive.lifetime_usage` | 6 | BE-PB-1..2 |
| `progressive.check_thresholds` | 40 | BE-PB-5..10 |
| `progressive.passed_amount` | 4 | BE-PB-13 |
| `progressive.to_credit` | 7 | BE-PB-11, BE-PB-20..24 |
| `alerts.measure` | 12 (2 corrected twins) | BE-AL-2..4 |
| `alerts.crossed` | 20 (2 corrected twins) | BE-AL-5..11 |

The check-threshold vectors reproduce the rows of the reference's own threshold tables (one vector per row, a
representative subset of 131 rows) plus threshold-precedence cases. Corrected twins (`…x`) express proposed rebuild
decisions (RBD-77, RBD-78) and are graded only when the owner rules them.

## Provenance (maintainers)

| Rules | Reference behaviour at the pin |
|---|---|
| BE-PB-1..4 | `$API/app/models/lifetime_usage.rb:23-25`; `$API/app/services/lifetime_usages/calculate_service.rb:13-69`; `$API/app/jobs/lifetime_usages/recalculate_and_check_job.rb:24-29`; `$API/app/services/lifetime_usages/flag_refresh_from_invoice_service.rb`; `$API/clock.rb:46-55` |
| BE-PB-5 | `$API/app/models/subscription.rb:306-313`; `$API/app/models/plan.rb:83-85`; `$API/app/models/usage_threshold.rb:19-35` |
| BE-PB-6..10 | `$API/app/services/lifetime_usages/usage_thresholds/check_service.rb:15-56` |
| BE-PB-11, BE-PB-20..24 | `$API/app/services/subscriptions/progressive_billed_amount.rb:21-68`; `$API/app/services/credits/progressive_billing_service.rb:12-83`; `$API/app/models/credit.rb:23`; `$API/app/services/credit_notes/create_from_progressive_billing_invoice.rb:14-80` |
| BE-PB-12..16 | `$API/app/services/invoices/progressive_billing_service.rb:13-146`; `$API/app/models/applied_usage_threshold.rb:17-23`; `$API/app/services/lifetime_usages/check_thresholds_service.rb:13-27` |
| BE-AL-1..4 | `$API/app/models/usage_monitoring/alert.rb:10-63`; `$API/app/models/usage_monitoring/*_alert.rb` (find_value); `$API/app/services/usage_monitoring/process_lifetime_usage_alert_service.rb:13-31` |
| BE-AL-5..10 | `$API/app/models/usage_monitoring/alert.rb:73-187` (one-time rows read the unordered threshold association, `:36-39`, `:127-141`); `$API/app/models/usage_monitoring/alert_threshold.rb` |
| BE-AL-11..12 | `$API/app/services/usage_monitoring/process_alert_service.rb:14-46`; `$API/app/services/usage_monitoring/track_subscription_activity_service.rb:14-28`; `$API/app/services/usage_monitoring/process_subscription_activity_service.rb:13-62`; `$API/app/services/usage_monitoring/process_wallet_alerts_service.rb:12-20`; `$API/clock.rb:33-37` |

Executions on the pinned toolchain (ruby-4.0.6, 2026-10-02, a dedicated oracle database):

- `oracle.sh run spec/services/lifetime_usages spec/services/usage_monitoring spec/models/usage_monitoring
  spec/services/subscriptions/progressive_billed_amount_spec.rb spec/services/credits/progressive_billing_service_spec.rb
  spec/models/{applied_usage_threshold,lifetime_usage,usage_threshold}_spec.rb spec/scenarios/invoices/progressive_billing_spec.rb`
  together with the chapter 09 spec set → `{"example_count":1141,"failure_count":0,…}`; the four core files
  (wallet credit, recurring rule, alert and threshold-check specs) → 132/132.
- Oracle modules `scripts/maintainer/oracle-adapter/ops/progressive.rb` and `ops/alerts.rb`: thresholds, lifetime
  usage rows, subscription invoices and fees, progressive invoices with credits and credit notes, alerts and their
  thresholds are built with the reference factories in a rolled-back transaction; the handlers call the real
  threshold check, applied-threshold model, lifetime-usage calculation (current usage handed in), billed-amount and
  progressive-credit services, the alert model's crossing and formatting and the alert-processing service. Every
  check-threshold vector mirrored from the reference's threshold tables cites the table row it reproduces.
- RBD-78 probe (alert-processing service, recurring step 100, previous 100, current 250): crossed `[100, 200]` — the
  previous value on a step is re-reported (`alerts.crossed.014`); decreasing with only a step (50 → −150) reports
  `[−100]` (`alerts.crossed.013`, compat; proposed corrected twin `alerts.crossed.013x`); increasing with only a step
  (−50 → 150) reports `[100]` (oracle probe, verifier run 2026-10-02). RBD-77 (`alerts.measure.002`): fees 100 and 250
  of the metric → 250; the units variant (`alerts.measure.003`, units 3 and 1 → 3) is paired with `alerts.measure.003x`. RBD-76
  (`progressive.lifetime_usage.002`): a draft subscription invoice's charge fee counts.
- Fix round of 2026-10-05 (database `lago_api_test_fr2g4`): threshold precedence `$API/app/models/subscription.rb:309-313`
  executed with a child plan holding its own thresholds (`progressive.check_thresholds.040`: the child's 5 passes, the
  parent's 10 is ignored) and with plan thresholds under a subscription without any (they apply). Alert steps are
  decimal (`$API/app/models/usage_monitoring/alert.rb:161-187`): 0 → 0.3 by 0.1 reports 0.1, 0.2, 0.3 increasing and
  −0.3, −0.2, −0.1 decreasing (`alerts.crossed.018`). No binary64 operation was found in the threshold check,
  lifetime-usage calculation, billed-amount or progressive-credit services.
- Update triggers: a pin bump; any change to the threshold check, lifetime-usage calculation, billed-amount or
  progressive-credit services, progressive invoice builder, alert models or alert-processing services.
