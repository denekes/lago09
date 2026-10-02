# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/invoice.rb — oracle handlers for the `invoice` area (billing-engine-spec chapter 07, rules BE-IV-*), plus the
# shared invoice builder used by ops/credit_note.rb (KitOracleInvoicing, loaded lazily at call time).
#
# Every handler drives the reference code path at the pin inside ctx.rollback (FactoryBot records, nothing persists):
#   invoice.totals               the subscription-invoice totals sequence of Invoices::CalculateFeesService (fees sum,
#                                Credits::ProgressiveBillingService, Credits::AppliedCouponsService,
#                                Invoices::ComputeTaxesAndTotalsService, Credits::CreditNoteService,
#                                Credits::AppliedPrepaidCreditsService, payment status) over fees taken from the input,
#                                and the one-off / pay-in-advance-charge / progressive-billing / credit variants as their
#                                invoice services order the same step services
#   invoice.apply_taxes          Fees::ApplyTaxesService per fee, then Invoices::ApplyTaxesService
#   invoice.fee_tax_selection    Fees::ApplyTaxesService#applicable_taxes over real charge/plan/customer/... records
#   invoice.coupon_amount        AppliedCoupons::AmountService (+ the Credit amount cast)
#   invoice.coupon_order         the applied-coupon ordering query of Credits::AppliedCouponsService
#   invoice.coupon_distribution  Credits::AppliedCouponService under the customer coupon lock
#   invoice.final_status         grace-period draft rule of Invoices::SubscriptionService + Invoices::TransitionToFinalStatusService
#   invoice.issuing_date         Invoices::CreateGeneratingService (issuing, expected finalization, payment due dates)
#   invoice.payment_due_date     Invoices::RefreshDraftAndFinalizeService#issuing_date / #payment_due_date (finalize time)
#   invoice.available_to_credit  Invoice#available_to_credit_amount_cents, #creditable/#refundable/#offsettable,
#                                #total_due_amount_cents, #fee_total_amount_cents, #voidable?
#   invoice.void                 Invoices::VoidService (with or without credit-note generation)
#   invoice.commitment_true_up   Invoices::SubscriptionService per billing run (the commitment fee comes from
#                                Fees::Commitments::Minimum::CreateService inside Invoices::CalculateFeesService); no
#                                stand-in: the subscription, plan, commitment, charge and events are real records
#   invoice.coupon_create        Coupons::CreateService in the API context (codes, as the coupons endpoint passes them)
#   invoice.coupon_apply         AppliedCoupons::CreateService over real coupon, target, charge and applied-coupon records
#
# Stand-ins (stated so the evidence stays honest):
#   - fee taxes are attached through the explicit tax-code path of Fees::ApplyTaxesService (tax selection precedence is
#     exercised separately by invoice.fee_tax_selection); the explicit call runs at the point where the invoice
#     pipeline computes fee taxes (after coupons), so amounts are those of the real pipeline;
#   - the orchestration order of the invoice services (which step runs for which invoice type/context) is mirrored here;
#     every step itself is the reference service.

