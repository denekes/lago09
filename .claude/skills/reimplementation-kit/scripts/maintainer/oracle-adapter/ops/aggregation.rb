# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/aggregation.rb — oracle ops of area `aggregation` (billing-engine-spec reference/04-aggregation-and-usage.md,
# BE-AG). Every op builds a throw-away tenant with FactoryBot inside ctx.rollback (organization, customer in the
# window's time zone, plan, billable metric, standard charge, subscription(s), events) and then calls the REAL
# lago-api code path:
#
#   aggregation.aggregate                  BillableMetrics::AggregationFactory -> <type>Service#aggregate (+ #per_event_aggregation;
#                                          charge_model "dynamic" adds the precise_total_amount_cents totals)
#   aggregation.in_advance_units           Charges::PayInAdvanceAggregationService (the pay-in-advance fee path)
#   aggregation.current_usage_in_advance   AggregationFactory with is_pay_in_advance + is_current_usage
#   aggregation.matching_and_ignored       ChargeFilters::MatchingAndIgnoredService (real charge filters + values)
#   aggregation.event_filter               ChargeFilters::EventMatchingService
#   aggregation.select_events              the event store's selection (Events::Stores::<store>#events) with
#                                          matching/ignored filters
#   aggregation.group_keys                 the event store's grouped count (group values as the store reads them)
#
# Metric code: input metric.code (schema default "kit_metric", METRIC_CODE); an event without `code` carries the
# metric's code (aggregation.aggregate schema).
#
# store "pg": events are Event rows (properties as the JSON request parser yields them; created_at = ingestion order).
# store "ch": events are inserted into ClickHouse events_enriched with the SAME column transform as the production
# materialized view (toDateTime64(timestamp, 3), JSONExtract(properties, 'Map(String, String)'), value; decimal_value,
# sorted_properties and enriched_at from the table defaults). ClickHouse work runs under
# $LAGO_SKILLS_CACHE/k7-state/ch.lock (CH-tagged spec suites truncate CH tables); one INSERT per event (rows written
# in one block would let the ReplacingMergeTree collapse duplicates at write time); the rows of the throw-away
# organization are deleted afterwards.
#
# Gotcha: FactoryBot sequences restart in every adapter process (organization slug "test-org-1", ...). Rows left in
# $ORACLE_DB by a direct `rspec` run of a `transaction: false` example make the first create fail with
# "Slug value_already_exist"; recreate the database (`oracle.sh db --reset`) after such runs.
#
# Input defaults applied here (schema defaults): store "pg"; window = DEFAULT_WINDOW for aggregate and
# in_advance_units; event transaction_id "e<n>" (1-based position in its list).

require "json"

