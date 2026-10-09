# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/wallet.rb — oracle handlers for the `wallets` area (billing-engine-spec chapter 09, rules BE-WL-*).
# Uses KitA8 (ops/alerts.rb). DB-backed handlers run inside KitA8.sandbox (always rolled back).
#
#   wallets.credits            WalletCredit.new / WalletCredit.from_amount_cents / WalletCredit.rounds_to_zero?
#   wallets.top_up             WalletTransactions::CreateFromParamsService (validation, paid / granted / voided credits,
#                              balance increase / decrease) on a persisted wallet
#   wallets.topup_amount       RecurringTransactionRule#compute_paid_credits / #compute_granted_credits
#   wallets.threshold_top_up   Wallets::ThresholdTopUpService on persisted wallet + rule (+ pending / declined
#                              transactions); the enqueued wallet-transaction job's params are the output
#   wallets.interval_due       Wallets::CreateIntervalWalletTransactionsService at a frozen clock (the batch query
#                              reads through the `direct` role, shared with the writing pool for the call)
#   wallets.allocate           Credits::AppliedPrepaidCreditsService on a persisted invoice with fees (allocation by
#                              Credits::AllocatePrepaidCreditsByWalletsService, wallet transactions, balance decrease)
#   wallets.ongoing_balance    Wallets::Balance::AllocateOngoingUsageByWalletsService over (unsaved) fee records,
#                              then Wallets::Balance::RefreshOngoingUsageService per wallet
#   wallets.consumption_order  WalletTransactions::TrackConsumptionService on a traceable wallet
#
# Stand-ins: none beyond building records with the reference's own factories; fees handed to the ongoing-balance
# allocation are unsaved Fee records (the reference passes the fees of in-memory current-usage invoices there).

module KitA8W
  module_function

  def wallet(ctx, org, cust, w, idx = 0, cache = {})
    currency = w.fetch("currency", cust.currency || "EUR")
    rate = ctx.dec(w.fetch("rate_amount", "1"))
    balance = Integer(w.fetch("balance_cents", 0))
    subunit = Money::Currency.new(currency).subunit_to_unit
    attrs = {
      customer: cust, organization: org, currency:, rate_amount: rate, balance_cents: balance,
      credits_balance: w["credits_balance"] ? ctx.dec(w["credits_balance"]) : BigDecimal(balance) / subunit / rate,
      consumed_credits: ctx.dec(w.fetch("consumed_credits", "0")),
      consumed_amount_cents: Integer(w.fetch("consumed_amount_cents", 0)),
      ongoing_balance_cents: Integer(w.fetch("ongoing_balance_cents", balance)),
      credits_ongoing_balance: ctx.dec(w.fetch("credits_ongoing_balance", "0")),
      priority: Integer(w.fetch("priority", 50)), traceable: KitA8.bool(w["traceable"]),
      allowed_fee_types: Array(w["allowed_fee_types"]),
      depleted_ongoing_balance: KitA8.bool(w["depleted_ongoing_balance"]),
      code: w.fetch("id", "w#{idx + 1}"), name: w.fetch("id", "w#{idx + 1}"),
      created_at: w["created_at"] ? ctx.instant(w["created_at"]) : KitA8::BASE_TIME + idx,
      status: w.fetch("status", "active")
    }
    %w[paid_top_up_min_amount_cents paid_top_up_max_amount_cents].each do |k|
      attrs[k.to_sym] = Integer(w[k]) if w[k]
    end
    wallet = KitA8.fb.create(:wallet, **attrs)
    Array(w["billable_metric_codes"]).each do |code|
      bm = cache[[:bm, code]] ||= KitA8.fb.create(:billable_metric, organization: org, code:)
      WalletTarget.create!(wallet:, billable_metric: bm, organization: org)
    end
    wallet
  end

  # Inbound transaction with a remaining amount (traceable wallets).
  def inbound(ctx, wallet, t, idx)
    cents = Integer(t.fetch("remaining_cents"))
    subunit = wallet.currency_for_balance.subunit_to_unit
    amount = BigDecimal(Integer(t.fetch("amount_cents", cents))) / subunit
    KitA8.fb.create(:wallet_transaction, wallet:, organization: wallet.organization, transaction_type: :inbound,
      status: t.fetch("state", "settled"), transaction_status: t.fetch("status", "granted"),
      source: t.fetch("source", "manual"), priority: Integer(t.fetch("priority", 50)),
      amount:, credit_amount: amount / wallet.rate_amount, remaining_amount_cents: cents,
      created_at: t["created_at"] ? ctx.instant(t["created_at"]) : KitA8::BASE_TIME + idx)
  end

  def tx_out(ctx, wt)
    {"transaction_status" => wt.transaction_status, "status" => wt.status,
     "credit_amount" => ctx.dec_out(wt.credit_amount), "amount" => ctx.dec_out(wt.amount),
     "amount_cents" => wt.amount_cents.to_i}
  end

  def domain_error_from(ctx, err)
    if err.respond_to?(:messages) && err.messages.is_a?(Hash) && err.messages.any?
      field, codes = err.messages.first
      ctx.domain_error!(Array(codes).first.to_s, field.to_s)
    end
    ctx.domain_error!(err.respond_to?(:code) ? err.code.to_s : err.class.name)
  end

  def rule_attrs(ctx, r)
    attrs = {
      trigger: r.fetch("trigger", "threshold"), method: r.fetch("method", "fixed"),
      interval: r["interval"], paid_credits: ctx.dec(r.fetch("paid_credits", "0")),
      granted_credits: ctx.dec(r.fetch("granted_credits", "0")),
      ignore_paid_top_up_limits: KitA8.bool(r["ignore_paid_top_up_limits"])
    }
    attrs[:threshold_credits] = ctx.dec(r["threshold_credits"]) if r["threshold_credits"]
    attrs[:target_ongoing_balance] = ctx.dec(r["target_ongoing_balance"]) if r["target_ongoing_balance"]
    attrs[:grants_target_top_up] = KitA8.bool(r["grants_target_top_up"]) if attrs[:method] == "target"
    attrs.compact
  end