module KitOracleInvoicing
  module_function

  BASE_TIME = Time.utc(2024, 3, 1, 10, 0, 0)

  def fb
    FactoryBot
  end

  def dec(ctx, v, default = nil)
    return default if v.nil?

    ctx.dec(v)
  end

  # Organization + customer with optional settings. Returns [org, customer].
  def customer(ctx, input)
    org = fb.create(:organization, webhook_url: nil)
    be = org.default_billing_entity
    be_attrs = (input["billing_entity"] || {}).slice(
      "timezone", "invoice_grace_period", "net_payment_term", "finalize_zero_amount_invoice",
      "subscription_invoice_issuing_date_anchor", "subscription_invoice_issuing_date_adjustment"
    )
    be.update!(be_attrs) if be_attrs.any?
    c_in = input["customer"] || {}
    attrs = {organization: org, billing_entity: be, currency: input.fetch("currency", "EUR")}
    %w[timezone invoice_grace_period net_payment_term finalize_zero_amount_invoice
      subscription_invoice_issuing_date_anchor subscription_invoice_issuing_date_adjustment].each do |k|
      attrs[k.to_sym] = c_in[k] if c_in.key?(k)
    end
    cust = fb.create(:customer, **attrs)
    [org, cust]
  end

  # Builder state shared by one call.
  class Book
    attr_reader :ctx, :org, :customer, :plans, :subs, :bms, :charges, :add_ons, :taxes, :fee_ids, :seq

    def initialize(ctx, org, customer, config = {})
      @ctx = ctx
      @org = org
      @customer = customer
      @config = config || {}
      @plans = {}
      @subs = {}
      @bms = {}
      @charges = {}
      @add_ons = {}
      @taxes = {}
      @fee_ids = {}
      @seq = 0
    end

    def fb
      FactoryBot
    end

    def next_time
      @seq += 1
      BASE_TIME + @seq
    end

    def tax(code, rate)
      t = @taxes[code]
      if t.nil?
        t = fb.create(:tax, organization: org, code:, name: code, rate: Float(rate))
        @taxes[code] = t
      elsif rate && t.rate != Float(rate)
        ctx.bad_input!("tax #{code} given with two rates")
      end
      t
    end

    def plan(code)
      @plans[code] ||= begin
        pc = (@config["plans"] || {})[code] || {}
        fb.create(:plan, organization: org, code:, amount_cents: Integer(pc.fetch("amount_cents", 0)),
          amount_currency: customer.currency || "EUR", interval: pc.fetch("interval", "monthly"),
          pay_in_advance: pc.fetch("pay_in_advance", false),
          trial_period: pc["trial_period_days"] && ctx.dec(pc["trial_period_days"]))
      end
    end

    def subscription(plan_code)
      @subs[plan_code] ||= begin
        sc = (@config["subscriptions"] || {})[plan_code] || {}
        attrs = {organization: org, customer:, plan: plan(plan_code), external_id: "sub_#{plan_code}",
                 billing_time: sc.fetch("billing_time", "calendar"), status: sc.fetch("status", "active")}
        %w[started_at subscription_at terminated_at].each do |k|
          attrs[k.to_sym] = ctx.instant(sc[k]) if sc[k]
        end
        attrs[:activated_at] = attrs[:started_at] if attrs[:started_at]
        attrs[:subscription_at] ||= attrs[:started_at] if attrs[:started_at]
        fb.create(:subscription, **attrs)
      end
    end

    def bm(code)
      @bms[code] ||= fb.create(:billable_metric, organization: org, code:)
    end

    def charge(plan_code, bm_code)
      @charges[[plan_code, bm_code]] ||= fb.create(:standard_charge, organization: org, plan: plan(plan_code),
        billable_metric: bm(bm_code), properties: {"amount" => "1"})
    end

    def add_on(code)
      @add_ons[code] ||= fb.create(:add_on, organization: org, code:, amount_cents: 100,
        amount_currency: customer.currency || "EUR")
    end

    # One fee from the kit fee object. Taxes are NOT applied here (pipeline order decides).
    def fee(invoice, f)
      type = f.fetch("fee_type", "charge")
      amount = Integer(f.fetch("amount_cents"))
      precise = f.key?("precise_amount_cents") ? ctx.dec(f["precise_amount_cents"]) : BigDecimal(amount)
      plan_code = f["plan_code"] || "plan"
      common = {
        organization: org, billing_entity: customer.billing_entity, invoice:, amount_cents: amount,
        precise_amount_cents: precise, amount_currency: invoice&.currency || customer.currency || "EUR",
        taxes_amount_cents: 0, taxes_precise_amount_cents: 0, taxes_rate: 0,
        precise_coupons_amount_cents: ctx.dec(f.fetch("precise_coupons_amount_cents", 0)),
        units: 1, total_aggregated_units: 1, created_at: next_time
      }
      fee = case type
      when "subscription"
        sub = subscription(plan_code)
        plan_amount = f["plan_amount_cents"] || (sub.plan.amount_cents.to_i.positive? ? sub.plan.amount_cents : amount)
        fb.create(:fee, **common, fee_type: "subscription", subscription: sub, invoiceable_type: "Subscription",
          invoiceable_id: sub.id, amount_details: {"plan_amount_cents" => Integer(plan_amount)})
      when "charge"
        sub = subscription(plan_code)
        ch = charge(plan_code, f["billable_metric_code"] || "bm_#{@fee_ids.size + 1}")
        fb.create(:fee, **common, fee_type: "charge", charge: ch, subscription: sub, invoiceable_type: "Charge",
          invoiceable_id: ch.id, properties: {})
      when "add_on"
        ao = add_on(f["add_on_code"] || "add_on_#{@fee_ids.size + 1}")
        fb.create(:fee, **common, fee_type: "add_on", add_on: ao, subscription: nil, invoiceable_type: "AddOn",
          invoiceable_id: ao.id)
      else
        ctx.bad_input!("fee_type #{type} is not supported by the oracle (subscription, charge, add_on)")
      end
      @fee_ids[fee.id] = f.fetch("id")
      fee
    end

    def fee_by_kit_id(id)
      real = @fee_ids.key(id)
      ctx.bad_input!("unknown fee id #{id}") unless real
      Fee.find(real)
    end

    # Applied coupon from the kit object (creation order = list order).
    def applied_coupon(ac)
      type = ac.fetch("coupon_type")
      freq = ac.fetch("frequency", "once")
      plan_codes = Array(ac["limited_plan_codes"])
      bm_codes = Array(ac["limited_billable_metric_codes"])
      cur = ac["amount_currency"] || customer.currency || "EUR"
      coupon = fb.create(:coupon, organization: org, code: "coupon_#{ac.fetch("id")}", coupon_type: type,
        amount_cents: (type == "fixed_amount") ? Integer(ac.fetch("amount_cents")) : nil,
        amount_currency: (type == "fixed_amount") ? cur : nil,
        percentage_rate: (type == "percentage") ? ctx.dec(ac.fetch("coupon_percentage_rate", ac.fetch("percentage_rate"))) : nil,
        frequency: freq, frequency_duration: ac["frequency_duration"],
        limited_plans: plan_codes.any?, limited_billable_metrics: bm_codes.any?,
        status: ac.fetch("coupon_status", "active"), created_at: next_time)
      plan_codes.each { |pc| fb.create(:coupon_plan, coupon:, plan: plan(pc), organization: org) }
      bm_codes.each { |bc| fb.create(:coupon_billable_metric, coupon:, billable_metric: bm(bc), organization: org) }
      applied = fb.create(:applied_coupon, organization: org, customer:, coupon:,
        amount_cents: (type == "fixed_amount") ? Integer(ac.fetch("amount_cents")) : nil,
        amount_currency: (type == "fixed_amount") ? cur : nil,
        percentage_rate: (type == "percentage") ? ctx.dec(ac.fetch("percentage_rate")) : nil,
        frequency: freq, frequency_duration: ac["frequency_duration"],
        frequency_duration_remaining: ac["frequency_duration_remaining"] || ac["frequency_duration"],
        status: ac.fetch("status", "active"), created_at: next_time)
      used = Integer(ac.fetch("used_amount_cents", 0))
      if used.positive?
        past = fb.create(:invoice, organization: org, customer:, billing_entity: customer.billing_entity,
          currency: cur, status: :finalized, created_at: next_time)
        fb.create(:credit, organization: org, invoice: past, applied_coupon: applied, amount_cents: used,
          amount_currency: cur)
      end
      applied
    end

    # Finalized credit note of an earlier invoice with an available balance.
    def available_credit_note(cn)
      cur = cn["currency"] || customer.currency || "EUR"
      past = fb.create(:invoice, organization: org, customer:, billing_entity: customer.billing_entity,
        currency: cur, status: :finalized, created_at: next_time)
      bal = Integer(cn.fetch("balance_amount_cents"))
      fb.create(:credit_note, organization: org, customer:, invoice: past, status: :finalized,
        credit_status: :available, credit_amount_cents: bal, credit_amount_currency: cur,
        balance_amount_cents: bal, balance_amount_currency: cur, total_amount_cents: bal,
        total_amount_currency: cur, taxes_amount_cents: 0, created_at: next_time)
    end

    def wallet(w)
      cur = w["currency"] || customer.currency || "EUR"
      rate = ctx.dec(w.fetch("rate_amount", "1"))
      bal = Integer(w.fetch("balance_cents"))
      credits = BigDecimal(bal) / Money::Currency.new(cur).subunit_to_unit / rate
      fb.create(:wallet, organization: org, customer:, currency: cur, balance_currency: cur, rate_amount: rate,
        balance_cents: bal, credits_balance: credits, ongoing_balance_cents: bal, credits_ongoing_balance: credits,
        priority: w.fetch("priority", 50), code: "wallet_#{w.fetch("id")}", name: w.fetch("id"),
        traceable: false, created_at: next_time)
    end

    def apply_explicit_taxes(fees_in)
      fees_in.each do |f|
        next if Array(f["taxes"]).empty?

        codes = f["taxes"].map { |t| tax(t.fetch("code"), t.fetch("rate")).code }
        fee = fee_by_kit_id(f.fetch("id"))
        Fees::ApplyTaxesService.call!(fee:, tax_codes: codes)
        fee.save!
      end
    end

    def tax_list_from(fees_in)
      fees_in.each { |f| Array(f["taxes"]).each { |t| tax(t.fetch("code"), t.fetch("rate")) } }
    end
  end

  # Runs the totals pipeline for one invoice. Returns [book, invoice, extras].
  def run_totals(ctx, input, status_after: nil)
    org, cust = customer(ctx, input)
    book = Book.new(ctx, org, cust, input)
    currency = input.fetch("currency", "EUR")
    type = input.fetch("invoice_type", "subscription")
    context = input.fetch("context", "finalize")
    ctx.bad_input!("context must be draft|finalize") unless %w[draft finalize].include?(context)
    reason = input["invoicing_reason"] || "subscription_periodic"
    fees_in = input.fetch("fees")
    book.tax_list_from(fees_in)

    invoice = fb.create(:invoice, organization: org, customer: cust, billing_entity: cust.billing_entity,
      currency:, invoice_type: (type == "pay_in_advance_charge") ? "subscription" : type,
      status: :generating, fees_amount_cents: 0, coupons_amount_cents: 0, taxes_amount_cents: 0,
      sub_total_excluding_taxes_amount_cents: 0, sub_total_including_taxes_amount_cents: 0,
      total_amount_cents: 0, credit_notes_amount_cents: 0, prepaid_credit_amount_cents: 0,
      progressive_billing_credit_amount_cents: 0, version_number: input.fetch("version_number", 4),
      created_at: BASE_TIME + 3600)
    fees_in.each { |f| book.fee(invoice, f) }
    invoice.reload

    applied = Array(input["applied_coupons"]).map { |ac| [ac.fetch("id"), book.applied_coupon(ac)] }
    cns = Array(input["credit_notes"]).map { |cn| [cn.fetch("id"), book.available_credit_note(cn)] }
    wallets = Array(input["wallets"]).map { |w| [w.fetch("id"), book.wallet(w)] }
    pb = input["progressive_billing"]
    setup_progressive(ctx, book, invoice, pb) if pb

    finalizing = context == "finalize"
    invoice.fees_amount_cents = invoice.fees.sum(:amount_cents)
    invoice.sub_total_excluding_taxes_amount_cents = invoice.fees.sum(:amount_cents) - invoice.coupons_amount_cents

    case type
    when "subscription"
      Credits::ProgressiveBillingService.call(invoice:) if pb
      Credits::AppliedCouponsService.call(invoice:) if finalizing && invoice.fees_amount_cents.positive?
    when "pay_in_advance_charge"
      Credits::AppliedCouponsService.call(invoice:) if invoice.fees_amount_cents.positive?
    when "progressive_billing"
      Credits::ProgressiveBillingService.call(invoice:) if pb
      Credits::AppliedCouponsService.call(invoice:)
    when "one_off"
      nil
    else
      ctx.bad_input!("invoice_type #{type} not supported")
    end

    book.apply_explicit_taxes(fees_in)
    invoice.fees.reload
    totals = Invoices::ComputeTaxesAndTotalsService.call(invoice:, finalizing:)
    totals.raise_if_error!

    if finalizing && %w[subscription pay_in_advance_charge progressive_billing].include?(type)
      credit_result = Credits::CreditNoteService.new(invoice:).call
      credit_result.raise_if_error!
      invoice.total_amount_cents -= credit_result.credits.sum(&:amount_cents) if credit_result.credits
      if invoice.total_amount_cents&.positive?
        prepaid = Credits::AppliedPrepaidCreditsService.call!(invoice:)
        invoice.total_amount_cents -= prepaid.prepaid_credit_amount_cents
      end
    end
    invoice.payment_status = invoice.total_amount_cents.positive? ? :pending : :succeeded
    invoice.save!
    invoice.reload
    [book, invoice, {applied:, cns:, wallets:}]
  end

  # Progressive billing: a finalized progressive-billing invoice of the same subscription covering the current
  # charges window, with charge fees of the same charges as the referenced current fees.
  def setup_progressive(ctx, book, invoice, pb)
    plan_code = pb.fetch("plan_code", "plan")
    sub = book.subscription(plan_code)
    from = BASE_TIME - 86_400 * 10
    to = BASE_TIME + 86_400 * 20
    ts = BASE_TIME
    fb.create(:invoice_subscription, organization: book.org, invoice:, subscription: sub, timestamp: ts,
      from_datetime: from, to_datetime: to, charges_from_datetime: ts, charges_to_datetime: to,
      invoicing_reason: "subscription_periodic")
    pbi = fb.create(:invoice, organization: book.org, customer: book.customer, billing_entity: book.customer.billing_entity,
      currency: invoice.currency, invoice_type: :progressive_billing, status: :finalized,
      fees_amount_cents: 0, coupons_amount_cents: Integer(pb.fetch("coupons_amount_cents", 0)),
      issuing_date: (ts - 86_400).to_date, created_at: BASE_TIME - 3600)
    fb.create(:invoice_subscription, organization: book.org, invoice: pbi, subscription: sub, timestamp: ts - 86_400,
      from_datetime: from, to_datetime: to, charges_from_datetime: from, charges_to_datetime: to,
      invoicing_reason: "progressive_billing")
    total = 0
    Array(pb.fetch("fees")).each do |pf|
      cur_fee = book.fee_by_kit_id(pf.fetch("same_charge_as"))
      amt = Integer(pf.fetch("amount_cents"))
      total += amt
      fb.create(:fee, organization: book.org, billing_entity: book.customer.billing_entity, invoice: pbi,
        fee_type: "charge", charge: cur_fee.charge, subscription: sub, invoiceable_type: "Charge",
        invoiceable_id: cur_fee.charge_id, amount_cents: amt, precise_amount_cents: amt, amount_currency: invoice.currency,
        taxes_amount_cents: 0, taxes_precise_amount_cents: 0, precise_coupons_amount_cents: 0, units: 1, total_aggregated_units: 1, properties: {})
    end
    pbi.update!(fees_amount_cents: total, sub_total_excluding_taxes_amount_cents: total, total_amount_cents: total)
  end

  def fee_out(book, fee)
    {
      "id" => book.fee_ids[fee.id],
      "precise_coupons_amount_cents" => fee.precise_coupons_amount_cents,
      "taxes_amount_cents" => fee.taxes_amount_cents,
      "taxes_precise_amount_cents" => fee.taxes_precise_amount_cents,
      "taxes_rate" => fee.taxes_rate,
      "precise_credit_notes_amount_cents" => fee.precise_credit_notes_amount_cents,
      "applied_taxes" => fee.applied_taxes.sort_by(&:tax_code).map do |at|
        {"code" => at.tax_code, "amount_cents" => at.amount_cents, "precise_amount_cents" => at.precise_amount_cents}
      end
    }
  end

  def invoice_out(invoice)
    {
      "fees_amount_cents" => invoice.fees_amount_cents,
      "coupons_amount_cents" => invoice.coupons_amount_cents,
      "progressive_billing_credit_amount_cents" => invoice.progressive_billing_credit_amount_cents,
      "sub_total_excluding_taxes_amount_cents" => invoice.sub_total_excluding_taxes_amount_cents,
      "taxes_amount_cents" => invoice.taxes_amount_cents,
      "taxes_rate" => invoice.taxes_rate,
      "sub_total_including_taxes_amount_cents" => invoice.sub_total_including_taxes_amount_cents,
      "credit_notes_amount_cents" => invoice.credit_notes_amount_cents,
      "prepaid_credit_amount_cents" => invoice.prepaid_credit_amount_cents,
      "total_amount_cents" => invoice.total_amount_cents,
      "payment_status" => invoice.payment_status
    }
  end

  def applied_taxes_out(invoice)
    invoice.applied_taxes.sort_by(&:tax_code).map do |at|
      {"code" => at.tax_code, "tax_rate" => at.tax_rate, "fees_amount_cents" => at.fees_amount_cents,
       "amount_cents" => at.amount_cents}
    end
  end
