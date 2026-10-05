# 01 — Domain model, money, time and numbering (BE-DM)

> Licence note: this chapter describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90` (2026-09-08).
> It is a behavioural specification written fresh from executed vectors and probes, not source code. Proprietary
> clean-room rebuilds should have it reviewed (`reimplementation-kit/reference/legal-and-provenance.md`).

Facts as of lago-api `591ae90`. This chapter is the foundation every other chapter builds on: conventions shared by
all objects, a reference card per entity, settings inheritance, time-zone and day-count primitives, money
representation and rounding, document numbering, code uniqueness and the status machines. Operations of other
chapters reuse its primitives (for example BE-DM-15 day counting in billing periods, BE-DM-23 rounding everywhere).

Reading guide: rules are numbered `BE-DM-n`; every rule line ends with `[vec: …]` naming the vectors (in
`billing-engine-spec/vectors/domain.*.jsonl`) that pin it, or a prose-only marker with the reason. Wire values of
enumerations are listed in `appendix-enums.md`; the currency table is `appendix-currencies.md`; terms are in
`glossary.md`. Vector inputs and outputs follow `reimplementation-kit/reference/vector-format.md` (decimals as
strings, instants with a zone, money in minor units).

<!-- evidence-check: off normative spec; evidence = the vector ids on each line, checked by kitrun against the oracle -->

## 1. Conventions

- **BE-DM-1** Tenancy. Every billing object belongs to exactly one organization; API lookups are always scoped to the organization of the API key, and every uniqueness rule on codes and external ids in this chapter is per organization (or narrower, BE-DM-50). [vec: domain.catalog.subscription_external_id_valid.006]
- **BE-DM-2** Identifiers. Internal ids are opaque random UUIDs (exposed as `lago_id`); client systems reference objects by their own strings: customer `external_id`, subscription `external_id`, catalog `code`s, and, on events, `external_subscription_id`, `external_customer_id` (optional), `transaction_id` and the billable-metric `code`. Events never carry internal ids. [vec: none (prose only: identity is exercised by the scenario tier through symbolic references)]
- **BE-DM-3** Instants are stored in UTC with microsecond precision; local calendar dates are always derived from an instant and the effective time zone of the customer (BE-DM-10) at the moment they are needed, except the invoice, which snapshots the zone at creation (BE-DM-13). No billing-area vector carries an instant with more than six fractional digits (the vector format allows nine for other areas); how a rebuild treats a finer input is not graded. [vec: domain.time.to_local.*]
- **BE-DM-4** Soft delete. Deleting a catalog object (billable metric and its filters, plan, charge, charge filter, fixed charge, add-on, coupon, tax, customer, billing entity, usage threshold) marks it deleted: it disappears from listings, lookups by code and uniqueness checks (except taxes, BE-DM-51), but stays resolvable from history, so fees and invoices keep pointing at a deleted charge, plan, add-on or customer. Fees and events can be soft-deleted too (for example the events of a deleted billable metric, chapter 02). Subscriptions, invoices, credit notes, wallets, wallet transactions and applied coupons are never soft-deleted; they use statuses (section 8). [vec: domain.catalog.code_reusable.*]
- **BE-DM-5** Enumerations travel as lowercase strings (wire values). The reference stores some as integers in declaration order (with gaps, see `appendix-enums.md`); a rebuild only needs the wire values. [vec: none (prose only: storage codes are not observable through any op; wire values are exercised by every area's vectors)]

## 2. Entity reference

One card per in-scope entity: the attributes that change behaviour, defaults, constraints and relations. Money
attributes are integers in minor units (`*_cents`) of the currency stored beside them; rates are percentages;
`decimal(p,s)` means a decimal with `s` fractional digits. "NN" = never null. Later chapters own the behaviour
(chapter numbers in brackets).

### 2.1 Organization and billing entity

| Entity | Attributes (default) | Constraints and behaviour |
|---|---|---|
| organization | `name` NN; `document_number_prefix` (generated, BE-DM-32); `default_currency` and `timezone` (read through the default billing entity, BE-DM-12); `hmac_key` (random, unique; webhook signing [12]); premium flags; event-store choice (Postgres or ClickHouse store [02, 04]) | 1..N billing entities (licence tier caps: 1, 2, unlimited). The **default billing entity** is the oldest active (not archived, not deleted) one. |
| billing entity | `code` NN; `name` NN; `default_currency` (USD); `timezone` (UTC); `document_numbering` (`per_customer`); `document_number_prefix` (BE-DM-32/33); `invoice_grace_period` (0 days); `net_payment_term` (0 days); `finalize_zero_amount_invoice` (true); `subscription_invoice_issuing_date_anchor` (`next_period_start`); `subscription_invoice_issuing_date_adjustment` (`align_with_finalization_date`); `document_locale` (`en`); default taxes; `archived_at`; deleted flag | `code` unique among the organization's non-archived, non-deleted entities (BE-DM-50). Every customer belongs to exactly one billing entity; invoices and fees record the billing entity; a subscription or wallet without one uses its customer's. The first billing entity of a new organization reuses the organization's id and name, so its generated prefix equals the organization's. |

### 2.2 Customer

| Attributes (default) | Constraints and behaviour |
|---|---|
| `external_id` NN; `billing_entity` NN; `sequential_id` (BE-DM-34); `slug` (BE-DM-35); `currency` (null until first use); `timezone` (null = inherit); `invoice_grace_period`, `net_payment_term` (null = inherit, ≥ 0); `finalize_zero_amount_invoice` (`inherit` \| `skip` \| `finalize`); issuing-date anchor/adjustment (null = inherit); `document_locale` (null = inherit); `customer_type` (`company` \| `individual` \| null); `account_type` (`customer` \| `partner`); customer taxes; deleted flag | `external_id` unique among non-deleted customers (BE-DM-53). **Currency**: set from the first object that needs one (subscription, wallet, coupon, one-off invoice) when blank; later objects in another currency neither change nor are rejected by it at this pin. A customer is no longer "editable" (currency etc.) once it has a subscription, an applied add-on, an invoice, a fixed-amount applied coupon or a wallet. Deleting a customer terminates its active subscriptions, cancels pending ones, terminates active applied coupons and wallets, and schedules its draft invoices for finalization. |

### 2.3 Catalog

| Entity | Attributes (default) | Constraints and behaviour |
|---|---|---|
| billable metric | `code` NN; `name` NN; `aggregation_type` (`count_agg`, `sum_agg`, `max_agg`, `unique_count_agg`, `weighted_sum_agg`, `latest_agg`, `custom_agg`); `field_name` (required except count/custom; cleared for count); `recurring` (false; forbidden with count, max, latest); `expression` (validated by the expression language [03]); `rounding_function` (`round` \| `ceil` \| `floor`, BE-DM-25) + `rounding_precision`; `weighted_interval` (`seconds`, required for weighted sum); filters `{key, values[]}` | Pay-in-advance capable: count, sum, unique count, custom [04, 05]. Unknown aggregation types are rejected. |
| plan | `code` NN; `name` NN; `interval` (`weekly`, `monthly`, `quarterly`, `semiannual`, `yearly`); `amount_cents` + `amount_currency`; `pay_in_advance` (false); `bill_charges_monthly`, `bill_fixed_charges_monthly`; `trial_period` (days, decimal); parent (plan override for one customer); usage thresholds; minimum commitment | `code` unique among the organization's non-deleted parent plans; an override (child) plan shares its parent's code [05, 06]. Upgrade/downgrade compares yearly-normalised amounts (weekly ×52, monthly ×12, quarterly ×4, semiannual ×2) [06]. |
| charge | `billable_metric`; `code` NN; `charge_model` (`standard`, `graduated`, `package`, `percentage`, `volume`, `graduated_percentage`, `custom`, `dynamic`); `properties` (model-specific JSON) NN; `pay_in_advance` (false); `invoiceable` (true); `prorated` (false); `min_amount_cents` (0); `regroup_paid_fees` (null \| `invoice`); charge filters; taxes | `code` unique among the plan's non-deleted parent charges (BE-DM-50). Model/metric/flag compatibility rules are chapter 05. |
| charge filter | `values` per billable-metric filter key (a subset of the metric filter's values, or the wildcard meaning all values); `properties`; `invoice_display_name`; `code` (BE-DM-56) | `code` unique per charge among non-deleted filters (BE-DM-57). Listing order is by last update, oldest first. |
| fixed charge | `add_on`; `code` NN; `charge_model` (`standard`, `graduated`, `volume`); `units` decimal ≥ 0 (0); `pay_in_advance`; `prorated`; `properties`; per-subscription unit overrides | `code` unique among the plan's non-deleted parent fixed charges. Effective units for a subscription: its active override, else the fixed charge's units [05]. |
| commitment | `commitment_type` (`minimum_commitment`, one per plan); `amount_cents` > 0; taxes | Chapter 05 (true-up). |
| add-on | `code` NN; `name`; `amount_cents` > 0; `amount_currency`; taxes | `code` unique among non-deleted add-ons. |
| coupon | `code` NN; `coupon_type` (`fixed_amount` \| `percentage`); `amount_cents`/`amount_currency` (fixed) or `percentage_rate` decimal(10,5) (percentage); `frequency` (`once` \| `recurring` \| `forever`) + `frequency_duration` (> 0 when recurring); `expiration` (`no_expiration` \| `time_limit`) + `expiration_at`; `reusable` (true); plan / billable-metric limitations; `status` (`active` \| `terminated`) | `code` unique among non-deleted coupons. Application is chapter 07. |
| tax | `code` NN; `name` NN; `rate` (percent, a binary floating-point number in the reference: BE-DM-30); `description` | `code` unique among ALL the organization's taxes, deleted ones included (BE-DM-51). Taxes attach to billing entities (defaults), customers, plans, charges, fixed charges, commitments and add-ons; fees, invoices and credit notes keep a snapshot (code, name, rate) of every applied tax [07]. |
| pricing unit | `code` (unique per organization); `short_name` (≤ 3 chars); exponent fixed at 2; per-charge conversion rate > 0 | Chapter 05. |

### 2.4 Subscription

| Attributes (default) | Constraints and behaviour |
|---|---|
| `external_id` NN; `customer`; `plan`; `status` (`pending`, `active`, `terminated`, `canceled`, `incomplete`); `billing_time` (`calendar` \| `anniversary`, default calendar); `subscription_at`, `started_at`, `activated_at`, `terminated_at`, `canceled_at`, `trial_ended_at`, `ending_at`; `previous_subscription` (upgrade/downgrade chain); `on_termination_credit_note` (`credit` \| `skip` \| `refund` \| `offset`; only for pay-in-advance plans); `on_termination_invoice` (`generate` \| `skip`, default generate); `cancellation_reason` (`payment_failed` \| `timeout` \| `manual`); activation rules (`payment`, with status `inactive`, `pending`, `satisfied`, `declined`, `failed`, `expired`, `not_applicable`) | External-id rule BE-DM-55; a plan change keeps the external id across a chain of subscriptions. Creating a subscription whose external id is used by an active subscription of the same customer is a plan change; when an active subscription of the organization has it and no plan change applies, creation is rejected with `value_already_exist`. Lifecycle, periods and proration: chapter 06. |

### 2.5 Fees, invoices, credit notes

| Entity | Attributes (default) | Constraints and behaviour |
|---|---|---|
| fee | `fee_type` (`charge`, `add_on`, `subscription`, `credit`, `commitment`, `fixed_charge`); `amount_cents` + `precise_amount_cents` decimal(40,15); `taxes_amount_cents` + `taxes_precise_amount_cents` decimal(40,15); `taxes_rate`; `precise_coupons_amount_cents` decimal(30,5); `precise_credit_notes_amount_cents` decimal(30,5); `unit_amount_cents` + `precise_unit_amount` decimal(30,15); `units` ≥ 0; `events_count`; `amount_details` (JSON); `grouped_by` (JSON, default `{}`); `pay_in_advance`; `payment_status` (`pending`, `succeeded`, `failed`, `refunded`); period boundaries; links to charge, charge filter, fixed charge, add-on, subscription, invoice (may be absent for pay-in-advance fees), true-up parent | Fee total = amount + taxes. Pay-in-advance duplicate guard: one non-deleted fee per (event transaction id, charge, charge filter). Money rules BE-DM-24, taxes BE-DM-27..30; computation chapters 05-06. |
| invoice | `invoice_type` (`subscription`, `add_on`, `credit`, `one_off`, `advance_charges`, `progressive_billing`); `status` (section 8); `payment_status` (`pending`, `succeeded`, `failed`); `tax_status` (`pending`, `succeeded`, `failed`, null); `number` (BE-DM-39..42); `sequential_id` (BE-DM-37); `billing_entity_sequential_id` (BE-DM-38); `issuing_date`, `expected_finalization_date`, `payment_due_date`; `timezone` (snapshot, BE-DM-13); `currency`; amounts `fees_amount_cents`, `coupons_amount_cents`, `progressive_billing_credit_amount_cents`, `sub_total_excluding_taxes_amount_cents`, `taxes_amount_cents`, `sub_total_including_taxes_amount_cents`, `credit_notes_amount_cents`, `prepaid_credit_amount_cents`, `total_amount_cents` (≥ 0), `total_paid_amount_cents` (all integers, default 0); `taxes_rate`; `self_billed`; `voided_at`; `finalized_at` | Invoice subscriptions record, per subscription, the billed boundaries and the invoicing reason (`subscription_starting`, `subscription_periodic`, `subscription_terminating`, `in_advance_charge`, `in_advance_charge_periodic`, `progressive_billing`); double billing of the same charges period is prevented. Amount due = 0 when voided, else total − total paid − offsets of finalized credit notes. Pipeline: chapter 07. |
| credit note | `sequential_id` (per invoice, BE-DM-44); `number` (BE-DM-45); `issuing_date`; `reason` (`duplicated_charge`, `product_unsatisfactory`, `order_change`, `order_cancellation`, `fraudulent_charge`, `other`); `status` (`draft`, `finalized`, `deleted`); `credit_status` (`available`, `consumed`, `voided`); `refund_status` (`pending`, `succeeded`, `failed`); credit, balance, refund, offset, total, taxes, coupons-adjustment, sub-total amounts (integers ≥ 0); precise taxes and coupons adjustment decimal(30,5); items `{fee, amount_cents, precise_amount_cents}` | Chapter 08. |

### 2.6 Wallets, thresholds, alerts, events, webhooks

| Entity | Attributes (default) | Constraints and behaviour |
|---|---|---|
| wallet | `code` (BE-DM-54); `status` (`active` \| `terminated`); `rate_amount` decimal(30,5) > 0 (currency per credit); `currency`; balances in cents and in credits (decimal(30,5)); `priority` 1..50 (50); `allowed_fee_types`; billable-metric targets; `traceable`; paid top-up min/max; `expiration_at` | Chapter 09. |
| wallet transaction | `transaction_type` (`inbound` \| `outbound`); `status` (`pending`, `settled`, `failed`); `transaction_status` (`purchased`, `granted`, `voided`, `invoiced`); `source` (`manual`, `interval`, `threshold`); `amount`, `credit_amount` decimal(30,5); remaining amount (inbound only); `priority` 1..50 | Chapter 09. |
| recurring top-up rule | `trigger` (`interval` \| `threshold`); `method` (`fixed` \| `target`); `interval` (`weekly`, `monthly`, `quarterly`, `yearly`, `semiannual`); paid/granted/threshold credits, target balance; `status` | Chapter 09. |
| usage threshold | `amount_cents` > 0; `recurring` (at most one recurring per parent); parent = plan XOR subscription; amounts unique per parent | Chapter 10. |
| usage alert | `alert_type` (9 types, `appendix-enums.md`); `code` (unique per subscription external id among non-deleted alerts); `direction` (`increasing` \| `decreasing`); thresholds `{value decimal(30,5), recurring, code}` (≤ 1 recurring, ≤ 20 thresholds); `previous_value` | Chapter 10. |
| event | `transaction_id` NN; `code` NN; `external_subscription_id`; `external_customer_id`; `timestamp` (µs); `properties` (JSON, default `{}`); `precise_total_amount_cents` decimal(40,15) | Idempotency, validation and resolution to customer and subscription: chapter 02. |
| webhook endpoint / webhook | endpoint: `webhook_url` (unique per organization, ≤ 10 per organization), `signature_algo` (`jwt` \| `hmac`, default jwt), `event_types` (null = all); webhook delivery: `status` (`pending`, `succeeded`, `failed`, `retrying`), `retries`, `http_status` | Chapter 12. |
| lifetime usage | one per subscription: historical, invoiced and current usage amounts (≥ 0); total = sum of the three | Chapter 10. |

## 3. Settings inheritance

- **BE-DM-10** Effective time zone of a customer = the customer's zone if present and not blank, else its billing entity's zone, else UTC. Every "local date", "today" and "end of day" of a customer in later chapters uses this zone. [vec: domain.time.effective_timezone.*]
- **BE-DM-11** Other customer settings inherit the same way, each independently: grace period (customer → billing entity → 0), net payment term (customer → billing entity), issuing-date anchor and adjustment (customer → billing entity), document locale (customer → billing entity). A value of 0 set on the customer is a value (it does not inherit); a blank time zone is not. The zero-amount finalization setting inherits through the customer's `inherit` choice (chapter 07). [vec: domain.time.applicable_settings.*]
- **BE-DM-12** The organization's own time zone and default currency are those of its default billing entity (the oldest active one) when it has one; the organization-level stored values are only a fallback and may disagree with what the engine uses. [vec: none (prose only: no op takes an organization; observed by the domain probe that updates the default billing entity and reads the organization)]
- **BE-DM-13** An invoice records the customer's effective time zone at creation; its issuing date and due dates are computed in that zone (chapter 07). [vec: none (prose only: exercised by chapter 07 vectors and the scenario tier)]

## 4. Time

All instants are UTC; a time zone is an IANA name. "Local" means wall-clock time in the effective zone (BE-DM-10).

- **BE-DM-14** Local conversion uses the zone's offset in force at that instant (daylight saving and historical rules included; half- and quarter-hour offsets exist). During an autumn change the same wall-clock time occurs twice with different offsets; during a spring change some wall-clock times never occur. [vec: domain.time.to_local.*]
- **BE-DM-15** Day count between two instants `from` and `to` in a zone (used for every proration and period length): `days = ceil(((to − from) + (offset(to) − offset(from))) / 24 h)`, where `offset(x)` is the zone's UTC offset at `x` (positive east of UTC), after the adjustment of BE-DM-16. This is the local wall-clock duration `local(to) − local(from)` (with `local(x) = x + offset(x)`) with any fraction of a day rounded up: across a spring change (the offset grows) the hour skipped by the clock is added back, across an autumn change the repeated hour is removed. Seconds and sub-second parts count. Two vectors pin the sign: in Sydney the offset falls from +11:00 to +10:00 and 30 days 00:59:59 of elapsed time are 29 days 23:59:59 of wall clock, so 30 days (`domain.time.days_between.006`); in New York the offset rises from −05:00 to −04:00 and 29 days 23:30 of elapsed time are 30 days 00:30 of wall clock, so 31 days (`domain.time.days_between.013`). The opposite sign gives 31 and 30. [vec: domain.time.days_between.*]
- **BE-DM-16** If `to` falls exactly on a local midnight, it is moved one second later before counting, so a period that ends at midnight counts the day that starts there (a zero-length period at midnight counts 1; a calendar month passed as "first instant of the month to first instant of the next month" counts one day more than the month). Billing periods therefore end at `23:59:59` local of their last day. [vec: domain.time.days_between.002, domain.time.days_between.003]
- **BE-DM-17** Because the offset change is compensated, a daylight-saving change neither adds nor removes a day (a 23-hour or 25-hour local day counts as one day). [vec: domain.time.days_between.005, domain.time.days_between.006]
- **BE-DM-18** For a period of a subscription that was terminated by an upgrade, the count is one less, floored at 0. [vec: domain.time.days_between.011, domain.time.days_between.012]
- **BE-DM-19** "Termination reached at instant t" is false unless the subscription status is terminated; otherwise both the termination instant and t are rounded to the nearest whole second (a half second rounds up) and the termination is reached when rounded(terminated_at) ≤ rounded(t). Billing-period and invoicing logic use it to decide whether a run at t is the terminating run of a subscription (chapters 06, 07). [vec: domain.time.terminated_at_reached.*]
- **BE-DM-20** Database-side "local date" computations (for example "subscriptions ending today", daily usage dates) use the same zone precedence as BE-DM-10. [vec: none (prose only: query-side restatement of BE-DM-10; exercised by chapter 06 and 13 vectors)]

Day count, as fresh pseudocode:

```
days_between(from, to, zone, terminated_by_upgrade = false):
    if local_time(to, zone) is 00:00:00.000000: to = to + 1 second
    seconds = (to - from) + (utc_offset(zone, to) - utc_offset(zone, from))   # = local(to) - local(from)
    days = ceiling(seconds / 86400)
    if terminated_by_upgrade: days = max(days - 1, 0)
    return days
