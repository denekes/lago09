# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/periods.rb — oracle handlers for the `periods` area (billing-engine-spec chapter 06, rules BE-SP-*).
#
# Every handler builds real records with FactoryBot (organization, customer with the effective time zone, plan(s),
# the subscription and its plan-change neighbours, invoices) and calls the reference code path at the pin:
#   periods.boundaries             Subscriptions::DatesService.new_instance(...) (from/to, charges, fixed charges,
#                                  durations, next end of period, beginnings of period)
#   periods.invoice_boundaries     Invoices::CreateInvoiceSubscriptionService (boundaries persisted for a billing run:
#                                  current-usage rule for upgrades, termination-on-billing-day swap, duplicate guard)
#   periods.billing_days           Subscriptions::BillingDateQuery (the "billed on this local day" predicate)
#   periods.periodic_billing       Subscriptions::OrganizationBillingService#call (full periodic selection; the jobs
#                                  it enqueues tell bill / rotate / nothing)
#   periods.chain                  BillingDateQuery + DatesService over consecutive billing days
#   periods.single_day_price       DatesService#single_day_price
#   periods.subscription_fee       Fees::SubscriptionService (context :preview) + Invoices::CalculateFeesService
#                                  #should_create_subscription_fee? (the fee gate)
#   periods.classify_change        Subscriptions::CreateService#upgrade? / #downgrade?
#   periods.trial_end              Subscription#trial_end_datetime / #trial_end_date / #in_trial_period?
#   periods.termination_credit_days CreditNotes::CreateFromTermination (remaining/used days, day price)
#   periods.create_status          Subscriptions::CreateService (status, started_at, jobs and webhooks enqueued)
#   periods.terminate              Subscriptions::TerminateService (status, webhooks, termination billing job)
#
# Isolation: handlers run inside `KitOraclePeriods.sandbox`, a NON-joinable outer transaction on the primary and
# events connections that is always rolled back. This is how the reference's transactional specs run: service
# transactions inside it are savepoints whose after-commit callbacks (jobs, webhooks) fire when they commit, so the
# enqueued jobs can be observed. The periodic-billing selection reads through the `direct` role; for that call the
# non-writing roles share the writing pool (the reference test framework does the same), so the query sees the
# sandbox rows. Output instants are floored to microseconds (the stored precision).

