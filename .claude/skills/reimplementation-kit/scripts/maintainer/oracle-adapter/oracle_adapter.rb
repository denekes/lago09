# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# oracle_adapter.rb — answers the kit adapter protocol v1 (JSON lines on stdin/stdout) with lago-api code at the pin.
# Started by `oracle.sh adapter` as `bundle exec rails runner <this file>` in RAILS_ENV=test against $ORACLE_DB.
#
# Op modules: every *.rb file in $ORACLE_OPS_DIR (default ./ops next to this file) is loaded after the built-ins, in
# file-name order, and registers handlers with
#
#     KitOracle.op("pricing.charge_model") do |input, ctx|
#       ...                      # call the real lago-api code
#       {"amount" => ctx.dec_out(amount)}      # Hash = output
#     end
#
# A later registration of the same op replaces an earlier one (area modules override the built-ins below).
# A handler signals a DOMAIN error with ctx.domain_error!(code, field), an unsupported input shape with
# ctx.bad_input!(msg). Any other exception becomes protocol error "internal" (message + first backtrace lines go
# to stderr). Output values are normalised before encoding: BigDecimal -> canonical decimal string, Time/DateTime/
# TimeWithZone -> UTC instant "...Z", Date -> "YYYY-MM-DD", Symbol -> String, Float -> shortest decimal string.
#
# Isolation helpers (ctx): rollback { } (primary + events connections, always rolled back), travel(instant) { },
# premium(flag) { }. After every call the adapter travels back, resets the premium flag and clears enqueued jobs.
# stdout is reserved for protocol lines: the real STDOUT is duplicated once and $stdout/STDOUT point at stderr.

require "json"
require "bigdecimal"
require "active_support/testing/time_helpers"

PROTO_OUT = STDOUT.dup
PROTO_OUT.sync = true
STDOUT.reopen(STDERR)
$stdout = STDERR

module KitOracle
  PROTO = 1
  IMPL = "lago-api-oracle"
  PIN = ENV.fetch("ORACLE_PIN", "591ae9005110")
  @handlers = {}
  @sources = {}

  class DomainError < StandardError
    attr_reader :code, :field

    def initialize(code, field = nil, message = nil)
      @code = code.to_s
      @field = field&.to_s
      super(message || code.to_s)
    end
  end

  class BadInput < StandardError; end

  class << self
    attr_reader :handlers, :sources

    def op(name, &block)
      raise ArgumentError, "op name must be <area>.<op>: #{name}" unless name.to_s.match?(/\A[a-z_]+\.[a-z0-9_]+\z/)

      @handlers[name.to_s] = block
      @sources[name.to_s] = caller_locations(1, 1).first&.path.to_s
    end
  end

  # Canonical encodings shared by every module ---------------------------------------------------------------
  module Codec
    extend self

    def dec(value)
      case value
      when nil then nil
      when BigDecimal then value
      when Integer then BigDecimal(value)
      when Float then BigDecimal(value.to_s)
      when String
        raise BadInput, "not a decimal: #{value.inspect}" unless value.match?(/\A-?\d+(\.\d+)?([eE][-+]?\d+)?\z/)

        BigDecimal(value)
      else raise BadInput, "not a decimal: #{value.inspect}"
      end
    end

    def dec_out(value)
      d = dec(value)
      return nil if d.nil?

      s = d.to_s("F")
      s = s.sub(/\.0\z/, "") if d.frac.zero?
      s == "-0" ? "0" : s
    end

    def instant(value)
      return value if value.is_a?(ActiveSupport::TimeWithZone)
      raise BadInput, "instant must be a string with a zone: #{value.inspect}" unless value.is_a?(String) &&
        value.match?(/\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d{1,9})?(Z|[+-]\d{2}:\d{2})\z/)

      Time.zone.parse(value)
    end

    def instant_out(value)
      t = value.respond_to?(:utc) ? value.utc : value
      frac = t.respond_to?(:nsec) ? t.nsec : 0
      if frac.zero?
        t.strftime("%Y-%m-%dT%H:%M:%SZ")
      else
        digits = format("%09d", frac).sub(/0+\z/, "")
        t.strftime("%Y-%m-%dT%H:%M:%S.") + digits + "Z"
      end
    end

    def normalize(obj)
      case obj
      when Hash then obj.each_with_object({}) { |(k, v), h| h[k.to_s] = normalize(v) }
      when Array then obj.map { |v| normalize(v) }
      when BigDecimal then dec_out(obj)
      when Float
        raise BadInput, "non-finite float in output" unless obj.finite?

        s = obj.to_s
        s.match?(/[eE]/) ? BigDecimal(s).to_s("F") : s
      when ActiveSupport::TimeWithZone, Time, DateTime then instant_out(obj)
      when Date then obj.iso8601
      when Symbol then obj.to_s
      else obj
      end
    end
  end

  class Ctx
    include ActiveSupport::Testing::TimeHelpers
    include Codec

    attr_reader :call_id, :profile, :line

    def initialize(call_id:, profile:, line:)
      @call_id = call_id
      @profile = profile
      @line = line
    end

    # The request re-parsed with every JSON number as BigDecimal (exact decimals for payload fields).
    def input_decimal
      @input_decimal ||= JSON.parse(line, decimal_class: BigDecimal).fetch("input")
    end

    def domain_error!(code, field = nil, message = nil)
      raise DomainError.new(code, field, message)
    end

    def bad_input!(message)
      raise BadInput, message
    end

    def rollback
      result = nil
      ApplicationRecord.transaction(requires_new: true) do
        EventsRecord.transaction(requires_new: true) do
          result = yield
          raise ActiveRecord::Rollback
        end
        raise ActiveRecord::Rollback
      end
      result
    end

    def travel(at, &)
      travel_to(at.is_a?(String) ? instant(at) : at, &)
    end

    def premium(flag = true)
      License.instance_variable_set(:@premium, flag ? true : false)
      yield
    ensure
      License.instance_variable_set(:@premium, false)
    end

    def reset!
      travel_back
      License.instance_variable_set(:@premium, false)
      adapter = ActiveJob::Base.queue_adapter
      adapter.enqueued_jobs.clear if adapter.respond_to?(:enqueued_jobs)
      adapter.performed_jobs.clear if adapter.respond_to?(:performed_jobs)
    end
  end