```

## 5. Money

- **BE-DM-21** Amounts are stored as integers in minor units of a currency (`*_cents`); the number of minor-unit digits (exponent) is a property of the currency: 2 for most, 0 for JPY, KRW, HUF, ISK, UGX and others, 3 for BHD, JOD, KWD, 4 for CLF (`appendix-currencies.md`). MRO is the single exception whose minor unit is one fifth. [vec: domain.money.currency_exponent.*]
- **BE-DM-22** Only the 142 currencies of `appendix-currencies.md` are accepted; any other code (including valid ISO codes such as OMR) is a validation error `value_is_invalid` on the currency attribute. [vec: domain.money.currency_exponent.*]
- **BE-DM-23** Every rounding of money and of metric values rounds half away from zero, also for negative values (−0.125 EUR → −13 cents), and is performed on exact decimals (0.135 is a tie, 1.005 at two places is 1.01). Binary floating point appears only in the documented float islands (BE-DM-30 and later chapters). [vec: domain.money.to_minor_units.*, domain.money.round.001, domain.money.round.003]
- **BE-DM-24** Major units to minor units: `amount_cents = round_half_away(amount, exponent) × 10^exponent`; the **precise** companion keeps the unrounded value in minor units: `precise_amount_cents = amount × 10^exponent`. Fees, true-ups, estimates and projections all follow this rule (chapters 05-06). The conversion is defined for the accepted currencies (BE-DM-22) whose minor unit is a power of ten: a code outside the accepted list never reaches it (the engine rejects such a code on every currency-bearing attribute) and MRO needs explicit treatment (`appendix-currencies.md`), so no vector converts either and their result is not graded. [vec: domain.money.to_minor_units.*]
- **BE-DM-25** Metric rounding function (billable metrics, BE-AG): `round` (half away from zero), `ceil` (towards +∞) or `floor` (towards −∞) at `precision` decimal places; a negative precision rounds to tens, hundreds, …; no precision means 0. [vec: domain.money.round.*]
- **BE-DM-26** Precision of stored companions: fee and fee-tax precise amounts and event precise totals keep 15 decimal places; unit prices 15; coupon and credit-note allocations and wallet credits 5; units are unbounded decimals. Values computed with more digits are stored at these scales (the chapters that own a value say where it is truncated or rounded before storing). [vec: none (prose only: storage scale; the vectors of chapters 05-09 compare precise values with the matching scale)]
- **BE-DM-27** Tax rows of a fee. The taxable base is the fee amount minus its coupon share: `base = amount_cents − precise_coupons_amount_cents`. For each applicable tax (selection precedence: chapter 07), the unrounded row is `(base × rate) / 100` — the product `base × rate` is exact and only the division by 100 is done in binary floating point — and the row amount is `round_half_away` of it: 180 cents at 17.5 % give 3150 / 100 = 31.5 → 32, never `base × (rate / 100)` = 31.499999999999996 → 31 (chapter 07 BE-IV-11, the same formula). The row's precise amount is `((precise_amount_cents − precise_coupons_amount_cents) × rate) / 100`, unrounded. [vec: domain.money.fee_taxes.*, invoice.apply_taxes.011]
- **BE-DM-28** The fee's `taxes_amount_cents` is the rounded sum of the UNROUNDED row amounts, not the sum of the rounded rows: two 10 % taxes on 15 cents give rows of 2 and 2 but a fee tax of 3; three 10 % taxes on 14 cents give rows 1 + 1 + 1 and a fee tax of 4 (RBD-69 keeps this). [vec: domain.money.fee_taxes.001, domain.money.fee_taxes.005, domain.money.fee_taxes.010]
- **BE-DM-29** The fee's `taxes_precise_amount_cents` is the sum of the precise rows and its `taxes_rate` the sum of the rates; with no applicable tax all three are 0 and there are no rows. Fee total = amount + taxes. [vec: domain.money.fee_taxes.001, domain.money.fee_taxes.002, domain.money.fee_taxes.004, domain.money.fee_taxes.006, domain.money.fee_taxes.010]
- **BE-DM-30** Tax rates are binary floating-point numbers in the reference (read back at 16 significant digits, so a rate is used as given up to 15 significant digits). The row arithmetic is `(base × rate) / 100`: exact product, then a binary floating-point division by 100 (chapter 07 BE-IV-11/12 use the same formula); the fee's tax total rounds the binary floating-point sum of the unrounded rows. For rates with one or two decimals and integer or 5-decimal bases this equals exact decimal arithmetic in every vector; the evaluation order matters, since `base × (rate / 100)` in binary floating point would give 31 instead of 32 for 180 cents at 17.5 % (the invoice-level consequences are RBD-68, chapter 07). [vec: domain.money.fee_taxes.010, invoice.apply_taxes.011]
- **BE-DM-31** Wallet credits ↔ money and pricing units ↔ money conversions are specified in chapters 09 and 05; they reuse BE-DM-23 and BE-DM-24 with their own rounding points. [vec: none (prose only: cross-reference; vectors in wallets.* and pricing.*)]

Fee taxes, as fresh pseudocode:

```
fee_taxes(amount_cents, precise_amount_cents, coupons, taxes):     # coupons = precise coupon share of the fee
    rows = []; sum_unrounded = 0; sum_precise = 0; rate_total = 0
    for tax in taxes:
        unrounded = (amount_cents - coupons) * tax.rate / 100
        precise   = (precise_amount_cents - coupons) * tax.rate / 100
        rows.append({code: tax.code, amount_cents: round_half_away(unrounded, 0), precise_amount_cents: precise})
        sum_unrounded += unrounded; sum_precise += precise; rate_total += tax.rate
    return rows, round_half_away(sum_unrounded, 0), sum_precise, rate_total