end

KitOracle.op("wallets.credits") do |input, ctx|
  currency = input.fetch("currency", "EUR")
  wallet = Wallet.new(currency:, rate_amount: ctx.dec(input.fetch("rate_amount")))
  if input.key?("credits")
    credits = ctx.dec(input["credits"])
    wc = WalletCredit.new(wallet:, credit_amount: credits, invoiceable: KitA8.bool(input["invoiceable"], true))
    rtz = WalletCredit.rounds_to_zero?(wallet:, credit_amount: input["credits"])
  elsif input.key?("cents")
    wc = WalletCredit.from_amount_cents(wallet:, amount_cents: ctx.dec(input["cents"]))
    rtz = nil
  else
    ctx.bad_input!("credits or cents required")
  end
  out = {"credits" => wc.credit_amount, "amount" => wc.amount, "amount_cents" => wc.amount_cents}
  out["rounds_to_zero"] = rtz unless rtz.nil?
  out
end

KitOracle.op("wallets.top_up") do |input, ctx|
  KitA8.sandbox do
    org = KitA8.org
    w_in = input.fetch("wallet")
    cust = KitA8.customer(org, currency: w_in.fetch("currency", "EUR"))
    wallet = KitA8W.wallet(ctx, org, cust, {"traceable" => false}.merge(w_in))
    Array(w_in["inbound"]).each_with_index { |t, i| KitA8W.inbound(ctx, wallet, t, i) }
    params = {wallet_id: wallet.id}
    %w[paid_credits granted_credits voided_credits].each { |k| params[k.to_sym] = input[k] if input.key?(k) }
    params[:reset_consumed_credits] = input["reset_consumed_credits"] if input.key?("reset_consumed_credits")
    params[:ignore_paid_top_up_limits] = input["ignore_paid_top_up_limits"] if input.key?("ignore_paid_top_up_limits")
    res = WalletTransactions::CreateFromParamsService.call(organization: org, params:)
    KitA8W.domain_error_from(ctx, res.error) unless res.success?
    wallet.reload
    {
      "transactions" => Array(res.wallet_transactions).map { |wt| KitA8W.tx_out(ctx, wt) },
      "wallet" => {"balance_cents" => wallet.balance_cents, "credits_balance" => ctx.dec_out(wallet.credits_balance),
                   "consumed_credits" => ctx.dec_out(wallet.consumed_credits),
                   "consumed_amount_cents" => wallet.consumed_amount_cents}
    }
  end
end