module KitOraclePeriods
  module_function

  INTERVALS = %w[weekly monthly quarterly semiannual yearly].freeze
  BILLING_TIMES = %w[calendar anniversary].freeze
  STATUSES = %w[pending active terminated canceled incomplete].freeze
  NEXT_KINDS = %w[none upgrade downgrade].freeze
  EXTERNAL_ID = "kit_sub"
  # One webhook endpoint per organization, so webhook jobs are enqueued (the reference skips them without one).
  WEBHOOK_URL = "https://hooks.kit.example/lago"

  def sandbox
    result = nil
    ApplicationRecord.transaction(joinable: false, requires_new: true) do
      EventsRecord.transaction(joinable: false, requires_new: true) do
        result = yield
        raise ActiveRecord::Rollback
      end
      raise ActiveRecord::Rollback
    end
    result
  end

  # Non-writing roles (e.g. :direct) temporarily use the writing pool, like the reference's test framework does.
  def with_shared_pools
    handler = ActiveRecord::Base.connection_handler
    saved = []
    handler.connection_pool_names.each do |name|
      pm = handler.send(:connection_name_to_pool_manager)[name]
      pm.shard_names.each do |shard|
        writing = pm.get_pool_config(ActiveRecord.writing_role, shard)
        next unless writing

        pm.role_names.each do |role|
          cfg = pm.get_pool_config(role, shard)
          next if cfg.nil? || cfg == writing

          saved << [pm, role, shard, cfg]
          pm.set_pool_config(role, shard, writing)
        end
      end
    end
    yield
  ensure
    saved&.each { |pm, role, shard, cfg| pm.set_pool_config(role, shard, cfg) }
  end

  def us(t)
    return nil if t.nil?

    t = t.in_time_zone("UTC") unless t.is_a?(ActiveSupport::TimeWithZone)
    t.utc.floor(6)
  end

  def bool(v, default = false)
    v.nil? ? default : (v ? true : false)
  end

  def opt_instant(ctx, v)
    v.nil? ? nil : ctx.instant(v)
  end

  def plan_attrs(ctx, p)
    interval = p.fetch("interval").to_s
    ctx.bad_input!("plan.interval must be one of #{INTERVALS.join("|")}") unless INTERVALS.include?(interval)
    trial = p["trial_period"]
    {
      interval:,
      pay_in_advance: bool(p["pay_in_advance"]),
      amount_cents: Integer(p.fetch("amount_cents", 100)),
      amount_currency: "EUR",
      bill_charges_monthly: p.key?("bill_charges_monthly") ? p["bill_charges_monthly"] : nil,
      bill_fixed_charges_monthly: bool(p["bill_fixed_charges_monthly"]),
      trial_period: trial.nil? ? nil : Float(ctx.dec(trial))
    }
  end

  World = Struct.new(:org, :customer, :plan, :sub, :prev, :nxt, keyword_init: true)

  # Builds the organization, the customer (effective time zone = input timezone), the plan, the subscription and,
  # when asked, its previous subscription (plan change it results from) and its next subscription (pending plan
  # change, or the subscription an upgrade created).
  def world(ctx, input)
    tz = input.fetch("timezone", "UTC")
    s = input.fetch("subscription")
    org = FactoryBot.create(:organization, webhook_url: WEBHOOK_URL)
    customer = FactoryBot.create(:customer, organization: org, timezone: tz, currency: "EUR")
    plan = FactoryBot.create(:plan, organization: org, **plan_attrs(ctx, input.fetch("plan")))

    billing_time = s.fetch("billing_time", "calendar").to_s
    ctx.bad_input!("subscription.billing_time must be calendar|anniversary") unless BILLING_TIMES.include?(billing_time)
    status = s.fetch("status", s["terminated_at"] ? "terminated" : "active").to_s
    ctx.bad_input!("subscription.status must be one of #{STATUSES.join("|")}") unless STATUSES.include?(status)
    sub_at = ctx.instant(s.fetch("subscription_at"))
    started = s.key?("started_at") ? opt_instant(ctx, s["started_at"]) : sub_at
    terminated_at = opt_instant(ctx, s["terminated_at"])
    created = s["created_at"] ? ctx.instant(s["created_at"]) : (started || sub_at)

    prev = nil
    if (ps = input["previous_subscription"])
      prev_plan = FactoryBot.create(:plan, organization: org,
        **plan_attrs(ctx, {"interval" => ps.fetch("interval", plan.interval), "amount_cents" => ps.fetch("amount_cents"),
                           "pay_in_advance" => ps.fetch("pay_in_advance", plan.pay_in_advance)}))
      prev_started = ctx.instant(ps.fetch("started_at"))
      prev = FactoryBot.create(:subscription, organization: org, customer:, plan: prev_plan, external_id: EXTERNAL_ID,
        billing_time:, subscription_at: sub_at, started_at: prev_started, activated_at: prev_started,
        status: :terminated, terminated_at: started || created, created_at: prev_started)
    end

    sub = FactoryBot.create(:subscription, organization: org, customer:, plan:, external_id: EXTERNAL_ID,
      billing_time:, subscription_at: sub_at, started_at: started, activated_at: started, status:,
      terminated_at:, ending_at: opt_instant(ctx, s["ending_at"]), trial_ended_at: opt_instant(ctx, s["trial_ended_at"]),
      created_at: created, previous_subscription: prev)

    nxt = nil
    kind = s.fetch("next_subscription", "none").to_s
    ctx.bad_input!("subscription.next_subscription must be none|upgrade|downgrade") unless NEXT_KINDS.include?(kind)
    if kind != "none"
      next_amount = if kind == "upgrade"
        plan.amount_cents * 2 + 100
      else
        ctx.bad_input!("a downgrade needs plan.amount_cents > 0") unless plan.amount_cents.positive?
        plan.amount_cents / 2
      end
      next_plan = FactoryBot.create(:plan, organization: org, interval: plan.interval, amount_cents: next_amount,
        pay_in_advance: plan.pay_in_advance)
      next_status = (kind == "upgrade" && status == "terminated") ? :active : :pending
      next_started = (next_status == :active) ? (terminated_at || created) : nil
      nxt = FactoryBot.create(:subscription, organization: org, customer:, plan: next_plan, external_id: EXTERNAL_ID,
        billing_time:, subscription_at: sub_at, started_at: next_started, activated_at: next_started,
        status: next_status, previous_subscription: sub, created_at: created + 1.second)
    end

    if (pi = input["previous_invoice"])
      inv = FactoryBot.create(:invoice, organization: org, customer:, status: :finalized, timezone: pi.fetch("timezone"))
      cto = ctx.instant(pi.fetch("charges_to_datetime"))
      FactoryBot.create(:invoice_subscription, invoice: inv, subscription: sub, organization: org, recurring: true,
        timestamp: cto + 1.second, to_datetime: cto, charges_to_datetime: cto,
        fixed_charges_to_datetime: pi["fixed_charges_to_datetime"] ? ctx.instant(pi["fixed_charges_to_datetime"]) : cto)
    end

    World.new(org:, customer:, plan:, sub: sub.reload, prev:, nxt:)
  end

  def dates_hash(ds)
    {
      "from_datetime" => us(ds.from_datetime),
      "to_datetime" => us(ds.to_datetime),
      "charges_from_datetime" => us(ds.charges_from_datetime),
      "charges_to_datetime" => us(ds.charges_to_datetime),
      "fixed_charges_from_datetime" => us(ds.fixed_charges_from_datetime),
      "fixed_charges_to_datetime" => us(ds.fixed_charges_to_datetime)
    }
  end

  def local_noon_utc(date, tz)
    ActiveSupport::TimeZone[tz].local(date.year, date.month, date.day, 12, 0, 0).utc
  end

  def billed_on?(sub, at)
    Subscriptions::BillingDateQuery.call(subscriptions: Subscription.where(id: sub.id), timestamp: at)
      .subscriptions.exists?
  end

  def jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs
  end

  def job_names(klass)
    jobs.select { |j| j[:job] == klass || j["job_class"] == klass.name }
  end

  def webhooks
    jobs.select { |j| (j[:job] || j["job_class"]).to_s == "SendWebhookJob" }.map { |j| Array(j[:args]).first.to_s }
  end

  def bill_reasons
    jobs.select { |j| (j[:job] || j["job_class"]).to_s == "BillSubscriptionJob" }.map do |j|
      kw = Array(j[:args]).find { |a| a.is_a?(Hash) && a.key?("invoicing_reason") }
      v = kw && kw["invoicing_reason"]
      v = v["value"] if v.is_a?(Hash)
      v ? v.to_s : "unknown"
    end
  end
