# Scenario manifest

> Licence note: these scenarios record observable behaviour of lago-api (AGPL-3.0) at pin `591ae90`
> (requests, clock ticks and the resulting API representations), replayed on the reference. Behavioural data,
> not source code; see `reimplementation-kit/reference/legal-and-provenance.md`.

End-to-end scenarios of the billing engine. Format, replay semantics and grading: `reimplementation-kit/reference/scenario-tier.md`. Run them with
`python3 reimplementation-kit/scripts/scenario-replay.py --impl-cmd "<your system adapter>"`. Every scenario below is
EXECUTED: replayed twice on the reference with identical results and rejected when one expected integer is
changed (mutation check). Sizes are compact-JSON bytes.

| Topic | Covers |
|---|---|
| `alert` | usage alerts |
| `commitment` | minimum commitment |
| `credit_note` | credit notes |
| `fixed_charge` | fixed charges |
| `invoice` | invoices, taxes, coupons, numbering, voiding |
| `lifetime` | lifetime usage / progressive billing |
| `pay_in_advance` | pay-in-advance charges and estimates |
| `store_ch` | columnar event-store variant |
| `subscription` | subscription lifecycle and billing periods |
| `usage` | current usage per charge model / aggregation |
| `wallet` | wallets and prepaid credits |

76 scenarios, 358725 bytes compact.

