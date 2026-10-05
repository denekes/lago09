# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/pricing.rb — oracle handlers for the `pricing` area (billing-engine-spec chapter 05, rules BE-PR-*).
#
# Every handler drives the reference code path at the pin:
#   pricing.charge_model            ChargeModels::Factory.new_instance(...).apply (all charge models, grouping wrapper)
#   pricing.pay_in_advance          Fees::CreatePayInAdvanceService#init_fee (real charge, subscription, Fee casts) with
#                                   the aggregation step replaced by the vector's aggregation input
#   pricing.fee_money               Fees::ChargeService#init_fee + #should_persist_fee? (real MeteredItem, Fee casts)
#   pricing.true_up                 Fees::CreateTrueUpService (real fee/charge/subscription, customer time zone)
#   pricing.pricing_unit            PricingUnitUsage.build_from_fiat_amounts + #to_fiat_currency_cents
#   pricing.validate_properties     Charges::Validators::<Model>Service + Charge#valid? (properties messages)
#   pricing.validate_charge         Charge#valid? / FixedCharge#valid? (model-level constraints)
#   pricing.default_properties      ChargeModels::BuildDefaultPropertiesService
#   pricing.filter_properties       ChargeModels::FilterPropertiesService (slicing, grouped_by renaming)
#   pricing.fixed_charge_units      FixedChargeEvents::Aggregations::{Simple,Prorated}AggregationService (real SQL)
#   pricing.fixed_charge_in_advance Fees::BuildPayInAdvanceFixedChargeService with the period boundaries and the
#                                   already-billed units taken from the input
#   pricing.fixed_charge_fee        Fees::FixedChargeService (real events, aggregation, charge model, Fee casts)
#   pricing.projection              Fees::ProjectionService#call with the aggregation step taken from the input
#   pricing.estimate_instant        Fees::EstimateInstant::BaseService#estimate_charge_fees
#   pricing.simulate                Charges::CalculatePriceService
#
# The only stand-in is the aggregator handle (StubAggregator below): it returns the per-event arrays supplied in the
# vector (the aggregation chapter's interface), exactly as the reference aggregator would for those events.
# DB-backed handlers run inside ctx.rollback; nothing persists.