end

W6 = KitOraclePeriods

# --- boundaries -------------------------------------------------------------------------------------------------

KitOracle.op("periods.boundaries") do |input, ctx|
  W6.sandbox do
    w = W6.world(ctx, input)
    at = ctx.instant(input.fetch("billing_at"))
    ds = Subscriptions::DatesService.new_instance(w.sub, at, current_usage: W6.bool(input["current_usage"]))
    out = W6.dates_hash(ds)
    out["fixed_charges_period_to_datetime"] = W6.us(ds.fixed_charges_period_to_datetime)
    out["period_days"] = ds.send(:compute_duration, from_date: ds.send(:compute_from_date)).to_i
    out["charges_duration_days"] = ds.charges_duration_in_days.to_i
    out["fixed_charges_duration_days"] = ds.fixed_charges_duration_in_days.to_i
    out["next_end_of_period"] = W6.us(ds.next_end_of_period)
    out["previous_beginning_of_period"] = W6.us(ds.previous_beginning_of_period)
    out["current_beginning_of_period"] = W6.us(ds.previous_beginning_of_period(current_period: true))
    out
  end
end

REASONS6 = %w[subscription_periodic subscription_starting subscription_terminating upgrading progressive_billing].freeze

KitOracle.op("periods.invoice_boundaries") do |input, ctx|
  W6.sandbox do
    w = W6.world(ctx, input)
    at = ctx.instant(input.fetch("billing_at"))
    reason = input.fetch("invoicing_reason").to_s
    ctx.bad_input!("invoicing_reason must be one of #{REASONS6.join("|")}") unless REASONS6.include?(reason)
    if W6.bool(input["previous_period_invoiced"])
      # Fixture: a recurring invoice already holds the boundaries a periodic run would compute at this instant for
      # the (not yet terminated) subscription.
      dup = w.sub.dup.tap { |s| s.status = :active }
      pds = Subscriptions::DatesService.new_instance(dup, at, current_usage: false)
      pinv = FactoryBot.create(:invoice, organization: w.org, customer: w.customer, status: :finalized)
      FactoryBot.create(:invoice_subscription, invoice: pinv, subscription: w.sub, organization: w.org, recurring: true,
        timestamp: at - 1.hour, from_datetime: pds.from_datetime, to_datetime: pds.to_datetime,
        charges_from_datetime: pds.charges_from_datetime, charges_to_datetime: pds.charges_to_datetime,
        fixed_charges_from_datetime: pds.fixed_charges_from_datetime, fixed_charges_to_datetime: pds.fixed_charges_to_datetime)
    end
    invoice = FactoryBot.create(:invoice, organization: w.org, customer: w.customer, status: :generating)
    res = Invoices::CreateInvoiceSubscriptionService.call(invoice:, subscriptions: [w.sub], timestamp: at.to_f,
      invoicing_reason: reason)
    ctx.domain_error!(res.error.code, nil) if !res.success? && res.error.respond_to?(:code)
    res.raise_if_error!
    is = res.invoice_subscriptions.first
    {
      "from_datetime" => W6.us(is.from_datetime), "to_datetime" => W6.us(is.to_datetime),
      "charges_from_datetime" => W6.us(is.charges_from_datetime), "charges_to_datetime" => W6.us(is.charges_to_datetime),
      "fixed_charges_from_datetime" => W6.us(is.fixed_charges_from_datetime),
      "fixed_charges_to_datetime" => W6.us(is.fixed_charges_to_datetime),
      "recurring" => is.recurring, "invoicing_reason" => is.invoicing_reason
    }
  end
