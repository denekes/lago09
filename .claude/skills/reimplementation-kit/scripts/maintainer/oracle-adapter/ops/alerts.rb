# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/alerts.rb — oracle handlers for the `alerts` area (billing-engine-spec chapter 10, rules BE-AL-*), plus KitA8,
# the helper shared with ops/progressive.rb and ops/wallet.rb (this file loads first: file-name order).
#
#   alerts.crossed   a persisted alert with its thresholds (UsageMonitoring::Alert, STI current_usage_amount) and the
#                    real UsageMonitoring::ProcessAlertService fed a current-usage object carrying `current`:
#                    Alert#find_thresholds_crossed (values), the triggered alert row it writes (formatted thresholds),
#                    and the alert's previous value afterwards
#   alerts.measure   Alert#find_value of the real STI class for the alert type, over a current-usage object with real
#                    (unsaved) Fee records on persisted charges, a LifetimeUsage, or a Wallet
#
# Stand-ins (stated so the evidence stays honest): the current-usage object handed to the services is a plain struct
# with `amount_cents` and `fees` (the reference passes the customer-usage result, which exposes the same two readers).
#
# Isolation: KitA8.sandbox — a NON-joinable outer transaction on the primary and events connections that is always
# rolled back (service transactions inside it behave like committed ones, as in the reference's transactional specs).

module KitA8
  module_function

  BASE_TIME = Time.utc(2024, 3, 1, 10, 0, 0)

  def fb
    FactoryBot
  end

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

  # Non-writing roles (the `direct` role used by a few batch queries) temporarily use the writing pool so they see
  # the sandbox rows, as the reference's test framework arranges for its own specs.
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

  def jobs
    ActiveJob::Base.queue_adapter.enqueued_jobs
  end

  def job_name(j)
    (j[:job] || j["job_class"]).to_s
  end

  def bool(v, default = false)
    v.nil? ? default : (v ? true : false)
  end

  def int(ctx, v, name)
    ctx.bad_input!("#{name} must be an integer") unless v.is_a?(Integer)
    v
  end

  def org(premium_integrations: [], timezone: nil)
    attrs = {webhook_url: nil}
    attrs[:premium_integrations] = premium_integrations if premium_integrations.any?
    o = fb.create(:organization, **attrs)
    o.default_billing_entity.update!(timezone:) if timezone
    o
  end

  def customer(org, currency: "EUR", timezone: nil)
    attrs = {organization: org, billing_entity: org.default_billing_entity, currency:}
    attrs[:timezone] = timezone if timezone
    fb.create(:customer, **attrs)
  end

  def plan(org, currency: "EUR", parent: nil)
    attrs = {organization: org, amount_cents: 0, amount_currency: currency, interval: "monthly"}
    attrs[:parent] = parent if parent
    fb.create(:plan, **attrs)
  end

  def subscription(org, customer, plan, external_id: "kit_sub", **extra)
    attrs = {organization: org, customer:, plan:, external_id:, status: "active",
             started_at: Time.utc(2024, 1, 1), subscription_at: Time.utc(2024, 1, 1)}
    attrs.merge!(extra)
    attrs[:activated_at] ||= attrs[:started_at]
    fb.create(:subscription, **attrs)
  end

  # Billable metric + standard charge per kit code, on `plan`.
  def charge_for(org, plan, code, cache, pay_in_advance: false)
    cache[[code, pay_in_advance]] ||= begin
      bm = cache[[:bm, code]] ||= fb.create(:billable_metric, organization: org, code:)
      attrs = {organization: org, plan:, billable_metric: bm, properties: {"amount" => "1"}}
      attrs[:pay_in_advance] = true if pay_in_advance
      attrs[:invoiceable] = true if pay_in_advance
      fb.create(:standard_charge, **attrs)
    end
  end

  Usage = Struct.new(:amount_cents, :fees)
end