end

# --- totals ------------------------------------------------------------------------------------------------------

KitOracle.op("invoice.totals") do |input, ctx|
  ctx.rollback do
    begin # not under a frozen clock: the credits created by the pipeline are listed in creation order
      book, invoice, ex = KitOracleInvoicing.run_totals(ctx, input)
      order = input.fetch("fees").map { |f| f.fetch("id") }
      fees = invoice.fees.sort_by { |f| order.index(book.fee_ids[f.id]) }
      credits = invoice.credits.order(:created_at).map do |c|
        if c.applied_coupon_id
          {"kind" => "coupon", "id" => ex[:applied].find { |_, a| a.id == c.applied_coupon_id }&.first, "amount_cents" => c.amount_cents}
        elsif c.credit_note_id
          {"kind" => "credit_note", "id" => ex[:cns].find { |_, n| n.id == c.credit_note_id }&.first, "amount_cents" => c.amount_cents}
        else
          {"kind" => "progressive_billing", "amount_cents" => c.amount_cents}
        end
      end
      out = {
        "fees" => fees.map { |f| KitOracleInvoicing.fee_out(book, f) },
        "invoice" => KitOracleInvoicing.invoice_out(invoice),
        "applied_taxes" => KitOracleInvoicing.applied_taxes_out(invoice),
        "credits" => credits
      }
      if ex[:applied].any?
        out["applied_coupons_after"] = ex[:applied].map do |id, a|
          a.reload
          {"id" => id, "status" => a.status, "frequency_duration_remaining" => a.frequency_duration_remaining}
        end
      end
      if ex[:cns].any?
        out["credit_notes_after"] = ex[:cns].map do |id, n|
          n.reload
          {"id" => id, "balance_amount_cents" => n.balance_amount_cents, "credit_status" => n.credit_status}
        end
      end
      if ex[:wallets].any?
        out["wallet_transactions"] = ex[:wallets].filter_map do |id, w|
          wt = WalletTransaction.where(wallet_id: w.id, invoice_id: invoice.id).first
          wt && {"wallet" => id, "amount_cents" => Integer(wt.amount_cents)}
        end
      end
      out
    end
  end