end

# --- scheduling -------------------------------------------------------------------------------------------------

KitOracle.op("periods.billing_days") do |input, ctx|
  W6.sandbox do
    w = W6.world(ctx, input)
    from = Date.iso8601(input.fetch("from_date"))
    to = Date.iso8601(input.fetch("to_date"))
    ctx.bad_input!("range longer than 800 days") if (to - from) > 800
    hour = input["utc_hour"]
    tz = input.fetch("timezone", "UTC")
    dates = (from..to).select do |d|
      at = hour.nil? ? W6.local_noon_utc(d, tz) : Time.utc(d.year, d.month, d.day, Integer(hour), 10, 0)
      W6.billed_on?(w.sub, at)
    end
    {"dates" => dates.map(&:iso8601)}
  end
end

KitOracle.op("periods.periodic_billing") do |input, ctx|
  W6.sandbox do
    w = W6.world(ctx, input)
    at = ctx.instant(input.fetch("billing_at"))
    Array(input["recurring_invoices_at"]).each do |t|
      inv = FactoryBot.create(:invoice, organization: w.org, customer: w.customer, status: :finalized)
      FactoryBot.create(:invoice_subscription, invoice: inv, subscription: w.sub, organization: w.org, recurring: true,
        timestamp: ctx.instant(t))
    end
    W6.jobs.clear
    W6.with_shared_pools do
      Subscriptions::OrganizationBillingService.call(organization: w.org, billing_at: at)
    end
    rotated = W6.jobs.any? { |j| (j[:job] || j["job_class"]).to_s == "Subscriptions::TerminateJob" }
    billed = W6.bill_reasons
    action = if rotated then "rotate"
    elsif billed.any? then "bill"
    else "none"
    end
    {"action" => action}
  end