| Id | Title | Topic | Rules | RBDs | Tags | Steps | Bytes |
|---|---|---|---|---|---|---|---|
| `scn.alert.usage.001` | lifetime usage alert over two periods | alert | BE-AL-12 | RBD-77, RBD-78 | premium | 10 | 4980 |
| `scn.commitment.advance.001` | minimum commitment of the previous period billed on the next in-advance invoice | commitment | BE-IV-3 | RBD-52 | premium | 3 | 3332 |
| `scn.commitment.arrears.001` | minimum commitment not reached: true-up fee on an arrears invoice | commitment | BE-IV-3 | RBD-52 | premium | 3 | 2321 |
| `scn.commitment.termination.001` | minimum commitment over a terminated period (March and April) | commitment | BE-IV-3 | RBD-52 | premium | 3 | 3426 |
| `scn.credit_note.termination.001` | termination credit note of a paid in-advance fee with tax: rounding of unused days | credit_note | BE-CN-11, BE-CN-15, BE-CN-16, BE-CN-17 | RBD-75 | premium | 3 | 4158 |
| `scn.credit_note.termination.004` | terminating a pay-in-advance subscription: credit note and final invoice | credit_note | BE-CN-15, BE-CN-16, BE-SP-55 | RBD-63 | core | 2 | 3971 |
| `scn.fixed_charge.override.001` | fixed charge units overridden through the subscription: delta billed from the highest paid value | fixed_charge | BE-PR-67, BE-PR-68 | - | premium | 3 | 4949 |
| `scn.fixed_charge.units.001` | fixed charge units raised mid-period: delta invoice in advance | fixed_charge | BE-PR-67, BE-PR-71 | - | premium | 2 | 3796 |
| `scn.fixed_charge.upgrade_prorated.001` | upgrade mid-period: the prorated in-advance fixed charge already paid is deducted from the new one | fixed_charge | BE-PR-72, BE-PR-70, BE-SP-52 | - | - | 2 | 6136 |
| `scn.invoice.coupons.001` | three limited and unlimited coupons split over the fees of two subscriptions with two tax rates | invoice | BE-DM-27, BE-DM-28, BE-IV-11, BE-IV-19, BE-IV-22, BE-IV-25 | RBD-68, RBD-69 | premium | 30 | 11383 |
| `scn.invoice.filters_grouped.001` | invoice fees per charge filter and per grouping key | invoice | BE-AG-31, BE-AG-36, BE-PR-51 | - | - | 7 | 6881 |
| `scn.invoice.leap.001` | invoice boundaries across a leap February | invoice | BE-DM-15 | RBD-64 | - | 2 | 3289 |
| `scn.invoice.lifecycle.002` | changing a customer's grace period moves the finalization of its draft invoice | invoice | BE-IV-6, BE-IV-33, BE-IV-37, BE-IV-39 | RBD-71 | premium | 3 | 2419 |
| `scn.invoice.lifecycle.003` | upgrade without grace period: termination and start invoices with their invoicing reasons | invoice | BE-IV-2, BE-SP-52 | RBD-61 | premium | 3 | 4741 |
| `scn.invoice.lifecycle.005` | pay-in-advance subscription terminated: fees billed correctly | invoice | BE-SP-55 | RBD-63 | - | 4 | 6450 |
| `scn.invoice.numbering.001` | per-customer invoice numbers with a grace period are assigned at finalization | invoice | BE-DM-37, BE-DM-40, BE-DM-42, BE-IV-1, BE-IV-35, BE-IV-39 | RBD-82 | premium | 9 | 5138 |
| `scn.invoice.one_off.001` | one-off invoice of add-ons: explicit tax codes replace the derived taxes | invoice | BE-IV-7, BE-IV-10, BE-IV-51 | - | - | 1 | 2270 |
| `scn.invoice.one_off.002` | one-off invoice: customer taxes take precedence over billing-entity taxes | invoice | BE-IV-10, BE-IV-51 | - | - | 1 | 2100 |
| `scn.invoice.prepaid.001` | prepaid credits are capped at the invoice total with fractional fee amounts | invoice | BE-IV-31, BE-WL-44, BE-WL-45 | - | premium | 11 | 8380 |
| `scn.invoice.prepaid.002` | wallet limited to a billable metric pays only that metric's fees | invoice | BE-WL-43, BE-WL-45 | - | premium | 5 | 6858 |
| `scn.invoice.progressive.001` | progressive billing: threshold invoice mid-month, then the period invoice credits it | invoice | BE-IV-32, BE-PB-4, BE-PB-12, BE-PB-14, BE-PB-22 | RBD-76 | premium | 8 | 4723 |
| `scn.invoice.progressive.002` | progressive billing: several thresholds crossed within one period | invoice | BE-CN-21, BE-PB-14, BE-PB-15 | RBD-76 | premium | 11 | 6359 |
| `scn.invoice.taxes.001` | plan tax vs charge taxes, charge minimum true-up and a fixed coupon on a monthly arrears invoice | invoice | BE-DM-27, BE-DM-28, BE-PR-59, BE-PR-60, BE-PR-61, BE-IV-10, BE-IV-11, BE-IV-12, BE-IV-13, BE-IV-25 | RBD-69 | core, premium | 13 | 5433 |
| `scn.invoice.taxes.002` | two coupons larger than the fees bring the invoice and its taxes to zero | invoice | BE-DM-27, BE-IV-11, BE-IV-20 | RBD-69 | premium | 9 | 3618 |
| `scn.invoice.taxes.003` | coupons over two subscriptions of one customer: coupon shares and taxes per fee | invoice | BE-DM-27, BE-DM-28, BE-IV-11, BE-IV-25 | RBD-69 | premium | 11 | 4777 |
| `scn.invoice.timezone.001` | customer zone behind UTC on another local day: invoice period computed in local time | invoice | BE-DM-10, BE-DM-13 | RBD-94 | premium | 1 | 2197 |
| `scn.invoice.void.001` | voiding a finalized invoice | invoice | BE-IV-41, BE-IV-42, BE-WL-62 | RBD-73 | core, premium | 2 | 3048 |
| `scn.lifetime.usage.001` | lifetime usage without progressive billing creates no threshold invoice | lifetime | BE-PB-2, BE-PB-3, BE-PB-4 | RBD-76 | premium | 42 | 5149 |
| `scn.pay_in_advance.estimate.001` | fee estimate of an event for a percentage charge with free units | pay_in_advance | BE-PR-44, BE-PR-83 | RBD-53 | premium | 4 | 4496 |
| `scn.pay_in_advance.recurring.001` | recurring metric billed in arrears over several periods | pay_in_advance | BE-AG-4 | - | - | 10 | 6585 |
| `scn.pay_in_advance.sum.001` | pay-in-advance sum charge with groups: per-event fees and usage | pay_in_advance | BE-PR-43, BE-PR-46, BE-AG-40 | - | - | 7 | 7725 |
| `scn.pay_in_advance.unique_count.001` | pay-in-advance unique count charge with groups | pay_in_advance | BE-PR-43, BE-AG-14 | - | - | 9 | 9920 |
| `scn.store_ch.latest.001` | columnar store: latest aggregation usage | store_ch | BE-AG-13 | RBD-25 | store-ch, optional | 7 | 3766 |
| `scn.store_ch.unique_count.001` | columnar store: unique count usage and fees over periods | store_ch | BE-AG-14 | RBD-27, RBD-28 | store-ch, optional | 5 | 3205 |
| `scn.store_ch.weighted_sum.001` | columnar store: weighted sum usage and invoices | store_ch | BE-AG-17 | RBD-29 | store-ch, optional | 8 | 5782 |
| `scn.subscription.billing.001` | monthly calendar arrears plan billed once per billing day | subscription | BE-DM-15 | RBD-94 | core | 5 | 2238 |
| `scn.subscription.billing.002` | monthly anniversary on the 31st: one invoice per period, month-end clamping | subscription | BE-DM-15, BE-SP-31 | RBD-64 | - | 16 | 6777 |
| `scn.subscription.billing.004` | quarterly anniversary from February 28 | subscription | BE-SP-31 | RBD-64 | - | 5 | 5154 |
| `scn.subscription.boundaries.001` | period and charge boundaries over several monthly invoices | subscription | BE-SP-19, BE-SP-20, BE-SP-21, BE-SP-31 | - | - | 4 | 5191 |
| `scn.subscription.boundaries.002` | yearly plan with charges billed monthly | subscription | BE-SP-17, BE-SP-32 | - | - | 6 | 5679 |
| `scn.subscription.boundaries.003` | charge boundaries for pay-in-advance and arrears charge types | subscription | BE-SP-15, BE-SP-21, BE-SP-22 | - | - | 6 | 8465 |
| `scn.subscription.downgrade.001` | downgrade takes effect at the period end (fixed charges in arrears) | subscription | BE-IV-2, BE-SP-35, BE-SP-53 | RBD-60 | - | 7 | 8771 |
| `scn.subscription.downgrade.002` (compat only) | plan amount edit cancels a pending downgrade by comparing raw amounts across intervals | subscription | BE-SP-62, BE-SP-53 | RBD-59 | - | 6 | 4466 |
| `scn.subscription.fee_selection.001` | upgrade: a recurring arrears charge also on the new plan is left to the successor | subscription | BE-SP-65, BE-SP-52, BE-AG-4 | - | - | 6 | 7339 |
| `scn.subscription.fee_selection.002` | termination: an in-advance recurring charge is not billed again on the final invoice | subscription | BE-SP-65, BE-SP-55, BE-CN-15 | - | - | 6 | 7392 |
| `scn.subscription.fee_selection.003` | starting invoice of an advance plan bills in-advance fixed charges only; arrears ones wait for the period end | subscription | BE-SP-66, BE-PR-70 | - | - | 3 | 5433 |
| `scn.subscription.fee_selection.004` | termination invoice bills arrears fixed charges but not in-advance fixed charges | subscription | BE-SP-66, BE-SP-55 | - | - | 2 | 4006 |
| `scn.subscription.recreate.001` | terminate and recreate on the same external id does not bill the period twice | subscription | BE-DM-55 | - | premium | 9 | 5584 |
| `scn.subscription.terminate.001` | subscription with an ending date terminates on that local day (Europe/Paris) | subscription | BE-DM-10, BE-SP-57 | RBD-63 | premium | 2 | 2482 |
| `scn.subscription.terminate.002` | ending date on a billing day bills the previous period once | subscription | BE-SP-27, BE-SP-57 | RBD-63 | premium | 2 | 2483 |
| `scn.subscription.terminate.003` | manual termination of an in-advance subscription: credit note for unused days and final invoice | subscription | BE-API-11, BE-CN-15, BE-SP-55 | RBD-63 | - | 7 | 5651 |
| `scn.subscription.terminate.005` | manual termination with invalid parameters answers a validation error | subscription | BE-API-14, BE-API-15 | - | - | 4 | 3101 |
| `scn.subscription.trial.001` | free trial: the subscription fee is billed at the end of the trial | subscription | BE-SP-61 | - | - | 6 | 2853 |
| `scn.subscription.upgrade.001` | upgrade with fixed charges billed in advance without proration | subscription | BE-PR-67, BE-PR-71, BE-SP-52 | RBD-61, RBD-62 | - | 5 | 9825 |
| `scn.subscription.upgrade.002` | termination fee of a subscription started mid-period is prorated on the whole period | subscription | BE-DM-15, BE-SP-52 | RBD-62 | - | 2 | 2388 |
| `scn.usage.boundaries.001` | quarterly anniversary from a month end: consecutive usage periods meet without overlap | usage | BE-SP-31 | RBD-64 | - | 3 | 2576 |
| `scn.usage.dynamic.001` | current usage, dynamic model priced from event amounts | usage | BE-PR-33 | - | - | 5 | 2919 |
| `scn.usage.filters.001` | current usage with overlapping charge filters | usage | BE-AG-32, BE-AG-33 | - | - | 4 | 2973 |
| `scn.usage.filters.002` | current usage lists every filter, zero ones included | usage | BE-AG-31, BE-AG-34 | - | - | 3 | 2577 |
| `scn.usage.graduated.001` | current usage, graduated model spanning tiers | usage | BE-PR-12, BE-PR-14, BE-PR-16 | RBD-48 | - | 10 | 3331 |
| `scn.usage.graduated_percentage.001` | current usage, graduated percentage model | usage | BE-PR-18, BE-PR-19, BE-PR-20 | - | premium | 3 | 2273 |
| `scn.usage.latest.001` | latest aggregation usage | usage | BE-AG-13 | - | - | 7 | 3718 |
| `scn.usage.package.001` | current usage, package model beyond free units | usage | BE-PR-8, BE-PR-10 | - | - | 14 | 3704 |
| `scn.usage.percentage.001` | current usage, percentage model with free events, free amount and fixed fee | usage | BE-PR-27, BE-PR-28, BE-PR-29 | - | - | 9 | 4667 |
| `scn.usage.prorated_graduated.001` | prorated graduated unique count with adds and removes | usage | BE-PR-35, BE-AG-14 | - | - | 7 | 3333 |
| `scn.usage.standard.001` | current usage, standard model | usage | BE-PR-6, BE-AG-11 | - | core | 6 | 2455 |
| `scn.usage.standard.002` | current usage, standard model grouped by a property | usage | BE-PR-5, BE-AG-36 | - | - | 5 | 2812 |
| `scn.usage.timezone.001` | current usage of a backdated subscription for a customer in Europe/Berlin | usage | BE-DM-10 | - | premium | 2 | 1445 |
| `scn.usage.unique_count.001` | unique count usage and fees over periods | usage | BE-AG-14, BE-AG-15 | - | - | 5 | 3159 |
| `scn.usage.volume.001` | current usage, volume model in the second range | usage | BE-PR-22, BE-PR-23 | - | - | 17 | 4269 |
| `scn.usage.weighted_sum.001` | weighted sum usage and invoices | usage | BE-AG-17, BE-AG-18 | - | - | 8 | 5729 |
| `scn.wallet.alert.001` | wallet balance consumed progressively by usage | wallet | BE-AL-12, BE-WL-55 | - | premium | 15 | 8383 |
| `scn.wallet.balance.001` | wallet balance and ongoing balance with pay-in-advance charges and taxes | wallet | BE-WL-52, BE-WL-55 | RBD-79 | premium | 7 | 4998 |
| `scn.wallet.topup.001` | paid credit top-up amounts are rounded | wallet | BE-WL-9 | RBD-81 | premium | 4 | 2839 |
| `scn.wallet.traceability.001` | wallet consumption spanning two credit inbounds in FIFO order | wallet | BE-WL-13 | - | - | 8 | 5345 |
| `scn.wallet.traceability.003` | granted and purchased prepaid credits shown separately on the invoice | wallet | BE-WL-13 | - | - | 9 | 6181 |