```

## 6. Identifiers and numbering

Numbers are assigned by the engine; clients cannot choose them. Every counter below is computed under a lock
scoped to its sequence, so concurrent assignments in one scope are serialised (BE-DM-47).

- **BE-DM-32** Default document prefix of an organization or billing entity: the first three characters (Unicode code points) of its name (all of it when shorter; spaces and non-ASCII letters kept, never transliterated) upper-cased with full Unicode case mapping (so `ß` becomes `SS` and the prefix part can be longer than three characters), a dash, and the last four characters of its id upper-cased (`LAGO` + id ending `…abcd1234` → `LAG-1234`). An organization always gets a generated prefix at creation; a billing entity only when none was supplied. [vec: domain.numbering.document_prefix.001, domain.numbering.document_prefix.002, domain.numbering.document_prefix.003, domain.numbering.document_prefix.004, domain.numbering.document_prefix.009]
- **BE-DM-33** A supplied prefix is upper-cased and must be 1 to 10 characters (`value_is_too_long` / `value_is_too_short` on `document_number_prefix`). [vec: domain.numbering.document_prefix.005, domain.numbering.document_prefix.008]
- **BE-DM-34** Customer sequential id = 1 + the largest sequential id among ALL customers of the organization, deleted ones included; gaps are never filled and a deleted customer's number is never reused. [vec: domain.numbering.next_sequential_id.002, domain.numbering.next_sequential_id.003]
- **BE-DM-35** Customer slug = ORGANIZATION prefix + `-` + the customer sequential id padded to three digits; it is set once at creation and never recomputed (a later prefix change does not rename existing slugs). [vec: domain.numbering.customer_slug.*]
- **BE-DM-36** Every numeric part of a document number is written in decimal, left-padded with zeros to at least three digits, and never truncated (`6` → `006`, `1234` → `1234`). [vec: domain.numbering.customer_slug.*, domain.numbering.invoice_number.008]
- **BE-DM-37** Invoice sequential id (per customer): assigned only when the invoice becomes finalized (BE-DM-42), as 1 + the largest sequential id among the same customer's invoices in the same billing entity, whatever their status (drafts that already hold one count). Invoices of other billing entities do not count. An invoice that already has one keeps it; the first invoice of its scope gets 1. [vec: domain.numbering.next_sequential_id.004, domain.numbering.next_sequential_id.005, domain.numbering.next_sequential_id.006]
- **BE-DM-38** Billing-entity sequential id: assigned at finalization when the billing entity numbers `per_billing_entity` and the invoice is not self-billed, as 1 + the largest value among the billing entity's non-self-billed invoices whose status is finalized or voided; drafts are ignored even if they hold a value (so a draft holding the next value and a newly finalized invoice can end up with the same value), and the counter is never reset (not monthly, not yearly). An invoice that already holds a value keeps it; the first invoice of its scope gets 1. [vec: domain.numbering.next_sequential_id.008, domain.numbering.next_sequential_id.009, domain.numbering.next_sequential_id.011, domain.numbering.next_sequential_id.012]
- **BE-DM-39** An invoice that is not being finalized keeps its number; a blank number becomes `<billing-entity prefix>-DRAFT`. [vec: domain.numbering.invoice_number.005]
- **BE-DM-40** At finalization with `per_customer` numbering, or for any self-billed invoice: `<billing-entity prefix>-<customer sequential id>-<invoice sequential id>` (BE-DM-36 padding). [vec: domain.numbering.invoice_number.001, domain.numbering.invoice_number.004, domain.numbering.invoice_number.008]
- **BE-DM-41** At finalization with `per_billing_entity` numbering (not self-billed): `<billing-entity prefix>-<YYYYMM>-<billing-entity sequential id>`, where YYYYMM is the year and month of the finalization wall clock in the billing entity's time zone (not the issuing date, not the customer's zone); since the counter never resets (BE-DM-38) the month part is informational (RBD-82 keeps this). [vec: domain.numbering.invoice_number.002, domain.numbering.invoice_number.003, domain.numbering.invoice_number.006, domain.numbering.invoice_number.007]
- **BE-DM-42** Finalization = the status becomes `finalized` from `draft`, `generating`, `open`, `failed` or `pending`; only then are sequential ids and the final number assigned. Later transitions (for example voiding) keep the number. [vec: domain.numbering.invoice_number.001, domain.numbering.invoice_number.002, domain.numbering.invoice_number.009, domain.numbering.invoice_number.011]
- **BE-DM-43** Prefix sources differ: invoice numbers use the BILLING ENTITY prefix while customer slugs use the ORGANIZATION prefix; they coincide only for the first billing entity (BE-DM-32). The customer part of an invoice number is the customer sequential id, not the slug. [vec: domain.numbering.invoice_number.001, domain.numbering.customer_slug.001]
- **BE-DM-44** Credit-note sequential id = 1 + the largest sequential id among the credit notes of the same invoice, any status. [vec: domain.numbering.next_sequential_id.013, domain.numbering.next_sequential_id.014]
- **BE-DM-45** Credit-note number = `<invoice number>-CN<credit-note sequential id>` (three-digit padding); computed when the stored number is blank (also for a draft) and recomputed when the credit note goes from draft to finalized; otherwise kept. [vec: domain.numbering.credit_note_number.*]
- **BE-DM-46** Payment receipts (out of scope) are numbered `<customer slug>-RCPT-<per-customer counter padded to 6 digits>`. [vec: none (prose only: payment receipts are an out-of-scope object; numbering convention given for completeness)]
- **BE-DM-47** Concurrency: each counter (customer per organization, invoice per customer and billing entity, billing-entity invoices per billing entity, credit note per invoice) is assigned inside the transaction that saves the document, serialised per scope (a lock or an equivalent atomic sequence). [vec: none (prose only: concurrency is not observable through a single-call op)]
- **BE-DM-48** Switching a billing entity to `per_billing_entity` numbering seeds the counter so the next number continues from the count of already-numbered invoices of that entity (chapter 07 owns the switch). [vec: none (prose only: exercised by the scenario tier's numbering scenario)]

Invoice number at save time, as fresh pseudocode:

```
on_save(invoice, previous_status, now):
    finalizing = invoice.status == "finalized" and previous_status in {draft, generating, open, failed, pending}
    if not finalizing:
        if invoice.number is blank: invoice.number = prefix + "-DRAFT"
        return
    if invoice.sequential_id is null: invoice.sequential_id = next_in(customer, billing_entity)        # BE-DM-37
    if numbering == per_billing_entity and not self_billed and invoice.be_sequential_id is null:
        invoice.be_sequential_id = next_in(billing_entity, finalized or voided, not self-billed)     # BE-DM-38
    if numbering == per_customer or self_billed:
        invoice.number = prefix + "-" + pad3(customer.sequential_id) + "-" + pad3(invoice.sequential_id)
    else:
        invoice.number = prefix + "-" + yyyymm(now, billing_entity.zone) + "-" + pad3(invoice.be_sequential_id)