end

KitOracle.op("periods.chain") do |input, ctx|
  W6.sandbox do
    w = W6.world(ctx, input)
    tz = input.fetch("timezone", "UTC")
    count = Integer(input.fetch("count"))
    ctx.bad_input!("count must be 1..24") unless (1..24).cover?(count)
    day = Date.iso8601(input.fetch("from_date"))
    periods = []
    guard = 0
    while periods.size < count
      ctx.bad_input!("no billing day within 1100 days") if (guard += 1) > 1100
      at = W6.local_noon_utc(day, tz)
      if W6.billed_on?(w.sub, at)
        ds = Subscriptions::DatesService.new_instance(w.sub, at, current_usage: false)
        periods << W6.dates_hash(ds).slice("from_datetime", "to_datetime", "charges_from_datetime", "charges_to_datetime")
          .merge("billing_date" => day.iso8601,
            "period_days" => ds.send(:compute_duration, from_date: ds.send(:compute_from_date)).to_i)
      end
      day += 1
    end
    {"periods" => periods}
  end
end

# --- amounts ----------------------------------------------------------------------------------------------------

KitOracle.op("periods.single_day_price") do |input, ctx|
  W6.sandbox do
    w = W6.world(ctx, input)
    at = ctx.instant(input.fetch("billing_at"))
    ds = Subscriptions::DatesService.new_instance(w.sub, at, current_usage: W6.bool(input["current_usage"]))
    from_date = input["from_date"] && Date.iso8601(input["from_date"])
    pac = input["plan_amount_cents"] && Integer(input["plan_amount_cents"])
    value = ds.single_day_price(optional_from_date: from_date, plan_amount_cents: pac)
    {"value" => value, "period_days" => ds.send(:compute_duration, from_date: from_date || ds.send(:compute_from_date)).to_i}
  end
end