module KitOraclePricing
  module_function

  MODELS = %w[standard graduated graduated_percentage package percentage volume dynamic custom].freeze

  # Per-event values the aggregator would return. Kit input convention (BE-PR chapter, pay-in-advance section):
  # `per_event_values` lists the values of the period's events in timestamp order; for a persisted pay-in-advance
  # event the current event is the LAST element (exclude_event drops it); for an estimate the current event is not
  # in the list and include_event_value appends `event_value`.
  class StubAggregator
    def initialize(by_group)
      @by_group = by_group
    end

    def per_event_aggregation(exclude_event: false, include_event_value: false, grouped_by_values: nil)
      key = grouped_by_values.presence && grouped_by_values.to_h.transform_keys(&:to_s)
      d = @by_group[key] || @by_group[nil] || {}
      if d.key?(:full)
        BillableMetrics::ProratedAggregations::BaseService::ProratedPerEventAggregationResult.new.tap do |r|
          r.event_aggregation = d[:full]
          r.event_prorated_aggregation = d[:pro]
        end
      else
        vals = Array(d[:values])
        vals = vals[0..-2] if exclude_event
        vals += [d[:event_value]] if include_event_value && !d[:event_value].nil?
        BillableMetrics::Aggregations::BaseService::PerEventAggregationResult.new.tap { |r| r.event_aggregation = vals }
      end
    end
  end

  def dec(ctx, v)
    v.nil? ? nil : ctx.dec(v)
  end

  def decs(ctx, list)
    list&.map { |x| ctx.dec(x) }
  end

  def currency(input)
    Money::Currency.new(input.fetch("currency", "EUR"))
  end

  def check_model!(ctx, model, allowed = MODELS)
    ctx.bad_input!("unknown model #{model.inspect}") unless allowed.include?(model)
  end

  # Charge properties as a jsonb column returns them: string keys, JSON numbers (Integer/Float).
  def jsonb(obj)
    JSON.parse(JSON.generate(obj || {}))
  end

  # amount_details in their stored (jsonb) form: decimals as strings, integers/floats as JSON numbers.
  def stored_json(obj)
    obj.nil? ? nil : JSON.parse(obj.to_json)
  end

  def per_event_entry(ctx, agg)
    entry = {}
    if agg.key?("per_event_full") || agg.key?("per_event_prorated")
      entry[:full] = decs(ctx, agg["per_event_full"] || [])
      entry[:pro] = decs(ctx, agg["per_event_prorated"] || [])
    end
    entry[:values] = decs(ctx, agg["per_event_values"]) if agg.key?("per_event_values")
    entry[:event_value] = dec(ctx, agg["event_value"]) if agg.key?("event_value")
    entry
  end

  def aggregator_needed?(agg)
    %w[per_event_full per_event_prorated per_event_values].any? { |k| agg.key?(k) } ||
      Array(agg["groups"]).any? { |g| aggregator_needed?(g) }
  end

  def fill_result(ctx, r, agg)
    r.aggregation = ctx.dec(agg.fetch("units"))
    r.count = agg.fetch("count", 0)
    r.full_units_number = dec(ctx, agg["full_units_number"])
    r.current_usage_units = dec(ctx, agg["current_usage_units"])
    r.total_aggregated_units = dec(ctx, agg["total_aggregated_units"])
    r.options = {running_total: decs(ctx, agg.fetch("running_total", []))}
    r.precise_total_amount_cents = dec(ctx, agg["precise_total_amount_cents"])
    r.custom_aggregation = {amount: ctx.dec(agg["custom_amount"]), units: r.aggregation} if agg.key?("custom_amount")
    r
  end

  # BillableMetrics::Aggregations::BaseService::Result built from the vector's aggregation object.
  def aggregation_result(ctx, agg)
    ctx.bad_input!("aggregation must be an object") unless agg.is_a?(Hash)
    r = fill_result(ctx, BillableMetrics::Aggregations::BaseService::Result.new, agg)
    by_group = {}
    by_group[nil] = per_event_entry(ctx, agg)
    if agg.key?("groups")
      r.aggregations = agg["groups"].map do |g|
        gr = fill_result(ctx, BillableMetrics::Aggregations::BaseService::Result.new, g)
        gr.grouped_by = g.fetch("grouped_by")
        by_group[g.fetch("grouped_by").transform_keys(&:to_s)] = per_event_entry(ctx, g)
        gr
      end
    end
    r.aggregator = StubAggregator.new(by_group) if aggregator_needed?(agg)
    r
  end

  def pricing_structure(input, properties)
    ChargeModels::PricingStructure.new(
      charge_model: input.fetch("model"),
      properties:,
      prorated: input.fetch("prorated", false),
      accepts_target_wallet: false,
      currency: currency(input)
    )
  end

  def result_out(res)
    out = {
      "amount" => res.amount,
      "unit_amount" => res.respond_to?(:unit_amount) ? res.unit_amount : nil,
      "units" => res.units,
      "amount_details" => res.respond_to?(:amount_details) ? stored_json(res.amount_details) : nil
    }
    out["projected_units"] = res.projected_units unless res.projected_units.nil?
    out["projected_amount"] = res.projected_amount unless res.projected_amount.nil?
    if res.is_a?(ChargeModels::GroupedService::Result)
      out.delete("unit_amount")
      out.delete("amount_details")
      out["groups"] = res.grouped_results.map do |g|
        {"grouped_by" => g.grouped_by, "units" => g.units, "amount" => g.amount, "unit_amount" => g.unit_amount,
         "amount_details" => stored_json(g.amount_details)}
      end
    end
    out.compact
  end

  # --- DB-backed fixtures (always inside ctx.rollback) --------------------------------------------------------

  def fb
    FactoryBot
  end

  World = Struct.new(:organization, :customer, :plan, :billable_metric, keyword_init: true)

  def world(input, aggregation_type: "sum_agg", recurring: false, field_name: "value", plan_amount_cents: 0,
    timezone: nil, metric: {})
    org = fb.create(:organization, webhook_url: nil)
    customer = fb.create(:customer, organization: org, timezone: timezone || input["timezone"] || "UTC",
      currency: input.fetch("currency", "EUR"))
    plan = fb.create(:plan, organization: org, amount_currency: input.fetch("currency", "EUR"),
      amount_cents: plan_amount_cents, interval: "monthly")
    # Saved without validation: the metric only parameterises the pricing code paths (weighted-sum intervals,
    # custom aggregators and field presence are the aggregation chapter's validations).
    bm = fb.build(:billable_metric, organization: org, aggregation_type: metric.fetch("aggregation_type", aggregation_type),
      recurring: metric.fetch("recurring", recurring), field_name: metric.key?("field_name") ? metric["field_name"] : field_name,
      rounding_function: metric["rounding_function"], rounding_precision: metric["rounding_precision"])
    bm.save!(validate: false)
    World.new(organization: org, customer:, plan:, billable_metric: bm)
  end

  def charge(w, model:, properties:, pay_in_advance: false, prorated: false, invoiceable: true, min_amount_cents: 0,
    regroup_paid_fees: nil)
    c = Charge.new(organization: w.organization, plan: w.plan, billable_metric: w.billable_metric, code: "kit_charge",
      charge_model: model, properties:, pay_in_advance:, prorated:, invoiceable:, min_amount_cents:,
      regroup_paid_fees:)
    c.save!(validate: false)
    c
  end

  def apply_pricing_unit(w, charge, rate)
    pu = PricingUnit.create!(organization: w.organization, name: "Kit credits", code: "kit_credits", short_name: "KC")
    AppliedPricingUnit.create!(organization: w.organization, pricing_unit: pu, pricing_unitable: charge,
      conversion_rate: rate)
    charge.reload
  end

  def subscription(w, started_at: Time.zone.parse("2024-01-01T00:00:00Z"), external_id: "kit_sub")
    fb.create(:subscription, customer: w.customer, plan: w.plan, organization: w.organization, external_id:,
      started_at:, subscription_at: started_at, billing_time: :calendar, status: :active)
  end

  def fee_out(fee)
    {
      "amount_cents" => fee.amount_cents,
      "precise_amount_cents" => fee.precise_amount_cents,
      "unit_amount_cents" => fee.unit_amount_cents,
      "precise_unit_amount" => fee.precise_unit_amount,
      "units" => fee.units,
      "total_aggregated_units" => fee.total_aggregated_units,
      "events_count" => fee.events_count,
      "amount_details" => stored_json(fee.amount_details)
    }
  end

  def pricing_unit_out(u)
    return nil unless u

    {
      "amount_cents" => u.amount_cents,
      "precise_amount_cents" => u.precise_amount_cents,
      "unit_amount_cents" => u.unit_amount_cents,
      "precise_unit_amount" => u.precise_unit_amount,
      "conversion_rate" => u.conversion_rate
    }
  end

  def boundaries(from: "2024-01-01T00:00:00Z", to: "2024-01-31T23:59:59Z", duration: 31, timestamp: nil)
    BillingPeriodBoundaries.new(
      from_datetime: Time.zone.parse(from), to_datetime: Time.zone.parse(to),
      charges_from_datetime: Time.zone.parse(from), charges_to_datetime: Time.zone.parse(to),
      charges_duration: duration, timestamp: Time.zone.parse(timestamp || to)
    )
  end
