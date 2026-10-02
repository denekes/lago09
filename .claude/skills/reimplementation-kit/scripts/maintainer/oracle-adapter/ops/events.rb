# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/events.rb — oracle ops of area `events` (billing-engine-spec reference/02-events-ingestion.md, BE-EV).
#
# Every op drives the REAL public endpoint in-process (POST /api/v1/events, POST /api/v1/events/batch) through
# ActionDispatch::Integration::Session — request parsing, parameter filtering, services, model validations, the
# unique index, rendering — inside ctx.rollback (primary + events connections, always rolled back). Nothing is
# re-typed: the outputs are read back from the response, from the persisted row, or from the captured raw-topic
# message. An exception that escapes the application is reported as http_status 500 (what production renders).
#
# Also defines KitA3, the helper shared with ops/expression.rb (loaded after this file, file-name order).

require "json"
require "open3"

module KitA3
  RAW_TOPIC = "events-raw"

  # Transparent capture hooks: remember the last service result / expression value of this thread.
  module CreateHook
    def call(...)
      r = super
      Thread.current[:kit_a3_result] = r
      r
    end
  end

  module ExpressionHook
    def evaluate(*args)
      r = super
      Thread.current[:kit_a3_expr] = r
      r
    end
  end

  # Swap the raw-topic producer only while a capture is active.
  module ProducerHook
    def producer
      Thread.current[:kit_a3_producer] || super
    end
  end

  class FakeProducer
    attr_reader :messages

    def initialize = (@messages = [])
    def produce_many_async(msgs) = @messages.concat(msgs)
    def produce_async(msg) = @messages << msg
  end

  class << self
    def install!
      return if @installed

      require "factory_bot"
      FactoryBot.find_definitions unless FactoryBot.factories.registered?(:organization)
      Events::CreateService.prepend(CreateHook)
      Events::CreateBatchService.prepend(CreateHook)
      BillableMetrics::EvaluateExpressionService.prepend(CreateHook)
      Lago::Expression.prepend(ExpressionHook)
      Karafka.singleton_class.prepend(ProducerHook)
      @installed = true
    end

    def org(store:, id: nil)
      install!
      attrs = {clickhouse_events_store: store == "ch"}
      attrs[:id] = id if id
      FactoryBot.create(:organization, **attrs)
    end

    # metrics: [{code, aggregation_type?, field_name?, expression?, deleted?}]
    def seed_metrics(org, metrics)
      Array(metrics).each do |m|
        type = m.fetch("aggregation_type", "sum_agg")
        attrs = {organization: org, code: m.fetch("code"), name: m.fetch("code"), aggregation_type: type,
                 field_name: (type == "count_agg") ? nil : m.fetch("field_name", "value"),
                 expression: m["expression"]}
        attrs[:weighted_interval] = "seconds" if type == "weighted_sum_agg"
        bm = BillableMetric.create!(**attrs)
        bm.discard! if m["deleted"]
      end
    end

    # existing: [{transaction_id, external_subscription_id?, code?, timestamp?, deleted?}] (stored before the call)
    def seed_events(org, existing)
      Array(existing).each do |e|
        ev = Event.create!(organization_id: org.id, transaction_id: e.fetch("transaction_id"),
          external_subscription_id: e["external_subscription_id"], code: e.fetch("code", "kit_code"),
          timestamp: e["timestamp"] ? Time.zone.parse(e["timestamp"]) : Time.zone.parse("2026-01-01T00:00:00Z"),
          properties: {})
        ev.discard! if e["deleted"]
      end
    end

    # One HTTP request against the full application; returns [status, parsed body or nil].
    # The audit/activity-log side channel (out of scope) is switched off for the request: with the CI-like env of
    # oracle.sh it would start a real Kafka producer towards a broker that does not exist (slow adapter exit).
    AUDIT_ENV = %w[LAGO_KAFKA_API_LOGS_TOPIC LAGO_KAFKA_ACTIVITY_LOGS_TOPIC].freeze

    def post(org, path, body_text)
      saved = AUDIT_ENV.to_h { |k| [k, ENV.delete(k)] }
      session = ActionDispatch::Integration::Session.new(Rails.application)
      session.post(path, params: body_text, headers: {
        "Content-Type" => "application/json", "Accept" => "application/json",
        "Authorization" => "Bearer #{org.api_keys.first.value}"
      })
      body = session.response.body
      [session.response.status, body.to_s.empty? ? nil : JSON.parse(body)]
    rescue StandardError => e # escaped the application: production renders a 500
      warn "[oracle events] unhandled #{e.class}: #{e.message[0, 200]}"
      [500, nil]
    ensure
      saved&.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    end

    def at(ctx, instant, &)
      instant ? ctx.travel(instant, &) : yield
    end

    # A JSON number with its exact text (JSON.parse decimal_class): emitted back verbatim.
    class Num
      attr_reader :text

      def initialize(text) = (@text = text)
    end

    # A JSON value in its wire form, numbers kept as JSON numbers with their exact text (the adapter's generic
    # normalisation would turn non-integer numbers into strings and lose the number/string distinction).
    def wire(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = wire(v) }
      when Array then obj.map { |v| wire(v) }
      when Num then JSON::Fragment.new(obj.text)
      when Float then JSON::Fragment.new(JSON.generate(obj))
      else obj
      end
    end

    def parse_exact(text) = JSON.parse(text, decimal_class: Num)

    # properties as persisted (pg: the stored JSON document read back exactly) or as published (ch: the in-memory
    # properties serialised exactly as the reference serialises them into the raw message).
    def stored_properties(ev)
      if ev.id
        text = EventsRecord.connection.select_value(
          EventsRecord.sanitize_sql(["SELECT properties::text FROM events WHERE id = ?", ev.id]))
        wire(parse_exact(text))
      else
        wire(parse_exact(ev.properties.to_json))
      end
    end

    def stored(ev)
      props = stored_properties(ev)
      ev = Event.unscoped.find(ev.id) if ev.id
      {"transaction_id" => ev.transaction_id, "code" => ev.code,
       "external_subscription_id" => ev.external_subscription_id, "timestamp" => ev.timestamp,
       "properties" => props,
       "precise_total_amount_cents" => ev.precise_total_amount_cents}
    end

    # Run a block with the raw-topic producer captured; returns [block value, messages].
    def capture_raw
      fake = FakeProducer.new
      old = ENV["LAGO_KAFKA_RAW_EVENTS_TOPIC"]
      ENV["LAGO_KAFKA_RAW_EVENTS_TOPIC"] = RAW_TOPIC
      Thread.current[:kit_a3_producer] = fake
      [yield, fake.messages]
    ensure
      ENV["LAGO_KAFKA_RAW_EVENTS_TOPIC"] = old
      Thread.current[:kit_a3_producer] = nil
    end

    # Temporarily emulate LAGO_EVENTS_BATCH_MAX_LENGTH=n (the reference reads it once at boot into a constant).
    def with_max_length(n)
      return yield if n.nil?

      klass = Events::CreateBatchService
      old = klass::MAX_LENGTH
      klass.send(:remove_const, :MAX_LENGTH)
      klass.const_set(:MAX_LENGTH, Integer(n))
      yield
    ensure
      if n
        klass.send(:remove_const, :MAX_LENGTH)
        klass.const_set(:MAX_LENGTH, old)
      end
    end

    def response_out(status, body)
      out = {"ok" => status == 200, "http_status" => status}
      out["error_details"] = body["error_details"] if body.is_a?(Hash) && body.key?("error_details")
      out
    end

    # The events-processor's expression engine (libexpression_go, lago-expression v0.2.0 as built by the
    # events-processor Dockerfile), called in a SUBPROCESS: the engine aborts the process on some inputs.
    PY_ENGINE = <<~PY
      import ctypes, json, sys
      lib = ctypes.CDLL(sys.argv[1])
      lib.evaluate.restype = ctypes.c_void_p
      lib.evaluate.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
      lib.free_evaluate.argtypes = [ctypes.c_void_p]
      expr, event_json = json.load(sys.stdin)
      p = lib.evaluate(expr.encode(), event_json.encode())
      if not p:
          print(json.dumps({"result": None}))
      else:
          s = ctypes.cast(p, ctypes.c_char_p).value.decode()
          lib.free_evaluate(p)
          print(json.dumps({"result": s}))
    PY

    def engine_so
      so = ENV["ORACLE_EXPRESSION_GO_SO"] ||
        File.join(ENV.fetch("LAGO_SKILLS_CACHE", File.join(Dir.home, ".cache/lago-skills")),
          "lago-expression-v0.2.0/target/release/libexpression_go.so")
      raise KitOracle::BadInput, "events-processor expression engine not found: #{so} (set ORACLE_EXPRESSION_GO_SO)" unless File.exist?(so)

      so
    end

    # => [:ok, string] | [:null] | [:aborted, signal]
    def engine_eval(expression, event_json)
      out, err, st = Open3.capture3("python3", "-c", PY_ENGINE, engine_so,
        stdin_data: JSON.generate([expression, event_json]))
      return [:aborted, st.termsig] if st.signaled?
      raise "engine helper failed (#{st.exitstatus}): #{err[-300..]}" unless st.success?

      r = JSON.parse(out)["result"]
      r.nil? ? [:null] : [:ok, r]
    end
  end