end

# --- taxes -------------------------------------------------------------------------------------------------------

KitOracle.op("invoice.apply_taxes") do |input, ctx|
  ctx.rollback do
    org, cust = KitOracleInvoicing.customer(ctx, input)
    book = KitOracleInvoicing::Book.new(ctx, org, cust)
    fees_in = input.fetch("fees")
    book.tax_list_from(fees_in)
    invoice = FactoryBot.create(:invoice, organization: org, customer: cust, billing_entity: cust.billing_entity,
      currency: input.fetch("currency", "EUR"), status: :generating)
    fees_in.each { |f| book.fee(invoice, f.merge("fee_type" => f.fetch("fee_type", "charge"))) }
    book.apply_explicit_taxes(fees_in)
    invoice.reload
    invoice.fees_amount_cents = invoice.fees.sum(&:amount_cents)
    sub_total = if input.key?("sub_total_excluding_taxes_amount_cents")
      Integer(input["sub_total_excluding_taxes_amount_cents"])
    else
      invoice.fees_amount_cents
    end
    invoice.sub_total_excluding_taxes_amount_cents = sub_total
    Invoices::ApplyTaxesService.call!(invoice:)
    order = fees_in.map { |f| f.fetch("id") }
    {
      "fees" => invoice.fees.sort_by { |f| order.index(book.fee_ids[f.id]) }.map { |f| KitOracleInvoicing.fee_out(book, f) },
      "applied_taxes" => KitOracleInvoicing.applied_taxes_out(invoice),
      "taxes_amount_cents" => invoice.taxes_amount_cents,
      "taxes_rate" => invoice.taxes_rate
    }
  end
end

