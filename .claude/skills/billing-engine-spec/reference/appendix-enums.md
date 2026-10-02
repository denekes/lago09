# Appendix: enumerations

> Licence note: this appendix describes observable behaviour of lago-api (AGPL-3.0) at pin `591ae90`. It is a
> behavioural specification, not source code; read `reimplementation-kit/reference/legal-and-provenance.md` before
> using it for a proprietary rebuild.

<!-- evidence-check: off normative spec; evidence = enum dump of the pinned runtime (Provenance) and the probe/spec runs listed there -->

Every enumerated attribute of the in-scope entities: the **wire value** (what the REST API, webhooks and kit vectors
use) and the **stored code** of the reference (an integer for integer-coded enums, the same text for text enums).
A rebuild only needs the wire values; the stored codes matter for data migration from the reference and explain
some quirks (retired codes, two different interval orders). Chapter 01 rule BE-DM-5 states the convention.

| Entity.attribute | Wire values = stored code | Storage | Notes |
|---|---|---|---|
| organization.document_numbering | `per_customer`=0, `per_organization`=1 | integer | legacy; only the billing-entity setting drives numbering (BE-DM-41). An organization created with per_organization gets a first billing entity with per_billing_entity. |
| billing entity.document_numbering | `per_customer`, `per_billing_entity` | text |  |
| billing entity.subscription_invoice_issuing_date_anchor | `current_period_end`, `next_period_start` | text |  |
| billing entity.subscription_invoice_issuing_date_adjustment | `keep_anchor`, `align_with_finalization_date` | text |  |
| customer.finalize_zero_amount_invoice | `inherit`=0, `skip`=1, `finalize`=2 | integer | inherit = use the billing entity's boolean setting |
| customer.customer_type | `company`, `individual` | text |  |
| customer.account_type | `customer`, `partner` | text |  |
| customer.subscription_invoice_issuing_date_anchor | `current_period_end`, `next_period_start` | text |  |
| customer.subscription_invoice_issuing_date_adjustment | `keep_anchor`, `align_with_finalization_date` | text |  |
| billable metric.aggregation_type | `count_agg`=0, `sum_agg`=1, `max_agg`=2, `unique_count_agg`=3, `weighted_sum_agg`=5, `latest_agg`=6, `custom_agg`=7 | integer | code 4 is retired (never reuse it); unknown values are rejected |
| billable metric.rounding_function | `round`, `ceil`, `floor` | text |  |
| billable metric.weighted_interval | `seconds` | text |  |
| plan.pricing_type | `legacy`, `product_catalog` | text | product_catalog plans are out of scope; legacy plans carry interval, amount and pay_in_advance |
| plan.interval | `weekly`=0, `monthly`=1, `yearly`=2, `quarterly`=3, `semiannual`=4 | integer | NOT the same order as the top-up rule interval below |
| charge.charge_model | `standard`=0, `graduated`=1, `package`=2, `percentage`=3, `volume`=4, `graduated_percentage`=5, `custom`=6, `dynamic`=7 | integer |  |
| charge.regroup_paid_fees | `invoice`=0 | integer | null = no regrouping |
| fixed charge.charge_model | `standard`, `graduated`, `volume` | text |  |
| commitment.commitment_type | `minimum_commitment`=0 | integer |  |
| coupon.status | `active`=0, `terminated`=1 | integer |  |
| coupon.expiration | `no_expiration`=0, `time_limit`=1 | integer |  |
| coupon.coupon_type | `fixed_amount`=0, `percentage`=1 | integer |  |
| coupon.frequency | `once`=0, `recurring`=1, `forever`=2 | integer |  |
| applied coupon.status | `active`=0, `terminated`=1 | integer |  |
| applied coupon.frequency | `once`=0, `recurring`=1, `forever`=2 | integer |  |
| subscription.status | `pending`=0, `active`=1, `terminated`=2, `canceled`=3, `incomplete`=4 | integer |  |
| subscription.billing_time | `calendar`=0, `anniversary`=1 | integer |  |
| subscription.on_termination_credit_note | `credit`, `skip`, `refund`, `offset` | text |  |
| subscription.on_termination_invoice | `generate`, `skip` | text |  |
| subscription.cancellation_reason | `payment_failed`, `timeout`, `manual` | text |  |
| subscription activation rule.status | `inactive`, `pending`, `satisfied`, `declined`, `failed`, `expired`, `not_applicable` | text |  |
| subscription activation rule.type | `payment` | text |  |
| fee.fee_type | `charge`=0, `add_on`=1, `subscription`=2, `credit`=3, `commitment`=4, `fixed_charge`=5, `product`=6 | integer | product belongs to the out-of-scope product-catalog features |
| fee.payment_status | `pending`=0, `succeeded`=1, `failed`=2, `refunded`=3 | integer |  |
| invoice.invoice_type | `subscription`=0, `add_on`=1, `credit`=2, `one_off`=3, `advance_charges`=4, `progressive_billing`=5 | integer |  |
| invoice.payment_status | `pending`=0, `succeeded`=1, `failed`=2 | integer |  |
| invoice.status | `draft`=0, `finalized`=1, `voided`=2, `generating`=3, `failed`=4, `open`=5, `closed`=6, `pending`=7, `deleted`=8 | integer | visible: draft, finalized, voided, failed, pending; invisible: generating, open, closed, deleted. Codes are not in lifecycle order; a stored row without a status is finalized (column default 1). |
| invoice.tax_status | `pending`, `succeeded`, `failed` | text |  |
| invoice subscription.invoicing_reason | `subscription_starting`, `subscription_periodic`, `subscription_terminating`, `in_advance_charge`, `in_advance_charge_periodic`, `progressive_billing` | text |  |
| credit note.credit_status | `available`=0, `consumed`=1, `voided`=2 | integer |  |
| credit note.refund_status | `pending`=0, `succeeded`=1, `failed`=2 | integer |  |
| credit note.reason | `duplicated_charge`=0, `product_unsatisfactory`=1, `order_change`=2, `order_cancellation`=3, `fraudulent_charge`=4, `other`=5 | integer |  |
| credit note.status | `draft`=0, `finalized`=1, `deleted`=2 | integer | a stored row without a status is finalized (column default) |
| wallet.status | `active`=0, `terminated`=1 | integer |  |
| wallet transaction.status | `pending`=0, `settled`=1, `failed`=2 | integer |  |
| wallet transaction.transaction_status | `purchased`=0, `granted`=1, `voided`=2, `invoiced`=3 | integer |  |
| wallet transaction.transaction_type | `inbound`=0, `outbound`=1 | integer |  |
| wallet transaction.source | `manual`=0, `interval`=1, `threshold`=2 | integer |  |
| recurring transaction rule (wallet top-up rule).interval | `weekly`=0, `monthly`=1, `quarterly`=2, `yearly`=3, `semiannual`=4 | integer | quarterly=2, yearly=3: differs from the plan interval codes |
| recurring transaction rule (wallet top-up rule).method | `fixed`=0, `target`=1 | integer |  |
| recurring transaction rule (wallet top-up rule).trigger | `interval`=0, `threshold`=1 | integer |  |
| recurring transaction rule (wallet top-up rule).status | `active`=0, `terminated`=1 | integer |  |
| usage alert.direction | `increasing`, `decreasing` | text |  |
| triggered alert.kind | `triggered`, `resolved`, `seeded` | text |  |
| webhook endpoint.signature_algo | `jwt`=0, `hmac`=1 | integer | default jwt |
| webhook delivery.status | `pending`=0, `succeeded`=1, `failed`=2, `retrying`=3 | integer |  |
| usage alert.alert_type | `current_usage_amount`, `billable_metric_current_usage_amount`, `billable_metric_current_usage_units`, `lifetime_usage_amount`, `billable_metric_lifetime_usage_units`, `wallet_balance_amount`, `wallet_credits_balance`, `wallet_ongoing_balance_amount`, `wallet_credits_ongoing_balance` | text | the three billable_metric_* types require a billable metric; the four wallet_* types target a wallet instead of a subscription |

## Provenance (maintainers)

- Dumped on 2026-10-02 from the pinned runtime (oracle toolchain, ruby-4.0.6): the declared enums of the in-scope
  models at `591ae90`, plus the alert type map `$API/app/models/usage_monitoring/alert.rb:10-20` @591ae90. The integer
  codes were also printed by the domain probe spec re-run on 2026-10-02 (12/12 examples green).
- Update trigger: a pin bump that adds or renumbers an enum value; re-dump and diff.