end

# --- events.parse_timestamp --------------------------------------------------------------------------------------
# Body {"event":{transaction_id, code, external_subscription_id[, "timestamp": <timestamp_json verbatim>]}} at the
# frozen clock received_at; output = the event time as persisted (PG store).
KitOracle.op("events.parse_timestamp") do |input, ctx|
  ts = input["timestamp_json"]
  member = ts.nil? ? "" : %(,"timestamp":#{ts})
  body = %({"event":{"transaction_id":"kit-ts","code":"kit_code","external_subscription_id":"kit-sub"#{member}}})
  ctx.rollback do
    org = KitA3.org(store: "pg")
    status, json = KitA3.at(ctx, input.fetch("received_at")) { KitA3.post(org, "/api/v1/events", body) }
    case status
    when 200
      {"timestamp" => Event.find_by!(organization_id: org.id, transaction_id: "kit-ts").timestamp}
    when 422
      details = json && json["error_details"]
      ctx.domain_error!("invalid_format", "timestamp") if details == {"timestamp" => ["invalid_format"]}
      raise "unexpected 422 body #{json.inspect}"
    else
      raise "unexpected HTTP #{status} #{json.inspect}"
    end
  end
end

# --- events.validate ---------------------------------------------------------------------------------------------
KitOracle.op("events.validate") do |input, ctx|
  ctx.rollback do
    org = KitA3.org(store: input.fetch("store"))
    KitA3.seed_metrics(org, input["metrics"])
    KitA3.seed_events(org, input["existing"])
    Thread.current[:kit_a3_result] = nil
    body = JSON.generate({"event" => input.fetch("event")})
    status, json = KitA3.at(ctx, input.fetch("received_at")) { KitA3.post(org, "/api/v1/events", body) }
    out = KitA3.response_out(status, json)
    if status == 200
      ev = Thread.current[:kit_a3_result].event
      out["persisted"] = ev.persisted?
      out["stored_event"] = KitA3.stored(ev)
      out["echo_timestamp"] = json.dig("event", "timestamp")
    end
    out
  end
end

# --- events.validate_batch ---------------------------------------------------------------------------------------
KitOracle.op("events.validate_batch") do |input, ctx|
  ctx.rollback do
    org = KitA3.org(store: input.fetch("store"))
    KitA3.seed_metrics(org, input["metrics"])
    KitA3.seed_events(org, input["existing"])
    Thread.current[:kit_a3_result] = nil
    body = input.key?("events") ? JSON.generate({"events" => input["events"]}) : "{}"
    status, json = KitA3.with_max_length(input["max_length"]) do
      KitA3.at(ctx, input.fetch("received_at")) { KitA3.post(org, "/api/v1/events/batch", body) }
    end
    out = KitA3.response_out(status, json)
    if status == 200
      events = Thread.current[:kit_a3_result].events
      out["persisted"] = events.map { |e| !e.id.nil? }
      out["stored_events"] = events.map { |e| KitA3.stored(e) }
    end
    out
  end
end

# --- events.raw_message ------------------------------------------------------------------------------------------
# The message published on the raw topic for one accepted event (POST /api/v1/events at ingested_at).
KitOracle.op("events.raw_message") do |input, ctx|
  ctx.rollback do
    org = KitA3.org(store: input.fetch("store"), id: input.fetch("organization_id"))
    KitA3.seed_metrics(org, input["metrics"])
    body = JSON.generate({"event" => input.fetch("event")})
    (status, json), messages = KitA3.capture_raw do
      KitA3.at(ctx, input.fetch("ingested_at")) { KitA3.post(org, "/api/v1/events", body) }
    end
    raise "event not accepted: HTTP #{status} #{json.inspect}" unless status == 200
    raise "expected exactly one raw message, got #{messages.size}" unless messages.size == 1

    msg = messages.first
    {"topic" => msg[:topic], "has_key" => msg.key?(:key),
     "message" => KitA3.wire(KitA3.parse_exact(msg[:payload]))}
  end
end

# --- events.duplicate_key ----------------------------------------------------------------------------------------
# Executable definition of the ingestion idempotency key: store `event`, then re-send it (a) unchanged and (b) with
# one field changed at a time; the key is the set of fields whose change lets the repeat through. null = an
# unchanged repeat is accepted (no idempotency).
KitOracle.op("events.duplicate_key") do |input, ctx|
  base = input.fetch("event")
  variants = {
    "transaction_id" => ->(e) { e.merge("transaction_id" => "#{e["transaction_id"]}-other") },
    "external_subscription_id" => ->(e) { e.merge("external_subscription_id" => "#{e["external_subscription_id"]}-other") },
    "code" => ->(e) { e.merge("code" => "#{e["code"]}_other") },
    "timestamp" => ->(e) { e.merge("timestamp" => (BigDecimal(e.fetch("timestamp").to_s) + 1).to_s("F")) },
    "properties" => ->(e) { e.merge("properties" => (e["properties"] || {}).merge("kit_other" => "1")) },
    "precise_total_amount_cents" => ->(e) { e.merge("precise_total_amount_cents" => "4242") }
  }
  ctx.rollback do
    org = KitA3.org(store: input.fetch("store"))
    send_one = lambda do |ev|
      status, = KitA3.at(ctx, input.fetch("received_at")) do
        KitA3.post(org, "/api/v1/events", JSON.generate({"event" => ev}))
      end
      status
    end
    probe = lambda do |ev|
      status = nil
      EventsRecord.transaction(requires_new: true) do
        status = send_one.call(ev)
        raise ActiveRecord::Rollback
      end
      status
    end
    first = send_one.call(base)
    raise "base event not accepted (HTTP #{first})" unless first == 200

    if probe.call(base) == 200
      {"key_fields" => nil}
    else
      {"key_fields" => variants.select { |_f, change| probe.call(change.call(base)) == 200 }.keys.sort}
    end
  end
end