KitOracle.op("invoice.fee_tax_selection") do |input, ctx|
  ctx.rollback do
    org, cust = KitOracleInvoicing.customer(ctx, input)
    book = KitOracleInvoicing::Book.new(ctx, org, cust)
    mk = ->(key) { Array(input[key]).map { |code| book.tax(code, input.fetch("rates", {}).fetch(code, "10")) } }
    explicit = input["explicit_tax_codes"]
    Array(explicit).each { |code| book.tax(code, input.fetch("rates", {}).fetch(code, "10")) }
    plan = book.plan("plan")
    mk.call("plan_taxes").each { |t| FactoryBot.create(:plan_applied_tax, plan:, tax: t, organization: org) }
    mk.call("customer_taxes").each { |t| FactoryBot.create(:customer_applied_tax, customer: cust, tax: t, organization: org) }
    mk.call("billing_entity_taxes").each do |t|
      FactoryBot.create(:billing_entity_applied_tax, billing_entity: cust.billing_entity, tax: t, organization: org)
    end
    sub = book.subscription("plan")
    type = input.fetch("fee_type")
    invoice = FactoryBot.create(:invoice, organization: org, customer: cust, billing_entity: cust.billing_entity,
      currency: cust.currency || "EUR", status: :generating)
    common = {organization: org, billing_entity: cust.billing_entity, invoice:, amount_cents: 1000,
              precise_amount_cents: 1000, amount_currency: "EUR", taxes_amount_cents: 0, taxes_precise_amount_cents: 0,
              precise_coupons_amount_cents: 0, units: 1, total_aggregated_units: 1}
    fee = case type
    when "subscription"
      FactoryBot.create(:fee, **common, fee_type: "subscription", subscription: sub, invoiceable_type: "Subscription", invoiceable_id: sub.id)
    when "charge"
      ch = book.charge("plan", "bm")
      mk.call("charge_taxes").each { |t| FactoryBot.create(:charge_applied_tax, charge: ch, tax: t, organization: org) }
      FactoryBot.create(:fee, **common, fee_type: "charge", charge: ch, subscription: sub, invoiceable_type: "Charge", invoiceable_id: ch.id, properties: {})
    when "add_on"
      ao = book.add_on("ao")
      mk.call("add_on_taxes").each { |t| FactoryBot.create(:add_on_applied_tax, add_on: ao, tax: t, organization: org) }
      FactoryBot.create(:fee, **common, fee_type: "add_on", add_on: ao, subscription: nil, invoiceable_type: "AddOn", invoiceable_id: ao.id)
    when "fixed_charge"
      ao = book.add_on("ao")
      fc = FactoryBot.create(:fixed_charge, organization: org, plan:, add_on: ao)
      mk.call("fixed_charge_taxes").each { |t| FactoryBot.create(:fixed_charge_applied_tax, fixed_charge: fc, tax: t, organization: org) }
      FactoryBot.create(:fee, **common, fee_type: "fixed_charge", fixed_charge: fc, subscription: sub, invoiceable_type: "FixedCharge", invoiceable_id: fc.id)
    when "commitment"
      cm = FactoryBot.create(:commitment, organization: org, plan:)
      mk.call("commitment_taxes").each { |t| FactoryBot.create(:commitment_applied_tax, commitment: cm, tax: t, organization: org) }
      FactoryBot.create(:fee, **common, fee_type: "commitment", subscription: sub, invoiceable_type: "Commitment", invoiceable_id: cm.id)
    else
      ctx.bad_input!("fee_type #{type} not supported")
    end
    res = Fees::ApplyTaxesService.call!(fee:, tax_codes: explicit)
    {"taxes" => res.applied_taxes.map(&:tax_code)}
  end
end

# --- coupons -----------------------------------------------------------------------------------------------------

KitOracle.op("invoice.coupon_amount") do |input, ctx|
  ctx.rollback do
    org, cust = KitOracleInvoicing.customer(ctx, input)
    book = KitOracleInvoicing::Book.new(ctx, org, cust)
    ac = input.fetch("applied_coupon").merge("id" => "c1")
    applied = book.applied_coupon(ac)
    base_raw = input.fetch("base_amount_cents")
    base = base_raw.is_a?(String) ? ctx.dec(base_raw) : Integer(base_raw)
    amount = AppliedCoupons::AmountService.call(applied_coupon: applied.reload, base_amount_cents: base).amount
    out = {"amount" => amount.is_a?(Float) ? amount : BigDecimal(amount.to_s),
           "amount_cents" => Credit.new(amount_cents: amount).amount_cents}
    out["remaining_amount_cents"] = applied.remaining_amount if applied.coupon.fixed_amount?
    out
  end
end

KitOracle.op("invoice.coupon_order") do |input, ctx|
  ctx.rollback do
    org, cust = KitOracleInvoicing.customer(ctx, input)
    book = KitOracleInvoicing::Book.new(ctx, org, cust)
    ids = {}
    input.fetch("applied_coupons").each do |ac|
      full = {"coupon_type" => "fixed_amount", "amount_cents" => 100}.merge(ac)
      full["limited_plan_codes"] = ["p_#{ac.fetch("id")}"] if ac["limited_plans"] && !ac["limited_plan_codes"]
      full["limited_billable_metric_codes"] = ["bm_#{ac.fetch("id")}"] if ac["limited_billable_metrics"] && !ac["limited_billable_metric_codes"]
      a = book.applied_coupon(full)
      ids[a.id] = ac.fetch("id")
    end
    scope = cust.applied_coupons.active.joins(:coupon)
      .order(Arel.sql("coupons.limited_billable_metrics DESC, coupons.limited_plans DESC, applied_coupons.created_at ASC"))
    # the exact relation Credits::AppliedCouponsService builds
    svc = Credits::AppliedCouponsService.new(invoice: Invoice.new(customer: cust))
    real = svc.send(:applied_coupons)
    ctx.bad_input!("ordering mismatch") unless real.map(&:id) == scope.map(&:id)
    {"order" => real.map { |a| ids[a.id] }}
  end
end

KitOracle.op("invoice.coupon_distribution") do |input, ctx|
  ctx.rollback do
    org, cust = KitOracleInvoicing.customer(ctx, input)
    book = KitOracleInvoicing::Book.new(ctx, org, cust)
    fees_in = input.fetch("fees")
    invoice = FactoryBot.create(:invoice, organization: org, customer: cust, billing_entity: cust.billing_entity,
      currency: input.fetch("currency", "EUR"), status: :generating, coupons_amount_cents: 0)
    fees_in.each { |f| book.fee(invoice, f) }
    applied = book.applied_coupon(input.fetch("applied_coupon").merge("id" => "c1"))
    invoice.reload
    invoice.fees_amount_cents = invoice.fees.sum(:amount_cents)
    invoice.sub_total_excluding_taxes_amount_cents = if input.key?("sub_total_excluding_taxes_amount_cents")
      Integer(input["sub_total_excluding_taxes_amount_cents"])
    else
      invoice.fees_amount_cents
    end
    credit = nil
    Customers::LockService.call(customer: cust, scope: :coupon) do
      res = Credits::AppliedCouponService.call(invoice:, applied_coupon: applied.reload)
      res.raise_if_error!
      credit = res.credit
    end
    applied.reload
    order = fees_in.map { |f| f.fetch("id") }
    {
      "credit_amount_cents" => credit&.amount_cents,
      "applied" => !credit.nil?,
      "fees" => invoice.fees.reload.sort_by { |f| order.index(book.fee_ids[f.id]) }.map do |f|
        {"id" => book.fee_ids[f.id], "precise_coupons_amount_cents" => f.precise_coupons_amount_cents}
      end,
      "sub_total_excluding_taxes_amount_cents" => invoice.sub_total_excluding_taxes_amount_cents,
      "applied_coupon_after" => {"status" => applied.status, "frequency_duration_remaining" => applied.frequency_duration_remaining}
    }
  end
end

# --- lifecycle ---------------------------------------------------------------------------------------------------