module KitA4
  METRIC_CODE = "kit_metric"
  CREATED_BASE = Time.utc(2030, 1, 1)
  CH_LOCK = File.join(ENV.fetch("LAGO_SKILLS_CACHE", File.expand_path("~/.cache/lago-skills")), "k7-state", "ch.lock")
  AGG_TYPES = %w[count_agg sum_agg max_agg unique_count_agg weighted_sum_agg latest_agg].freeze
  # default window of aggregation.aggregate and aggregation.in_advance_units (schema default)
  DEFAULT_WINDOW = {"from" => "2024-03-01T00:00:00Z", "to" => "2024-03-31T23:59:59.999999Z"}.freeze

  class << self
    def install!
      return if @installed

      require "factory_bot"
      FactoryBot.find_definitions unless FactoryBot.factories.registered?(:organization)
      @installed = true
    end

    # ---- tenant -------------------------------------------------------------------------------------------------
    def tenant(ctx, store:, tz:, metric:, charge: {}, metric_filters: nil, deduplicate: false, charge_model: "standard")
      install!
      ctx.bad_input!("store must be pg|ch") unless %w[pg ch].include?(store)
      type = metric.fetch("aggregation_type")
      ctx.bad_input!("unsupported aggregation_type #{type}") unless AGG_TYPES.include?(type)

      org = FactoryBot.create(:organization, clickhouse_events_store: store == "ch",
        clickhouse_deduplication_enabled: deduplicate ? true : false)
      customer = FactoryBot.create(:customer, organization: org, timezone: tz || "UTC")
      plan = FactoryBot.create(:plan, organization: org, interval: "monthly", amount_cents: 1000)
      bm = BillableMetric.create!(
        organization: org, code: metric.fetch("code", METRIC_CODE), name: metric.fetch("code", METRIC_CODE), aggregation_type: type,
        field_name: (type == "count_agg") ? nil : metric.fetch("field_name", "value"),
        recurring: metric.fetch("recurring", false),
        rounding_function: metric["rounding_function"], rounding_precision: metric["rounding_precision"],
        weighted_interval: (type == "weighted_sum_agg") ? "seconds" : nil
      )
      Array(metric_filters).each do |key, values|
        BillableMetricFilter.create!(billable_metric: bm, organization: org, key:, values:)
      end
      bm.reload
      ctx.bad_input!("charge_model must be standard|dynamic") unless %w[standard dynamic].include?(charge_model)
      ch = FactoryBot.create(:standard_charge, organization: org, plan:, billable_metric: bm, charge_model:,
        pay_in_advance: charge.fetch("pay_in_advance", false), prorated: charge.fetch("prorated", false),
        invoiceable: true, properties: (charge_model == "dynamic") ? {} : {"amount" => "1"})
      {org:, customer:, plan:, metric: bm, charge: ch, store:}
    end

    # subscription: {external_id?, started_at, terminated_at?, upgraded?, previous?: {started_at, terminated_at}}
    def subscription(ctx, t, sub, default_start)
      ext = sub.fetch("external_id", "sub_1")
      started = sub["started_at"] ? ctx.instant(sub["started_at"]) : default_start
      prev = nil
      if (p = sub["previous"])
        prev = FactoryBot.create(:subscription, organization: t[:org], customer: t[:customer], plan: t[:plan],
          external_id: ext, status: :terminated, started_at: ctx.instant(p.fetch("started_at")),
          subscription_at: ctx.instant(p.fetch("started_at")), activated_at: ctx.instant(p.fetch("started_at")),
          terminated_at: ctx.instant(p.fetch("terminated_at")))
      end
      terminated = sub["terminated_at"] && ctx.instant(sub["terminated_at"])
      s = FactoryBot.create(:subscription, organization: t[:org], customer: t[:customer], plan: t[:plan],
        external_id: ext, status: terminated ? :terminated : :active, started_at: started,
        subscription_at: started, activated_at: started, terminated_at: terminated, previous_subscription: prev)
      if sub["upgraded"]
        ctx.bad_input!("upgraded needs terminated_at") unless terminated
        pricier = FactoryBot.create(:plan, organization: t[:org], interval: "monthly", amount_cents: 100_000)
        FactoryBot.create(:subscription, organization: t[:org], customer: t[:customer], plan: pricier,
          external_id: ext, status: :active, started_at: terminated, subscription_at: terminated,
          activated_at: terminated, previous_subscription: s)
        s.reload
      end
      s
    end

    # ---- events -------------------------------------------------------------------------------------------------
    def props_of(ctx, e)
      if e.key?("properties_json")
        ActiveSupport::JSON.decode(e["properties_json"])
      else
        e.fetch("properties", {})
      end
    end

    # The enriched `value` text the events-processor writes when a vector does not state it (events-processor-spec
    # EP-F1..F2, compat): "1" for count; strings verbatim; numbers read as binary64 and written with their shortest
    # digits, in exponent form d.ddde+XX when the decimal exponent is below -4 or at least 6 (1000000 -> "1e+06");
    # booleans as true/false; "<nil>" when missing or null. Objects and arrays are approximated by their JSON text
    # (the events-processor prints its own map/slice rendering; no vector relies on it).
    def enriched_value(t, e, props)
      return e["enriched_value"] if e.key?("enriched_value")
      return "1" if t[:metric].count_agg?

      v = props[t[:metric].field_name]
      case v
      when nil then "<nil>"
      when String then v
      when Integer, Float, BigDecimal then ep_number_text(v.to_f)
      when true, false then v.to_s
      else v.to_json
      end
    end

    def ep_number_text(f)
      return (1.0 / f).negative? ? "-0" : "0" if f.zero?

      sign = f.negative? ? "-" : ""
      _sign, digits, _base, exp = BigDecimal(f.abs.to_s).split # shortest round-trip digits, value = 0.digits * 10**exp
      e10 = exp - 1
      if e10 < -4 || e10 >= 6
        mantissa = (digits.length > 1) ? "#{digits[0]}.#{digits[1..]}" : digits
        "#{sign}#{mantissa}e#{e10.negative? ? "-" : "+"}#{format("%02d", e10.abs)}"
      elsif e10 >= 0
        int = digits[0, e10 + 1].ljust(e10 + 1, "0")
        frac = digits[(e10 + 1)..].to_s
        frac.empty? ? "#{sign}#{int}" : "#{sign}#{int}.#{frac}"
      else
        "#{sign}0.#{"0" * (-e10 - 1)}#{digits}"
      end
    end

    # Returns {transaction_id => persisted Event (pg) | Events::Common (ch)}.
    def insert_events(ctx, t, sub, events)
      Array(events).each_with_index.to_h do |e, i|
        props = props_of(ctx, e)
        ts = ctx.instant(e.fetch("timestamp"))
        seq = e.fetch("ingest_seq", i + 1)
        attrs = {organization_id: t[:org].id, code: e.fetch("code", t[:metric].code),
                 transaction_id: e.fetch("transaction_id") { "e#{i + 1}" },
                 external_subscription_id: e.fetch("external_subscription_id", sub.external_id),
                 timestamp: ts, properties: props}
        ptac = e["precise_total_amount_cents"] && ctx.dec(e["precise_total_amount_cents"])
        attrs[:precise_total_amount_cents] = ptac if ptac
        record = if t[:store] == "pg"
          ev = Event.create!(**attrs, created_at: CREATED_BASE + seq, updated_at: CREATED_BASE + seq)
          ev.discard! if e["deleted"]
          ev
        else
          ctx.bad_input!("deleted events are a pg-store input") if e["deleted"]
          (t[:ch_rows] ||= []) << {
            "organization_id" => attrs[:organization_id], "external_subscription_id" => attrs[:external_subscription_id].to_s,
            "code" => attrs[:code], "timestamp" => format("%d.%03d", ts.to_i, ts.nsec / 1_000_000),
            "transaction_id" => attrs[:transaction_id],
            "properties" => e.key?("properties_json") ? e["properties_json"] : JSON.generate(props),
            "value" => enriched_value(t, e, props), "precise_total_amount_cents" => ptac&.to_s("F"), "_seq" => seq
          }
          Events::Common.new(id: nil, **attrs)
        end
        [attrs[:transaction_id], record]
      end
    end

    def ch_execute(sql)
      Clickhouse::BaseRecord.connection.execute(sql)
    end

    # Insert the buffered rows in ingestion order (seq), ONE INSERT PER ROW (each row its own part, as separately
    # consumed Kafka batches would be: a single multi-row insert would let ReplacingMergeTree collapse duplicates
    # at write time), with exactly the column transform of the enriched materialized view.
    def flush_ch(t)
      rows = Array(t[:ch_rows]).sort_by { it["_seq"] }
      structure = "organization_id String, external_subscription_id String, code String, timestamp String, " \
        "transaction_id String, properties String, value Nullable(String), precise_total_amount_cents Nullable(Decimal(40, 15))"
      q = Clickhouse::BaseRecord.connection
      rows.each do |r|
        ch_execute(<<~SQL)
          INSERT INTO events_enriched (organization_id, external_subscription_id, transaction_id, timestamp, code, properties, value, precise_total_amount_cents)
          SELECT organization_id, external_subscription_id, transaction_id, toDateTime64(timestamp, 3), code,
                 JSONExtract(properties, 'Map(String, String)'), value, precise_total_amount_cents
          FROM format(JSONEachRow, #{q.quote(structure)}, #{q.quote(JSON.generate(r.except("_seq")))})
        SQL
      end
    end

    def ch_cleanup(t)
      ch_execute("DELETE FROM events_enriched WHERE organization_id = #{Clickhouse::BaseRecord.connection.quote(t[:org].id)}")
    rescue StandardError => e
      warn "[oracle aggregation] ch cleanup: #{e.class}: #{e.message[0, 160]}"
    end

    # Serialise ClickHouse work with the spec suites (they truncate CH tables). Non-blocking retries, max ~25 s.
    def with_ch_lock(store)
      return yield unless store == "ch"

      FileUtils.mkdir_p(File.dirname(CH_LOCK))
      File.open(CH_LOCK, File::RDWR | File::CREAT, 0o644) do |f|
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 25
        until f.flock(File::LOCK_EX | File::LOCK_NB)
          raise "ClickHouse lock busy (#{CH_LOCK})" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          sleep 0.2
        end
        begin
          yield
        ensure
          f.flock(File::LOCK_UN)
        end
      end
    end

    # Run the block inside the rollback and (store ch) the CH lock; the block stores its tenant in state[:t] so the
    # CH rows of that organization are deleted afterwards.
    def run(ctx, store)
      with_ch_lock(store) do
        ctx.rollback do
          state = {}
          begin
            yield state
          ensure
            ch_cleanup(state[:t]) if store == "ch" && state[:t]
          end
        end
      end
    end

    def window(ctx, w)
      from = ctx.instant(w.fetch("from"))
      to = ctx.instant(w.fetch("to"))
      dur = w["charges_duration_days"] || ((to.to_date - from.to_date).to_i + 1)
      [from, to, dur, w.fetch("timezone", "UTC")]
    end

    def metered_item(charge, from, to, dur)
      Fees::ChargeService::MeteredItem.from_charge(
        charge:,
        boundaries: BillingPeriodBoundaries.new(from_datetime: from, to_datetime: to, charges_from_datetime: from,
          charges_to_datetime: to, charges_duration: dur, timestamp: to)
      )
    end

    def cached!(ctx, t, sub, c, from)
      return unless c

      CachedAggregation.create!(
        organization_id: t[:org].id, external_subscription_id: sub.external_id, charge_id: t[:charge].id,
        event_transaction_id: c.fetch("event_transaction_id", "kit_cached"),
        timestamp: c["timestamp"] ? ctx.instant(c["timestamp"]) : from,
        current_aggregation: ctx.dec(c.fetch("current_aggregation")),
        max_aggregation: c["max_aggregation"] && ctx.dec(c["max_aggregation"]),
        max_aggregation_with_proration: c["max_aggregation_with_proration"] && ctx.dec(c["max_aggregation_with_proration"]),
        grouped_by: c.fetch("grouped_by", {})
      )
    end

    # ---- output -------------------------------------------------------------------------------------------------
    def d(ctx, v)
      return nil if v.nil?
      return ctx.dec_out(BigDecimal(v.to_s)) if v.is_a?(Float)

      ctx.dec_out(v)
    end

    def result_hash(ctx, r)
      h = {}
      %i[aggregation count current_usage_units full_units_number variation total_aggregated_units
        pay_in_advance_aggregation current_aggregation max_aggregation max_aggregation_with_proration
        units_applied precise_total_amount_cents pay_in_advance_precise_total_amount_cents].each do |k|
        v = r.public_send(k)
        h[k.to_s] = d(ctx, v) unless v.nil?
      end
      h["recurring_updated_at"] = ctx.instant_out(r.recurring_updated_at) if r.recurring_updated_at
      if r.options.is_a?(Hash) && r.options.key?(:running_total)
        h["running_total"] = Array(r.options[:running_total]).map { d(ctx, it) }
      end
      h["grouped_by"] = r.grouped_by.transform_keys(&:to_s) if r.grouped_by
      h
    end

    def breakdowns(ctx, list)
      Array(list).map { |b| {"groups" => b[:groups].transform_keys(&:to_s), "value" => d(ctx, b[:value])} }
    end
  end
end

# ---- aggregation.aggregate ----------------------------------------------------------------------------------------
KitOracle.op("aggregation.aggregate") do |input, ctx|
  store = input.fetch("store", "pg")
  from, to, dur, tz = KitA4.window(ctx, input.fetch("window", KitA4::DEFAULT_WINDOW))
  opts = input.fetch("options", {})
  KitA4.run(ctx, store) do |state|
    t = state[:t] = KitA4.tenant(ctx, store:, tz:, metric: input.fetch("metric"),
      charge: {"pay_in_advance" => opts.fetch("is_pay_in_advance", false), "prorated" => opts.fetch("prorated", false)},
      deduplicate: input.fetch("deduplicate", false), charge_model: input.fetch("charge_model", "standard"))
    sub = KitA4.subscription(ctx, t, input.fetch("subscription", {}), from)
    records = KitA4.insert_events(ctx, t, sub, input.fetch("events"))
    KitA4.flush_ch(t) if store == "ch"
    KitA4.cached!(ctx, t, sub, input["cached"], from)

    boundaries = {from_datetime: from, to_datetime: to, charges_duration: dur}
    filters = {charge_id: t[:charge].id}
    if (btx = input["boundary_transaction_id"])
      ev = records.fetch(btx) { ctx.bad_input!("boundary_transaction_id not among events") }
      filters[:event] = (store == "pg") ? Events::CommonFactory.new_instance(source: ev) : ev
      boundaries[:max_timestamp] = filters[:event].timestamp
    end
    filters[:grouped_by] = input["grouped_by"] if input["grouped_by"].present?
    filters[:grouped_by_values] = input["grouped_by_values"] if input["grouped_by_values"].present?
    filters[:presentation_by] = input["presentation_by"] if input["presentation_by"].present?
    filters[:matching_filters] = input["matching"] if input["matching"]
    filters[:ignored_filters] = input["ignored"] if input["ignored"]

    agg = BillableMetrics::AggregationFactory.new_instance(
      metered_item: KitA4.metered_item(t[:charge], from, to, dur),
      current_usage: opts.fetch("is_current_usage", false),
      context: Events::Stores::EventContext.from(subscription: sub),
      boundaries:, filters:, bypass_aggregation: opts.fetch("bypass", false)
    )
    agg_options = {
      free_units_per_events: opts.fetch("free_units_per_events", 0).to_i,
      free_units_per_total_aggregation: ctx.dec(opts.fetch("free_units_per_total_aggregation", "0")),
      is_current_usage: opts.fetch("is_current_usage", false),
      is_pay_in_advance: opts.fetch("is_pay_in_advance", false)
    }
    res = agg.aggregate(options: agg_options)
    ctx.domain_error!(res.error.code.to_s) if res.respond_to?(:failure?) && res.failure?

    out = KitA4.result_hash(ctx, res)
    out.delete("grouped_by") if input["grouped_by"].blank?
    if res.aggregations
      out["groups"] = res.aggregations.map { KitA4.result_hash(ctx, it) }
    end
    out["breakdowns"] = KitA4.breakdowns(ctx, res.breakdowns) unless res.breakdowns.nil?
    if opts["per_event"]
      pe = agg.per_event_aggregation(exclude_event: opts.fetch("exclude_event", false),
        include_event_value: false, grouped_by_values: input["grouped_by_values"].presence)
      out["per_event"] = Array(pe.event_aggregation).map { KitA4.d(ctx, it) }
      if pe.respond_to?(:event_prorated_aggregation)
        out["per_event_prorated"] = Array(pe.event_prorated_aggregation).map { KitA4.d(ctx, it) }
      end
    end
    out
  end
end

# ---- aggregation.in_advance_units ---------------------------------------------------------------------------------
# The units one pay-in-advance event adds, and the running state the reference caches after it.
KitOracle.op("aggregation.in_advance_units") do |input, ctx|
  store = input.fetch("store", "pg")
  from, to, dur, tz = KitA4.window(ctx, input.fetch("window", KitA4::DEFAULT_WINDOW))
  KitA4.run(ctx, store) do |state|
    metric = {"aggregation_type" => input.fetch("aggregation_type"), "field_name" => input.fetch("field_name", "value"),
              "recurring" => input.fetch("recurring", input.fetch("prorated", false))}
    t = state[:t] = KitA4.tenant(ctx, store:, tz:, metric:,
      charge: {"pay_in_advance" => true, "prorated" => input.fetch("prorated", false)})
    sub = KitA4.subscription(ctx, t, input.fetch("subscription", {}), from)
    ev_in = input.fetch("event")
    events = Array(input["prior_events"]) + [ev_in.merge("transaction_id" => ev_in.fetch("transaction_id", "kit_event"))]
    records = KitA4.insert_events(ctx, t, sub, events)
    KitA4.flush_ch(t) if store == "ch"
    KitA4.cached!(ctx, t, sub, input["cached"], from)

    event = records.fetch(ev_in.fetch("transaction_id", "kit_event"))
    event = Events::CommonFactory.new_instance(source: event) if store == "pg"
    boundaries = BillingPeriodBoundaries.new(from_datetime: from, to_datetime: to, charges_from_datetime: from,
      charges_to_datetime: to, charges_duration: dur, timestamp: event.timestamp)
    charge = t[:charge]
    if input["grouped_by"].present?
      charge.update!(properties: charge.properties.merge("pricing_group_keys" => input["grouped_by"]))
    end
    res = Charges::PayInAdvanceAggregationService.call!(charge:, boundaries:, properties: charge.properties, event:)
    out = {"units" => KitA4.d(ctx, res.pay_in_advance_aggregation)}
    nc = {}
    %i[current_aggregation max_aggregation max_aggregation_with_proration units_applied].each do |k|
      v = res.public_send(k)
      nc[k.to_s] = KitA4.d(ctx, v) unless v.nil?
    end
    out["new_cached"] = nc
    out["full_units_number"] = KitA4.d(ctx, res.full_units_number) unless res.full_units_number.nil?
    out
  end
end

# ---- aggregation.current_usage_in_advance -------------------------------------------------------------------------
# Current usage of a pay-in-advance charge: total of the period vs what the cache says was billed.
KitOracle.op("aggregation.current_usage_in_advance") do |input, ctx|
  type = input.fetch("aggregation_type", "sum_agg")
  ctx.bad_input!("current_usage_in_advance supports sum_agg") unless type == "sum_agg"
  from, to, dur, tz = KitA4.window(ctx, input.fetch("window", {"from" => "2024-03-01T00:00:00Z",
    "to" => "2024-03-31T23:59:59Z", "charges_duration_days" => 31}))
  KitA4.run(ctx, "pg") do |state|
    t = state[:t] = KitA4.tenant(ctx, store: "pg", tz:, metric: {"aggregation_type" => type, "field_name" => "value"},
      charge: {"pay_in_advance" => true})
    sub = KitA4.subscription(ctx, t, {}, from)
    total = ctx.dec(input.fetch("total"))
    KitA4.insert_events(ctx, t, sub, [{"transaction_id" => "kit_total", "timestamp" => ctx.instant_out(from + 3600),
                                       "properties" => {"value" => total.to_s("F")}}])
    KitA4.cached!(ctx, t, sub, input["cached"]&.merge("timestamp" => ctx.instant_out(from + 7200)), from)
    agg = BillableMetrics::AggregationFactory.new_instance(
      metered_item: KitA4.metered_item(t[:charge], from, to, dur), current_usage: true,
      context: Events::Stores::EventContext.from(subscription: sub),
      boundaries: {from_datetime: from, to_datetime: to, charges_duration: dur}, filters: {charge_id: t[:charge].id}
    )
    res = agg.aggregate(options: {free_units_per_events: 0, free_units_per_total_aggregation: BigDecimal(0),
                                  is_current_usage: true, is_pay_in_advance: true})
    {"aggregation" => KitA4.d(ctx, res.aggregation), "current_usage_units" => KitA4.d(ctx, res.current_usage_units)}
  end
end

# ---- charge-filter ops --------------------------------------------------------------------------------------------
module KitA4
  class << self
    # metric_filters: {key: [values]}; charge_filters: [{id, created_seq?, updated_seq?, values: {key: [v] | "ALL"}}]
    def charge_filters!(ctx, t, charge_filters)
      bm_filters = t[:metric].filters.index_by(&:key)
      Array(charge_filters).to_h do |cf|
        seq = cf.fetch("created_seq", 0)
        useq = cf.fetch("updated_seq", seq)
        filter = ChargeFilter.create!(charge: t[:charge], organization: t[:org], properties: {"amount" => "1"},
          created_at: CREATED_BASE + seq, updated_at: CREATED_BASE + useq)
        cf.fetch("values").each do |key, vals|
          bmf = bm_filters.fetch(key) { ctx.bad_input!("charge filter key #{key} is not a metric filter key") }
          values = (vals == "ALL") ? [ChargeFilterValue::ALL_FILTER_VALUES] : vals
          ChargeFilterValue.create!(charge_filter: filter, billable_metric_filter: bmf, organization: t[:org], values:,
            created_at: CREATED_BASE + seq, updated_at: CREATED_BASE + useq)
        end
        filter.update_columns(updated_at: CREATED_BASE + useq)
        [cf.fetch("id"), filter]
      end
    end

    def filter_tenant(ctx, input)
      tenant(ctx, store: "pg", tz: "UTC", metric: {"aggregation_type" => "count_agg"},
        metric_filters: input.fetch("metric_filters"))
    end
  end
end

KitOracle.op("aggregation.matching_and_ignored") do |input, ctx|
  KitA4.run(ctx, "pg") do |state|
    t = state[:t] = KitA4.filter_tenant(ctx, input)
    by_id = KitA4.charge_filters!(ctx, t, input.fetch("charge_filters"))
    charge = Charge.find(t[:charge].id)
    selected = input["selected"]
    filter = if selected.nil?
      ChargeFilter.new(charge:)
    else
      charge.filters.find(by_id.fetch(selected) { ctx.bad_input!("selected filter unknown") }.id)
    end
    r = ChargeFilters::MatchingAndIgnoredService.call(charge:, filter:)
    {"matching" => r.matching_filters.to_h { |k, v| [k.to_s, Array(v)] },
     "ignored" => r.ignored_filters.map { |h| h.to_h { |k, v| [k.to_s, Array(v)] } }}
  end
end

KitOracle.op("aggregation.event_filter") do |input, ctx|
  KitA4.run(ctx, "pg") do |state|
    t = state[:t] = KitA4.filter_tenant(ctx, input)
    by_id = KitA4.charge_filters!(ctx, t, input.fetch("charge_filters"))
    ids = by_id.to_h { |k, f| [f.id, k] }
    charge = Charge.find(t[:charge].id)
    event = Event.new(organization_id: t[:org].id, code: KitA4::METRIC_CODE, transaction_id: "kit_event",
      timestamp: Time.current, properties: ActiveSupport::JSON.decode(input.fetch("properties_json")))
    r = ChargeFilters::EventMatchingService.call(charge:, event:)
    {"filter_id" => r.charge_filter && ids.fetch(r.charge_filter.id),
     "matching_filter_ids" => Array(r.matching_charge_filters).map { ids.fetch(it.id) }}
  end
end

# Events selected by matching / ignored filters (count store query over the window), per store.
KitOracle.op("aggregation.select_events") do |input, ctx|
  store = input.fetch("store", "pg")
  KitA4.run(ctx, store) do |state|
    t = state[:t] = KitA4.tenant(ctx, store:, tz: "UTC", metric: {"aggregation_type" => "count_agg"})
    sub = KitA4.subscription(ctx, t, {}, ctx.instant("2024-01-01T00:00:00Z"))
    events = input.fetch("events").each_with_index.map do |e, i|
      {"transaction_id" => e.fetch("transaction_id"), "timestamp" => format("2024-01-15T00:00:%02dZ", i % 60)}.merge(e)
    end
    KitA4.insert_events(ctx, t, sub, events)
    KitA4.flush_ch(t) if store == "ch"
    klass = (store == "pg") ? Events::Stores::PostgresStore : Events::Stores::ClickhouseStore
    es = klass.new(code: KitA4::METRIC_CODE, context: Events::Stores::EventContext.from(subscription: sub),
      boundaries: {from_datetime: ctx.instant("2024-01-01T00:00:00Z"), to_datetime: ctx.instant("2024-01-31T23:59:59Z")},
      filters: {matching_filters: input.fetch("matching"), ignored_filters: input.fetch("ignored")})
    ids = (store == "pg") ? es.events.pluck(:transaction_id) : es.events.pluck("events_enriched.transaction_id")
    {"transaction_ids" => ids.sort}
  end
end

# Group values an event falls into for grouping keys, as the store reads them (count grouped by the keys).
KitOracle.op("aggregation.group_keys") do |input, ctx|
  store = input.fetch("store", "pg")
  KitA4.run(ctx, store) do |state|
    t = state[:t] = KitA4.tenant(ctx, store:, tz: "UTC", metric: {"aggregation_type" => "count_agg"})
    sub = KitA4.subscription(ctx, t, {}, ctx.instant("2024-01-01T00:00:00Z"))
    KitA4.insert_events(ctx, t, sub, [{"transaction_id" => "kit_event", "timestamp" => "2024-01-15T00:00:00Z",
                                       "properties_json" => input.fetch("properties_json")}])
    KitA4.flush_ch(t) if store == "ch"
    klass = (store == "pg") ? Events::Stores::PostgresStore : Events::Stores::ClickhouseStore
    es = klass.new(code: KitA4::METRIC_CODE, context: Events::Stores::EventContext.from(subscription: sub),
      boundaries: {from_datetime: ctx.instant("2024-01-01T00:00:00Z"), to_datetime: ctx.instant("2024-01-31T23:59:59Z")},
      filters: {grouped_by: input.fetch("grouped_by")})
    groups = es.grouped_count
    ctx.bad_input!("expected one group, got #{groups.size}") unless groups.size == 1
    {"grouped_by" => groups.first.groups.transform_keys(&:to_s)}
  end
end