```

## 7. Codes and uniqueness

- **BE-DM-50** Code uniqueness scopes. Organization-wide among non-deleted rows: billable metric, coupon, add-on, plan (parent plans only), customer `external_id`; among non-deleted and non-archived rows: billing entity `code`; plan-wide among non-deleted parent rows: charge and fixed charge `code`; charge-wide among non-deleted rows: charge filter `code`; customer-wide among ACTIVE wallets: wallet `code`; organization-wide: pricing unit `code`, webhook endpoint URL; per subscription external id among non-deleted alerts: alert `code`. A conflict is the validation error `value_already_exist` on the code attribute. [vec: domain.catalog.code_reusable.*]
- **BE-DM-51** Exception: a tax code stays taken after the tax is deleted (deleted taxes still block the code), unlike every other catalog code. RBD-80 records this; the corrected profile proposes allowing reuse (owner to rule). [vec: domain.catalog.code_reusable.tax.001, domain.catalog.code_reusable.tax.001x]
- **BE-DM-52** Codes and external ids compare case-sensitively and byte-exactly (`API_calls` ≠ `api_calls`). [vec: domain.catalog.code_reusable.billable_metric.003]
- **BE-DM-53** A deleted customer's external id can be reused by a new customer; events resolve customers through the deletion time (chapter 02). [vec: domain.catalog.code_reusable.customer.001]
- **BE-DM-54** A wallet code is unique among the customer's active wallets; a terminated wallet frees its code. [vec: domain.catalog.code_reusable.wallet.*]
- **BE-DM-55** Subscription external id: there is no global uniqueness. When a subscription enters `active` or `incomplete` (creation or status change), it is invalid (`value_already_exist` on `external_id`) if another subscription of the same organization, of any customer, with the SAME status already has that external id. Pending, terminated and canceled duplicates are allowed, and an active and an incomplete subscription may share one. [vec: domain.catalog.subscription_external_id_valid.*]
- **BE-DM-56** Charge-filter code (generated at creation, never recomputed): build the canonical text — keys sorted, each rendered `key:` followed by its values sorted and joined with `+`, the parts joined with `|` (sorting is plain code-point order, so `10` < `2` < `9`) — then `code = slug(canonical)[0:200] + "_" + hex(sha256(canonical as UTF-8))[0:8]` (the hash is taken over the canonical text as given, not NFC-normalised). slug: normalise to Unicode NFC; replace each non-ASCII character that is in the transliteration table (BE-DM-59) by its ASCII approximation and every other non-ASCII character by `?`; replace every run of characters other than ASCII letters, digits, `-` and `_` with `_`, collapse repeated `_`, remove one leading and one trailing `_`, lower-case. The all-values wildcard is the literal value `__ALL_FILTER_VALUES__`. [vec: domain.catalog.charge_filter_code.*]
- **BE-DM-57** When the generated code is already used by another filter of the same charge, the first free of `code_2`, `code_3`, … is taken. [vec: domain.catalog.charge_filter_code.004, domain.catalog.charge_filter_code.005]
- **BE-DM-58** An override (child) plan, charge or fixed charge shares its parent's code; uniqueness applies to parents only. [vec: none (prose only: plan overrides are created through the plan-override API; no unit op covers them)]
- **BE-DM-59** Transliteration table of BE-DM-56 (a fixed table, independent of any locale): the characters U+00C0–U+017E except `÷` (U+00F7), plus `Ǫ ǫ Ǭ ǭ` (U+01EA–U+01ED) and `ẞ` (U+1E9E), 195 entries. Each maps to its base letter without diacritics (`é` → `e`, `Ľ` → `L`, `ź` → `z`), except these: `Æ`→`AE`, `æ`→`ae`, `Ð`→`D`, `ð`→`d`, `×`→`x`, `Ø`→`O`, `ø`→`o`, `Þ`→`Th`, `þ`→`th`, `ß`→`ss`, `ẞ`→`SS`, `Đ`→`D`, `đ`→`d`, `Ħ`→`H`, `ħ`→`h`, `ı`→`i`, `Ĳ`→`IJ`, `ĳ`→`ij`, `ĸ`→`k`, `Ŀ`→`L`, `ŀ`→`l`, `Ł`→`L`, `ł`→`l`, `ŉ`→`'n`, `Ŋ`→`NG`, `ŋ`→`ng`, `Œ`→`OE`, `œ`→`oe`, `Ŧ`→`T`, `ŧ`→`t`. Every other non-ASCII character (Latin Extended-B and Additional letters such as `ở`, `ſ`, CJK, symbols, a combining mark with no precomposed form) is not transliterated and ends up as a separator. Decomposition-based ASCII folding is NOT equivalent. [vec: domain.catalog.charge_filter_code.010, domain.catalog.charge_filter_code.011]