KitOracle.op("invoice.final_status") do |input, ctx|
  ctx.rollback do
    org, cust = KitOracleInvoicing.customer(ctx, input)
    fees_amount = Integer(input.fetch("fees_amount_cents"))
    total = Integer(input.fetch("total_amount_cents", fees_amount))
    gated = input.fetch("subscription_gated", false)
    invoice = FactoryBot.create(:invoice, organization: org, customer: cust, billing_entity: cust.billing_entity,
      currency: "EUR", status: gated ? :open : :generating, fees_amount_cents: fees_amount, total_amount_cents: total,
      tax_status: input.fetch("tax_pending", false) ? "pending" : nil, invoice_type: :subscription)
    if gated
      plan = FactoryBot.create(:plan, organization: org)
      sub = FactoryBot.create(:subscription, organization: org, customer: cust, plan:, status: :incomplete)
      FactoryBot.create(:subscription_activation_rule, organization: org, subscription: sub, status: "pending",
        timeout_hours: 48)
      FactoryBot.create(:invoice_subscription, organization: org, invoice:, subscription: sub)
    end
    # Invoices::SubscriptionService#set_invoice_generated_status: draft when a grace period applies (not gated)
    grace = !gated && cust.applicable_invoice_grace_period.positive?
    if grace
      invoice.status = :draft
    else
      Invoices::TransitionToFinalStatusService.call(invoice:)
    end
    invoice.save!
    {"status" => invoice.reload.status, "subscription_gated" => invoice.subscription_gated?}
  end
end

KitOracle.op("invoice.issuing_date") do |input, ctx|
  ctx.rollback do
    org, cust = KitOracleInvoicing.customer(ctx, input)
    at = ctx.instant(input.fetch("datetime"))
    res = Invoices::CreateGeneratingService.call(
      customer: cust, invoice_type: input.fetch("invoice_type", "subscription"), datetime: at,
      currency: "EUR", charge_in_advance: input.fetch("charge_in_advance", false),
      invoicing_reason: input.fetch("invoicing_reason", "subscription_periodic"),
      subscription_gated: input.fetch("subscription_gated", false)
    )
    res.raise_if_error!
    inv = res.invoice
    {"issuing_date" => inv.issuing_date, "expected_finalization_date" => inv.expected_finalization_date,
     "payment_due_date" => inv.payment_due_date, "net_payment_term" => inv.net_payment_term}
  end
end

KitOracle.op("invoice.payment_due_date") do |input, ctx|
  ctx.rollback do
    org, cust = KitOracleInvoicing.customer(ctx, input)
    now = ctx.instant(input.fetch("now"))
    drafted = Date.iso8601(input.fetch("drafted_issuing_date"))
    invoice = FactoryBot.create(:invoice, organization: org, customer: cust, billing_entity: cust.billing_entity,
      currency: "EUR", status: :draft, issuing_date: drafted, invoice_type: :subscription)
    plan = FactoryBot.create(:plan, organization: org)
    sub = FactoryBot.create(:subscription, organization: org, customer: cust, plan:)
    FactoryBot.create(:invoice_subscription, organization: org, invoice:, subscription: sub,
      recurring: input.fetch("recurring", true))
    ctx.travel(now) do
      svc = Invoices::RefreshDraftAndFinalizeService.new(invoice: invoice.reload)
      {"issuing_date" => svc.send(:issuing_date), "payment_due_date" => svc.send(:payment_due_date)}
    end
  end
end

KitOracle.op("invoice.available_to_credit") do |input, ctx|
  ctx.rollback do
    org, cust = KitOracleInvoicing.customer(ctx, input)
    inv_in = input.fetch("invoice")
    invoice = FactoryBot.create(:invoice, organization: org, customer: cust, billing_entity: cust.billing_entity,
      currency: "EUR", invoice_type: inv_in.fetch("invoice_type", "subscription"),
      status: inv_in.fetch("status", "finalized"), version_number: inv_in.fetch("version_number", 4),
      fees_amount_cents: Integer(inv_in.fetch("fees_amount_cents")),
      coupons_amount_cents: Integer(inv_in.fetch("coupons_amount_cents", 0)),
      progressive_billing_credit_amount_cents: Integer(inv_in.fetch("progressive_billing_credit_amount_cents", 0)),
      total_amount_cents: Integer(inv_in.fetch("total_amount_cents", 0)),
      total_paid_amount_cents: Integer(inv_in.fetch("total_paid_amount_cents", 0)),
      payment_status: inv_in.fetch("payment_status", "pending"))
    plan = FactoryBot.create(:plan, organization: org)
    sub = FactoryBot.create(:subscription, organization: org, customer: cust, plan:)
    fees = input.fetch("fees").map do |f|
      fee = FactoryBot.create(:fee, organization: org, billing_entity: cust.billing_entity, invoice:, subscription: sub,
        fee_type: "subscription", invoiceable_type: "Subscription", invoiceable_id: sub.id,
        amount_cents: Integer(f.fetch("amount_cents")), precise_amount_cents: Integer(f.fetch("amount_cents")),
        taxes_rate: Float(f.fetch("taxes_rate", "0")), taxes_amount_cents: 0, taxes_precise_amount_cents: 0)
      credited = Integer(f.fetch("credited_amount_cents", 0))
      if credited.positive?
        cn = FactoryBot.create(:credit_note, organization: org, customer: cust, invoice:, status: :draft,
          credit_amount_cents: 0, refund_amount_cents: 0, offset_amount_cents: 0, balance_amount_cents: 0, total_amount_cents: 0)
        FactoryBot.create(:credit_note_item, organization: org, credit_note: cn, fee:, amount_cents: credited, precise_amount_cents: credited)
      end
      fee
    end
    Array(input["credit_notes"]).each do |cn|
      FactoryBot.create(:credit_note, organization: org, customer: cust, invoice:, status: cn.fetch("status", "finalized"),
        credit_amount_cents: Integer(cn.fetch("credit_amount_cents", 0)), refund_amount_cents: Integer(cn.fetch("refund_amount_cents", 0)),
        offset_amount_cents: Integer(cn.fetch("offset_amount_cents", 0)), balance_amount_cents: Integer(cn.fetch("credit_amount_cents", 0)),
        total_amount_cents: Integer(cn.fetch("credit_amount_cents", 0)) + Integer(cn.fetch("refund_amount_cents", 0)) + Integer(cn.fetch("offset_amount_cents", 0)),
        credit_status: cn.fetch("credit_status", "available"))
    end
    invoice.reload
    _ = fees
    {
      "available_to_credit_amount_cents" => invoice.available_to_credit_amount_cents,
      "creditable_amount_cents" => invoice.creditable_amount_cents,
      "refundable_amount_cents" => invoice.refundable_amount_cents,
      "offsettable_amount_cents" => invoice.offsettable_amount_cents,
      "total_due_amount_cents" => invoice.total_due_amount_cents,
      "fee_total_amount_cents" => invoice.fee_total_amount_cents,
      "voidable" => invoice.voidable?
    }
  end