end

# --- charge models ----------------------------------------------------------------------------------------------

KitOracle.op("pricing.charge_model") do |input, ctx|
  model = input.fetch("model")
  KitOraclePricing.check_model!(ctx, model)
  props = KitOraclePricing.jsonb(input.fetch("properties"))
  flags = input.fetch("flags", {})
  props = props.merge(exclude_event: true) if flags["exclude_event"]
  props = props.merge(include_event_value: true) if flags["include_event_value"]
  agg = KitOraclePricing.aggregation_result(ctx, input.fetch("aggregation"))
  ratio = input.key?("period_ratio") ? Float(input["period_ratio"]) : 1.0
  ctx.premium(input.fetch("premium", false)) do
    res = begin
      ChargeModels::Factory.new_instance(
        pricing_structure: KitOraclePricing.pricing_structure(input, props),
        aggregation_result: agg,
        period_ratio: ratio,
        calculate_projected_usage: input.fetch("calculate_projected_usage", false)
      ).apply
    rescue NoMethodError, NotImplementedError, TypeError, ZeroDivisionError, FloatDomainError => e
      ctx.domain_error!("charge_model_error", nil, "#{e.class}: #{e.message}"[0, 200])
    end
    KitOraclePricing.result_out(res)
  end
end

# --- pay in advance ---------------------------------------------------------------------------------------------