KitOracle.op("periods.subscription_fee") do |input, ctx|
  W6.sandbox do
    w = W6.world(ctx, input)
    b = input.fetch("boundaries")
    from = ctx.instant(b.fetch("from_datetime"))
    to = ctx.instant(b.fetch("to_datetime"))
    ts = ctx.instant(b.fetch("timestamp"))
    inv_created = input["invoice_created_at"] ? ctx.instant(input["invoice_created_at"]) : ts
    other = Array(input["other_subscription_fees_created_at"]).map { |t| ctx.instant(t) }
    count = Integer(input.fetch("invoice_count", 1 + other.size))
    ctx.bad_input!("invoice_count must be >= 1 + number of other subscription fees") if count < 1 + other.size

    invoice = FactoryBot.create(:invoice, organization: w.org, customer: w.customer, status: :draft, created_at: inv_created,
      invoice_type: :subscription)
    FactoryBot.create(:invoice_subscription, invoice:, subscription: w.sub, organization: w.org, timestamp: ts,
      from_datetime: from, to_datetime: to, charges_from_datetime: from, charges_to_datetime: to,
      recurring: W6.bool(input["recurring"]), invoicing_reason: input.fetch("invoicing_reason", "subscription_periodic"))
    (count - 1).times do |i|
      other_inv = FactoryBot.create(:invoice, organization: w.org, customer: w.customer, status: :finalized,
        invoice_type: :subscription, created_at: other[i] || (inv_created - (i + 1).days))
      FactoryBot.create(:invoice_subscription, invoice: other_inv, subscription: w.sub, organization: w.org,
        timestamp: other[i] || (inv_created - (i + 1).days), recurring: true)
      next unless other[i]

      FactoryBot.create(:fee, invoice: other_inv, subscription: w.sub, organization: w.org,
        billing_entity: w.customer.billing_entity, fee_type: :subscription, amount_cents: w.plan.amount_cents,
        precise_amount_cents: w.plan.amount_cents, created_at: other[i])
    end

    boundaries = BillingPeriodBoundaries.new(from_datetime: from, to_datetime: to, charges_from_datetime: from,
      charges_to_datetime: to, charges_duration: nil, timestamp: ts)
    svc = Fees::SubscriptionService.new(invoice:, subscription: w.sub, boundaries:, context: :preview)
    basis = if svc.send(:should_compute_terminated_amount?) then "terminated"
    elsif svc.send(:should_compute_upgraded_amount?) then "upgraded"
    elsif svc.send(:should_use_full_amount?) then "full_period"
    else "first_period"
    end
    fee = svc.call.raise_if_error!.fee

    gate = ctx.travel(inv_created) do
      Invoices::CalculateFeesService.new(invoice: invoice.reload, recurring: W6.bool(input["recurring"]))
        .send(:should_create_subscription_fee?, w.sub.reload, boundaries)
    end
    {
      "created" => gate ? true : false,
      "basis" => basis,
      "precise_amount_cents" => fee.precise_amount_cents,
      "amount_cents" => fee.amount_cents
    }
  end
end

# --- lifecycle helpers ------------------------------------------------------------------------------------------

KitOracle.op("periods.classify_change") do |input, ctx|
  W6.sandbox do
    org = FactoryBot.create(:organization, webhook_url: nil)
    customer = FactoryBot.create(:customer, organization: org, currency: "EUR")
    cur = input.fetch("current")
    nxt = input.fetch("next")
    cur_plan = FactoryBot.create(:plan, organization: org, **W6.plan_attrs(ctx, cur))
    new_plan = if W6.bool(nxt["same_plan"])
      cur_plan
    else
      FactoryBot.create(:plan, organization: org, **W6.plan_attrs(ctx, nxt))
    end
    current = FactoryBot.create(:subscription, organization: org, customer:, plan: cur_plan, external_id: W6::EXTERNAL_ID)
    svc = Subscriptions::CreateService.new(customer:, plan: new_plan, params: {external_id: W6::EXTERNAL_ID})
    svc.instance_variable_set(:@current_subscription, current)
    kind = if svc.send(:upgrade?) then "upgrade"
    elsif svc.send(:downgrade?) then "downgrade"
    else "same"
    end
    {"kind" => kind, "current_yearly_amount_cents" => cur_plan.yearly_amount_cents,
     "next_yearly_amount_cents" => new_plan.yearly_amount_cents}
  end
end

KitOracle.op("periods.trial_end") do |input, ctx|
  W6.sandbox do
    w = W6.world(ctx, input)
    at = ctx.instant(input.fetch("at"))
    ctx.travel(at) do
      sub = w.sub.reload
      {
        "trial_end_datetime" => W6.us(sub.trial_end_datetime),
        "trial_end_date" => sub.trial_end_date&.iso8601,
        "initial_started_at" => W6.us(sub.initial_started_at),
        "in_trial" => sub.in_trial_period? ? true : false
      }
    end
  end
end