KitOracle.op("wallets.topup_amount") do |input, ctx|
  w = input.fetch("wallet", {})
  wallet = Wallet.new(currency: w.fetch("currency", "EUR"), rate_amount: ctx.dec(w.fetch("rate_amount", "1")),
    credits_ongoing_balance: ctx.dec(w.fetch("credits_ongoing_balance", "0")))
  %w[paid_top_up_min_amount_cents paid_top_up_max_amount_cents].each do |k|
    wallet.public_send(:"#{k}=", Integer(w[k])) if w[k]
  end
  rule = RecurringTransactionRule.new(wallet:, **KitA8W.rule_attrs(ctx, input.fetch("rule")))
  paid = rule.compute_paid_credits(ongoing_balance: wallet.credits_ongoing_balance,
    pending_credits: ctx.dec(input.fetch("pending_credits", "0")))
  {"paid_credits" => paid, "granted_credits" => rule.compute_granted_credits}
end

KitOracle.op("wallets.threshold_top_up") do |input, ctx|
  now = ctx.instant(input.fetch("now", "2024-03-15T12:00:00Z"))
  ctx.travel(now) do
    KitA8.sandbox do
      org = KitA8.org
      cust = KitA8.customer(org)
      wallet = KitA8W.wallet(ctx, org, cust, {"traceable" => false, "created_at" => "2024-01-01T00:00:00Z"}.merge(input.fetch("wallet")))
      RecurringTransactionRule.create!(wallet:, organization: org, status: input.fetch("rule_status", "active"),
        **KitA8W.rule_attrs(ctx, {"trigger" => "threshold"}.merge(input.fetch("rule"))))
      subunit = wallet.currency_for_balance.subunit_to_unit
      Array(input["transactions"]).each do |t|
        credits = ctx.dec(t.fetch("credit_amount"))
        attrs = {wallet:, organization: org, transaction_type: :inbound, transaction_status: t.fetch("transaction_status", "purchased"),
                 status: t.fetch("status", "pending"), source: t.fetch("source", "threshold"),
                 credit_amount: credits, amount: credits * wallet.rate_amount, remaining_amount_cents: nil,
                 created_at: ctx.instant(t.fetch("created_at", input.fetch("now", "2024-03-15T12:00:00Z")))}
        attrs[:failed_at] = ctx.instant(t["failed_at"]) if t["failed_at"]
        attrs[:settled_at] = t["settled_at"] ? ctx.instant(t["settled_at"]) : nil
        KitA8.fb.create(:wallet_transaction, **attrs)
      end
      _ = subunit
      KitA8.jobs.clear
      Wallets::ThresholdTopUpService.call(wallet: Wallet.find(wallet.id), state_changed: KitA8.bool(input["state_changed"], true))
      job = KitA8.jobs.find { |j| KitA8.job_name(j) == "WalletTransactions::CreateJob" }
      if job
        args = Array(job[:args] || job["arguments"]).first || {}
        params = args["params"] || {}
        {"top_up" => true, "paid_credits" => ctx.dec_out(params["paid_credits"]), "granted_credits" => ctx.dec_out(params["granted_credits"])}
      else
        {"top_up" => false}
      end
    end
  end
end

KitOracle.op("wallets.interval_due") do |input, ctx|
  interval = input.fetch("interval")
  ctx.bad_input!("bad interval") unless RecurringTransactionRule::INTERVALS.map(&:to_s).include?(interval)
  now = ctx.instant(input.fetch("now"))
  KitA8.sandbox do
    org = KitA8.org(timezone: input["billing_entity_timezone"])
    cust = KitA8.customer(org, timezone: input["timezone"])
    wallet = KitA8W.wallet(ctx, org, cust, {"traceable" => false, "created_at" => input.fetch("wallet_created_at")})
    rule = {"trigger" => "interval", "interval" => interval, "method" => input.fetch("method", "fixed"),
            "paid_credits" => input.fetch("paid_credits", "10"), "granted_credits" => input.fetch("granted_credits", "0")}
    rule["target_ongoing_balance"] = input["target_ongoing_balance"] if input["target_ongoing_balance"]
    attrs = KitA8W.rule_attrs(ctx, rule)
    attrs[:started_at] = ctx.instant(input["rule_started_at"]) if input["rule_started_at"]
    attrs[:expiration_at] = ctx.instant(input["rule_expiration_at"]) if input["rule_expiration_at"]
    RecurringTransactionRule.create!(wallet:, organization: org, status: "active", **attrs)
    Array(input["interval_top_ups_at"]).each do |t|
      KitA8.fb.create(:wallet_transaction, wallet:, organization: org, transaction_type: :inbound, source: :interval,
        transaction_status: :purchased, status: :settled, amount: "1", credit_amount: "1", remaining_amount_cents: nil,
        created_at: ctx.instant(t))
    end
    KitA8.jobs.clear
    ctx.travel(now) do
      KitA8.with_shared_pools { Wallets::CreateIntervalWalletTransactionsService.call }
    end
    job = KitA8.jobs.find do |j|
      KitA8.job_name(j) == "WalletTransactions::CreateJob" &&
        (Array(j[:args] || j["arguments"]).first || {}).dig("params", "wallet_id") == wallet.id
    end
    out = {"due" => !job.nil?}
    if job
      params = Array(job[:args] || job["arguments"]).first["params"]
      out["paid_credits"] = ctx.dec_out(params["paid_credits"])
      out["granted_credits"] = ctx.dec_out(params["granted_credits"])
    end
    out
  end