KitOracle.op("pricing.pay_in_advance") do |input, ctx|
  model = input.fetch("model")
  KitOraclePricing.check_model!(ctx, model)
  persisted = input.fetch("persisted", true)
  ctx.premium(input.fetch("premium", false)) do
    ctx.rollback do
      w = KitOraclePricing.world(input, aggregation_type: input.fetch("metric_aggregation_type", "sum_agg"))
      charge = KitOraclePricing.charge(w, model:, properties: KitOraclePricing.jsonb(input.fetch("properties")),
        pay_in_advance: input.fetch("pay_in_advance", true), prorated: input.fetch("prorated", false))
      KitOraclePricing.apply_pricing_unit(w, charge, ctx.dec(input["pricing_unit_conversion_rate"])) if input["pricing_unit_conversion_rate"]
      KitOraclePricing.subscription(w)
      ts = Time.zone.parse("2024-01-15T12:00:00Z")
      event = Events::Common.new(id: persisted ? SecureRandom.uuid : nil, organization_id: w.organization.id,
        external_subscription_id: "kit_sub", transaction_id: "kit_tx", timestamp: ts, code: w.billable_metric.code,
        properties: {}, persisted:)

      agg_in = input.fetch("aggregation")
      agg = KitOraclePricing.aggregation_result(ctx, agg_in)
      agg.pay_in_advance_aggregation = ctx.dec(agg_in.fetch("event_units"))
      agg.pay_in_advance_precise_total_amount_cents = KitOraclePricing.dec(ctx, agg_in["event_precise_total_amount_cents"])
      agg.pay_in_advance_event = event
      if (cached = agg_in["cached"])
        agg.current_aggregation = KitOraclePricing.dec(ctx, cached["current_aggregation"])
        agg.max_aggregation = KitOraclePricing.dec(ctx, cached["max_aggregation"])
        agg.units_applied = KitOraclePricing.dec(ctx, cached["units_applied"])
      end
      unless agg.aggregator
        agg.aggregator = KitOraclePricing::StubAggregator.new({nil => KitOraclePricing.per_event_entry(ctx, agg_in)})
      end

      svc = Fees::CreatePayInAdvanceService.new(charge:, event:, estimate: !persisted)
      svc.define_singleton_method(:aggregate) { |**| agg }
      svc.define_singleton_method(:cache_aggregation_result) { |**| nil }
      fee = begin
        svc.send(:init_fee, properties: charge.properties)
      rescue BaseService::FailedResult => e
        ctx.domain_error!(e.result.error.respond_to?(:code) ? e.result.error.code : "service_failure", nil, e.message)
      rescue NoMethodError, NotImplementedError, TypeError, ZeroDivisionError, FloatDomainError => e
        ctx.domain_error!("charge_model_error", nil, "#{e.class}: #{e.message}"[0, 200])
      end
      out = KitOraclePricing.fee_out(fee)
      out["pay_in_advance"] = fee.pay_in_advance
      pu = KitOraclePricing.pricing_unit_out(fee.pricing_unit_usage)
      out["pricing_unit_usage"] = pu if pu
      out
    end
  end
end

# --- fee materialisation ----------------------------------------------------------------------------------------

KitOracle.op("pricing.fee_money") do |input, ctx|
  ctx_name = input.fetch("context", "invoice")
  ctx.bad_input!("context must be invoice|current_usage|recurring") unless %w[invoice current_usage recurring].include?(ctx_name)
  ctx.premium(true) do
    ctx.rollback do
      w = KitOraclePricing.world(input, recurring: input.fetch("prorated", false))
      charge = KitOraclePricing.charge(w, model: "standard", properties: {"amount" => "1"},
        pay_in_advance: input.fetch("pay_in_advance", false), prorated: input.fetch("prorated", false),
        invoiceable: input.fetch("invoiceable", true))
      KitOraclePricing.apply_pricing_unit(w, charge, ctx.dec(input["pricing_unit_conversion_rate"])) if input["pricing_unit_conversion_rate"]
      sub = KitOraclePricing.subscription(w)
      mi = Fees::ChargeService::MeteredItem.from_charge(charge:, boundaries: KitOraclePricing.boundaries)
      options = Fees::ChargeService::Options.new(context: (ctx_name == "invoice") ? nil : ctx_name.to_sym)
      svc = Fees::ChargeService.new(invoice: nil, metered_item: mi, subscription: sub, options:)
      ar = ChargeModels::BaseService::Result.new
      ar.amount = ctx.dec(input.fetch("amount"))
      ar.unit_amount = ctx.dec(input.fetch("unit_amount"))
      ar.units = ctx.dec(input.fetch("units"))
      ar.full_units_number = KitOraclePricing.dec(ctx, input["full_units_number"])
      ar.current_usage_units = KitOraclePricing.dec(ctx, input["current_usage_units"])
      ar.total_aggregated_units = KitOraclePricing.dec(ctx, input["total_aggregated_units"])
      ar.count = input.fetch("events_count", 0)
      ar.amount_details = {}
      ar.grouped_by = nil
      fee = svc.send(:init_fee, ar, selected_metered_item: mi, adjusted: nil)
      out = KitOraclePricing.fee_out(fee)
      out.delete("amount_details")
      out["persisted"] = svc.send(:should_persist_fee?, fee, [fee])
      out["pay_in_advance"] = fee.pay_in_advance
      pu = KitOraclePricing.pricing_unit_out(fee.pricing_unit_usage)
      out["pricing_unit_usage"] = pu if pu
      out
    end
  end
