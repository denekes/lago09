# 06 — Subscriptions and billing periods (BE-SP)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08).
> It is a behavioural specification written fresh from executed vectors and probes, not source code. Proprietary
> clean-room rebuilds should have it reviewed (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90`. This chapter specifies how a subscription moves through its life (creation,
activation, plan changes, termination, trials) and how the engine cuts time into billing periods: which period a
billing run bills, the windows handed to usage aggregation (chapter 04) and fixed charges (chapter 05), on which
local days the clock bills a subscription, and how the subscription fee (the plan amount) is prorated. Invoice
assembly (taxes, coupons, credits) is chapter 07; the termination credit note itself is chapter 08.

Reading guide: rules are numbered `BE-SP-n`; every rule line ends with `[vec: …]` naming the vectors (in
`billing-engine-spec/vectors/periods.*.jsonl`) or scenarios (`scn.*`) that pin it, or a prose-only marker with the
reason. Day counting is BE-DM-15..18, the "termination reached" test BE-DM-19, the effective time zone BE-DM-10
(chapter 01). Vector inputs follow `reimplementation-kit/reference/vector-format.md`; the op schemas
`reimplementation-kit/schemas/ops/periods.*.schema.json` define every input field and its default.

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun against the oracle -->

## 1. Concepts

| Field | Meaning |
|---|---|
| `subscription_at` | requested start; its **local date** in the customer's effective zone is the **anchor** `A` (day `A.d`, month `A.m`, weekday `A.wd`); plan changes keep it |
| `started_at` | actual service start (set at activation; may differ from `subscription_at`) |
| `ending_at` | scheduled end; the clock terminates the subscription on that local day |
| `terminated_at` | actual end (set once and never changed by a later termination) |
| `canceled_at` | set when a not-yet-started (pending) or payment-gated subscription is abandoned |
| `trial_ended_at` | set once the trial-end billing has run |
| `billing_time` | `calendar` (periods follow the calendar) or `anniversary` (periods follow the anchor); default calendar |
| plan `interval` | `weekly`, `monthly`, `quarterly`, `semiannual`, `yearly` |
| plan `pay_in_advance` | the subscription fee is billed at the start of its period (advance) or after its end (arrears) |
| plan `trial_period` | trial length in days (a decimal; fractions allowed) |
| plan `bill_charges_monthly`, `bill_fixed_charges_monthly` | yearly and semiannual plans only: bill usage charges / fixed charges every month (the "monthly split") |
| successor, predecessor | a plan change links two subscriptions with the same external id: the **successor** of a subscription is the most recently created non-canceled subscription that replaces it (pending until the change takes effect, then active); the replaced subscription is its **predecessor**. "Upgraded" = has a successor whose yearly-normalised amount (BE-SP-51) is greater or equal; "downgraded" = has a successor with a lower one |

Statuses: `pending` (created, not started), `active`, `terminated`, `canceled`, `incomplete` (waiting for a payment
gate). The state machine is section 8; wire values are in `appendix-enums.md`.

- **BE-SP-1** The time fields above are instants stored in UTC; every local date in this chapter is taken in the customer's effective time zone (BE-DM-10) at the moment it is needed. `terminated_at` is write-once: terminating again never moves it. [vec: none (prose only: field semantics; each field is exercised by the op vectors of sections 3-9)]
- **BE-SP-2** The monthly-split flags are meaningful only for yearly and semiannual plans; on other intervals they are ignored (the engine stores them empty). [vec: periods.boundaries.split.001]
- **BE-SP-3** The anchor is the local date of `subscription_at` in the effective zone, not its UTC date: 03:00 UTC on the 15th is the 14th for a customer in New York. Every boundary below is computed on local dates and converted back to UTC. [vec: periods.billing_days.monthly.005, periods.boundaries.clamp.002, periods.boundaries.dst.001, periods.boundaries.dst.002, periods.boundaries.dst.003, periods.boundaries.tz.001, periods.boundaries.tz.003]
- **BE-SP-4** A period covering local dates `s..e` runs from local `s 00:00:00` to local `e 23:59:59.999999` (microsecond precision, the stored precision), both converted to UTC with the offset in force at that instant; consecutive periods therefore meet one microsecond apart and daylight-saving changes move the UTC bounds, not the local dates. [vec: periods.boundaries.dst.001, periods.boundaries.dst.002, periods.boundaries.dst.003, periods.boundaries.monthly.002, periods.boundaries.tz.001, periods.boundaries.weekly.002]

## 2. Period algebra

Notation: `clamp(y, m, d)` = the date `y-m-min(d, days_in_month(y, m))`. A **period start** is a local date on which
a period of the subscription begins; a period runs from one start to the day before the next start.

- **BE-SP-5** Calendar starts: weekly — every Monday (ISO weeks); monthly — day 1 of every month; quarterly — day 1 of January, April, July, October; semiannual — January 1 and July 1; yearly — January 1. [vec: periods.boundaries.base.008, periods.boundaries.base.009, periods.boundaries.dst.001, periods.boundaries.dst.002, periods.boundaries.dst.003, periods.boundaries.monthly.001, periods.boundaries.monthly.002, periods.boundaries.monthly.003]
- **BE-SP-6** Anniversary monthly starts: `clamp(y, m, A.d)` for every month. Each start is re-clamped from the anchor day, never from the previous start, so short months never "drag" the anchor: anchor 31 gives Jan 31–Feb 27, Feb 28–Mar 30, Mar 31–Apr 29, Apr 30–May 30 (28, 31, 30, 31 days); anchor 30 gives Jan 30–Feb 27, Feb 28–Mar 29. An anchor on day 1 coincides with calendar months. [vec: periods.billing_days.monthly.001, periods.boundaries.base.001, periods.boundaries.base.002, periods.boundaries.monthly.005, periods.boundaries.monthly.006, periods.boundaries.tz.003, periods.chain.001]
- **BE-SP-7** Anniversary quarterly and semiannual starts: `clamp(y, m, A.d)` for the months `m` with `m ≡ A.m (mod 3)` (quarterly) or `m ≡ A.m (mod 6)` (semiannual). Anchor 31 August, quarterly: Aug 31–Nov 29, Nov 30–Feb 27, Feb 28–May 30, May 31–Aug 30; semiannual: Aug 31–Feb 27 (181 days), Feb 28–Aug 30 (184 days). [vec: periods.boundaries.base.010, periods.boundaries.quarterly.004]
- **BE-SP-8** Anniversary yearly starts: `clamp(y, A.m, A.d)` every year, so a 29 February anchor starts on 28 February in common years and on 29 February in leap years (Feb 28 2023–Feb 28 2024 is 366 days, Feb 29 2024–Feb 27 2025 is 365). [vec: periods.billing_days.yearly.001, periods.boundaries.base.006, periods.boundaries.tz.005, periods.boundaries.yearly.002, periods.boundaries.yearly.003, periods.boundaries.yearly.004, periods.boundaries.yearly.005, periods.chain.007]
- **BE-SP-9** Anniversary weekly starts: every date whose weekday is `A.wd` (periods of 7 days). [vec: periods.billing_days.weekly.001, periods.boundaries.base.007, periods.boundaries.weekly.004, periods.boundaries.weekly.005, periods.boundaries.weekly.008]
- **BE-SP-10** The **period of a date** `X`, `period(X)`, is the period whose start is the latest period start on or before `X`; its end is the day before the following start. [vec: periods.boundaries.base.001, periods.boundaries.base.008, periods.boundaries.base.009, periods.boundaries.clamp.001, periods.boundaries.clamp.003, periods.boundaries.dst.001, periods.boundaries.tz.001, periods.boundaries.tz.003]
- **BE-SP-11** The **length** of a period is its number of local days (end − start + 1): weekly 7; monthly 28-31; quarterly 89-92; semiannual 181-184; yearly 365 or 366 (a calendar year's own length; an anniversary year has 366 days when it contains a 29 February). Lengths are always those of whole periods, even when the subscription covers only part of one. [vec: periods.boundaries.base.006, periods.boundaries.base.009, periods.boundaries.dst.001, periods.boundaries.dst.002, periods.boundaries.dst.003, periods.subscription_fee.024, periods.termination_credit_days.008]

## 3. Boundaries of a billing run

A billing run for a subscription happens at an instant `billing_at` (the invoice timestamp). It produces the
subscription-fee period `[from_datetime, to_datetime]`, the usage-charges window `[charges_from, charges_to]` and the
fixed-charges window `[fixed_charges_from, fixed_charges_to]` (op `periods.boundaries`).

Let `D` = local date of `billing_at`. In **current-usage mode** (usage views, estimates, progressive billing,
section 4) the run looks at the running period; otherwise it bills the period that just ended (arrears) or that
just started (advance).

- **BE-SP-12** Base date `B`: in current-usage mode `B = D`. Otherwise `B` = `D` minus one interval (7 days; 1, 3, 6 or 12 calendar months, keeping the day of month and clamping it to the target month's length), with one correction for anniversary subscriptions of month-based intervals: when `D` is the last day of its month and `D.d < A.d`, `B = clamp(y, m, A.d)` where `y-m` is the month one interval before `D`'s month. Example: anchor 31, run on 30 April → `B` = 31 March (not 30 March), so the run bills Mar 31–Apr 29. [vec: periods.boundaries.base.001, periods.boundaries.base.002, periods.boundaries.base.006, periods.boundaries.base.007, periods.boundaries.base.008, periods.boundaries.tz.001]
- **BE-SP-13** "Terminated at billing time" = status `terminated` and `terminated_at` reached at `billing_at` (BE-DM-19: both rounded to whole seconds). A subscription whose status is terminated but whose termination lies after `billing_at` is treated as running for the fee period. [vec: periods.boundaries.clamp.003, periods.boundaries.clamp.004, periods.boundaries.clamp.006, periods.boundaries.clamp.008, periods.boundaries.clamp.009, periods.boundaries.clamp.010, periods.boundaries.monthly.003]
- **BE-SP-14** Subscription-fee period = `period(D)` when the plan is in advance, or when the subscription is terminated at billing time with an arrears plan and is not downgraded (no successor with a lower yearly amount — whether that successor is still pending or already activated by the rotation of BE-SP-53, whose invoice therefore bills the period that just ended); otherwise `period(B)`. [vec: periods.boundaries.base.001, periods.boundaries.base.008, periods.boundaries.base.009, periods.boundaries.clamp.001, periods.boundaries.clamp.003, periods.boundaries.dst.001, periods.boundaries.tz.001, periods.boundaries.tz.003]
- **BE-SP-15** Usage-charges period = `period(D)` when the subscription is terminated at billing time and has no successor at all; otherwise, for an arrears plan, the subscription-fee period; for an advance plan, `period(B)` (the fee is billed ahead, usage behind). [vec: periods.boundaries.base.008, periods.boundaries.base.009, periods.boundaries.base.010, periods.boundaries.clamp.001, periods.boundaries.clamp.003, periods.boundaries.clamp.006, periods.boundaries.clamp.008]
- **BE-SP-16** Fixed-charges period = the usage-charges period computed the same way, except where the monthly split of BE-SP-17 applies to one family only. [vec: periods.boundaries.tzchange.005]
- **BE-SP-17** Monthly split (yearly and semiannual plans): when `bill_charges_monthly` is set, the usage-charges period is computed by BE-SP-12..15 as if the plan were monthly with the same anchor day and billing time (calendar months, or `clamp(y, m, A.d)` months); `bill_fixed_charges_monthly` does the same for the fixed-charges period. The subscription-fee period always keeps the plan interval. The monthly family evaluates "terminated at billing time" (BE-SP-13, used by BE-SP-14/15) against **00:00:00 UTC of the local date `D`**, not against `billing_at` (RBD-103, compat): a split subscription whose termination instant is later than that is treated as not terminated for the monthly family, so the run at its termination bills the **previous** monthly period (terminated 20 March 2024 15:00 UTC, calendar → charges window 1–29 February, the window the periodic run of 1 March already billed), while a termination at or before that instant bills the current month up to the termination. West of UTC every termination falls after that instant; east of UTC only a termination before 00:00 UTC (local morning) bills the current month. Corrected profile (RBD-103, proposed): the monthly family tests the termination against `billing_at`, so the run bills the current monthly period up to the termination. The fee period and a non-split family use `billing_at` as usual; the clamps of BE-SP-21/22 apply afterwards. [vec: periods.boundaries.semiannual.009, periods.boundaries.semiannual.010, periods.boundaries.semiannual.011, periods.boundaries.split.001, periods.boundaries.split.003, periods.boundaries.split.004, periods.boundaries.split.005, periods.boundaries.split.010, periods.boundaries.split.010x, periods.boundaries.split.011, periods.boundaries.split.012, periods.boundaries.split.013, periods.boundaries.split.013x, periods.boundaries.split.014, periods.boundaries.split.014x, periods.boundaries.split.015, periods.boundaries.split.015x, periods.boundaries.split.016, periods.boundaries.split.016x, periods.invoice_boundaries.011, periods.invoice_boundaries.011x]

  Consequence and deployment note for BE-SP-17 (RBD-103). On the terminating invoice of a split subscription the
  repeated window is billed a second time: the duplicate check for charge fees looks only inside the invoice being
  built, so it does not see the fees of the periodic invoice that already billed that window, and the usage from the
  start of the current monthly period to the termination is never billed. The windows are executed
  (`periods.boundaries.split.001` for the periodic run of 1 March, `periods.boundaries.split.010` and
  `periods.invoice_boundaries.011` for the termination); the second billing follows from the reference's fee code
  and is not vectorised. "00:00 of `D`" is midnight in the reference **server process's** time zone, not a fixed
  UTC rule; the kit assumes a server running in UTC (the deployment norm) and every vector was produced that way. A
  server in another zone moves the cut-off accordingly.
- **BE-SP-18** Presence on split plans: a run is in the **first month** of the plan period when, for calendar plans, `D` falls in January (yearly) or January/July (semiannual); for anniversary plans, when the monthly period (anchor day `A.d`) that holds `D` starts in the anchor month (yearly) or in the anchor month or six months later (semiannual). Usage-charges bounds are present unless only `bill_fixed_charges_monthly` is set and the run is not in a first month (current usage always has them); fixed-charges bounds are present unless only `bill_charges_monthly` is set and the run is not in a first month — **even in current-usage mode**. Absent bounds are `null`. [vec: periods.boundaries.semiannual.009, periods.boundaries.semiannual.010, periods.boundaries.semiannual.011, periods.boundaries.split.001, periods.boundaries.split.003, periods.boundaries.split.004, periods.boundaries.split.005]
- **BE-SP-19** `from_datetime` = local start of the fee period's first day; when that is before `started_at`, it becomes the local start of `started_at`'s **day** (the subscription fee of a first period counts the whole start day). [vec: periods.boundaries.clamp.001, periods.boundaries.clamp.002]
- **BE-SP-20** `to_datetime` = local end of the fee period's last day; when the subscription is terminated at billing time and that end is after the termination, it becomes `terminated_at` rounded to the nearest whole second (half a second rounds up); finally, when it is before `started_at`, it becomes `started_at`. [vec: periods.boundaries.clamp.003, periods.boundaries.clamp.004, periods.boundaries.clamp.010, periods.boundaries.monthly.003, periods.boundaries.monthly.006, periods.boundaries.semiannual.005]
- **BE-SP-21** `charges_from` = local start of the charges period's first day (after the zone-change rule BE-SP-23); when that is before `started_at`, it becomes **exactly** `started_at` (usage counts from the start instant, unlike the fee). [vec: periods.boundaries.clamp.001, periods.boundaries.clamp.002]
- **BE-SP-22** `charges_to` = local end of the charges period's last day; when the subscription's status is `terminated` (whatever the run instant) and `terminated_at` is not after that end, it becomes exactly `terminated_at` (not rounded); when it is before `started_at`, it becomes `started_at`. Fixed-charges bounds follow BE-SP-21/22 with the fixed-charges period. [vec: periods.boundaries.clamp.003, periods.boundaries.clamp.004, periods.boundaries.clamp.006, periods.boundaries.clamp.008, periods.boundaries.clamp.009, periods.boundaries.monthly.003, periods.boundaries.monthly.006]
- **BE-SP-23** Zone-change continuity (usage and fixed charges only): take the subscription's latest invoice (ordered by the end of its subscription-fee period, falling back to its creation time); if that invoice recorded a time zone different from the current effective zone and holds a charges end, let `C` = that charges end + 1 second; if the computed `charges_from` is within 26 hours of `C`, use `C` instead (the same with the fixed-charges end for `fixed_charges_from`). Because stored ends carry `.999999`, `C` is `…:00.999999` and a sub-second gap remains. [vec: periods.boundaries.tzchange.001, periods.boundaries.tzchange.002, periods.boundaries.tzchange.003, periods.boundaries.tzchange.005, periods.boundaries.tzchange.006]
- **BE-SP-24** Durations: `period_days` = length of the fee period (BE-SP-11) — the divisor of the single-day price (BE-SP-38); `charges_duration_days` and `fixed_charges_duration_days` = lengths of the charges and fixed-charges periods (the monthly length under a split). Lengths use the unclamped periods. [vec: periods.boundaries.base.009, periods.boundaries.split.001, periods.boundaries.yearly.021, periods.single_day_price.004, periods.single_day_price.007, periods.single_day_price.014]
- **BE-SP-25** Neighbouring edges: `next_end_of_period` = local end of `period(D)`; `current_beginning_of_period` = local start of `period(D)`; `previous_beginning_of_period` = local start of `period(B)`; `fixed_charges_period_to_datetime` = the fixed-charges end of BE-SP-22 computed even when the fixed-charges bounds are absent (BE-SP-18). Edges ignore `started_at`. [vec: periods.boundaries.monthly.021, periods.boundaries.monthly.023, periods.boundaries.quarterly.016, periods.boundaries.weekly.002, periods.boundaries.weekly.008, periods.boundaries.yearly.019]

Summary of a billing run (fresh pseudocode; `P` = period function of BE-SP-10 for the plan interval, `Pm` = the
same for monthly periods with the same anchor; `start(d)`/`end(d)` = local 00:00 / 23:59:59.999999 of date `d`):

```
D  = local_date(billing_at);  B = base_date(D)                      # BE-SP-12
T  = terminated_at_billing(billing_at)                              # BE-SP-13
fee_date    = D if advance or (T and arrears and not downgraded) else B
charges_date(Q) = D if (T_Q and no successor) else (fee_date_Q if arrears else B_Q)   # Q = P, or Pm under a split
                  # T_P = T; T_Pm tests the termination against 00:00 UTC of D (BE-SP-17, RBD-103 compat;
                  # corrected profile: T_Pm = T)
from = start(P(fee_date).first);  if from < started_at: from = start(local_date(started_at))
to   = end(P(fee_date).last);     if T and to > round_s(terminated_at): to = round_s(terminated_at)
                                   if to < started_at: to = started_at
charges_from = start(Q(charges_date).first) -> zone-change rule -> max(…, started_at)
charges_to   = end(Q(charges_date).last); if status terminated and terminated_at <= charges_to: charges_to = terminated_at
                                   if charges_to < started_at: charges_to = started_at
(fixed charges: the same with the fixed family; presence gates of BE-SP-18 apply last)
```

Worked example (calendar monthly, arrears, customer in Asia/Tokyo, run at `2024-01-31T15:10Z` = local 1 February
00:10): `D` = Feb 1, `B` = Jan 1, fee and charges period = January → `[2023-12-31T15:00Z, 2024-01-31T14:59:59.999999Z]`
(`periods.boundaries.tz.001`). The same run one hour earlier is still local 31 January and bills December.

## 4. Boundaries recorded on an invoice

When an invoice is created for a subscription, the boundaries of section 3 are adjusted by the billing reason
(op `periods.invoice_boundaries`).

- **BE-SP-26** Current-usage mode is used for progressive-billing invoices and for a subscription that is terminated at billing time and was upgraded (its successor's yearly amount is greater or equal); every other reason uses the billing mode. [vec: periods.invoice_boundaries.005]
- **BE-SP-27** Termination on a billing day: for a terminated subscription with no successor, when `billing_at − 1 day` is not before `started_at`, compute the current-usage charges end `X` at `billing_at − 1 day` (subscription treated as active); if `billing_at ≥ X` and `billing_at − X < 1 day` (the termination falls within the first 24 hours after a period end), the invoice bills the **previous full period** — the boundaries of a normal billing run at `billing_at` for the subscription treated as active — unless a periodic invoice already holds exactly those boundaries, in which case the cut-short current period is billed. Together with BE-SP-34 (the periodic run skips the `ending_at` day) this bills each period exactly once. [vec: periods.invoice_boundaries.001, periods.invoice_boundaries.003, periods.invoice_boundaries.004]
- **BE-SP-28** A periodic run refuses to bill a subscription whose computed boundaries are already on a periodic invoice: same fee `from`/`to`, plus the same charges (or fixed-charges) bounds for a split family; the error code is `duplicated_invoices` (the periodic biller ignores it). [vec: periods.invoice_boundaries.008]
- **BE-SP-29** Each invoice line records the run instant, the boundaries, `recurring = true` only for periodic runs, and a reason: `subscription_periodic`, `subscription_starting`, `subscription_terminating`, `progressive_billing`, or for a plan-change invoice (`upgrading`) `subscription_terminating` on the subscription terminated at that instant and `subscription_starting` on its successor. [vec: periods.invoice_boundaries.001, periods.invoice_boundaries.005, periods.invoice_boundaries.007, periods.invoice_boundaries.010]

## 5. Scheduling: billing days and the periodic run

- **BE-SP-30** Calendar billing days (local date `T`): weekly — `T` is a Monday; monthly — `T.d = 1`; quarterly — `T.d = 1` and `T.m ∈ {1, 4, 7, 10}`; semiannual — `T.d = 1` and `T.m ∈ {1, 7}`; yearly — 1 January. [vec: periods.billing_days.monthly.006, periods.billing_days.monthly.007, periods.billing_days.monthly.009, periods.billing_days.semiannual.003, periods.billing_days.weekly.002, periods.periodic_billing.001, periods.periodic_billing.014]
- **BE-SP-31** Anniversary billing days: weekly — weekday of `T` = `A.wd`. Define `day_match(T)` = `A.d = T.d`, or `T` is the last day of its month and `A.d > T.d`. Monthly — `day_match`; quarterly — `day_match` and `T.m ≡ A.m (mod 3)`; semiannual — `day_match` and `T.m ≡ A.m (mod 6)`; yearly — `T.m = A.m` and (`T.d = A.d`, or `T` is 28 February in a common year and `A.d ∈ {28, 29}`). So anchor 31 bills on the last day of shorter months, a 29 February anchor bills on 28 February in common years, and a 28 February anchor bills on 28 February also in leap years. [vec: periods.billing_days.monthly.001, periods.billing_days.monthly.002, periods.billing_days.monthly.003, periods.billing_days.monthly.004, periods.billing_days.monthly.005, periods.billing_days.quarterly.003, periods.billing_days.yearly.001]
- **BE-SP-32** Split plans are billed every month: calendar — every `T.d = 1`; anniversary — every `day_match(T)`; when either monthly flag is set. [vec: periods.billing_days.semiannual.003, periods.billing_days.yearly.005]
- **BE-SP-33** The clock runs hourly (at a fixed minute) and evaluates `T` as the customer's local date at the run instant, so a subscription is billed by the first run after its local midnight: an Asia/Tokyo calendar-monthly subscription is billed by the 15:10 UTC run of the last UTC day of the previous month; an America/Los_Angeles one by a run dated the 2nd in UTC. Equivalence between implementations is judged at local-day granularity (RBD-94). [vec: periods.billing_days.monthly.007, periods.billing_days.monthly.009, periods.periodic_billing.014]
- **BE-SP-34** Periodic selection at run instant `R` (local date `T`): the subscription is `active`; `T` is a billing day; the local date of `started_at` is before `T` (a subscription started today is not billed periodically); the **UTC** date of its creation is on or before the UTC date of `R`; it has no `ending_at`, or the local date of `ending_at` is not `T` (the termination path bills that day, BE-SP-27); and no periodic invoice of the subscription has a timestamp whose local date is `T` (one periodic invoice per local day). [vec: periods.periodic_billing.001, periods.periodic_billing.003, periods.periodic_billing.004, periods.periodic_billing.006, periods.periodic_billing.009, periods.periodic_billing.011]
- **BE-SP-35** A selected subscription with a pending successor (a downgrade waiting for the period end) is not billed periodically: the run terminates it and activates the successor (BE-SP-53). [vec: periods.periodic_billing.008]
- **BE-SP-36** The selected subscriptions of one customer in one run are grouped into invoices successively by effective payment method, plan currency, billing entity, then subscriptions opting out of consolidation are split off alone, then by purchase-order number; each group gives one periodic invoice (timestamp = the run instant) and one non-invoiceable-fees run. [vec: none (prose only: grouping needs several subscriptions of one customer in one run; no unit op isolates it and the curated scenarios bill one subscription per customer)]
- **BE-SP-37** Consecutive periodic runs tile time: each fee period starts one microsecond after the previous one ends, and its length is the fee period length (BE-SP-11); for an advance plan each run bills the period that starts on its billing day and the usage of the period before (op `periods.chain` evaluates each billing day at local noon). [vec: periods.chain.001, periods.chain.002, periods.chain.003, periods.chain.005, periods.chain.007, periods.chain.009]

## 6. Subscription fee

Inputs of op `periods.subscription_fee`: the fee period `[from, to]` and run instant `ts` of the invoice line
(section 4), the subscription and its plan-change neighbours, and the subscription-fee history.

- **BE-SP-38** Single-day price `sdp(X)` = `amount_cents ÷ length(period(X))` computed as an IEEE-754 binary64 quotient (a float island, RBD-55/RBD-96). The default `X` is the start of the fee period of a billing run at `ts` (unclamped), so a subscription created mid-period by an upgrade divides by the whole period length (anchor 15 January, quarterly, upgrade on 20 May → 91 days). [vec: periods.single_day_price.001, periods.single_day_price.002, periods.single_day_price.004, periods.single_day_price.005, periods.single_day_price.006, periods.single_day_price.007, periods.single_day_price.009, periods.subscription_fee.001]
- **BE-SP-39** The amount basis is chosen in this order: (1) **terminated** — the subscription is terminated, the plan is in arrears, and it was upgraded or has no successor; (2) **upgraded** — it has a predecessor (a plan change), it is on at most one non-deleted invoice, and the predecessor's plan has a yearly amount lower or equal to its own; (3) **full_period** — any of: plan in advance with anniversary billing and no predecessor; a subscription fee of this subscription was created before this invoice; started in the past (BE-SP-44) with an advance plan; started in the past with `started_at` before `previous_beginning_of_period` at `ts`; (4) **first_period** otherwise (first invoices and post-downgrade first invoices). [vec: periods.subscription_fee.001, periods.subscription_fee.008, periods.subscription_fee.012, periods.subscription_fee.015, periods.subscription_fee.019, periods.subscription_fee.029, periods.subscription_fee.030]
- **BE-SP-40** Terminated basis: `days × sdp(local date of from')` where `from'` = `from`, or the trial end instant when the trial ends strictly inside `(from, to)`; the amount is 0 when the trial end is at or after `to`. `days` is the day count of BE-DM-15..17 between `from'` and `to`, minus one (floored at 0) when the subscription was upgraded (BE-DM-18: the upgrade day is paid by the new plan). [vec: periods.subscription_fee.019, periods.subscription_fee.021, periods.subscription_fee.022, periods.subscription_fee.024, periods.subscription_fee.027]
- **BE-SP-41** Upgraded basis: `days(from', to) × sdp(default)` with the same trial rule; the predecessor's unused days come back as a credit (BE-SP-58). [vec: periods.subscription_fee.025]
- **BE-SP-42** Full-period basis: the plan amount; with a trial ending strictly inside `(from, to)`, `days(trial end instant, to) × sdp(local date of from)`; 0 when the trial ends at or after `to`. [vec: periods.subscription_fee.008, periods.subscription_fee.012, periods.subscription_fee.015, periods.subscription_fee.017, periods.subscription_fee.018, periods.subscription_fee.028, periods.subscription_fee.029]
- **BE-SP-43** First-period basis: `days(from', to) × sdp(default)`. The trial test here uses the **trial end day** (UTC midnight of the initial start's UTC date plus the trial length, BE-SP-60): 0 when it is at or after `to`; when it falls strictly inside `(from, to)`, `from'` = the exact trial end instant. [vec: periods.subscription_fee.001, periods.subscription_fee.002, periods.subscription_fee.002x, periods.subscription_fee.003, periods.subscription_fee.005, periods.subscription_fee.005x, periods.subscription_fee.030]
- **BE-SP-44** "Started in the past" compares **UTC** calendar dates: UTC date of `started_at` < UTC date of the subscription's creation. A start and a creation on the same local day can therefore count as "in the past" for customers far from UTC (RBD-57). [vec: periods.subscription_fee.008, periods.subscription_fee.032, periods.subscription_fee.033, periods.subscription_fee.033x]
- **BE-SP-45** Precision: the binary64 result is converted to decimal by taking its shortest round-trip decimal digits and **cutting** (not rounding) them to 16 significant digits (`57.142857142857146` → `57.14285714285714`; `25.499999999999996` → `25.49999999999999`); stored with 15 decimal places. `amount_cents` = the binary64 value rounded half away from zero, so an exact half that the float misses rounds down (21 of 28 days of 34 cents = 25.499999999999996 → 25; exact arithmetic gives 26, RBD-55). Integer results (plan amount, 0) are exact. [vec: periods.subscription_fee.001, periods.subscription_fee.002, periods.subscription_fee.002x, periods.subscription_fee.005, periods.subscription_fee.005x, periods.subscription_fee.034]
- **BE-SP-46** Fee gate — the subscription fee is put on an invoice only when all hold: (a) not (plan in advance and another subscription fee of this subscription, on another invoice, was created within the **UTC** day that carries the customer-local date of `ts` (the invoice line's run instant, not the invoice's stored issuing date) — `[that date 00:00 UTC, 23:59:59.999999 UTC]`; RBD-58); (b) the yearly/semiannual gate BE-SP-47; (c) the trial gate BE-SP-48; (d) not the first invoice of an arrears plan that only has advance fixed charges; (e) the subscription is active or incomplete, or terminated with an arrears plan, or terminated after the invoice was created. [vec: periods.subscription_fee.037, periods.subscription_fee.040, periods.subscription_fee.042, periods.subscription_fee.043, periods.subscription_fee.044, periods.subscription_fee.044x]
- **BE-SP-47** Yearly and semiannual gate (other intervals pass): advance plan not started in the past — first month of the plan period (BE-SP-18 definition, with `D` = local date of `ts`) or the subscription never had a subscription fee; advance plan started in the past — first month of the plan period but not the first month of the **first** plan period (calendar: `D` falls in the anchor's local year; anniversary: the monthly period holding `D` starts in the anchor month of the anchor's year); arrears — terminated, or first month of the plan period. Split plans therefore carry the subscription fee only once per plan period. [vec: periods.subscription_fee.037, periods.subscription_fee.040]
- **BE-SP-48** Trial gate: when the subscription is in trial at the invoice's creation instant (BE-SP-60) and the local date of `ts` is not the local date of the trial end, no fee. [vec: periods.subscription_fee.042]

Usage charges and fixed charges on the same invoice line (their amounts are chapter 05; this is only which of them
are billed):

- **BE-SP-65** Usage charges: none at all when the invoice was created without usage charges (the start-day invoice of an advance plan, the trial-end invoice, the payment-gating invoice: BE-SP-49, BE-SP-61, BE-SP-63) or when the charges window is absent or empty (`charges_from` not strictly before `charges_to`). Otherwise every charge of the plan is billed except: non-invoiceable charges (billed outside the invoice, chapter 05); pay-in-advance charges of non-recurring metrics (billed per event); a pay-in-advance charge of a recurring metric when the subscription is terminated and is upgraded or has no successor; an arrears, non-prorated charge of a recurring metric when the subscription is terminated, upgraded, and the successor's plan has a charge on the same metric (the successor bills that usage). [vec: scn.subscription.fee_selection.001, scn.subscription.fee_selection.002]
- **BE-SP-66** Fixed charges: none when the fixed-charges window is absent or reversed (`fixed_charges_from` after `fixed_charges_to`; equal bounds are billed), or when the subscription is neither active nor incomplete — unless it is terminated and the plan has an arrears fixed charge, or it was terminated after the invoice was created. Otherwise every fixed charge of the subscription is billed except: arrears fixed charges while the subscription's only invoice line is a starting one (`subscription_starting`); pay-in-advance fixed charges of a terminated subscription. [vec: scn.subscription.fee_selection.003, scn.subscription.fee_selection.004]

## 7. Lifecycle

- **BE-SP-49** Creation compares local dates of `subscription_at` and "now". Past → `active` at once, `started_at = subscription_at` (BE-SP-50), webhook `subscription.started`, **no invoice at creation** (the next periodic run bills it; RBD-65). Today → activated immediately with `started_at = subscription_at` even when that instant is later today; an advance plan not in trial is billed at once (reason `subscription_starting`, without usage charges); otherwise, when the plan has pay-in-advance fixed charges, those are billed on a separate fixed-charges invoice timed one second after the start (chapter 05); webhook `subscription.started`. Future → `pending`, no invoice, no webhook; the clock activates it when its local date arrives (every 5 minutes, BE-CK). [vec: periods.create_status.001, periods.create_status.002, periods.create_status.004, periods.create_status.005, periods.create_status.006]
- **BE-SP-50** A backdated creation starts no earlier than the latest termination instant of a terminated subscription with the same external id whose termination was invoiced (`on_termination_invoice = generate`), so a window already billed by a terminating invoice is never reopened. [vec: periods.create_status.009]
- **BE-SP-51** A requested plan change is classified by **yearly-normalised amounts** (weekly ×52 — not 365/7 —, monthly ×12, quarterly ×4, semiannual ×2, yearly ×1): new ≥ current → upgrade (equal counts as an upgrade, including an interval change at the same annual price); new < current → downgrade; the same plan → no change (the existing subscription is returned). [vec: periods.classify_change.001, periods.classify_change.003, periods.classify_change.005, periods.classify_change.006, periods.classify_change.007, periods.subscription_fee.021]
- **BE-SP-52** Upgrade (immediate): a new subscription with the same external id inherits `subscription_at` (the anchor) and `billing_time`; the old one is terminated now as an upgrade (no separate terminating invoice; a pay-in-advance old plan gets the unused-days credit of BE-SP-58); both are billed on one invoice one second later; the new subscription appears on it only if its plan is in advance and not in trial, or it has advance fixed charges. [vec: periods.boundaries.clamp.008, periods.invoice_boundaries.005, periods.subscription_fee.021, periods.subscription_fee.025, scn.subscription.upgrade.001, scn.subscription.upgrade.002, scn.fixed_charge.upgrade_prorated.001]
- **BE-SP-53** Downgrade (deferred): a pending successor is created (same external id, inherited anchor and billing time) and the current subscription receives `subscription.updated`; on its next billing day the periodic run terminates it **without** the termination procedure (no unused-days credit note, `on_termination_*` ignored; RBD-60), activates the successor and bills the old subscription on one invoice, with the successor on the same invoice only when its plan is in advance or it has advance fixed charges. Terminating a subscription cancels a pending successor. [vec: periods.periodic_billing.008, scn.subscription.downgrade.001, scn.subscription.downgrade.002]
- **BE-SP-54** Termination request by status: `active` → `terminated` (`terminated_at` = now unless already set), pending successor canceled; `pending` → `canceled` (`canceled_at`), the predecessor (if any) receives `subscription.updated`; `terminated` → unchanged; `canceled` → error `subscription_canceled`; `incomplete` → `canceled` through the payment-gate decline of BE-SP-63 (webhook `subscription.canceled`, not `subscription.terminated`). A request on a subscription whose successor is `incomplete` is refused with `next_subscription_incomplete` (except inside an upgrade). Every other successful path, including the pending and already-terminated ones, emits `subscription.terminated` (RBD-66). [vec: periods.terminate.001, periods.terminate.003, periods.terminate.003x, periods.terminate.004, periods.terminate.004x, periods.terminate.005, periods.terminate.005x]
- **BE-SP-55** Terminating an active subscription (not as an upgrade) schedules a terminating invoice at `terminated_at` (reason `subscription_terminating`) when `on_termination_invoice = generate` (default), and always bills non-invoiceable fees; with an advance plan whose current-period invoice was issued (always true in the first period) and `on_termination_credit_note` ∈ {`credit` (default), `refund`, `offset`}, it issues the unused-days credit note (BE-SP-58, chapter 08). [vec: periods.terminate.001, scn.subscription.terminate.003, scn.subscription.fee_selection.002, scn.subscription.fee_selection.004]
- **BE-SP-56** A manual termination of an active subscription emits `subscription.updated` before `subscription.terminated`: the termination options are re-saved on every call because the stored option and the requested option compare unequal even when they are the same value. [vec: periods.terminate.001]
- **BE-SP-57** `ending_at` must be after today and after `subscription_at` (dates); an hourly clock job terminates active subscriptions whose local `ending_at` date is today, with `terminated_at` = the clock instant (not `ending_at`). [vec: periods.subscription_fee.027, scn.subscription.terminate.001, scn.subscription.terminate.002]
- **BE-SP-58** Unused days at termination (advance plans). Let `E` = UTC calendar date of `next_end_of_period` computed at `terminated_at` (BE-SP-25), and `F` = UTC calendar date of the local end of the termination day, minus one day when the subscription is terminated by an upgrade. With a trial whose end date `TE` (UTC calendar date of the trial end day, BE-SP-60) is on or after `F`, replace `F` by `E` when `TE > E`, else by `TE − 1 day`. `remaining = max(E − F, 0)` days (UTC dates of local day ends coincide with local-day arithmetic in every zone). Unused amount = `remaining × sdp` (binary64), where `sdp` uses the plan amount recorded on the last subscription fee (else the plan amount) over the period of the termination instant. A fractional trial makes `TE` carry a fraction of a day; differences are then truncated toward zero. The credit is capped and split by chapter 08. [vec: periods.termination_credit_days.001, periods.termination_credit_days.002, periods.termination_credit_days.003, periods.termination_credit_days.006, periods.termination_credit_days.007, periods.termination_credit_days.008]
- **BE-SP-59** Used days (for the refund share, chapter 08) = `min(L, E) − S + 1` floored at 0, where `L` = UTC calendar date of the local end of the termination day, `E` as in BE-SP-58, and `S` = UTC calendar date of `from_datetime` at `terminated_at` (BE-SP-19), or `TE` when later. [vec: periods.termination_credit_days.001]
- **BE-SP-60** Trial: the **initial start** is the earliest `started_at` among the customer's subscriptions with the same external id (else `subscription_at`), so plan changes never restart a trial — the new plan's `trial_period` counts from the initial start. Trial end instant = initial start + `trial_period` days (fractions allowed: 1.5 days = 36 h); trial end day = UTC midnight of the initial start's UTC date + `trial_period` days. In trial ⇔ no `trial_ended_at`, the initial start is not in the future, and the trial end instant is in the future. [vec: periods.create_status.006, periods.subscription_fee.002, periods.subscription_fee.005, periods.subscription_fee.012, periods.termination_credit_days.007, periods.trial_end.001, periods.trial_end.004]
- **BE-SP-61** Trial-end billing: an hourly clock job bills advance plans whose trial end is reached in local time (reason `subscription_starting`, without usage charges) unless already billed today by a periodic run or billed on the start day, then sets `trial_ended_at` and emits `subscription.trial_ended`. [vec: periods.subscription_fee.028, periods.subscription_fee.042, scn.subscription.trial.001]
- **BE-SP-62** A plan that has subscriptions accepts only edits of name, display name, description and amount; interval, advance flag, currency, trial and the monthly flags are frozen. Changing the amount cancels pending downgrades whose plan amount now exceeds the current plan's — comparing raw `amount_cents`, not yearly amounts (RBD-59, compat; the corrected proposal compares yearly-normalised amounts): a monthly plan edited from 1,000 to 900 cancels a pending downgrade to a yearly plan of 6,000 although 10,800 a year still exceeds 6,000 — and executes pending successors on this plan that now qualify as upgrades. [vec: scn.subscription.downgrade.002]
- **BE-SP-63** Payment-gated activation (activation rules, out of the core): a pending subscription with pending rules becomes `incomplete` (started_at set, a gating invoice without usage charges, webhook `subscription.incomplete`); all rules satisfied → `active`; any rule failed/expired/declined → `canceled` (webhook `subscription.canceled`). [vec: none (prose only: payment gating depends on payment providers, chapter 14)]
- **BE-SP-64** API exposure: the subscription object reports the current billing period as the current-usage charges window at `max(now, started_at)`; while a downgrade is pending, its effective date is the day after `next_end_of_period(now)`, and once the successor is active, the successor's start date. [vec: none (prose only: serializer view of BE-SP-15/25; exercised by the scenario snapshots)]

## 8. State machine

```
            create (local date of subscription_at)
   past ──────────────► active ◄──── activate (clock, local date reached; or today)
   today ─► pending ──► active                  pending ──(rules pending)──► incomplete
   future ► pending                                         incomplete ──(rules ok)──► active
                                                             incomplete ──(rule rejected / terminate)──► canceled
   active ──terminate / ending_at day / downgrade rotation / upgrade──► terminated
   pending ──terminate──► canceled          canceled ──terminate──► error subscription_canceled
   terminated ──terminate──► terminated (no change; webhook re-sent)
```

| Transition | Webhooks (in order) | Invoice |
|---|---|---|
| create past | `subscription.started` | none (BE-SP-49) |
| create today / activation | `subscription.started` | advance plan not in trial: starting invoice |
| manual terminate (active) | `subscription.updated`, `subscription.terminated` | terminating invoice unless `skip` |
| terminate pending | (`subscription.updated` on predecessor), `subscription.terminated` | none |
| terminate again | `subscription.terminated` | none |
| terminate incomplete | `subscription.canceled` | gating invoice closed |
| upgrade | `subscription.started` (new) | one invoice: old terminating + new starting |
| downgrade request / rotation | `subscription.updated` / `subscription.terminated` + `subscription.started` | rotation invoice |
| trial end | `subscription.trial_ended` | advance plan: starting invoice |

## 9. Edge cases (people get these wrong)

| Case | Rule |
|---|---|
| Month-end anchors re-clamp every period (31st → Feb 28, Mar 31, Apr 30); they never drift to the 28th | BE-SP-6 |
| Arrears run on 30 April for anchor 31 bills Mar 31–Apr 29 (base-date correction) | BE-SP-12 |
| The subscription fee of a first period counts the whole start day; usage counts from the exact start instant | BE-SP-19, BE-SP-21 |
| Fee end is the termination rounded to the second; charges end is the exact termination | BE-SP-20, BE-SP-22 |
| Period length is the whole period even for an upgrade mid-period | BE-SP-11, BE-SP-38 |
| Terminated-by-upgrade subscriptions bill one day fewer | BE-SP-40 |
| Equal yearly price is an upgrade; weekly annualises ×52 | BE-SP-51 |
| Termination 15 min after a period end bills the previous full period, and the periodic run skips that day | BE-SP-27, BE-SP-34 |
| Single-day price and proration are binary floats; precise amounts are cut to 16 significant digits; x.5 cents can round down | BE-SP-38, BE-SP-45 |
| "Started in the past" and the same-day fee check use UTC days | BE-SP-44, BE-SP-46 |
| Split plans: fixed-charge bounds are absent outside the first month even for current usage | BE-SP-18 |
| Split plans terminated after 00:00 UTC of the local termination day bill the previous month's usage again, and the current month's usage is never billed (RBD-103) | BE-SP-17 |
| Zone change: new charges start = previous end + 1 s (a sub-second gap) | BE-SP-23 |
| Backdated subscriptions get no invoice at creation | BE-SP-49 |
| Terminating a pending subscription cancels it but sends `subscription.terminated`; manual termination also sends `subscription.updated` first | BE-SP-54, BE-SP-56 |

## 10. Vectors

| File | Ops | Vectors | Rules |
|---|---|---|---|
| `periods.boundaries.jsonl` | `boundaries`, `invoice_boundaries` | 121 (6 corrected) | BE-SP-2..29 |
| `periods.billing_days.jsonl` | `billing_days`, `periodic_billing` | 34 (1 corrected) | BE-SP-30..35 |
| `periods.chains.jsonl` | `chain` | 8 | BE-SP-37 |
| `periods.subscription_fee.jsonl` | `subscription_fee`, `single_day_price` | 56 (6 corrected) | BE-SP-38..48 |
| `periods.lifecycle.jsonl` | `classify_change`, `trial_end`, `termination_credit_days`, `create_status`, `terminate` | 37 (3 corrected) | BE-SP-49..60 |

Run them: `python3 reimplementation-kit/scripts/kitrun.py --impl-cmd "<your adapter>" --areas periods`. Every
`both`/`compat` vector is EXECUTED against the reference (`kitrun --areas periods` against the reference, 2026-10-02:
`SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=240 passed=240 skipped_ops=0 exit=0`). The 16 corrected twins are
`ruling: proposed` until the owner rules the decision they carry: RBD-55 (`periods.subscription_fee.002x`,
`periods.subscription_fee.005x`, `periods.subscription_fee.034x`, `periods.subscription_fee.035x`), RBD-57
(`periods.periodic_billing.011x`, `periods.subscription_fee.033x`), RBD-58 (`periods.subscription_fee.044x`), RBD-66
(`periods.terminate.003x`, `periods.terminate.004x`, `periods.terminate.005x`) and RBD-103
(`periods.boundaries.split.010x`, `periods.boundaries.split.013x`, `periods.boundaries.split.014x`,
`periods.boundaries.split.015x`, `periods.boundaries.split.016x`, `periods.invoice_boundaries.011x`). Vectors
tagged `slow` scan long date ranges. Scenarios that exercise this chapter end to end: `scn.subscription.*` (start,
billing, upgrade, downgrade, termination, trial, fee selection) and `scn.fixed_charge.upgrade_prorated.001`.

Implementation notes: vector inputs leave out every field that equals its op-schema default, so an adapter must apply
the schema defaults; inputs carry the customer's effective zone in `timezone` (default `UTC`); `subscription`
fields default as in the op schema (`started_at` = `subscription_at`, status `active`, or `terminated` when
`terminated_at` is given); `next_subscription: upgrade|downgrade` stands for a successor whose yearly amount is higher
(upgrade, active once this subscription is terminated) or lower (downgrade, pending). `periods.subscription_fee` takes
the invoice line's boundaries as input; compute them with `periods.invoice_boundaries`.

## Provenance (maintainers)

Rule → reference location (lago-api @591ae90):

| Rules | Reference |
|---|---|
| BE-SP-1 | `$API/app/models/subscription.rb:134` (terminated_at written once); DDL `$API/db/structure.sql:3901` |
| BE-SP-2 | `$API/app/models/plan.rb:101`, `:105`; `$API/app/services/plans/create_service.rb:137` |
| BE-SP-3, 4 | `$API/app/services/subscriptions/dates_service.rb:228`, `:236`, `:242`; `$API/app/services/utils/timezone.rb:16` |
| BE-SP-5..10 | `$API/app/services/subscriptions/dates_service.rb:284`, `:307`; `$API/app/services/subscriptions/dates/monthly_service.rb:62`, `:109`; `$API/app/services/subscriptions/dates/quarterly_service.rb:62`, `:96`; `$API/app/services/subscriptions/dates/semiannual_service.rb:140`, `:174`; `$API/app/services/subscriptions/dates/yearly_service.rb:73`, `:143`, `:175`; `$API/app/services/subscriptions/dates/weekly_service.rb:22`, `:60`; specs `$API/spec/services/subscriptions/dates/*_service_spec.rb` |
| BE-SP-11 | `$API/app/services/subscriptions/dates/monthly_service.rb:35`; `$API/app/services/subscriptions/dates/yearly_service.rb:155`; `$API/app/services/subscriptions/dates/weekly_service.rb:70` |
| BE-SP-12 | `$API/app/services/subscriptions/dates_service.rb:232`; `$API/app/services/subscriptions/dates/monthly_service.rb:48`; `$API/app/services/subscriptions/dates/quarterly_service.rb:48`; `$API/app/services/subscriptions/dates/semiannual_service.rb:126`; `$API/app/services/subscriptions/dates/yearly_service.rb:47`; `$API/app/services/subscriptions/dates/weekly_service.rb:10` |
| BE-SP-13 | `$API/app/models/concerns/terminatable.rb:6` |
| BE-SP-14..16 | `$API/app/services/subscriptions/dates_service.rb:273`, `:279`; `$API/app/services/subscriptions/dates/monthly_service.rb:6`, `:14`, `:25` (same shape in every interval) |
| BE-SP-17, 18 | `$API/app/services/subscriptions/dates/yearly_service.rb:6`, `:26`, `:39`, `:62`, `:89`, `:109`; `$API/app/services/subscriptions/dates/semiannual_service.rb:6`, `:27`, `:40`, `:49`, `:64`, `:84`; `$API/app/models/concerns/terminatable.rb:11` (a local date is turned into 00:00 server time; RBD-103); the per-invoice duplicate check of charge fees `$API/app/services/fees/charge_service.rb:409` (looks only inside the invoice being built, hence the second billing of RBD-103) |
| BE-SP-19..22 | `$API/app/services/subscriptions/dates_service.rb:64`, `:80`, `:95`, `:117`, `:128`, `:150` |
| BE-SP-23 | `$API/app/services/subscriptions/dates_service.rb:101`, `:137`, `:248`, `:255`; `$API/app/models/invoice_subscription.rb:29`; spec `$API/spec/services/subscriptions/dates/monthly_service_spec.rb:330` |
| BE-SP-24, 25 | `$API/app/services/subscriptions/dates_service.rb:161`, `:171`, `:189`, `:197`, `:202` |
| BE-SP-26..29 | `$API/app/services/invoices/create_invoice_subscription_service.rb:18`, `:69`, `:101`, `:113`, `:146`; `$API/app/models/invoice_subscription.rb:57`; `$API/app/services/subscriptions/terminated_dates_service.rb:12`; spec `$API/spec/scenarios/subscriptions/terminate_ended_spec.rb:137` |
| BE-SP-30..32 | `$API/app/services/subscriptions/billing_date_query.rb:36`, `:111`, `:124`, `:141`, `:160`, `:177`; spec `$API/spec/services/subscriptions/billing_date_query_spec.rb:1` |
| BE-SP-33 | `$API/clock.rb:79`; `$API/app/services/subscriptions/organization_billing_service.rb:56` |
| BE-SP-34, 35 | `$API/app/services/subscriptions/organization_billing_service.rb:14`, `:115`, `:117`, `:119`, `:512` |
| BE-SP-36 | `$API/app/services/subscriptions/organization_billing_service.rb:29`, `:541`, `:550`, `:556`, `:572` |
| BE-SP-37 | composition of BE-SP-14 and BE-SP-30 (date services + billing-date query) |
| BE-SP-38..45 | `$API/app/services/fees/subscription_service.rb:16`, `:111`, `:125`, `:132`, `:141`, `:158`, `:188`, `:216`, `:247`, `:280`; `$API/app/services/subscriptions/dates_service.rb:197`; `$API/app/models/subscription.rb:161`, `:198`, `:208`; `$API/app/models/concerns/billing_period_date_diff.rb:6`; spec `$API/spec/services/fees/subscription_service_spec.rb:1` |
| BE-SP-46..48 | `$API/app/services/invoices/calculate_fees_service.rb:82`, `:268`, `:294`, `:318`, `:400`, `:408` |
| BE-SP-65, 66 | `$API/app/services/invoices/calculate_fees_service.rb:104`, `:111`, `:117`, `:147`, `:181`, `:342`, `:353`; `$API/app/models/charge.rb:107`; `$API/app/services/subscriptions/activate_service.rb:41`, `:137`; `$API/app/services/subscriptions/free_trial_billing_service.rb:23` |
| BE-SP-49, 50 | `$API/app/services/subscriptions/create_service.rb:138`, `:180`, `:189`, `:207`, `:216`; `$API/app/services/subscriptions/activate_service.rb:125`, `:181`; `$API/app/jobs/clock/activate_subscriptions_job.rb:1` |
| BE-SP-51 | `$API/app/models/plan.rb:120`; `$API/app/services/subscriptions/create_service.rb:124`, `:131` |
| BE-SP-52, 53 | `$API/app/services/subscriptions/plan_upgrade_service.rb:18`, `:60`; `$API/app/services/subscriptions/plan_downgrade_service.rb:19`, `:39`; `$API/app/services/subscriptions/activate_service.rb:60`, `:93`, `:107`; `$API/app/services/subscriptions/organization_billing_service.rb:18` |
| BE-SP-54..56 | `$API/app/services/subscriptions/terminate_service.rb:17`, `:19`, `:21`, `:24`, `:32`, `:40`, `:62`, `:65`, `:68`, `:200`; `$API/app/services/subscriptions/activation_rules/resolve_subscription_status_service.rb:20`; spec `$API/spec/services/subscriptions/terminate_service_spec.rb:1` |
| BE-SP-57 | `$API/app/services/subscriptions/validate_service.rb:51`; `$API/app/jobs/clock/terminate_ended_subscriptions_job.rb:9` |
| BE-SP-58, 59 | `$API/app/services/credit_notes/create_from_termination.rb:87`, `:98`, `:106`, `:114`, `:195`; spec `$API/spec/services/credit_notes/create_from_termination_spec.rb:208` |
| BE-SP-60, 61 | `$API/app/models/subscription.rb:179`, `:185`, `:190`, `:208`; `$API/app/services/subscriptions/free_trial_billing_service.rb:13` |
| BE-SP-62 | `$API/app/services/plans/update_service.rb:32`, `:76`, `:332` |
| BE-SP-63 | `$API/app/services/subscriptions/activate_service.rb:35`; `$API/app/services/subscriptions/terminate_service.rb:96` |
| BE-SP-64 | `$API/app/serializers/v1/subscription_serializer.rb:26`; `$API/app/models/subscription.rb:234` |

Executions on the pinned toolchain (ruby-4.0.6, 2026-10-02, database `lago_api_test_a6`):

- `oracle.sh run -j 1` over `spec/services/subscriptions/dates` (5 files), `spec/services/subscriptions/dates_service_spec.rb`,
  `terminated_dates_service_spec.rb`, `spec/services/fees/subscription_service_spec.rb`,
  `spec/services/credit_notes/create_from_termination_spec.rb`: `{"example_count":668,"failure_count":0,…}`.
- `oracle.sh run -j 1` over the subscription services (billing-date query, organization billing, create, activate,
  activate-all-pending, terminate, plan upgrade/downgrade, free-trial billing, validate, update), `spec/models/subscription_spec.rb`,
  `spec/models/plan_spec.rb` and `spec/scenarios/subscriptions` (13 files, ClickHouse-tagged ones under the lock):
  `{"example_count":1314,"failure_count":0,…}`.
- The 119 boundary and 29 proration assertions transcribed from the dates, fees and termination specs were first
  re-run with the substitute harness (119/119, 29/29) and then through the oracle module: every spec-asserted value
  in the kept vectors matched.
- Oracle module `scripts/maintainer/oracle-adapter/ops/periods.rb`: real date services, invoice-subscription,
  billing-date query, organization biller, fee, credit-note, create/terminate services and model methods over
  FactoryBot records in a rolled-back non-joinable transaction (after-commit jobs and webhooks observable). Outputs
  are floored to microseconds.
- Findings by execution: RBD-58 confirmed (`periods.subscription_fee.044`); RBD-65 confirmed (no invoice at
  creation for a backdated subscription, `periods.create_status.001`); RBD-66 confirmed for pending and re-terminated
  subscriptions; new: manual termination also emits `subscription.updated` (BE-SP-56); fixed-charge bounds absent in
  current usage on charges-split plans (BE-SP-18); zone-change continuity leaves a sub-second gap (BE-SP-23);
  precise subscription fees are cut, not rounded, to 16 significant digits (BE-SP-45); split plans test termination
  for the monthly family against 00:00 UTC of the local billing date, so a mid-day termination bills the previous
  month's usage (BE-SP-17, RBD-103: `periods.boundaries.split.010`..`016`, east and west of UTC, fixed-charges and
  semiannual anniversary variants, and on the terminating invoice `periods.invoice_boundaries.011`; the periodic run
  of the 1st billing the same window is `periods.boundaries.split.001`). The RBD-103 corrected twins were recomputed
  by an independent model of the monthly-family window that reproduces every compat twin executed on the reference:
  `reimplementation-kit/scripts/maintainer/recompute-periods-rbd103.py` (`check` recomputes every RBD-103 vector in
  both profiles, 16/16 agree on 2026-10-02; `adapter` serves the same model to kitrun).
- Re-run of 2026-10-02 on a fresh database (`lago_api_test_fr3`): the RBD-103 compat twins and the trimmed
  vectors (inputs without schema-default fields, one evidence citation, shorter titles) against the oracle:
  `kitrun --areas periods` 240/240 PASS.
- Update triggers: a pin bump (re-run the spec list and kitrun), any change to the date services, the billing-date
  query, the organization biller, the fee or termination services.
