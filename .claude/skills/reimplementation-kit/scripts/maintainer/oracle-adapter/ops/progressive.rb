# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/progressive.rb — oracle handlers for the `progressive` area (billing-engine-spec chapter 10, rules BE-PB-*).
# Uses KitA8 (ops/alerts.rb). Every handler runs inside KitA8.sandbox (always rolled back).
#
#   progressive.check_thresholds  usage thresholds created on the subscription, its plan or the parent plan, a
#                                 LifetimeUsage row, then LifetimeUsages::UsageThresholds::CheckService (which reads
#                                 Subscription#applicable_usage_thresholds)
#   progressive.passed_amount     AppliedUsageThreshold#passed_threshold_amount_cents
#   progressive.lifetime_usage    subscription invoices + fees as records, then LifetimeUsages::CalculateService
#                                 (invoiced usage recomputed; current usage handed in)
#   progressive.to_credit         progressive-billing invoices of the period as records, then
#                                 Subscriptions::ProgressiveBilledAmount and Credits::ProgressiveBillingService on the
#                                 period invoice (the automatic credit-note path included; no premium flag needed)
#
# Stand-ins: the current usage handed to the lifetime-usage calculation is a struct with `amount_cents` (the reference
# passes the customer-usage result there, which exposes the same reader).

module KitA8PB
  module_function

  PERIOD_FROM = Time.utc(2024, 3, 1)
  PERIOD_TO = Time.utc(2024, 3, 31, 23, 59, 59)

  def cents_list(ctx, v, name)
    ctx.bad_input!("#{name} must be an array of integers") unless v.is_a?(Array) && v.all?(Integer)
    v
  end
end

KitOracle.op("progressive.check_thresholds") do |input, ctx|
  fixed = KitA8PB.cents_list(ctx, input.fetch("fixed_cents", []), "fixed_cents")
  recurring = input["recurring_cents"]
  attach = input.fetch("attach", "subscription")
  ctx.bad_input!("attach must be subscription|plan|parent_plan") unless %w[subscription plan parent_plan].include?(attach)

  KitA8.sandbox do
    org = KitA8.org
    cust = KitA8.customer(org)
    parent = (attach == "parent_plan") ? KitA8.plan(org) : nil
    plan = KitA8.plan(org, parent:)
    sub = KitA8.subscription(org, cust, plan,
      progressive_billing_disabled: KitA8.bool(input["progressive_billing_disabled"]))
    owner = {"subscription" => sub, "plan" => plan, "parent_plan" => parent}.fetch(attach)
    fixed.each { |a| owner.usage_thresholds.create!(amount_cents: a, organization: org) }
    owner.usage_thresholds.create!(amount_cents: Integer(recurring), recurring: true, organization: org) if recurring
    KitA8PB.cents_list(ctx, input.fetch("plan_fixed_cents", []), "plan_fixed_cents").each do |a|
      plan.usage_thresholds.create!(amount_cents: a, organization: org)
    end
    sub.reload
    lu = KitA8.fb.create(:lifetime_usage, organization: org, subscription: sub,
      historical_usage_amount_cents: Integer(input.fetch("historical_cents", 0)),
      invoiced_usage_amount_cents: Integer(input.fetch("invoiced_cents", 0)),
      current_usage_amount_cents: Integer(input.fetch("current_cents")))
    res = LifetimeUsages::UsageThresholds::CheckService.call!(lifetime_usage: lu,
      progressive_billed_amount: Integer(input.fetch("progressively_billed_cents", 0)))
    passed = res.passed_thresholds
    {"passed_fixed_cents" => passed.reject(&:recurring).map(&:amount_cents),
     "recurring_passed" => passed.any?(&:recurring)}
  end
end

KitOracle.op("progressive.passed_amount") do |input, ctx|
  threshold = UsageThreshold.new(amount_cents: Integer(input.fetch("amount_cents")),
    recurring: KitA8.bool(input["recurring"]))
  applied = AppliedUsageThreshold.new(usage_threshold: threshold,
    lifetime_usage_amount_cents: Integer(input.fetch("lifetime_usage_cents")))
  {"passed_amount_cents" => applied.passed_threshold_amount_cents}
end