## 8. Status machines

Overview of every lifecycle; the chapter in brackets owns triggers, timing and side effects. Timestamps named in a
transition are set once (the first time) and never overwritten.

- **BE-DM-60** Subscription [06]: create → `active` when its subscription date (customer-local) is before today, else `pending` (today: activated at once by the same request; future: by the clock). `pending` → `active`, or → `incomplete` when it has pending activation rules (payment gating; `started_at` set). `incomplete` → `active` when every rule is satisfied or not applicable; → `canceled` when a rule is failed, expired or declined. `active` → `terminated` (`terminated_at`); `pending` → `canceled` (`canceled_at`); terminating a canceled subscription is an error (`subscription_canceled`) and terminating a terminated one is a no-op. Activation sets `started_at`/`activated_at` once. [vec: none (prose only: exercised by chapter 06 lifecycle vectors and the scenario tier)]
- **BE-DM-61** Activation rule [06]: `inactive` → `pending` → `satisfied` \| `declined` \| `failed` \| `expired`; `not_applicable` when the rule does not apply. [vec: none (prose only: payment gating depends on out-of-scope payment providers)]
- **BE-DM-62** Invoice [07]: created `generating` → `draft` (grace period > 0) \| `finalized` \| `closed` (zero fees and zero-amount finalization disabled) \| `open` (gated subscription) \| `pending` (tax or tax-id check pending) \| `failed` (tax provider error). `draft` → `finalized` (finalize, or the clock once the expected finalization date is reached) \| `deleted`; `finalized` → `voided` (`voided_at`; no longer payable or overdue); `open` → `finalized` \| `closed`; `failed` → `pending` \| `open` (retry). Visible statuses: draft, finalized, voided, failed, pending; the others are never listed by the API. [vec: none (prose only: exercised by chapter 07 lifecycle vectors and the scenario tier)]
- **BE-DM-63** Credit note [08], three independent axes: `status` draft → finalized (a credit note on a draft invoice is finalized with it); `credit_status` `available` (set when the credit amount > 0) → `consumed` (balance 0) \| `voided` (balance forced to 0); `refund_status` `pending` (set when the refund amount > 0) → `succeeded` \| `failed`. Voidable only while the balance is > 0. [vec: none (prose only: exercised by chapter 08 vectors and the scenario tier)]
- **BE-DM-64** Wallet `active` → `terminated` (`terminated_at`); wallet transaction `pending` → `settled` (`settled_at`) \| `failed` (`failed_at`); inbound transactions can be `voided` [09]. [vec: none (prose only: exercised by chapter 09 vectors and the scenario tier)]
- **BE-DM-65** Coupon and applied coupon `active` → `terminated` (`terminated_at`); recurring top-up rule `active` → `terminated`, and counts as active only while its expiration is absent or in the future [07, 09]. [vec: none (prose only: exercised by chapter 07 and 09 vectors)]
- **BE-DM-66** Webhook delivery `pending` → `succeeded` \| `failed` \| `retrying` [12]. [vec: none (prose only: exercised by chapter 12 vectors)]

