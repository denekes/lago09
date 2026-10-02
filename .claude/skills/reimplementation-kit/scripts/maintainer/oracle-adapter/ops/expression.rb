# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/expression.rb — oracle op `expression.evaluate` (billing-engine-spec reference/03-expression-language.md,
# BE-EX). Three surfaces, selected by input.mode:
#
#   rails    the ingestion path: a sum metric (field "kit_result") carrying the expression is created through the
#            model (its validation decides parse errors), then the event is POSTed to /api/v1/events; the output is
#            the value the binding returned (captured) and the text persisted in properties["kit_result"].
#   preview  POST /api/v1/billable_metrics/evaluate_expression at the frozen clock `now`.
#   ep       the events-processor engine library (libexpression_go, lago-expression v0.2.0, the build the
#            events-processor Dockerfile ships) called with input.event_json verbatim, in a subprocess.
#
# Guard: on a division by zero the Ruby binding raises `fatal` (not rescuable in the frame that raises it; a process
# evaluating on its main thread outside the request stack exits 1; inside the app's request stack it surfaces as an
# error and the web server answers HTTP 500, verified under Puma 7.2.1 on 2026-10-02), and the events-processor
# library aborts the process. Before an in-process evaluation (rails, preview) of an expression containing "/", the
# same expression is tried in the subprocess engine; if that aborts, the op answers protocol error `internal` so
# the oracle never depends on where the fatal surfaces.

load File.join(__dir__, "events.rb") unless defined?(KitA3)

module KitA3Expr
  FIELD = "kit_result"

  class << self
    def guard!(ctx, expression, event)
      return unless expression.to_s.include?("/")

      props = (event || {})["properties"] || {}
      ts = (event || {})["timestamp"]
      json = JSON.generate({"code" => (event || {})["code"].to_s, "timestamp" => ts.to_s.empty? ? 0 : ts.to_s.to_d.floor,
                            "properties" => props.transform_values { |v| v.is_a?(Numeric) ? v : v.to_s }})
      kind, sig = KitA3.engine_eval(expression, json)
      raise "reference engine aborts on this input (signal #{sig}); not evaluated in-process" if kind == :aborted
    end

    def number_or_string(v)
      v.is_a?(BigDecimal) ? {"value" => v, "type" => "number"} : {"value" => v.to_s, "type" => "string"}
    end

    def rails(input, ctx)
      expression = input.fetch("expression")
      event = input.fetch("event")
      code = event.fetch("code")
      guard!(ctx, expression, event)
      ctx.rollback do
        org = KitA3.org(store: "pg")
        bm = BillableMetric.new(organization: org, code:, name: code, aggregation_type: "sum_agg",
          field_name: FIELD, expression:)
        unless bm.valid?
          ctx.domain_error!("parse_error", "expression", "metric not saved: invalid_expression") if bm.errors.added?(:expression, :invalid_expression)
          raise "metric invalid: #{bm.errors.to_hash}"
        end
        bm.save!
        body = {"transaction_id" => "kit-expr", "code" => code, "external_subscription_id" => "kit-sub",
                "properties" => event["properties"] || {}}
        body["timestamp"] = event["timestamp"] if event.key?("timestamp")
        Thread.current[:kit_a3_expr] = nil
        status, json = KitA3.at(ctx, input["now"] || "2026-01-01T00:00:00Z") do
          KitA3.post(org, "/api/v1/events", JSON.generate({"event" => body}))
        end
        case status
        when 200
          stored = Event.find_by!(organization_id: org.id, transaction_id: "kit-expr").properties[FIELD]
          number_or_string(Thread.current[:kit_a3_expr]).merge("text" => stored)
        when 422
          details = json && json["error_details"]
          prefix = "expression_evaluation_failed: "
          if details.is_a?(String) && details.start_with?(prefix)
            ctx.domain_error!("evaluation_error", nil, details.delete_prefix(prefix))
          end
          raise "unexpected 422 body #{json.inspect}"
        else
          raise "unexpected HTTP #{status}"
        end
      end
    end

    def preview(input, ctx)
      expression = input["expression"]
      event = input["event"]
      guard!(ctx, expression, event)
      ctx.rollback do
        org = KitA3.org(store: "pg")
        body = {"expression" => expression}
        body["event"] = event if input.key?("event")
        Thread.current[:kit_a3_expr] = nil
        status, json = KitA3.at(ctx, input.fetch("now")) do
          KitA3.post(org, "/api/v1/billable_metrics/evaluate_expression", JSON.generate(body))
        end
        case status
        when 200
          v = json.fetch("expression_result").fetch("value")
          number_or_string(Thread.current[:kit_a3_expr]).merge("text" => v.is_a?(String) ? v : JSON.generate(v))
        when 422
          details = json["error_details"] || {}
          field, codes = details.first
          ctx.domain_error!(Array(codes).first, field) if details.size == 1 && Array(codes).size == 1
          raise "unexpected 422 body #{json.inspect}"
        else
          raise "unexpected HTTP #{status}"
        end
      end
    end

    def ep(input, ctx)
      expression = input.fetch("expression")
      event_json = input["event_json"] || JSON.generate(input.fetch("event"))
      kind, payload = KitA3.engine_eval(expression, event_json)
      case kind
      when :ok
        value = begin
          BigDecimal(payload) if payload.match?(/\A[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?\z/)
        rescue ArgumentError
          nil
        end
        {"value" => value || payload, "text" => payload}
      when :null then ctx.domain_error!("evaluation_error", nil, "engine returned no value")
      else raise "events-processor engine aborted (signal #{payload})"
      end
    end
  end
end

KitOracle.op("expression.evaluate") do |input, ctx|
  case input.fetch("mode")
  when "rails" then KitA3Expr.rails(input, ctx)
  when "preview" then KitA3Expr.preview(input, ctx)
  when "ep" then KitA3Expr.ep(input, ctx)
  else ctx.bad_input!("mode must be rails|preview|ep")
  end
end