end

# Built-in ops (area modules may replace them) -------------------------------------------------------------------

# Whole local days between two instants in a zone (DST-aware), optionally for a subscription terminated by upgrade.
KitOracle.op("domain.days_between") do |input, ctx|
  from = ctx.instant(input.fetch("from"))
  to = ctx.instant(input.fetch("to"))
  tz = input.fetch("timezone")
  if input["terminated_upgraded"]
    probe = Class.new do
      include BillingPeriodDateDiff

      def initialize(tz) = (@tz = tz)
      def customer = Struct.new(:applicable_timezone).new(@tz)
      def terminated? = true
      def upgraded? = true
    end
    {"days" => probe.new(tz).date_diff_with_timezone(from, to)}
  else
    {"days" => Utils::Datetime.date_diff_with_timezone(from, to, tz)}
  end
end

# Billable-metric style rounding of a decimal (round = half away from zero, ceil, floor) at a precision.
KitOracle.op("domain.round") do |input, ctx|
  mode = input.fetch("mode")
  ctx.bad_input!("mode must be round|ceil|floor") unless %w[round ceil floor].include?(mode)
  metric = BillableMetric.new(rounding_function: mode, rounding_precision: input["precision"])
  units = ctx.dec(input.fetch("value"))
  result = BillableMetrics::Aggregations::ApplyRoundingService.call(billable_metric: metric, units:)
  {"value" => ctx.dec_out(result.units)}
end

ops_dir = ENV.fetch("ORACLE_OPS_DIR", File.join(__dir__, "ops"))
Dir[File.join(ops_dir, "*.rb")].sort.each { |f| load f }

# Protocol loop --------------------------------------------------------------------------------------------------
module KitOracle
  module Loop
    module_function

    def send_line(obj)
      PROTO_OUT.write(JSON.generate(obj) + "\n")
      PROTO_OUT.flush
    end

    def run
      STDIN.each_line do |line|
        line = line.strip
        next if line.empty?

        msg = begin
          JSON.parse(line)
        rescue JSON::ParserError => e
          warn "[oracle] unparsable request: #{e.message}"
          next
        end
        case msg["type"]
        when "hello" then hello(msg)
        when "call" then call(msg, line)
        when "bye" then break
        else warn "[oracle] unknown message type #{msg["type"].inspect}"
        end
      end
      0
    end

    def hello(msg)
      if msg["proto"] != PROTO
        warn "[oracle] protocol mismatch: runner #{msg["proto"]}, adapter #{PROTO}"
      end
      send_line(
        "type" => "hello", "proto" => PROTO, "impl" => IMPL,
        "impl_version" => "lago-api@#{PIN} ruby-#{RUBY_VERSION}",
        "profiles" => ["compat"], "ops" => KitOracle.handlers.keys.sort
      )
    end

    def call(msg, line)
      id = msg["id"]
      name = "#{msg["area"]}.#{msg["op"]}"
      handler = KitOracle.handlers[name]
      return send_line("type" => "result", "id" => id, "error" => {"code" => "unsupported_op", "message" => name}) unless handler

      ctx = Ctx.new(call_id: id, profile: msg["profile"], line:)
      begin
        out = handler.call(msg.fetch("input"), ctx)
        raise BadInput, "handler returned #{out.class}, expected Hash" unless out.is_a?(Hash)

        send_line("type" => "result", "id" => id, "output" => Codec.normalize(out))
      rescue DomainError => e
        err = {"code" => e.code}
        err["field"] = e.field if e.field
        err["message"] = e.message if e.message != e.code
        send_line("type" => "result", "id" => id, "error" => err)
      rescue BadInput, KeyError => e
        send_line("type" => "result", "id" => id, "error" => {"code" => "bad_input", "message" => e.message})
      rescue Exception => e # rubocop:disable Lint/RescueException
        warn "[oracle] #{name} #{id}: #{e.class}: #{e.message}\n  #{Array(e.backtrace).first(5).join("\n  ")}"
        send_line("type" => "result", "id" => id,
          "error" => {"code" => "internal", "message" => "#{e.class}: #{e.message}"[0, 500]})
      ensure
        ctx.reset!
      end
    end
  end
end

exit(KitOracle::Loop.run)