## 9. Legacy and compatibility notes

- The organization-level `document_numbering` (`per_customer` \| `per_organization`) is legacy: only the billing
  entity's setting drives numbering; an organization created with `per_organization` gets a first billing entity
  with `per_billing_entity`.
- A legacy organization-wide invoice counter exists in the reference's storage (column default 0) but is never
  assigned; a rebuild omits it.
- Billable-metric aggregation code 4 (a retired recurring count) must stay unused when migrating stored data.
- Several stored columns are ignored by the reference (a duplicated-in-advance fee flag that still participates in
  the pay-in-advance unique index, a negative-amount invoice column, two subscription columns): leave them out of a
  new schema but keep the pay-in-advance uniqueness semantics (chapter 05).
- Some uniqueness guards on invoice subscriptions and applied taxes exempt rows created before mid-2023 (legacy data).
- The plan `pricing_type` `product_catalog` and fee type `product` belong to out-of-scope catalog features
  (chapter 14); legacy plans always carry an interval, an amount and a pay-in-advance flag.

## 10. Edge cases (people get these wrong)

| Case | Rule |
|---|---|
| Fee tax ≠ sum of its rounded tax rows (15 cents, 2 × 10 % → rows 2 + 2, fee tax 3) | BE-DM-28 |
| −0.125 EUR rounds to −13 cents; 0.135 EUR to 14 cents (decimal ties, away from zero) | BE-DM-23 |
| HUF has no minor unit; MRO's minor unit is one fifth; OMR is rejected | BE-DM-21, BE-DM-22 |
| A period ending exactly at local midnight counts one more day | BE-DM-16 |
| DST months still count 30/31 days: the day count adds `offset(to) − offset(from)` to the elapsed time (wall-clock duration), not the reverse | BE-DM-15, BE-DM-17 |
| Upgraded-and-terminated periods count one day fewer | BE-DM-18 |
| Termination checks round to whole seconds (x.5 rounds up) | BE-DM-19 |
| Customer zone blank string = not set; customer net payment term 0 = set | BE-DM-10, BE-DM-11 |
| Per-billing-entity invoice numbers show the finalization month in the BILLING ENTITY zone but the counter never resets | BE-DM-38, BE-DM-41 |
| Invoice numbers use the billing-entity prefix, customer slugs the organization prefix | BE-DM-43 |
| Padding never truncates (`1234` stays `1234`) | BE-DM-36 |
| Deleted customers' numbers are never reused; deleted tax codes cannot be reused; other deleted codes can | BE-DM-34, BE-DM-50, BE-DM-51 |
| Two active subscriptions of DIFFERENT customers cannot share an external id; an active and a pending one can | BE-DM-55 |
| Charge-filter values sort as text (`10` before `2`); only Latin-1/Latin Extended-A letters are transliterated, every other non-ASCII character vanishes from the readable part | BE-DM-56, BE-DM-59 |