end

# --- charge minimum true-up -------------------------------------------------------------------------------------

KitOracle.op("pricing.true_up") do |input, ctx|
  ctx.premium(true) do
    ctx.rollback do
      w = KitOraclePricing.world(input, timezone: input.fetch("timezone", "UTC"))
      charge = KitOraclePricing.charge(w, model: "standard", properties: {"amount" => "1"},
        min_amount_cents: input.fetch("min_amount_cents"))
      KitOraclePricing.apply_pricing_unit(w, charge, ctx.dec(input["pricing_unit_conversion_rate"])) if input["pricing_unit_conversion_rate"]
      sub = KitOraclePricing.subscription(w)
      if input.fetch("terminated_upgraded", false)
        # a real upgrade: the subscription is terminated and its successor is on a more expensive plan
        richer = FactoryBot.create(:plan, organization: w.organization, amount_cents: w.plan.amount_cents + 100_000,
          amount_currency: w.plan.amount_currency, interval: "monthly")
        sub.update!(status: :terminated, terminated_at: ctx.instant(input.fetch("charges_to")))
        FactoryBot.create(:subscription, customer: w.customer, plan: richer, organization: w.organization,
          external_id: "kit_sub", previous_subscription: sub, started_at: ctx.instant(input.fetch("charges_to")),
          status: :active)
        sub.reload
      end
      props = {
        "charges_from_datetime" => ctx.instant(input.fetch("charges_from")).iso8601(3),
        "charges_to_datetime" => ctx.instant(input.fetch("charges_to")).iso8601(3),
        "charges_duration" => input.fetch("charges_duration_days")
      }
      fee = Fee.new(organization: w.organization, billing_entity: w.customer.billing_entity, subscription: sub, charge:,
        fee_type: :charge, invoiceable: charge, amount_currency: w.plan.amount_currency, amount_cents: 0,
        precise_amount_cents: 0, units: 0, properties: props, payment_status: :pending)
      res = Fees::CreateTrueUpService.call(fee:, used_amount_cents: input.fetch("used_amount_cents"),
        used_precise_amount_cents: ctx.dec(input.fetch("used_precise_amount_cents")))
      tu = res.true_up_fee
      if tu.nil?
        {"fee" => nil}
      else
        out = KitOraclePricing.fee_out(tu)
        out.delete("amount_details")
        pu = KitOraclePricing.pricing_unit_out(tu.pricing_unit_usage)
        out["pricing_unit_usage"] = pu if pu
        {"fee" => out}
      end
    end
  end
end

# --- pricing units ----------------------------------------------------------------------------------------------

KitOracle.op("pricing.pricing_unit") do |input, ctx|
  pu = PricingUnit.new(short_name: "KC")
  apu = AppliedPricingUnit.new(pricing_unit: pu, conversion_rate: ctx.dec(input.fetch("conversion_rate")))
  usage = PricingUnitUsage.build_from_fiat_amounts(amount: ctx.dec(input.fetch("amount")),
    unit_amount: ctx.dec(input.fetch("unit_amount")), applied_pricing_unit: apu)
  fiat = usage.to_fiat_currency_cents(KitOraclePricing.currency(input))
  {
    "pricing_unit_usage" => KitOraclePricing.pricing_unit_out(usage).except("conversion_rate"),
    "fiat" => fiat.transform_keys(&:to_s)
  }
end

# --- validation, defaults, slicing ------------------------------------------------------------------------------

