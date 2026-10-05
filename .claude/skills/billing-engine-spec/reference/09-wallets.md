# 09 — Wallets and prepaid credits (BE-WL)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08).
> It is a behavioural specification written fresh from executed vectors and probes, not source code. Proprietary
> clean-room rebuilds should have it reviewed (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90`. A **wallet** holds prepaid credits of one customer in one currency. Credits are
bought (paid credits, settled by a credit invoice) or granted (free), are consumed by finalized invoices (prepaid
credits, the last step of the invoice totals pipeline of chapter 07), can be voided, and are refilled automatically
by recurring rules (on a calendar interval or when the balance falls under a threshold). Between invoices the engine
keeps an **ongoing balance** that subtracts the not-yet-invoiced usage of the customer. This chapter specifies the
money/credit conversions, transaction requests, traceable consumption, recurring top-ups, allocation to invoices and
the ongoing balance. Wallet alerts are chapter 10 (BE-AL); the clock jobs that drive expiry, interval top-ups and
the ongoing-balance refresh are chapter 13; webhook payloads are chapter 12.

Reading guide: rules are numbered `BE-WL-n`; every rule line ends with `[vec: …]` naming the vectors that pin it, or
a prose-only marker with the reason. Vector file: `wallets.jsonl` (ops `wallets.credits`, `wallets.top_up`,
`wallets.consumption_order`, `wallets.topup_amount`, `wallets.threshold_top_up`, `wallets.interval_due`,
`wallets.allocate`, `wallets.ongoing_balance`; schemas in `reimplementation-kit/schemas/ops/wallets.*.schema.json`).
End-to-end flows: `scn.wallet.*`, `scn.invoice.prepaid.*` (scenario tier). Most wallet features beyond plain prepaid
credits are gated by the premium licence (RBD-97). `⊘` marks a binary64 division (notation of chapter 07, reading
guide).

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun against the oracle -->

## 1. Entities

| Entity | Fields that matter for behaviour |
|---|---|
| wallet | `currency`; `rate_amount` (> 0, currency amount of ONE credit); `balance_cents` and `credits_balance` (decimal, 5 places); `ongoing_balance_cents`, `credits_ongoing_balance`, `ongoing_usage_balance_cents`, `credits_ongoing_usage_balance`; `consumed_credits`, `consumed_amount_cents`; `priority` 1..50 (default 50, lower = used first); `allowed_fee_types` (subset of charge, subscription, add_on, fixed_charge, commitment, credit; empty = all); billable-metric targets (empty = all); `traceable`; `paid_top_up_min_amount_cents` / `paid_top_up_max_amount_cents` (optional, > 0, max ≥ min); `invoice_requires_successful_payment`; `expiration_at`; `status` active \| terminated; `depleted_ongoing_balance`; `code` (unique among the customer's active wallets) |
| wallet transaction | `transaction_type` inbound \| outbound; `status` pending \| settled \| failed; `transaction_status` purchased \| granted \| voided \| invoiced; `source` manual \| interval \| threshold; `amount` (currency, 5 places), `credit_amount` (credits, 5 places), money in minor units = `amount × 10^exponent`; `remaining_amount_cents` (inbound of traceable wallets only); `priority` 1..50; `invoice` (outbound invoiced), `voided_invoice` (re-credit) |
| consumption | link inbound → outbound with `consumed_amount_cents` (> 0) — traceable wallets only |
| recurring rule | `trigger` interval \| threshold; `interval` weekly \| monthly \| quarterly \| semiannual \| yearly; `method` fixed \| target; `paid_credits`, `granted_credits`, `threshold_credits`, `target_ongoing_balance`; `grants_target_top_up` (target only); `ignore_paid_top_up_limits`; `started_at`; `expiration_at`; `status` active \| terminated. At most one rule per wallet through the API. |

Status machines (chapter 01, BE-DM-64): wallet active → terminated; transaction pending → settled \| failed.

## 2. Credits and money

Notation: `e` = currency exponent (appendix-currencies), `round_e` = round half away from zero to `e` places.

- **BE-WL-1** Credits to money: `amount = round_e(credits × rate_amount)`; `amount_cents = amount × 10^e` (an integer). [vec: wallets.credits.001, wallets.credits.004, wallets.credits.008, wallets.credits.009]
- **BE-WL-2** Invoiceable credits (paid and granted credits, outbound invoiced amounts) are snapped to whole minor units: the credit count kept is `amount ÷ rate_amount`, so credits that cannot be expressed in whole minor units are rounded away (1034 credits at 0.001 EUR become 1030). How the reference divides depends on the currency exponent: for `e = 0` the amount is a whole number and the division is binary64 (a "float island", RBD-96: 3.3 credits at 1.5 JPY become `5 ⊘ 1.5` = 3.3333333333333335); for `e > 0` it is a decimal division (0.333 credits at 3 EUR: amount 1.00, credits 0.33333333333333333333333333333333, 32 digits; vectors compare such quotients at 20 places). [vec: wallets.credits.001, wallets.credits.004, wallets.credits.009, wallets.credits.012, wallets.credits.014]
- **BE-WL-3** Non-invoiceable conversions (voided credits) keep the requested credit count while the money amount is rounded, so the credit and money balances can diverge (RBD-81). [vec: wallets.credits.002, wallets.top_up.015]
- **BE-WL-4** Money to credits: the minor-unit amount is first rounded half away from zero to an integer, `amount = that ⊘ 10^e` (binary64), then `credits = amount / rate_amount` as a decimal division of the amount's binary64 text (100 cents at rate 3 EUR: 1.0, then 0.33333333333333333333…, not the binary64 0.3333333333333333); the credits are then snapped as invoiceable credits (BE-WL-2), which for `e = 0` recomputes them as the binary64 `amount ⊘ rate_amount` (5 JPY at rate 1.5: 3.3333333333333335, not the decimal 3.33333333333333333333…). Used when an amount of money is taken from a wallet (prepaid credits, voiding a remaining amount, the min/max top-up limits in credits). [vec: wallets.credits.011, wallets.credits.013, wallets.credits.014, wallets.allocate.012]
- **BE-WL-5** "Rounds to zero": a credit amount floored to 5 decimal places that is positive but converts (BE-WL-1) to 0 minor units. 0 credits, and amounts that floor to 0, do not round to zero. [vec: wallets.credits.005, wallets.credits.007, wallets.credits.008, wallets.credits.010, wallets.top_up.003]

## 3. Transaction requests (top-up, grant, void)

One request carries any of `paid_credits`, `granted_credits`, `voided_credits` (decimal text) and is processed in
that order on an active wallet. Wallet creation with initial credits issues the same request asynchronously.

- **BE-WL-6** Validation (all errors collected, field = the request field): wallet unknown → `wallet_not_found`; terminated → `wallet_is_terminated` (field `wallet_id`); an amount that is not decimal text in [0, 10^25 − 1] → `invalid_paid_credits` / `invalid_granted_credits` / `invalid_voided_credits` (plus `invalid_amount`); paid or granted credits that round to zero (BE-WL-5) → `amount_rounds_to_zero`; voided credits above `credits_balance` → `insufficient_credits`; naming an inbound transaction to void on a non-traceable wallet → `wallet_not_traceable`, an unknown one → `wallet_transaction_not_found`, one with nothing remaining → `no_remaining_amount` (field `voided_transaction_id`). Errors are collected in that order (wallet, paid, granted, voided, voided transaction); a caller that reports one error reports the first collected, and for an invalid amount the specific `invalid_<field>` code comes before `invalid_amount`. [vec: wallets.top_up.003, wallets.top_up.012, wallets.top_up.014]
- **BE-WL-7** Each amount is floored to 5 decimal places before use; an amount that is then 0 creates no transaction. [vec: wallets.top_up.001, wallets.top_up.013]
- **BE-WL-8** Paid credits only: the money value (BE-WL-1) must be ≥ `paid_top_up_min_amount_cents` (else `amount_below_minimum`) and ≤ `paid_top_up_max_amount_cents` (else `amount_above_maximum`), unless the request says `ignore_paid_top_up_limits`. Granted credits are never limited. [vec: wallets.top_up.005, wallets.top_up.006, wallets.top_up.007]
- **BE-WL-9** Paid credits create an inbound `purchased` transaction with status `pending` (credits snapped, BE-WL-2) and a **credit invoice** (chapter 07: one credit fee, no tax). The balance does not change yet. When the credit invoice's payment succeeds the transaction is settled and the balance increases (BE-WL-10 arithmetic; traceable wallets get `remaining_amount_cents = amount_cents`); a failed payment marks it `failed`; a credit invoice settled by a credit-note offset instead of a payment also marks it `failed` (no credits). With `invoice_requires_successful_payment` (premium) the credit invoice stays `open` without a number until paid, then is finalized; the flag affects only the invoice, credits are added on payment success in both cases. [vec: wallets.top_up.001, wallets.top_up.007, scn.wallet.topup.001]
- **BE-WL-10** Granted credits create an inbound `granted` transaction, `settled` at once: `balance_cents += amount_cents`, `credits_balance += credits` (traceable wallets: `remaining_amount_cents = amount_cents`). [vec: wallets.top_up.001]
- **BE-WL-11** A grant with `reset_consumed_credits` (used to give back the wallet usage of a voided invoice, RBD-74) also lowers the consumption counters: `consumed_credits = max(0, consumed_credits − credits)`, `consumed_amount_cents = max(0, floor((consumed_credits_before − credits) × rate_amount × 10^e))`. [vec: wallets.top_up.009, wallets.top_up.010]
- **BE-WL-12** Voided credits create an outbound `voided` transaction, settled at once, and decrease the wallet like a consumption: `balance_cents −= amount_cents`, `credits_balance −= credits`, `consumed_credits += credits`, `consumed_amount_cents += amount_cents`; the voided credit count is not snapped (BE-WL-3). On a traceable wallet the void may name one inbound transaction (it must have a remaining amount; omitting the amount voids its whole remaining amount); otherwise it consumes by BE-WL-13. [vec: wallets.top_up.011, wallets.top_up.015]

## 4. Traceable wallets: consumption order

A wallet is created traceable when the customer has no active non-traceable wallet. A traceable wallet's balance
must stay ≥ 0; a non-traceable wallet may go negative through usage.

- **BE-WL-13** Every outbound transaction of a traceable wallet (invoiced or voided) consumes the settled inbound transactions with a positive remaining amount in this order: `priority` ascending, then granted before any other status, then oldest first; each consumption takes `min(remaining, still to consume)`. The invoice's prepaid amount is split into granted and purchased parts from these consumptions when every wallet of the customer is traceable. [vec: wallets.consumption_order.001, wallets.consumption_order.002, wallets.allocate.011, scn.wallet.traceability.001, scn.wallet.traceability.003]
- **BE-WL-14** An outbound aimed at one inbound transaction consumes only that one; more than its remaining amount → `exceeds_remaining_transaction_amount` (field `amount_cents`). The named transaction always exists here: an unknown one is rejected earlier by the request validation (`wallet_transaction_not_found`, BE-WL-6). [vec: wallets.consumption_order.004, wallets.consumption_order.005]
- **BE-WL-15** More than the total remaining amount → `exceeds_available_amount` (field `amount_cents`); nothing is consumed. [vec: wallets.consumption_order.003]
- **BE-WL-16** Every decrease (invoice, void) applies the BE-WL-12 arithmetic to the wallet; the remaining amount of inbound transactions never goes below 0. [vec: wallets.top_up.011, wallets.top_up.015]

## 5. Recurring top-up rules

### 5.1 Amounts

Inputs: the rule, the wallet's `credits_ongoing_balance` (call it `ongoing`), and the credits of the wallet's pending
purchased transactions (`pending`). Limits in credits: `min_c` / `max_c` = the wallet's paid top-up limits converted
by BE-WL-4 (absent when the limit is absent).

- **BE-WL-20** Interval trigger, fixed method: paid = the rule's `paid_credits`, granted = its `granted_credits`, whatever the balance. [vec: wallets.topup_amount.001]
- **BE-WL-21** Threshold trigger, fixed method: if `paid_credits = 0` (or no threshold), paid = `paid_credits`. Otherwise `gap = threshold_credits − ongoing − granted_credits − pending`; if `gap < paid_credits`, paid = `paid_credits`; else paid = `paid_credits × (floor(gap ÷ paid_credits) + 1)` (it always tops up *past* the threshold), then capped at `max_c` unless the rule ignores limits. Granted = `granted_credits`. [vec: wallets.topup_amount.002, wallets.topup_amount.003, wallets.topup_amount.005, wallets.topup_amount.007, wallets.topup_amount.008, wallets.topup_amount.009, wallets.topup_amount.010]
- **BE-WL-22** Target method (either trigger), paying: if `ongoing ≥ target_ongoing_balance` paid = 0; else paid = `target − ongoing`, raised to `min_c` unless the rule ignores limits; the maximum is never applied. Granted = 0. [vec: wallets.topup_amount.011, wallets.topup_amount.014]
- **BE-WL-23** Target method with `grants_target_top_up`: paid = 0 and granted = `target − ongoing` (0 when reached), with no minimum. [vec: wallets.topup_amount.013]
- **BE-WL-24** The limits in credits come from the money limits through BE-WL-4 (a 25.00 EUR minimum at rate 0.5 is 50 credits). [vec: wallets.topup_amount.007, wallets.topup_amount.008, wallets.topup_amount.011]

### 5.2 Threshold trigger

- **BE-WL-25** After an ongoing-balance refresh that changed the ongoing balance or the ongoing usage (BE-WL-55), the first active threshold rule of the wallet is evaluated: nothing when `credits_ongoing_balance > threshold_credits`, nothing when `pending + credits_ongoing_balance > threshold_credits`; otherwise a top-up request is issued with the BE-WL-21..23 amounts. [vec: wallets.threshold_top_up.001, wallets.threshold_top_up.002, wallets.threshold_top_up.003, wallets.threshold_top_up.004, wallets.threshold_top_up.008]
- **BE-WL-26** Decline back-off: when the paid amount is positive and an automatic (threshold) purchased top-up of the wallet failed less than one hour ago, no request is issued unless a purchased top-up of the wallet was settled after that failure. [vec: wallets.threshold_top_up.005]
- **BE-WL-27** The request carries source `threshold`, the rule's transaction metadata and name, ignores the paid limits for target rules (and when the rule says so), is delayed 2 seconds and is de-duplicated while one is queued. Three or more automatic top-ups within 10 minutes only raise an operational warning. [vec: wallets.threshold_top_up.001]

### 5.3 Interval trigger

The interval sweep runs from the clock (chapter 13) at a time `now`. The **anchor** is the rule's `started_at`, or the
wallet creation instant when absent, expressed as a local date in the customer's effective time zone (BE-DM time
zone rules); `today` is `now` in the same zone.

- **BE-WL-28** A rule is due when the anchor matches today: weekly = same ISO weekday; monthly = same day of month, where on the last day of a month every anchor day from today's day to 31 matches; quarterly = the month is the anchor month plus a multiple of 3 (anchor months 3, 6, 9, 12 match those months) and the day rule of monthly; semiannual = anchor month or anchor month + 6, plus the day rule; yearly = same month and day, where Feb 28 of a non-leap year also matches an anchor on Feb 29. [vec: wallets.interval_due.001, wallets.interval_due.003, wallets.interval_due.004, wallets.interval_due.005, wallets.interval_due.007, wallets.interval_due.011, wallets.interval_due.016]
- **BE-WL-29** Not due: wallet or rule not active; the anchor has not started — the reference compares the anchor's **local wall-clock time** with `now` read as a UTC wall-clock time, so the start shifts by the zone offset on the anchor day (ahead of UTC a rule started in the last offset-hours of its local day is never due that day and its first top-up is skipped; behind UTC it is due up to the offset before its start instant; RBD-105, compat kept; proposed: compare instants); the rule expired (`expiration_at ≤ now`); the wallet was created today (local date, even when the rule has an earlier `started_at`); the wallet already received an inbound interval top-up today (local date). [vec: wallets.interval_due.009, wallets.interval_due.010, wallets.interval_due.013, wallets.interval_due.014, wallets.interval_due.017, wallets.interval_due.017x]
- **BE-WL-30** A due target rule whose paid and granted amounts are both 0 issues nothing. [vec: wallets.interval_due.015]
- **BE-WL-31** A due rule issues one top-up request with source `interval` and the BE-WL-20/22/23 amounts computed at sweep time from the wallet's ongoing balance in credits (a wallet at 0 tops a target rule up by its whole target); target rules ignore the paid limits. [vec: wallets.interval_due.001, wallets.interval_due.018]

## 6. Prepaid credits on an invoice

Runs once per finalized invoice when its total is still positive after credit notes (chapter 07, BE-IV-31). Amounts
below are minor units and may be fractional until BE-WL-44.

- **BE-WL-40** Eligible wallets: active, `balance_cents > 0`, same currency as the invoice; ordered by `priority` ascending, then creation time. [vec: wallets.allocate.001, wallets.allocate.009]
- **BE-WL-41** Fee buckets: each fee with `sub_total = amount_cents − precise_coupons ≠ 0` contributes `cap = sub_total + taxes_precise_amount − precise_credit_notes_amount` when `cap > 0`, to the bucket keyed by (fee type, billable metric of the charge or none[, target wallet code — only when the organization enables event-targeted wallets and the charge accepts a target wallet]). Caps of a bucket add up. [vec: wallets.allocate.003, wallets.allocate.008]
- **BE-WL-42** Buckets are ordered by cap descending; equal caps come in an order the reference does not define (fee storage order through an unstable sort), which changes the result only when restricted wallets compete for the tied buckets (vectors avoid that case; see BE-WL-52 and RBD-104). Reconciliation: `d = invoice total − Σ caps`; when `0 < d ≤ number of buckets` (a rounding gap), `d` is added to the first (largest) bucket; otherwise caps stay as they are. [vec: wallets.allocate.003, wallets.allocate.005, wallets.allocate.006, wallets.allocate.007]
- **BE-WL-43** For each wallet in order, for each bucket in order with a positive remainder that the wallet may pay — a bucket with a target wallet code only by the wallet whose code equals it; otherwise when the wallet targets that (charge, metric), or allows that fee type, or has neither restriction — take `min(bucket remainder, wallet balance − already taken from this wallet, invoice remainder)`. [vec: wallets.allocate.001, wallets.allocate.003, wallets.allocate.004, scn.invoice.prepaid.002]
- **BE-WL-44** Each wallet with a positive total gets ONE outbound `invoiced` transaction, settled: its money is the wallet total converted by BE-WL-4 (so rounded half away to whole minor units) and its credits follow the rate; traceable wallets consume by BE-WL-13; the balance decreases (BE-WL-12 arithmetic); `invoice.prepaid_credit_amount_cents += Σ transaction amounts`; then all wallets of the customer get an ongoing-balance refresh. [vec: wallets.allocate.001, wallets.allocate.007, wallets.allocate.011, wallets.allocate.012, scn.invoice.prepaid.001]
- **BE-WL-45** Prepaid credits are applied at most once per invoice (a second attempt fails with `already_applied`), and never on drafts, one-off invoices or credit invoices (chapter 07 variant matrix). [vec: scn.invoice.prepaid.001, scn.invoice.prepaid.002]

## 7. Ongoing balance

The ongoing balance anticipates what the next invoices will consume. It is recomputed for all active wallets of a
customer together (the allocation of one depends on the others).

- **BE-WL-50** Net usage per fee key (fee type, billable metric, target wallet code, currency): `+ (amount + taxes)` of each current-usage fee of the customer's active subscriptions; `+ (amount + taxes − precise coupons)` of each fee of the customer's draft invoices with a non-zero total; `− (sub_total + taxes)` of each fee of the subscription's progressive-billing invoices already billed in the current period (chapter 10); `− (amount + taxes)` of each current-usage fee of a charge billed in advance (already invoiced at event time; this subtraction applies to current-usage fees only, so a draft-invoice or progressive-billing fee of such a charge counts fully). [vec: wallets.ongoing_balance.001, wallets.ongoing_balance.004, wallets.ongoing_balance.011]
- **BE-WL-51** Budget per currency = `max(0, Σ nets of that currency)`; keys with a net ≤ 0 receive nothing but their negative nets lower the budget. [vec: wallets.ongoing_balance.004, wallets.ongoing_balance.005]
- **BE-WL-52** Keys with a positive net, largest first, are allocated to the applicable wallets (BE-WL-43 applicability, same currency) in wallet order: `take = min(net remaining, budget)`; a wallet with an active threshold rule takes everything left (its room counts as 0, it may go negative); the last applicable wallet takes everything left; any other wallet takes at most `balance − already allocated to it`. Equal nets are ordered by the text of the key's parts in turn (fee type, metric, target wallet code, currency): fee types compare as text (`charge` before `subscription`, the same in both profiles: `wallets.ongoing_balance.009` is `both`), but the metric part is the metric's internal id, so two metrics with equal nets come in an order a rebuild cannot reproduce, and the split across restricted wallets depends on it (RBD-104, compat kept; proposed: the metric's code in place of its internal id). [vec: wallets.ongoing_balance.002, wallets.ongoing_balance.003, wallets.ongoing_balance.005, wallets.ongoing_balance.006, wallets.ongoing_balance.009, wallets.ongoing_balance.010x, scn.wallet.balance.001]
- **BE-WL-53** Per wallet: `ongoing_usage_balance_cents` = its allocation; `ongoing_balance_cents = balance_cents − allocation`; credit forms = `(cents ⊘ 10^e) / rate_amount` — binary64 to money, then a decimal division by the rate — stored at 5 places. [vec: wallets.ongoing_balance.001]
- **BE-WL-54** `depleted_ongoing_balance` turns true when the ongoing balance becomes ≤ 0 (webhook `wallet.depleted_ongoing_balance`, chapter 12) and back to false when it becomes > 0. [vec: wallets.ongoing_balance.001, wallets.ongoing_balance.002]
- **BE-WL-55** After each refresh: the threshold rule check (BE-WL-25, only when the ongoing state changed) and the wallet alerts (chapter 10). Refreshes happen after every wallet decrease and grant, and periodically for customers flagged for refresh; the reference schedules the periodic refresh only when a cache backend is configured (RBD-79, chapter 13). [vec: scn.wallet.balance.001, scn.wallet.alert.001]

## 8. Lifecycle

- **BE-WL-60** Creation: at most 6 active wallets per customer (an organization limit replaces 6 when event-targeted wallets are enabled) → `wallet_limit_reached`; the code defaults to the name in snake case (or `default`), suffixed with the creation epoch second when taken; a blank customer currency is set from the wallet; initial paid/granted credits are rejected when they round to zero and paid ones are checked against the limits, then issued as a request (section 3). [vec: none (prose only: API resource behaviour, exercised by the scenario tier)]
- **BE-WL-61** Expiration: wallets with `expiration_at ≤ now` are terminated by the clock (hourly); terminating a wallet terminates its rules and does not void the remaining balance. Expired rules are terminated by the clock as well. [vec: none (prose only: clock wiring, chapter 13)]
- **BE-WL-62** Voiding an invoice without a credit note gives every invoiced outbound transaction of an active wallet back as a granted grant with `reset_consumed_credits` (BE-WL-11) linked to the voided invoice (RBD-74); amounts that round to zero are skipped. [vec: wallets.top_up.009, scn.invoice.void.001]

## 9. Edge cases

| Case | Behaviour | Vectors |
|---|---|---|
| 1034 credits at 0.001 EUR | 1030 credits, 1.03 EUR (credits that are not whole minor units vanish) | wallets.credits.001 |
| credits 0.000009 | floors to 0: no transaction, not "rounds to zero" | wallets.credits.010, wallets.top_up.013 |
| threshold rule, balance −50, paid 50, threshold 10 | 100 credits (past the threshold, never landing on it) | wallets.topup_amount.003 |
| target rule and wallet maximum | the maximum is ignored | wallets.topup_amount.014 |
| monthly anchor 31, February | due on the last day of February | wallets.interval_due.003 |
| invoice total 3, caps 1.2 + 1.2 | rounding gap reconciled: 3 | wallets.allocate.007 |
| invoice total 10, caps 1.2 + 1.2 | gap too large, 2.4 rounded to 2 | wallets.allocate.006 |
| wallet with a threshold rule | absorbs all ongoing usage, may go negative | wallets.ongoing_balance.003 |
| ongoing balance exactly 0 | depleted | wallets.ongoing_balance.002 |
| interval rule started at 23:00 local in a zone ahead of UTC | not due that day, first top-up skipped (RBD-105) | wallets.interval_due.017, wallets.interval_due.017x |
| equal ongoing nets of two metrics, restricted wallets | split depends on internal ids (RBD-104) | wallets.ongoing_balance.010x |

## 10. Vectors

| File / op | Count | Rules |
|---|---|---|
| `wallets.credits` | 14 | BE-WL-1..5 |
| `wallets.top_up` | 15 | BE-WL-3, BE-WL-5..12 |
| `wallets.consumption_order` | 6 | BE-WL-13..15 |
| `wallets.topup_amount` | 14 | BE-WL-20..24 |
| `wallets.threshold_top_up` | 8 | BE-WL-25..27 |
| `wallets.interval_due` | 19 (1 corrected twin) | BE-WL-28..31 |
| `wallets.allocate` | 12 | BE-WL-40..44 |
| `wallets.ongoing_balance` | 11 (1 corrected) | BE-WL-50..54 |

All compat-graded vectors are EXECUTED through the oracle; all are `both` profile except the RBD-105 pair
(`wallets.interval_due.017` compat, `.017x` corrected) and `wallets.ongoing_balance.010x`, a corrected vector without
a compat twin because the reference's order of tied metrics is not reproducible. Corrected vectors are graded only
when the owner rules RBD-104 and RBD-105. The floating-point steps — the credit division of a zero-exponent
currency (BE-WL-2, also reached by BE-WL-4 through the snap) and the cents-to-money step `cents ⊘ 10^e` (BE-WL-4,
BE-WL-53) — are float islands under RBD-96; the credit division of other currencies is decimal (`wallets.credits.012`,
`wallets.credits.013`, compared at 20 places). `wallets.credits.014` (5 JPY at 1.5 → 3.3333333333333335, compared
exactly) tells the zero-exponent island apart from a decimal division; `wallets.credits.004` is compared as binary64.
The cents-to-money step has no discriminating input: a whole number of minor units divided by `10^e` reads back as the
exact decimal. Notation `⊘`: chapter 07 reading guide.

## Provenance (maintainers)

| Rules | Reference behaviour at the pin |
|---|---|
| BE-WL-1..5 | `$API/app/models/wallet_credit.rb:7-36` |
| BE-WL-6..8 | `$API/app/services/wallet_transactions/validate_service.rb:5-86`; `$API/app/services/validators/wallet_transaction_amount_limits_validator.rb:19-48`; `$API/app/services/wallet_transactions/create_from_params_service.rb:36-57` |
| BE-WL-9 | `$API/app/services/wallet_transactions/create_from_params_service.rb:114-143`; `$API/app/services/invoices/paid_credit_service.rb:24-29`; `$API/app/jobs/invoices/prepaid_credit_job.rb:17-41`; `$API/app/services/wallets/apply_paid_credits_service.rb:13-22`; `$API/app/services/wallet_transactions/settle_service.rb:20-24` |
| BE-WL-10..12 | `$API/app/services/wallet_transactions/create_from_params_service.rb:145-173`; `$API/app/services/wallets/balance/increase_service.rb:16-38`; `$API/app/services/wallets/balance/decrease_service.rb:19-26`; `$API/app/services/wallet_transactions/void_service.rb:23-84` |
| BE-WL-13..16 | `$API/app/models/wallet_transaction.rb:80-88`; `$API/app/services/wallet_transactions/track_consumption_service.rb:14-84`; `$API/app/services/credits/applied_prepaid_credits_service.rb:73-93`; `$API/app/models/wallet.rb:55`; `$API/app/services/wallets/create_service.rb:245-247` |
| BE-WL-20..24 | `$API/app/models/recurring_transaction_rule.rb:72-153`; `$API/app/models/wallet.rb:83-93` |
| BE-WL-25..27 | `$API/app/services/wallets/threshold_top_up_service.rb:7-88`; `$API/app/services/wallets/balance/update_ongoing_service.rb:16-31` |
| BE-WL-28..31 | `$API/app/services/wallets/create_interval_wallet_transactions_service.rb:7-271` |
| BE-WL-40..45 | `$API/app/services/credits/allocate_prepaid_credits_by_wallets_service.rb:29-130`; `$API/app/services/credits/applied_prepaid_credits_service.rb:13-124` |
| BE-WL-50..55 | `$API/app/services/customers/refresh_wallets_service.rb:14-81`; `$API/app/services/wallets/balance/allocate_ongoing_usage_by_wallets_service.rb:33-146`; `$API/app/services/wallets/balance/refresh_ongoing_usage_service.rb:16-68`; `$API/clock.rb:57-70` |
| BE-WL-60..62 | `$API/app/services/wallets/create_service.rb:14-91`, `:161-186`; `$API/app/services/wallets/validate_service.rb:5-50`; `$API/app/services/wallets/terminate_service.rb:11-28`; `$API/app/services/wallet_transactions/recredit_service.rb:15-38` |

Executions on the pinned toolchain (ruby-4.0.6, 2026-10-02, a dedicated oracle database):

- `oracle.sh run spec/models/wallet_credit_spec.rb spec/models/recurring_transaction_rule_spec.rb
  spec/models/usage_monitoring/alert_spec.rb spec/services/lifetime_usages/usage_thresholds/check_service_spec.rb`
  → `{"example_count":132,"failure_count":0,…}`.
- `oracle.sh run spec/scenarios/wallets spec/services/wallets spec/services/wallet_transactions
  spec/services/credits/allocate_prepaid_credits_by_wallets_service_spec.rb spec/services/credits/applied_prepaid_credits_service_spec.rb
  spec/services/customers/refresh_wallets_service_spec.rb spec/scenarios/invoices/{progressive_billing,negative_total_with_prepaid_credits,invoicing_with_prepaid_credits}_spec.rb
  spec/models/{wallet,wallet_transaction}_spec.rb` and the chapter 10 spec set (88 files in one run, one ClickHouse-tagged
  file under the shared lock) → `{"example_count":1141,"failure_count":0,…}`.
- Oracle module `scripts/maintainer/oracle-adapter/ops/wallet.rb`: builds wallets, transactions, rules, invoices and
  fees with the reference factories in a rolled-back transaction and calls the real conversion model, transaction
  request service, consumption tracker, rule model, threshold top-up service, interval sweep (with its `direct` query
  role sharing the writing pool), prepaid-credit services and ongoing-usage services. Vectors mirrored from reference
  examples carry the example line in `evidence.ref`; the oracle reproduced every asserted value. A mutation run (one
  expected value changed in each of the 173 compat-graded vectors of chapters 09-10) failed 173/173; the unmutated
  files pass 173/173 (`kitrun.py --areas wallets,progressive,alerts` against the oracle).
- Fix round of 2026-10-02: RBD-105 from the interval sweep's start test (`$API/app/services/wallets/create_interval_wallet_transactions_service.rb:98`,
  anchor expression `:245-252`, zone conversion `$API/app/services/utils/timezone.rb:16-19`), pinned by
  `wallets.interval_due.017` through the oracle (Asia/Tokyo, start 14:00Z, sweep 14:30Z → not due). RBD-104 from the
  tie-break of the ongoing allocation (`$API/app/services/wallets/balance/allocate_ongoing_usage_by_wallets_service.rb:98-104`,
  key `:118-124`); the prepaid allocation sorts by cap only (`$API/app/services/credits/allocate_prepaid_credits_by_wallets_service.rb:89`).
  Probe: the input of `wallets.ongoing_balance.010x` run 12 times through the oracle gave a 100 / b 100 seven times
  and a 200 / b 0 five times; `wallets.ongoing_balance.009` (charge before subscription) gave the same result in 10 of 10 runs. Oracle re-run of
  chapters 09-10: 175/175 compat-graded vectors PASS.
- Fix round of 2026-10-05 (database `lago_api_test_fr2g4`): the credit conversions of `$API/app/models/wallet_credit.rb:7-36`
  divide a rounded amount by the rate through the float-division helper, which returns a binary64 only when the amount
  is a whole number (zero-exponent currencies) and a decimal otherwise — executed: 0.333 credits at 3 EUR and 100 cents
  at 3 EUR give 0.33333333333333333333333333333333 (`wallets.credits.012`, `.013`) while 3.3 credits at 1.5 JPY give
  3.3333333333333335 (`wallets.credits.004`); the ongoing credit forms divide `cents ⊘ 10^e` by the rate the same way
  (`$API/app/services/wallets/balance/refresh_ongoing_usage_service.rb:58-68`). Pay-in-advance subtraction only for
  current-usage fees: `$API/app/services/customers/refresh_wallets_service.rb:56-59`, executed
  (`wallets.ongoing_balance.011`). Interval target rule on a wallet at 0 credits: `wallets.interval_due.018`. An unknown
  inbound transaction named in a consumption is looked up with a raising find in
  `$API/app/services/wallet_transactions/track_consumption_service.rb:33`; requests reach it only after the validation of
  BE-WL-6. kitrun of chapters 09-10 against the oracle (shipped and holdout) PASS within the 392/392 run of chapter 07.
- Independent verification of 2026-10-05 (database `lago_api_test_v2g4`): money to credits for a zero-exponent
  currency passes through the invoiceable snap of `$API/app/models/wallet_credit.rb:26-32`, whose rounded amount is an
  integer, so the final division is binary64: 5 JPY at 1.5 → 3.3333333333333335 (`wallets.credits.014`, executed).
- Update triggers: a pin bump; any change to the wallet credit model, the wallet transaction services, the
  recurring rule model, the threshold and interval top-up services, the prepaid-credit allocation or the ongoing-usage
  allocation.