KitOracle.op("periods.termination_credit_days") do |input, ctx|
  W6.sandbox do
    w = W6.world(ctx, input)
    ctx.bad_input!("subscription.status must be terminated") unless w.sub.terminated?
    if (pac = input["fee_plan_amount_cents"])
      inv = FactoryBot.create(:invoice, organization: w.org, customer: w.customer, status: :finalized)
      FactoryBot.create(:fee, invoice: inv, subscription: w.sub, organization: w.org,
        billing_entity: w.customer.billing_entity, fee_type: :subscription, amount_cents: Integer(pac),
        precise_amount_cents: Integer(pac), amount_details: {"plan_amount_cents" => Integer(pac)})
    end
    svc = CreditNotes::CreateFromTermination.new(subscription: w.sub, upgrade: W6.bool(input["upgrade"]))
    ds = svc.send(:date_service)
    {
      "remaining_days" => svc.send(:remaining_duration).to_i,
      "used_days" => svc.send(:used_duration).to_i,
      "period_days" => ds.send(:compute_duration, from_date: ds.send(:compute_from_date)).to_i,
      "day_price" => svc.send(:day_price),
      "unused_amount_cents" => svc.send(:calculate_base_unused_amount),
      "next_end_of_period" => W6.us(ds.next_end_of_period)
    }
  end
end

KitOracle.op("periods.create_status") do |input, ctx|
  W6.sandbox do
    tz = input.fetch("timezone", "UTC")
    now = ctx.instant(input.fetch("now"))
    org = FactoryBot.create(:organization, webhook_url: W6::WEBHOOK_URL)
    customer = FactoryBot.create(:customer, organization: org, timezone: tz, currency: "EUR")
    plan = FactoryBot.create(:plan, organization: org, **W6.plan_attrs(ctx, input.fetch("plan")))
    if (pt = input["previous_terminated_at"])
      old_plan = FactoryBot.create(:plan, organization: org, interval: plan.interval, amount_cents: plan.amount_cents)
      FactoryBot.create(:subscription, organization: org, customer:, plan: old_plan, external_id: W6::EXTERNAL_ID,
        status: :terminated, started_at: ctx.instant(pt) - 30.days, subscription_at: ctx.instant(pt) - 30.days,
        terminated_at: ctx.instant(pt), on_termination_invoice: input.fetch("previous_on_termination_invoice", "generate"))
    end
    ctx.travel(now) do
      W6.jobs.clear
      params = {external_id: W6::EXTERNAL_ID, subscription_at: ctx.instant(input.fetch("subscription_at")),
                billing_time: input.fetch("billing_time", "calendar")}
      res = Subscriptions::CreateService.call(customer:, plan:, params:)
      if !res.success?
        err = res.error
        code = err.respond_to?(:messages) ? err.messages.values.flatten.first : err.code
        field = err.respond_to?(:messages) ? err.messages.keys.first : nil
        ctx.domain_error!(code, field)
      end
      sub = res.subscription.reload
      {
        "status" => sub.status,
        "started_at" => W6.us(sub.started_at),
        "billed_at_creation" => W6.bill_reasons.any?,
        "invoicing_reasons" => W6.bill_reasons,
        "webhooks" => W6.webhooks
      }
    end
  end
end

KitOracle.op("periods.terminate") do |input, ctx|
  W6.sandbox do
    w = W6.world(ctx, input)
    now = ctx.instant(input.fetch("now"))
    ctx.travel(now) do
      W6.jobs.clear
      opts = {}
      opts[:on_termination_invoice] = input["on_termination_invoice"] if input.key?("on_termination_invoice")
      res = Subscriptions::TerminateService.call(subscription: w.sub.reload, **opts)
      if !res.success?
        err = res.error
        code = err.respond_to?(:messages) ? err.messages.values.flatten.first : err.code
        ctx.domain_error!(code, nil)
      end
      sub = w.sub.reload
      out = {
        "status" => sub.status,
        "terminated_at" => W6.us(sub.terminated_at),
        "canceled" => sub.canceled_at.present?,
        "webhooks" => W6.webhooks,
        "invoicing_reasons" => W6.bill_reasons
      }
      out["next_subscription_status"] = w.nxt.reload.status if w.nxt
      out["previous_subscription_status"] = w.prev.reload.status if w.prev
      out
    end
  end
end