KitOracle.op("pricing.validate_properties") do |input, ctx|
  model = input.fetch("model")
  KitOraclePricing.check_model!(ctx, model)
  kind = input.fetch("kind", "charge")
  ctx.premium(input.fetch("premium", false)) do
    bm = BillableMetric.new(aggregation_type: input.fetch("metric_aggregation_type", "sum_agg"))
    props = KitOraclePricing.jsonb(input.fetch("properties"))
    chargeable = if kind == "fixed_charge"
      FixedCharge.new(charge_model: model, properties: props)
    else
      Charge.new(charge_model: model, properties: props, billable_metric: bm)
    end
    validator = ChargePropertiesValidation::PROPERTIES_VALIDATORS[model.to_sym] || Charges::Validators::BaseService
    v = validator.new(charge: chargeable)
    valid = v.valid?
    errors = valid ? {} : v.result.error.messages.transform_keys(&:to_s)
    chargeable.errors.clear
    chargeable.send(:validate_charge_model_properties, model)
    # The record's own validation run ends with ActiveRecord's duplicate-error removal (autosave callback), so the
    # record (and the API) lists each code once; apply the same step so property_messages is the record's list.
    chargeable.send(:_ensure_no_duplicate_errors) if chargeable.respond_to?(:_ensure_no_duplicate_errors, true)
    {"valid" => valid, "errors" => errors, "property_messages" => chargeable.errors[:properties]}
  end
end

KitOracle.op("pricing.validate_charge") do |input, ctx|
  model = input.fetch("model")
  kind = input.fetch("kind", "charge")
  ctx.premium(input.fetch("premium", false)) do
    ctx.rollback do
      metric = input.fetch("metric", {})
      w = KitOraclePricing.world(input, aggregation_type: metric.fetch("aggregation_type", "sum_agg"),
        recurring: metric.fetch("recurring", false))
      props = input.key?("properties") ? KitOraclePricing.jsonb(input["properties"]) :
        KitOraclePricing.jsonb(ChargeModels::BuildDefaultPropertiesService.call(model) || {})
      record = if kind == "fixed_charge"
        add_on = FactoryBot.create(:add_on, organization: w.organization)
        FixedCharge.new(organization: w.organization, plan: w.plan, add_on:, code: "kit_fixed", charge_model: model,
          properties: props, pay_in_advance: input.fetch("pay_in_advance", false),
          prorated: input.fetch("prorated", false), units: ctx.dec(input.fetch("units", "1")))
      else
        Charge.new(organization: w.organization, plan: w.plan, billable_metric: w.billable_metric, code: "kit_charge",
          charge_model: model, properties: props, pay_in_advance: input.fetch("pay_in_advance", false),
          prorated: input.fetch("prorated", false), invoiceable: input.fetch("invoiceable", true),
          regroup_paid_fees: input["regroup_paid_fees"], min_amount_cents: input.fetch("min_amount_cents", 0))
      end
      valid = record.valid?
      {"valid" => valid, "errors" => record.errors.messages.transform_keys(&:to_s).reject { |_, v| v.empty? }}
    rescue ArgumentError => e
      # enum assignment of an unknown model raises before validation
      ctx.domain_error!("value_is_invalid", "charge_model", e.message)
    end
  end
end

KitOracle.op("pricing.default_properties") do |input, ctx|
  {"properties" => KitOraclePricing.stored_json(ChargeModels::BuildDefaultPropertiesService.call(input.fetch("model")))}
end

KitOracle.op("pricing.filter_properties") do |input, ctx|
  model = input.fetch("model")
  kind = input.fetch("kind", "charge")
  bm = BillableMetric.new(aggregation_type: input.fetch("metric_aggregation_type", "sum_agg"))
  chargeable = (kind == "fixed_charge") ? FixedCharge.new(charge_model: model) : Charge.new(charge_model: model, billable_metric: bm)
  res = ChargeModels::FilterPropertiesService.call(chargeable:, properties: input.fetch("properties"))
  {"properties" => KitOraclePricing.stored_json(res.properties)}
end

# --- fixed charges ----------------------------------------------------------------------------------------------

module KitOraclePricing
  module_function

  def fixed_charge_world(input, ctx, model: "standard", properties: {"amount" => "1"}, pay_in_advance: false,
    prorated: false)
    w = world(input, timezone: input.fetch("timezone", "UTC"))
    add_on = FactoryBot.create(:add_on, organization: w.organization)
    fc = FixedCharge.new(organization: w.organization, plan: w.plan, add_on:, code: "kit_fixed", charge_model: model,
      properties:, pay_in_advance:, prorated:, units: 0)
    fc.save!(validate: false)
    started = input["subscription_started_at"] ? ctx.instant(input["subscription_started_at"]) : Time.zone.parse("2023-01-01T00:00:00Z")
    sub = subscription(w, started_at: started)
    base = Time.zone.parse("2020-01-01T00:00:00Z")
    Array(input["events"]).each do |e|
      FixedChargeEvent.create!(organization: w.organization, subscription: sub, fixed_charge: fc,
        units: ctx.dec(e.fetch("units")), timestamp: ctx.instant(e.fetch("timestamp")),
        created_at: base + e.fetch("created_seq").to_i.seconds, updated_at: base)
    end
    [w, fc, sub]
  end

  def fixed_window(input, ctx)
    win = input.fetch("window")
    {
      "fixed_charges_from_datetime" => ctx.instant(win.fetch("from")),
      "fixed_charges_to_datetime" => ctx.instant(win.fetch("to")),
      "fixed_charges_duration" => win.fetch("duration_days")
    }.with_indifferent_access
  end