end

# --- void --------------------------------------------------------------------------------------------------------

KitOracle.op("invoice.void") do |input, ctx|
  ctx.rollback do
    ctx.travel(KitOracleInvoicing::BASE_TIME + 7200) do
      ctx.premium(input.fetch("premium", true)) do
        book, invoice = KitOracleCreditNotes.build_invoice(ctx, input.fetch("invoice"))
        KitOracleCreditNotes.setup_previous(ctx, book, invoice, input["previous_credit_notes"])
        invoice.reload
        voidable = invoice.voidable?
        params = {
          generate_credit_note: input.fetch("generate_credit_note", false),
          credit_amount: input.fetch("credit_amount_cents", 0),
          refund_amount: input.fetch("refund_amount_cents", 0)
        }.with_indifferent_access
        r = Invoices::VoidService.call(invoice:, params:)
        unless r.success?
          err = r.error
          code = err.respond_to?(:code) && err.code ? err.code.to_s : err.class.name
          field = err.respond_to?(:messages) && err.messages.is_a?(Hash) ? err.messages.keys.first.to_s : nil
          code = err.messages.values.flatten.first.to_s if field
          ctx.domain_error!(code, field)
        end
        invoice.reload
        prev_n = Array(input["previous_credit_notes"]).size
        {
          "status" => invoice.status,
          "voidable_before" => voidable,
          "credit_notes" => invoice.credit_notes.order(:sequential_id).drop(prev_n).map do |c|
            {"credit_amount_cents" => c.credit_amount_cents, "refund_amount_cents" => c.refund_amount_cents,
             "total_amount_cents" => c.total_amount_cents, "credit_status" => c.credit_status,
             "items" => c.items.order(:created_at).map { |i| {"fee_id" => book.fee_ids[i.fee_id], "amount_cents" => i.amount_cents} }}
          end,
          "applied_coupons_after" => book.customer.applied_coupons.order(:created_at).map do |a|
            {"status" => a.status, "frequency_duration_remaining" => a.frequency_duration_remaining}
          end
        }
      end
    end
  end
end

# invoice.commitment_true_up — plan minimum commitment over real billing runs (BE-IV-54..58). One organization, a customer
# (effective time zone = input timezone), a plan with a minimum commitment, an optional arrears standard charge on a
# count metric with its events, and one subscription; each run calls Invoices::SubscriptionService (what
# BillSubscriptionJob calls) at its instant, after marking the subscription terminated for a terminating run (what
# Subscriptions::TerminateService does before billing). The commitment fee itself comes from
# Fees::Commitments::Minimum::CreateService inside Invoices::CalculateFeesService; nothing is stubbed.
module KitOracleCommitment
  module_function

  INTERVALS = %w[weekly monthly quarterly semiannual yearly].freeze
  REASONS = %w[subscription_starting subscription_periodic subscription_terminating].freeze

  def bound(ctx, value)
    return nil if value.nil?

    ctx.instant_out(Time.zone.parse(value.to_s).utc.floor)
  end

  def fee_out(ctx, fee)
    return nil if fee.nil?

    {
      "amount_cents" => fee.amount_cents,
      "precise_amount_cents" => ctx.dec_out(fee.precise_amount_cents),
      "unit_amount_cents" => fee.unit_amount_cents,
      "precise_unit_amount" => ctx.dec_out(fee.precise_unit_amount),
      "units" => ctx.dec_out(fee.units),
      "from_datetime" => bound(ctx, fee.properties["from_datetime"]),
      "to_datetime" => bound(ctx, fee.properties["to_datetime"])
    }
  end

  def run(ctx, input)
    p_in = input.fetch("plan")
    interval = p_in.fetch("interval").to_s
    ctx.bad_input!("plan.interval must be one of #{INTERVALS.join("|")}") unless INTERVALS.include?(interval)
    s_in = input.fetch("subscription")
    started = ctx.instant(s_in.fetch("started_at"))
    runs = Array(input.fetch("billing_runs"))
    ctx.bad_input!("billing_runs is empty") if runs.empty?

    org = FactoryBot.create(:organization, webhook_url: nil)
    customer = FactoryBot.create(:customer, organization: org, timezone: input.fetch("timezone", "UTC"), currency: "EUR")
    plan = FactoryBot.create(:plan, organization: org, interval:, amount_cents: Integer(p_in.fetch("amount_cents", 0)),
      amount_currency: "EUR", pay_in_advance: p_in.fetch("pay_in_advance", false) ? true : false,
      bill_charges_monthly: p_in["bill_charges_monthly"] ? true : nil)
    FactoryBot.create(:commitment, :minimum_commitment, plan:, amount_cents: Integer(input.fetch("commitment_amount_cents")))
    if (u = input["usage"])
      bm = FactoryBot.create(:billable_metric, organization: org, code: "kit_count", aggregation_type: "count_agg",
        field_name: nil, recurring: false)
      FactoryBot.create(:standard_charge, plan:, billable_metric: bm, pay_in_advance: false, invoiceable: true,
        properties: {"amount" => ctx.dec(u.fetch("amount")).to_s("F")})
    end
    sub = FactoryBot.create(:subscription, organization: org, customer:, plan:, external_id: "kit_sub",
      billing_time: s_in.fetch("billing_time", "calendar"), subscription_at: started, started_at: started,
      activated_at: started, status: :active, created_at: started)
    Array(input.dig("usage", "events")).each_with_index do |ts, i|
      Event.create!(organization_id: org.id, code: "kit_count", transaction_id: "kit_tx_#{i + 1}",
        external_subscription_id: "kit_sub", timestamp: ctx.instant(ts), properties: {})
    end

    invoices = runs.map do |r|
      at = ctx.instant(r.fetch("at"))
      reason = r.fetch("reason", "subscription_periodic").to_s
      ctx.bad_input!("reason must be one of #{REASONS.join("|")}") unless REASONS.include?(reason)
      sub.update!(status: :terminated, terminated_at: at) if reason == "subscription_terminating"
      res = ctx.travel(at) do
        Invoices::SubscriptionService.call(subscriptions: [sub.reload], timestamp: at.to_i, invoicing_reason: reason.to_sym)
      end
      res.raise_if_error!
      inv = res.invoice&.reload
      next nil if inv.nil?

      {"fees_amount_cents" => inv.fees_amount_cents, "commitment" => fee_out(ctx, inv.fees.commitment.order(:id).first)}
    end
    {"invoices" => invoices}
  end