# Invoices: [{status, invoice_type, subscription: self|predecessor|canceled|other_start|other_external_id,
#             fees: [{fee_type: charge|subscription, amount_cents}]}]
KitOracle.op("progressive.lifetime_usage") do |input, ctx|
  KitA8.sandbox do
    org = KitA8.org
    cust = KitA8.customer(org)
    plan = KitA8.plan(org)
    start = Time.utc(2024, 1, 1)
    sub = KitA8.subscription(org, cust, plan, external_id: "kit_sub", subscription_at: start, started_at: Time.utc(2024, 2, 1))
    subs = {"self" => sub}
    make = lambda do |key|
      subs[key] ||= case key
      when "predecessor"
        KitA8.subscription(org, cust, KitA8.plan(org), external_id: "kit_sub", subscription_at: start,
          started_at: start, status: "terminated", terminated_at: Time.utc(2024, 2, 1))
      when "canceled"
        KitA8.subscription(org, cust, KitA8.plan(org), external_id: "kit_sub", subscription_at: start,
          started_at: start, status: "canceled", canceled_at: Time.utc(2024, 1, 2))
      when "other_start"
        KitA8.subscription(org, cust, KitA8.plan(org), external_id: "kit_sub", subscription_at: Time.utc(2023, 1, 1),
          started_at: Time.utc(2023, 1, 1), status: "terminated", terminated_at: Time.utc(2023, 12, 31))
      when "other_external_id"
        KitA8.subscription(org, cust, KitA8.plan(org), external_id: "kit_other")
      else ctx.bad_input!("unknown subscription key #{key}")
      end
    end
    cache = {}
    Array(input["invoices"]).each do |i|
      s = make.call(i.fetch("subscription", "self"))
      inv = KitA8.fb.create(:invoice, organization: org, customer: cust, currency: "EUR",
        status: i.fetch("status", "finalized"), invoice_type: i.fetch("invoice_type", "subscription"))
      KitA8.fb.create(:invoice_subscription, invoice: inv, subscription: s, organization: org)
      Array(i["fees"]).each do |f|
        amount = Integer(f.fetch("amount_cents"))
        if f.fetch("fee_type", "charge") == "charge"
          charge = KitA8.charge_for(org, s.plan, "m_#{s.plan.id[0, 6]}", cache)
          KitA8.fb.create(:charge_fee, invoice: inv, subscription: s, charge:, organization: org,
            amount_cents: amount, precise_amount_cents: amount, taxes_amount_cents: 0, taxes_precise_amount_cents: 0)
        else
          KitA8.fb.create(:fee, invoice: inv, subscription: s, organization: org, fee_type: "subscription",
            amount_cents: amount, precise_amount_cents: amount, taxes_amount_cents: 0, taxes_precise_amount_cents: 0)
        end
      end
    end
    lu = KitA8.fb.create(:lifetime_usage, organization: org, subscription: sub,
      historical_usage_amount_cents: Integer(input.fetch("historical_cents", 0)),
      recalculate_invoiced_usage: true, recalculate_current_usage: true)
    LifetimeUsages::CalculateService.call!(lifetime_usage: lu,
      current_usage: KitA8::Usage.new(Integer(input.fetch("current_cents", 0)), []))
    lu.reload
    {"invoiced_usage_cents" => lu.invoiced_usage_amount_cents, "total_cents" => lu.total_amount_cents}
  end
end