end

KitOracle.op("pricing.fixed_charge_units") do |input, ctx|
  ctx.rollback do
    _w, fc, sub = KitOraclePricing.fixed_charge_world(input, ctx, prorated: input.fetch("prorated", false))
    bnd = KitOraclePricing.fixed_window(input, ctx)
    klass = input.fetch("prorated", false) ? FixedChargeEvents::Aggregations::ProratedAggregationService :
      FixedChargeEvents::Aggregations::SimpleAggregationService
    svc = klass.new(fixed_charge: fc, subscription: sub, boundaries: bnd)
    res = svc.call
    out = {"units" => res.aggregation, "full_units_number" => res.full_units_number}
    if input.fetch("prorated", false)
      pe = svc.per_event_aggregation
      out["per_event_full"] = pe.event_aggregation
      out["per_event_prorated"] = pe.event_prorated_aggregation
    end
    out
  end
end

KitOracle.op("pricing.fixed_charge_fee") do |input, ctx|
  model = input.fetch("model")
  KitOraclePricing.check_model!(ctx, model, %w[standard graduated volume])
  ctx.rollback do
    _w, fc, sub = KitOraclePricing.fixed_charge_world(input, ctx, model:, properties: KitOraclePricing.jsonb(input.fetch("properties")),
      prorated: input.fetch("prorated", false))
    bnd = KitOraclePricing.fixed_window(input, ctx)
    from = bnd["fixed_charges_from_datetime"]
    to = bnd["fixed_charges_to_datetime"]
    boundaries = BillingPeriodBoundaries.new(from_datetime: from, to_datetime: to, charges_from_datetime: from,
      charges_to_datetime: to, charges_duration: bnd["fixed_charges_duration"], timestamp: to + 1.second,
      fixed_charges_from_datetime: from, fixed_charges_to_datetime: to, fixed_charges_duration: bnd["fixed_charges_duration"])
    invoice = FactoryBot.create(:invoice, organization: sub.organization, customer: sub.customer, status: :draft,
      currency: sub.plan.amount_currency)
    svc = Fees::FixedChargeService.new(invoice:, fixed_charge: fc, subscription: sub, boundaries:, context: :invoice_preview)
    res = ctx.travel(input.fetch("now", "2030-01-01T00:00:00Z")) { svc.call }
    ctx.domain_error!("charge_model_error", nil, res.error.message) unless res.success?
    out = KitOraclePricing.fee_out(res.fee)
    out.delete("events_count")
    out["persisted"] = svc.send(:should_persist_fee?)
    out
  end
end

KitOracle.op("pricing.fixed_charge_in_advance") do |input, ctx|
  model = input.fetch("model")
  KitOraclePricing.check_model!(ctx, model, %w[standard graduated volume])
  ctx.rollback do
    _w, fc, sub = KitOraclePricing.fixed_charge_world(input, ctx, model:, properties: KitOraclePricing.jsonb(input.fetch("properties")),
      pay_in_advance: true, prorated: input.fetch("prorated", false))
    ts = ctx.instant(input.fetch("timestamp"))
    from = ctx.instant(input.fetch("fixed_charges_from"))
    to = ctx.instant(input.fetch("fixed_charges_to"))
    bnd = BillingPeriodBoundaries.new(from_datetime: from, to_datetime: to, charges_from_datetime: nil,
      charges_to_datetime: nil, fixed_charges_from_datetime: from, fixed_charges_to_datetime: to,
      timestamp: ts, charges_duration: nil, fixed_charges_duration: input.fetch("fixed_charges_duration_days"))
    already = ctx.dec(input.fetch("already_billed_units"))
    event = FixedChargeEvent.new(organization: sub.organization, subscription: sub, fixed_charge: fc,
      units: ctx.dec(input.fetch("new_units")), timestamp: ts)
    svc = Fees::BuildPayInAdvanceFixedChargeService.new(subscription: sub, fixed_charge: fc, fixed_charge_event: event,
      timestamp: ts.to_i)
    svc.define_singleton_method(:calculate_boundaries) { bnd }
    svc.define_singleton_method(:find_already_paid_units) { |_b| already }
    fee = svc.call.fee
    out = KitOraclePricing.fee_out(fee)
    out.delete("events_count")
    out.delete("amount_details")
    out
  end