end

KitOracle.op("invoice.commitment_true_up") do |input, ctx|
  ctx.rollback { KitOracleCommitment.run(ctx, input) }
end

# invoice.coupon_create / invoice.coupon_apply — coupon catalogue and application checks (BE-IV-17, BE-IV-18):
# Coupons::CreateService in the API context (codes as the API passes them) and AppliedCoupons::CreateService (what the
# applied-coupons endpoint calls), over real organization, customer, plan, metric, charge and applied-coupon records.
module KitOracleCoupons
  module_function

  COUPON_KEYS = %w[coupon_type amount_cents amount_currency percentage_rate frequency frequency_duration reusable
    expiration expiration_at].freeze
  OVERRIDE_KEYS = %w[amount_cents amount_currency percentage_rate frequency frequency_duration].freeze

  def catalog(ctx, org, plans_in, extra_plan_codes, extra_bm_codes)
    bms = {}
    bm = ->(code) { bms[code] ||= FactoryBot.create(:billable_metric, organization: org, code:) }
    plans = {}
    Array(plans_in).each do |p|
      plan = FactoryBot.create(:plan, organization: org, code: p.fetch("code"))
      Array(p["billable_metric_codes"]).each { |c| FactoryBot.create(:standard_charge, plan:, billable_metric: bm.call(c)) }
      plans[plan.code] = plan
    end
    Array(extra_plan_codes).each { |c| plans[c] ||= FactoryBot.create(:plan, organization: org, code: c) }
    Array(extra_bm_codes).each { |c| bm.call(c) }
    [plans, bms]
  end

  def args_of(ctx, c)
    a = c.slice(*COUPON_KEYS).transform_keys(&:to_sym)
    a[:percentage_rate] = ctx.dec(a[:percentage_rate]) if a.key?(:percentage_rate)
    a[:expiration] ||= "no_expiration"
    a
  end

  # Every coupon attribute the input leaves out is nil (no factory default leaks into the record).
  def record_attrs(ctx, c)
    a = args_of(ctx, c).except(:reusable)
    %i[amount_cents amount_currency percentage_rate frequency_duration expiration_at].each { |k| a[k] = nil unless a.key?(k) }
    a
  end

  # A coupon record (not through the create service) with its targets, for the apply op.
  def coupon_record(ctx, org, plans, bms, c, code)
    coupon = FactoryBot.create(:coupon, organization: org, code:, name: code, status: c.fetch("status", "active"),
      reusable: c.fetch("reusable", true), limited_plans: Array(c["plan_codes"]).any?,
      limited_billable_metrics: Array(c["billable_metric_codes"]).any?, **record_attrs(ctx, c))
    Array(c["plan_codes"]).each { |p| CouponTarget.create!(coupon:, plan: plans.fetch(p), organization_id: org.id) }
    Array(c["billable_metric_codes"]).each do |b|
      CouponTarget.create!(coupon:, billable_metric: bms.fetch(b), organization_id: org.id)
    end
    coupon
  end

  def create(ctx, input)
    c = input.fetch("coupon")
    org = FactoryBot.create(:organization, webhook_url: nil)
    cat = input["catalog"] || {}
    catalog(ctx, org, [], cat["plan_codes"], cat["billable_metric_codes"])
    args = args_of(ctx, c).merge(organization_id: org.id, name: "kit coupon", code: "kit_coupon")
    applies = {}
    applies[:plan_codes] = c["plan_codes"] if c.key?("plan_codes")
    applies[:billable_metric_codes] = c["billable_metric_codes"] if c.key?("billable_metric_codes")
    args[:applies_to] = applies if applies.any?
    previous = CurrentContext.source
    CurrentContext.source = "api"
    res = begin
      Coupons::CreateService.call(**args)
    ensure
      CurrentContext.source = previous
    end
    KitOracleCreditNotes.first_error!(ctx, res) unless res.success?
    cp = res.coupon.reload
    {"coupon" => {"status" => cp.status, "reusable" => cp.reusable, "limited_plans" => cp.limited_plans,
                  "limited_billable_metrics" => cp.limited_billable_metrics, "frequency_duration" => cp.frequency_duration,
                  "targets" => cp.coupon_targets.count}}
  end

  def apply(ctx, input)
    org = FactoryBot.create(:organization, webhook_url: nil)
    codes = ->(k) { ([input["coupon"]] + Array(input["applied_before"]).map { |e| e["coupon"] }).compact.flat_map { |c| Array(c[k]) } }
    plans, bms = catalog(ctx, org, input["plans"], codes.call("plan_codes"), codes.call("billable_metric_codes"))
    customer = FactoryBot.create(:customer, organization: org, currency: input.fetch("customer_currency", "EUR"))
    coupon = coupon_record(ctx, org, plans, bms, input.fetch("coupon"), "kit_coupon")
    Array(input["applied_before"]).each_with_index do |e, i|
      other = e["coupon"] ? coupon_record(ctx, org, plans, bms, e["coupon"], "kit_before_#{i + 1}") : coupon
      FactoryBot.create(:applied_coupon, customer:, coupon: other, status: e.fetch("status", "active"),
        amount_cents: other.amount_cents, amount_currency: other.amount_currency, percentage_rate: other.percentage_rate,
        frequency: other.frequency, frequency_duration: other.frequency_duration)
    end
    params = (input["overrides"] || {}).slice(*OVERRIDE_KEYS).transform_keys(&:to_sym)
    params[:percentage_rate] = ctx.dec(params[:percentage_rate]) if params.key?(:percentage_rate)
    res = AppliedCoupons::CreateService.call(customer:, coupon:, params:)
    KitOracleCreditNotes.first_error!(ctx, res) unless res.success?
    ac = res.applied_coupon.reload
    {"applied_coupon" => {"status" => ac.status, "amount_cents" => ac.amount_cents, "amount_currency" => ac.amount_currency,
                          "percentage_rate" => ac.percentage_rate && ctx.dec_out(ac.percentage_rate),
                          "frequency" => ac.frequency, "frequency_duration" => ac.frequency_duration,
                          "frequency_duration_remaining" => ac.frequency_duration_remaining},
     "customer_currency" => customer.reload.currency}
  end
end

KitOracle.op("invoice.coupon_create") do |input, ctx|
  ctx.rollback { ctx.travel(input.fetch("now", "2024-03-01T10:00:00Z")) { KitOracleCoupons.create(ctx, input) } }
end

KitOracle.op("invoice.coupon_apply") do |input, ctx|
  ctx.rollback { ctx.travel(input.fetch("now", "2024-03-01T10:00:00Z")) { KitOracleCoupons.apply(ctx, input) } }
end