end

# fees: [{fee_type: charge|subscription|add_on|fixed_charge|commitment, billable_metric_code?, amount_cents,
#         precise_coupons_cents?, taxes_precise_cents?, precise_credit_notes_cents?, target_wallet_code?}]
KitOracle.op("wallets.allocate") do |input, ctx|
  premium = KitA8.bool(input["premium"])
  ctx.premium(premium) do
    KitA8.sandbox do
      currency = input.fetch("currency", "EUR")
      # premium = premium licence AND the organization's event-targeted-wallets feature
      org = KitA8.org(premium_integrations: premium ? ["events_targeting_wallets"] : [])
      cust = KitA8.customer(org, currency:)
      plan = KitA8.plan(org, currency:)
      sub = KitA8.subscription(org, cust, plan)
      cache = {}
      wallets = Array(input.fetch("wallets")).each_with_index.map do |w, i|
        wallet = KitA8W.wallet(ctx, org, cust, w, i, cache)
        Array(w["inbound"]).each_with_index { |t, j| KitA8W.inbound(ctx, wallet, t, (i * 10) + j) }
        [wallet.id, w.fetch("id", "w#{i + 1}")]
      end.to_h
      invoice = KitA8.fb.create(:invoice, organization: org, customer: cust, currency:, status: :finalized,
        total_amount_cents: Integer(input.fetch("invoice_total_cents")), prepaid_credit_amount_cents: 0)
      Array(input.fetch("fees")).each do |f|
        a = Integer(f.fetch("amount_cents"))
        common = {invoice:, subscription: sub, organization: org, amount_cents: a, precise_amount_cents: a,
                  amount_currency: currency,
                  precise_coupons_amount_cents: ctx.dec(f.fetch("precise_coupons_cents", "0")),
                  taxes_precise_amount_cents: ctx.dec(f.fetch("taxes_precise_cents", "0")),
                  taxes_amount_cents: ctx.dec(f.fetch("taxes_precise_cents", "0")).round,
                  precise_credit_notes_amount_cents: ctx.dec(f.fetch("precise_credit_notes_cents", "0"))}
        type = f.fetch("fee_type", "charge")
        if type == "charge"
          charge = KitA8.charge_for(org, plan, f.fetch("billable_metric_code", "m1"), cache)
          if f["target_wallet_code"]
            charge.update!(accepts_target_wallet: true)
            common[:grouped_by] = {"target_wallet_code" => f["target_wallet_code"]}
          end
          KitA8.fb.create(:charge_fee, charge:, **common)
        else
          KitA8.fb.create(:fee, fee_type: type, **common)
        end
      end
      res = Credits::AppliedPrepaidCreditsService.call(invoice:)
      KitA8W.domain_error_from(ctx, res.error) unless res.success?
      invoice.reload
      out = {
        "per_wallet" => res.wallet_transactions.map do |wt|
          {"wallet" => wallets.fetch(wt.wallet_id), "amount_cents" => wt.amount_cents.to_i,
           "credit_amount" => ctx.dec_out(wt.credit_amount)}
        end,
        "prepaid_credit_amount_cents" => invoice.prepaid_credit_amount_cents
      }
      out["prepaid_granted_credit_amount_cents"] = invoice.prepaid_granted_credit_amount_cents if invoice.prepaid_granted_credit_amount_cents
      out["prepaid_purchased_credit_amount_cents"] = invoice.prepaid_purchased_credit_amount_cents if invoice.prepaid_purchased_credit_amount_cents
      out
    end
  end
end

