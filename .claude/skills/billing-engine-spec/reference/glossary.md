# Glossary

> Licence note: this glossary describes concepts of the Lago billing engine (lago-api, AGPL-3.0) at pin `591ae90` in
> neutral words. It is a behavioural specification, not source code; see
> `reimplementation-kit/reference/legal-and-provenance.md`.

<!-- evidence-check: off normative spec; definitions only, each term points to the chapter rules that carry vectors -->

Terms used across the billing-engine chapters, alphabetical. "→" points to the defining chapter or rule.

| Term | Meaning |
|---|---|
| activation rule | A condition that must be satisfied before a subscription becomes active (today only payment); while pending the subscription is `incomplete` → BE-DM-60, chapter 06 |
| add-on | A one-off catalog item with a fixed amount, invoiced on a one-off invoice or used by fixed charges → chapter 05 |
| aggregation | Reduction of a metric's events in a window to units (count, sum, max, unique count, weighted sum, latest, custom) → chapter 04 |
| amount details | JSON breakdown attached to a fee explaining how a charge model produced the amount (tiers, packages, free units) → chapter 05 |
| anniversary / calendar billing | `billing_time` of a subscription: periods aligned on the subscription start date, or on calendar boundaries (1st of the month, Monday, 1 January …) → chapter 06 |
| applied coupon | A coupon attached to one customer, with its own frequency counter and remaining amount → chapter 07 |
| applied tax | Snapshot of a tax (code, name, rate) on a fee, invoice or credit note, with the amount it produced → BE-DM-27, chapter 07 |
| billable metric | What is measured from events: a code, an aggregation type, an optional field name, filters, rounding and recurrence → chapter 04 |
| billing entity | The legal issuer of invoices inside an organization: currency, time zone, numbering, grace period, default taxes → section 2.1 of chapter 01 |
| billing period | The interval a subscription fee or charge covers, in the customer's time zone → chapter 06 |
| charge | A priced billable metric inside a plan (charge model + properties) → chapter 05 |
| charge filter | A charge variant priced differently for events whose properties match given values → BE-DM-56, chapter 04 |
| charge model | Pricing function of a charge: standard, graduated, package, percentage, volume, graduated percentage, dynamic, custom → chapter 05 |
| clock | The scheduler that runs periodic jobs (billing, finalization, activation, termination, refreshes) → chapter 13 |
| code | Client-chosen identifier of a catalog object, unique in a scope → BE-DM-50 |
| commitment (minimum) | A minimum amount per period for a plan; a true-up fee covers the shortfall → chapter 05 |
| coupon | Discount definition (fixed amount or percentage; once, recurring or forever) → chapter 07 |
| credit note | Document crediting part of a finalized invoice back to the customer (credit, refund or offset) → chapter 08 |
| current usage | Usage of the open billing period, priced without creating fees → chapter 04 |
| customer | The billed party: external id, currency, time zone, settings inherited from the billing entity → section 2.2 of chapter 01 |
| day count | Number of local days between two instants, DST-compensated, rounded up → BE-DM-15 |
| draft | Invoice status during the grace period; numbers, coupons, credit notes and wallets are applied only at finalization → chapter 07 |
| effective time zone | Customer zone, else billing-entity zone, else UTC → BE-DM-10 |
| event | One usage record sent by a client: transaction id, metric code, subscription external id, timestamp, properties → chapter 02 |
| exponent | Number of minor-unit digits of a currency → BE-DM-21, `appendix-currencies.md` |
| external id | Client-side identifier of a customer or subscription → BE-DM-2, BE-DM-53, BE-DM-55 |
| fee | One priced line of an invoice (or a pay-in-advance charge without invoice): subscription, charge, fixed charge, add-on, commitment, credit → section 2.5 of chapter 01 |
| finalization | Transition of an invoice to `finalized`; assigns numbers and applies coupons, credit notes and prepaid credits → BE-DM-42, chapter 07 |
| fixed charge | A plan item with a number of units (seats, licences) priced like a charge, independent of events → chapter 05 |
| float island | A computation where the reference uses binary floating point; compat vectors compare with `float64` → BE-DM-30, RBD-96 |
| grace period | Days an invoice stays draft before automatic finalization → BE-DM-11, chapter 07 |
| in arrears / in advance | Billed after the period (usage) or at its start (subscription fee, pay-in-advance charges) → chapters 05-06 |
| invoice subscription | Link between an invoice and a subscription recording the billed boundaries and the invoicing reason → section 2.5 of chapter 01 |
| lifetime usage | Per-subscription running usage amount used by progressive billing and alerts → chapter 10 |
| local date | Calendar date of an instant in the effective time zone → BE-DM-14 |
| minor units (`*_cents`) | Integer amounts in units of 10^-exponent of the currency → BE-DM-21, BE-DM-24 |
| net payment term | Days between issuing date and payment due date → BE-DM-11, chapter 07 |
| organization | The tenant: owns everything, holds the API keys and the webhook signing key → BE-DM-1 |
| pay in advance (charge) | A charge billed per event at ingestion instead of at period end → chapters 04-05 |
| plan | Catalog template: interval, base amount, charges, fixed charges, commitment, thresholds → chapter 06 |
| plan override | A child plan customised for one customer that shares the parent plan's code → BE-DM-58 |
| precise amount | Unrounded companion of a money amount, in minor units with decimals → BE-DM-24, BE-DM-26 |
| prefix (document number) | Upper-case text starting every invoice or slug of an organization or billing entity → BE-DM-32 |
| premium | Licence flag that enables some behaviours (graduated percentage, progressive billing, alerts …); vectors carry `premium: true` → RBD-97 |
| prepaid credits | Wallet credits applied to finalized invoices → chapter 09 |
| pricing unit | A custom unit charges can be priced in, converted to the fiat currency → chapter 05 |
| progressive billing | Invoicing usage as soon as lifetime usage crosses thresholds within a period → chapter 10 |
| proration | Scaling an amount by the fraction of a period used, from day counts → chapters 05-06 |
| recurring metric | A metric whose value carries over from period to period (for example seats) → chapter 04 |
| self-billed | Invoice issued on behalf of a partner customer; always numbered per customer → BE-DM-40 |
| sequential id | Per-scope counter used in numbers: customer, invoice, billing-entity invoice, credit note → BE-DM-34..44 |
| slug | Customer reference `<organization prefix>-<sequential id>` → BE-DM-35 |
| soft delete | Deleted but still resolvable from history → BE-DM-4 |
| subscription | A customer on a plan, with a lifecycle and billing periods → chapter 06 |
| tax | Percentage applied to fees; selected by precedence → BE-DM-27, chapter 07 |
| top-up rule | Wallet rule granting or purchasing credits on an interval or below a threshold → chapter 09 |
| true-up | Fee bringing a charge or plan up to its minimum amount → chapter 05 |
| usage alert | Notification when a measured usage or balance crosses thresholds → chapter 10 |
| usage threshold | Progressive-billing amount (one-off or recurring) that triggers an invoice → chapter 10 |
| wallet | Prepaid credit balance of a customer, with a rate (currency per credit) and priority → chapter 09 |
| webhook | Signed HTTP notification of an engine event to the organization's endpoints → chapter 12 |

## Provenance (maintainers)

- Terms follow the entity and service vocabulary of lago-api @591ae90 as summarised in chapter 01 (its Provenance
  section lists the reference locations). No behaviour is defined here; every arrow points to a rule with vectors.
- Update trigger: a new chapter term or a renamed concept.