end

# --- projection, estimates, simulator ---------------------------------------------------------------------------

KitOracle.op("pricing.projection") do |input, ctx|
  model = input.fetch("model")
  KitOraclePricing.check_model!(ctx, model)
  ctx.premium(input.fetch("premium", false)) do
    ctx.rollback do
      w = KitOraclePricing.world(input, timezone: input.fetch("timezone", "UTC"),
        recurring: input.fetch("recurring", false))
      charge = KitOraclePricing.charge(w, model:, properties: KitOraclePricing.jsonb(input.fetch("properties")),
        prorated: input.fetch("prorated", false))
      sub = KitOraclePricing.subscription(w)
      cur = input.fetch("current", {})
      fee = Fee.new(organization: w.organization, billing_entity: w.customer.billing_entity, subscription: sub, charge:,
        fee_type: :charge, invoiceable: charge, amount_currency: w.plan.amount_currency,
        amount_cents: cur.fetch("amount_cents", 0), precise_amount_cents: cur.fetch("amount_cents", 0),
        units: ctx.dec(cur.fetch("units", "0")), payment_status: :pending, grouped_by: {},
        properties: {"from_datetime" => ctx.instant(input.fetch("from")).iso8601(3),
                     "to_datetime" => ctx.instant(input.fetch("to")).iso8601(3),
                     "charges_duration" => input.fetch("charges_duration_days")})
      agg = KitOraclePricing.aggregation_result(ctx, input.fetch("aggregation"))
      agg.define_singleton_method(:success?) { true }
      svc = Fees::ProjectionService.new(fees: [fee])
      svc.define_singleton_method(:run_aggregation) { agg }
      res = ctx.travel(input.fetch("now")) { svc.call }
      ratio = ctx.travel(input.fetch("now")) { svc.send(:period_ratio) }
      {
        "period_ratio" => ratio,
        "projected_units" => res.projected_units,
        "projected_amount_cents" => res.projected_amount_cents
      }
    end
  end
end

KitOracle.op("pricing.estimate_instant") do |input, ctx|
  model = input.fetch("model")
  KitOraclePricing.check_model!(ctx, model, %w[standard percentage])
  ctx.rollback do
    metric = input.fetch("metric", {})
    w = KitOraclePricing.world(input, metric:, aggregation_type: metric.fetch("aggregation_type", "sum_agg"))
    charge = KitOraclePricing.charge(w, model:, properties: KitOraclePricing.jsonb(input.fetch("properties")),
      pay_in_advance: true)
    sub = KitOraclePricing.subscription(w)
    event = Events::Common.new(id: nil, organization_id: w.organization.id, external_subscription_id: "kit_sub",
      transaction_id: "kit_tx", timestamp: Time.zone.parse("2024-01-15T12:00:00Z"), code: w.billable_metric.code,
      properties: input.fetch("event_properties", {}), persisted: false)
    svc = Fees::EstimateInstant::BaseService.new(organization: w.organization, subscription: sub)
    h = svc.send(:estimate_charge_fees, charge, event)
    {
      "amount_cents" => h[:amount_cents],
      "precise_amount" => h[:precise_amount],
      "units" => h[:units],
      "precise_unit_amount" => h[:precise_unit_amount],
      "events_count" => h[:events_count]
    }
  end
end

KitOracle.op("pricing.simulate") do |input, ctx|
  model = input.fetch("model")
  KitOraclePricing.check_model!(ctx, model)
  ctx.premium(input.fetch("premium", false)) do
    ctx.rollback do
      w = KitOraclePricing.world(input, plan_amount_cents: input.fetch("plan_amount_cents", 0),
        aggregation_type: input.fetch("metric_aggregation_type", "sum_agg"))
      charge = KitOraclePricing.charge(w, model:, properties: KitOraclePricing.jsonb(input.fetch("properties")))
      res = Charges::CalculatePriceService.call(units: input.fetch("units"), charge:)
      {
        "charge_amount_cents" => res.charge_amount_cents,
        "subscription_amount_cents" => res.subscription_amount_cents,
        "total_amount_cents" => res.total_amount_cents
      }
    end
  end
end