# fees lists: [{fee_type?, billable_metric_code?, amount_cents, taxes_cents?, precise_coupons_cents?, currency?,
#               pay_in_advance?}]
KitOracle.op("wallets.ongoing_balance") do |input, ctx|
  KitA8.sandbox do
    currency = input.fetch("currency", "EUR")
    org = KitA8.org
    cust = KitA8.customer(org, currency:)
    plan = KitA8.plan(org, currency:)
    sub = KitA8.subscription(org, cust, plan)
    cache = {}
    names = {}
    Array(input.fetch("wallets")).each_with_index do |w, i|
      wallet = KitA8W.wallet(ctx, org, cust, w, i, cache)
      names[wallet.id] = w.fetch("id", "w#{i + 1}")
      if w["threshold_rule"]
        RecurringTransactionRule.create!(wallet:, organization: org, status: "active", trigger: "threshold",
          method: "fixed", paid_credits: 1, granted_credits: 0, threshold_credits: ctx.dec(w.fetch("threshold_credits", "0")))
      end
    end
    build = lambda do |list|
      Array(list).map do |f|
        type = f.fetch("fee_type", "charge")
        charge = (type == "charge") ? KitA8.charge_for(org, plan, f.fetch("billable_metric_code", "m1"), cache, pay_in_advance: KitA8.bool(f["pay_in_advance"])) : nil
        Fee.new(organization: org, subscription: sub, charge:, fee_type: type,
          amount_cents: Integer(f.fetch("amount_cents")), amount_currency: f.fetch("currency", currency),
          taxes_amount_cents: Integer(f.fetch("taxes_cents", 0)),
          precise_coupons_amount_cents: ctx.dec(f.fetch("precise_coupons_cents", "0")))
      end
    end
    current = build.call(input["current_usage_fees"])
    wallets = cust.wallets.active.includes(:recurring_transaction_rules, :wallet_targets).in_application_order.to_a
    allocs = Wallets::Balance::AllocateOngoingUsageByWalletsService.call!(
      customer: cust, wallets:, current_usage_fees: current,
      draft_invoices_fees: build.call(input["draft_invoice_fees"]),
      progressive_billing_fees: build.call(input["progressive_billing_fees"]),
      pay_in_advance_fees: current.select { |f| f.charge&.pay_in_advance? }
    ).wallet_allocations
    wallets.map do |wallet|
      Wallets::Balance::RefreshOngoingUsageService.call!(wallet:, ongoing_usage_amount_cents: allocs[wallet],
        skip_single_wallet_update: true)
    end
    {
      "wallets" => wallets.map do |wallet|
        wallet.reload
        {"id" => names.fetch(wallet.id), "ongoing_usage_balance_cents" => wallet.ongoing_usage_balance_cents,
         "ongoing_balance_cents" => wallet.ongoing_balance_cents,
         "credits_ongoing_usage_balance" => ctx.dec_out(wallet.credits_ongoing_usage_balance),
         "credits_ongoing_balance" => ctx.dec_out(wallet.credits_ongoing_balance),
         "depleted_ongoing_balance" => wallet.depleted_ongoing_balance}
      end
    }
  end
end

# inbound: [{id, status: granted|purchased, priority?, remaining_cents}] in creation order;
# outbound_cents; inbound_id? (consume from that one only)
KitOracle.op("wallets.consumption_order") do |input, ctx|
  KitA8.sandbox do
    org = KitA8.org
    cust = KitA8.customer(org)
    inbound_in = Array(input.fetch("inbound"))
    total = inbound_in.sum { |t| Integer(t.fetch("remaining_cents")) }
    wallet = KitA8W.wallet(ctx, org, cust, {"traceable" => true, "balance_cents" => total,
                                            "rate_amount" => input.fetch("rate_amount", "1")})
    ids = {}
    inbound_in.each_with_index do |t, i|
      wt = KitA8W.inbound(ctx, wallet, t, i)
      ids[wt.id] = t.fetch("id", "in#{i + 1}")
    end
    cents = Integer(input.fetch("outbound_cents"))
    subunit = wallet.currency_for_balance.subunit_to_unit
    amount = BigDecimal(cents) / subunit
    out = WalletTransaction.create!(wallet:, organization: org, transaction_type: :outbound, status: :settled,
      transaction_status: :invoiced, amount:, credit_amount: amount / wallet.rate_amount, settled_at: Time.current,
      invoice_requires_successful_payment: false)
    target = input["inbound_id"] && ids.key(input["inbound_id"])
    res = WalletTransactions::TrackConsumptionService.call(outbound_wallet_transaction: out,
      inbound_wallet_transaction_id: target)
    KitA8W.domain_error_from(ctx, res.error) unless res.success?
    rows = WalletTransactionConsumption.where(outbound_wallet_transaction_id: out.id).order(:created_at).to_a
    {"consumptions" => rows.map { |c| {"inbound" => ids.fetch(c.inbound_wallet_transaction_id), "amount_cents" => c.consumed_amount_cents} }}
  end
end