KitOracle.op("alerts.crossed") do |input, ctx|
  direction = input.fetch("direction", "increasing")
  ctx.bad_input!("direction must be increasing|decreasing") unless %w[increasing decreasing].include?(direction)
  thresholds = input.fetch("thresholds")
  ctx.bad_input!("thresholds must be an array") unless thresholds.is_a?(Array)

  KitA8.sandbox do
    org = KitA8.org
    cust = KitA8.customer(org)
    sub = KitA8.subscription(org, cust, KitA8.plan(org))
    alert = UsageMonitoring::CurrentUsageAmountAlert.create!(
      organization: org, code: "kit_alert", name: "kit", subscription_external_id: sub.external_id,
      direction:, previous_value: ctx.dec(input.fetch("previous"))
    )
    thresholds.each_with_index do |t, i|
      alert.thresholds.create!(organization_id: org.id, value: ctx.dec(t.fetch("value")),
        code: t["code"] || "t#{i + 1}", recurring: KitA8.bool(t["recurring"]))
    end
    alert = UsageMonitoring::Alert.find(alert.id)
    current = ctx.dec(input.fetch("current"))
    crossed = alert.find_thresholds_crossed(current)

    alert = UsageMonitoring::Alert.includes(:thresholds).find(alert.id)
    UsageMonitoring::ProcessAlertService.call!(alert:, alertable: sub,
      current_metrics: KitA8::Usage.new(current, []))
    triggered = UsageMonitoring::TriggeredAlert.where(usage_monitoring_alert_id: alert.id).order(:created_at).last
    out = {
      "crossed" => crossed.map { |v| ctx.dec_out(v) },
      "triggered" => !triggered.nil?,
      "previous_after" => ctx.dec_out(alert.reload.previous_value)
    }
    out["crossed_thresholds"] = Array(triggered&.crossed_thresholds).map do |h|
      {"code" => h["code"], "value" => ctx.dec_out(h["value"]), "recurring" => h["recurring"]}
    end
    out
  end
end

KitOracle.op("alerts.measure") do |input, ctx|
  type = input.fetch("alert_type")
  klass_name = UsageMonitoring::Alert::STI_MAPPING[type]
  ctx.bad_input!("unknown alert_type #{type}") unless klass_name

  KitA8.sandbox do
    org = KitA8.org
    cust = KitA8.customer(org)
    plan = KitA8.plan(org)
    sub = KitA8.subscription(org, cust, plan)
    cache = {}
    attrs = {organization: org, code: "kit_alert", name: "kit", direction: "increasing"}
    if UsageMonitoring::Alert::WALLET_TYPES.include?(type)
      w = input["wallet"] || {}
      wallet = KitA8.fb.create(:wallet, customer: cust, organization: org, traceable: false)
      wallet.assign_attributes(
        balance_cents: Integer(w.fetch("balance_cents", 0)),
        credits_balance: ctx.dec(w.fetch("credits_balance", "0")),
        ongoing_balance_cents: Integer(w.fetch("ongoing_balance_cents", 0)),
        credits_ongoing_balance: ctx.dec(w.fetch("credits_ongoing_balance", "0"))
      )
      attrs[:wallet] = wallet
      metrics = wallet
    else
      attrs[:subscription_external_id] = sub.external_id
      if UsageMonitoring::Alert::BILLABLE_METRIC_TYPES.include?(type)
        code = input.fetch("billable_metric_code")
        KitA8.charge_for(org, plan, code, cache)
        attrs[:billable_metric] = cache[[:bm, code]]
      end
      if type == "lifetime_usage_amount"
        l = input.fetch("lifetime_usage")
        metrics = LifetimeUsage.new(organization: org, subscription: sub,
          historical_usage_amount_cents: Integer(l.fetch("historical_cents", 0)),
          invoiced_usage_amount_cents: Integer(l.fetch("invoiced_cents", 0)),
          current_usage_amount_cents: Integer(l.fetch("current_cents", 0)))
      else
        u = input.fetch("current_usage")
        fees = Array(u["fees"]).map do |f|
          charge = KitA8.charge_for(org, plan, f.fetch("billable_metric_code"), cache)
          Fee.new(organization: org, subscription: sub, charge:, fee_type: "charge",
            amount_cents: Integer(f.fetch("amount_cents", 0)), amount_currency: "EUR",
            units: ctx.dec(f.fetch("units", "0")))
        end
        metrics = KitA8::Usage.new(Integer(u.fetch("amount_cents", 0)), fees)
      end
    end
    alert = klass_name.constantize.create!(**attrs)
    value = alert.find_value(metrics)
    {"value" => value.nil? ? nil : ctx.dec_out(value)}
  end
end