## 11. Vectors

| File | Ops | Vectors | Rules |
|---|---|---|---|
| `domain.time.jsonl` | `effective_timezone`, `applicable_settings`, `to_local`, `days_between`, `terminated_at_reached` | 41 | BE-DM-10, 11, 14-19 |
| `domain.money.jsonl` | `currency_exponent`, `to_minor_units`, `round`, `fee_taxes` | 34 | BE-DM-21-25, 27-30 |
| `domain.numbering.jsonl` | `document_prefix`, `customer_slug`, `next_sequential_id`, `invoice_number`, `credit_note_number` | 42 | BE-DM-32-45 |
| `domain.catalog.jsonl` | `code_reusable`, `subscription_external_id_valid`, `charge_filter_code` | 33 (one corrected twin) | BE-DM-50-59 |

Run them: `python3 reimplementation-kit/scripts/kitrun.py --impl-cmd "<your adapter>" --areas domain`. Every
`both`/`compat` vector is EXECUTED against the reference (`kitrun` against the oracle on 2026-10-05: 149/149 PASS
with the maintainers' holdout, and 143/143 for the shipped vectors plus the 23 runner self-test vectors of this area). The single corrected vector
(`domain.catalog.code_reusable.tax.001x`, RBD-80) is `ruling: proposed` until the owner rules.

## Provenance (maintainers)

Rule → reference location (lago-api @591ae90), with the spec examples or probes that were re-executed:

| Rules | Reference |
|---|---|
| BE-DM-1, 2 | `$API/app/controllers/api/base_controller.rb:26`; `$API/app/models/event.rb:33` |
| BE-DM-4 | `$API/app/models/fee.rb:12` (deleted parents kept); soft-delete scope e.g. `$API/app/models/plan.rb:67` |
| BE-DM-10, 11 | `$API/app/models/customer.rb:219`, `:225`, `:231`, `:235`, `:239`, `:277`; specs `$API/spec/models/customer_spec.rb:703-830` |
| BE-DM-12 | `$API/app/models/organization.rb:112`, `:271`, `:278`; domain probe (organization reads default billing entity) |
| BE-DM-13 | `$API/app/services/invoices/create_generating_service.rb:34` |
| BE-DM-14 | `$API/app/models/concerns/customer_timezone.rb:6`; spec `$API/spec/models/customer_spec.rb:999` |
| BE-DM-15..18 | `$API/app/services/utils/datetime.rb:55`; `$API/app/models/concerns/billing_period_date_diff.rb:6`; spec `$API/spec/services/utils/datetime_spec.rb:201-257` |
| BE-DM-19 | `$API/app/models/concerns/terminatable.rb:6` |
| BE-DM-20 | `$API/app/services/utils/timezone.rb:16` |
| BE-DM-21, 22 | `$API/app/models/concerns/currencies.rb:6`; money library of the pinned bundle |
| BE-DM-23, 24 | `$API/config/initializers/money.rb:6`; `$API/app/models/fee.rb:43`; `$API/app/services/fees/charge_service.rb:290-293` |
| BE-DM-25 | `$API/app/services/billable_metrics/aggregations/apply_rounding_service.rb:18` |
| BE-DM-27..30 | `$API/app/services/fees/apply_taxes_service.rb:37-53`; `$API/app/models/fee.rb:238`, `:242` |
| BE-DM-32, 33 | `$API/app/models/billing_entity.rb:96`, `:118`, `:163`; `$API/app/models/organization.rb:252`, `:305` |
| BE-DM-34, 35 | `$API/app/models/customer.rb:136`, `:410`; `$API/app/models/concerns/sequenced.rb:24` |
| BE-DM-37..42 | `$API/app/models/invoice.rb:137`, `:599`, `:618`, `:629`, `:692`; spec `$API/spec/models/invoice_spec.rb:176-830` |
| BE-DM-44, 45 | `$API/app/models/credit_note.rb:74`, `:193`; spec `$API/spec/models/credit_note_spec.rb:95-512` |
| BE-DM-46 | `$API/db/structure.sql:2021` |
| BE-DM-48 | `$API/app/services/billing_entities/change_invoice_numbering_service.rb:13` |
| BE-DM-50..54 | `$API/app/models/tax.rb:42`, `$API/app/models/billable_metric.rb:58`, `$API/app/models/coupon.rb:53`, `$API/app/models/add_on.rb:24`, `$API/app/models/plan.rb:152`, `$API/app/models/charge.rb:187`, `$API/app/models/fixed_charge.rb:108`, `$API/app/models/billing_entity.rb:86`, `$API/app/models/customer.rb:162`, `$API/app/models/wallet.rb:123` |
| BE-DM-55 | `$API/app/models/subscription.rb:56`, `:227`; `$API/app/services/subscriptions/create_service.rb:72` |
| BE-DM-56, 57, 59 | `$API/app/models/charge_filter.rb:33`, `:47`; spec `$API/spec/models/charge_filter_spec.rb:460-512`; BE-DM-59 = the default approximation table of the transliterator in the pinned bundle (dumped with the oracle toolchain on 2026-10-02: 195 entries, no locale-specific rules in the application's locales) |
| BE-DM-60..66 | `$API/app/services/subscriptions/create_service.rb:165`, `$API/app/services/subscriptions/activate_service.rb:13`, `$API/app/services/subscriptions/terminate_service.rb:17`, `$API/app/models/invoice.rb:85`, `$API/app/services/invoices/transition_to_final_status_service.rb:14`, `$API/app/models/credit_note.rb:153`, `$API/app/models/wallet_transaction.rb:124`, `$API/app/models/recurring_transaction_rule.rb:56` |

Executions on the pinned toolchain (ruby-4.0.6, 2026-10-02, database `lago_api_test_a2`):

- `oracle.sh run` over the 54 in-scope model and utility spec files (organization, billing entity, customer, billable
  metric and filters, plan, charge, charge filter and values, fixed charge, commitment, add-on, coupon, applied
  coupon, tax, subscription, fee, invoice, invoice subscription, credit note and items, credit, wallet, wallet credit,
  wallet transaction and consumptions, recurring rule, usage threshold and applied, lifetime and daily usage, the
  13 usage-monitoring specs, webhook and endpoint, pricing units, event, the date-diff and terminatable concerns,
  date utilities): `{"example_count":1663,"failure_count":0,…}` (ClickHouse-tagged examples included, run under the
  ClickHouse lock).
- The domain probe spec (12 examples: tax-code reuse, catalog code reuse, customer sequence across deletion,
  subscription external-id per status, column defaults, enum codes, slug vs invoice prefixes, organization zone via
  the default billing entity, fee tax rounding, money minor units, plan code scoping, event customer resolution
  across deletion): 12/12 green; outputs identical to the earlier run except random ids.
- Oracle module `scripts/maintainer/oracle-adapter/ops/domain.rb`; `kitrun --vectors domain.*.jsonl
  selftest/domain.selftest.jsonl` → `SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=171 passed=171`.
  `domain.to_minor_units` takes `amount_cents` from the fee model's money setter and computes the precise companion
  as the product in the pinned runtime; `domain.currency_exponent` reads the pinned money table.
- Re-run of 2026-10-05 (database `lago_api_test_fr2g1`): `kitrun --areas domain --include-holdout` → `SUMMARY kitrun:
  areas=2 pass=2 fail=0 vectors=149 passed=149`; shipped vectors plus `selftest/domain.selftest.jsonl` → 143/143. New
  vector `domain.time.days_between.013` (EXECUTED) pins the offset sign of BE-DM-15 with `days_between.006` (the
  reference subtracts `offset(from) − offset(to)` from the elapsed time, `$API/app/services/utils/datetime.rb:55-68`).
  Oracle probes behind statements without a vector: finalizing with no sequential id yields `…-004-001` (per customer
  and self-billed) and `…-202610-001` (per billing entity), the first value of an empty scope; `domain.to_minor_units`
  converts OMR with exponent 3 (the model setter does not validate the list) and refuses MRO, which is why both are
  outside the op's graded domain; an instant with a 1 µs fraction counts (`2024-01-01T00:00Z` to
  `2024-01-02T00:00:00.000001Z` → 2 days).
- Update triggers: a pin bump (re-run the spec list, the probe and kitrun), a change of the money library or of the
  accepted currency list, any change to numbering services.