# pb_invoices: [{status, fees: [{charge, amount_cents}], coupons_cents, credited_cents: [{status, amount_cents}],
#                credit_notes: [{credit_status, credit_amount_cents}]}] in issuing order (later = newer)
# fees: period invoice charge fees [{charge, amount_cents}]
KitOracle.op("progressive.to_credit") do |input, ctx|
  KitA8.sandbox do
    org = KitA8.org
    cust = KitA8.customer(org)
    plan = KitA8.plan(org)
    sub = KitA8.subscription(org, cust, plan)
    cache = {}
    charge = ->(code) { KitA8.charge_for(org, plan, code, cache) }
    window = {charges_from_datetime: KitA8PB::PERIOD_FROM, charges_to_datetime: KitA8PB::PERIOD_TO,
              from_datetime: KitA8PB::PERIOD_FROM, to_datetime: KitA8PB::PERIOD_TO,
              timestamp: KitA8PB::PERIOD_FROM}
    pb_invoices = Array(input["pb_invoices"]).each_with_index.map do |p, idx|
      fees_in = Array(p["fees"])
      fees_sum = fees_in.sum { |f| Integer(f.fetch("amount_cents")) }
      inv = KitA8.fb.create(:invoice, organization: org, customer: cust, currency: "EUR",
        invoice_type: :progressive_billing, status: p.fetch("status", "finalized"),
        issuing_date: Date.new(2024, 3, 2 + idx), fees_amount_cents: fees_sum,
        coupons_amount_cents: Integer(p.fetch("coupons_cents", 0)),
        sub_total_excluding_taxes_amount_cents: fees_sum - Integer(p.fetch("coupons_cents", 0)),
        created_at: KitA8::BASE_TIME + (idx * 3600))
      KitA8.fb.create(:invoice_subscription, invoice: inv, subscription: sub, organization: org,
        invoicing_reason: :progressive_billing, **window)
      fees_in.each do |f|
        a = Integer(f.fetch("amount_cents"))
        KitA8.fb.create(:charge_fee, invoice: inv, subscription: sub, charge: charge.call(f.fetch("charge")),
          organization: org, amount_cents: a, precise_amount_cents: a, taxes_amount_cents: 0,
          taxes_precise_amount_cents: 0, taxes_rate: 0)
      end
      Array(p["credited_cents"]).each do |c|
        other = KitA8.fb.create(:invoice, organization: org, customer: cust, currency: "EUR",
          status: c.fetch("status", "finalized"))
        Credit.create!(organization: org, invoice: other, progressive_billing_invoice: inv,
          amount_cents: Integer(c.fetch("amount_cents")), amount_currency: "EUR", before_taxes: true)
      end
      Array(p["credit_notes"]).each do |c|
        a = Integer(c.fetch("credit_amount_cents"))
        KitA8.fb.create(:credit_note, invoice: inv, customer: cust, organization: org,
          credit_status: c.fetch("credit_status", "available"), credit_amount_cents: a, balance_amount_cents: a,
          total_amount_cents: a, taxes_amount_cents: 0)
      end
      inv
    end

    fees_in = Array(input.fetch("fees"))
    total = fees_in.sum { |f| Integer(f.fetch("amount_cents")) }
    inv = KitA8.fb.create(:invoice, organization: org, customer: cust, currency: "EUR", status: :draft,
      invoice_type: :subscription, fees_amount_cents: total, sub_total_excluding_taxes_amount_cents: total,
      progressive_billing_credit_amount_cents: 0)
    KitA8.fb.create(:invoice_subscription, invoice: inv, subscription: sub, organization: org,
      invoicing_reason: :subscription_periodic, **window)
    fee_records = fees_in.map do |f|
      a = Integer(f.fetch("amount_cents"))
      [f.fetch("charge"), KitA8.fb.create(:charge_fee, invoice: inv, subscription: sub,
        charge: charge.call(f.fetch("charge")), organization: org, amount_cents: a, precise_amount_cents: a,
        taxes_amount_cents: 0, taxes_precise_amount_cents: 0, precise_coupons_amount_cents: 0)]
    end

    billed = Subscriptions::ProgressiveBilledAmount.call!(subscription: sub, timestamp: KitA8PB::PERIOD_FROM)
    inv.reload
    res = Credits::ProgressiveBillingService.call!(invoice: inv)
    # input credit notes carry the factory reason; the automatic over-credit note is created with reason "other"
    auto = CreditNote.where(invoice_id: pb_invoices.map(&:id), reason: "other")
    {
      "progressive_billed_cents" => billed.progressive_billed_amount,
      "to_credit_cents" => billed.to_credit_amount,
      "credit_cents" => res.credits.sum(&:amount_cents),
      "credit_note_cents" => auto.sum(&:credit_amount_cents),
      "fees" => fee_records.map { |code, f| {"charge" => code, "precise_coupons_cents" => ctx.dec_out(f.reload.precise_coupons_amount_cents)} }
    }
  end
end
