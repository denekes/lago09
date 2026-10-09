# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/api.rb — oracle handlers for the `api` area (billing-engine-spec chapter 11, rules BE-API-*), plus KitApiOps, the
# helper module shared with ops/clock.rb and ops/webhook.rb (this file loads first of the three: file-name order).
#
#   api.pagination_meta   a real ActiveRecord relation (a row source of `total_count` rows) paginated exactly like
#                         the index endpoints (`scope.page(params[:page]).per(params[:per_page] || PER_PAGE)`), then
#                         the controller concern's pagination_metadata (with the invoices count cache when
#                         `cached_count` is given: the cache is primed through the same concern first)
#   api.count_cache_key   the count-cache key the invoices / customer-invoices / fees index endpoints write, from the
#                         params those controllers really pass (permit lists of the controllers), captured from a
#                         memory cache store; the SHA-256 pre-image is captured from the digest call itself
#   api.error_body        a controller instance renders the failure (render_error_response, bad_request_error,
#                         unauthorized_error, not_found) into a test response; status + exact body bytes
#   api.auth_token        the base controller's Authorization-header parsing on a test request
#   api.authorize         the base controller's authorize step with a real (unsaved) ApiKey/Organization pair
#
# Stand-ins (stated so the evidence stays honest): controllers are instantiated outside the Rack stack (request and
# response objects are ActionDispatch test objects); the 500 produced by an unhandled failure is reported as the kit
# domain error `server_error` (the body of a 500 is not part of the kit contract).

require "json"
require "digest"
require "socket"

module KitApiOps
  module_function

  ENV_LOCK = Mutex.new

  def install!
    return if @installed

    require "factory_bot"
    FactoryBot.find_definitions unless FactoryBot.factories.registered?(:organization)
    @installed = true
  end

  # A controller instance able to run private helpers and render into a test response.
  def controller(klass = ::Api::BaseController, method: "GET", path: "/api/v1/kit", query: nil, headers: {}, path_params: {})
    env = Rack::MockRequest.env_for(query.present? ? "#{path}?#{query}" : path, method:)
    req = ActionDispatch::Request.new(env)
    headers.each { |k, v| req.headers[k] = v }
    req.path_parameters = path_params.symbolize_keys if path_params.present?
    c = klass.new
    c.set_request!(req)
    c.set_response!(ActionDispatch::Response.new)
    c
  end

  def rendered(controller)
    resp = controller.response
    {"http_status" => resp.status, "body_json" => resp.body.to_s}
  end

  # Temporarily replace Rails.cache (the test environment uses a null store).
  def with_memory_cache
    store = ActiveSupport::Cache::MemoryStore.new
    saved = Rails.cache
    Rails.cache = store
    yield store
  ensure
    Rails.cache = saved
  end

  # Record the argument of every Digest::SHA256.digest / .hexdigest call made inside the block (thread-local spy,
  # prepended once; it only records and always calls the real implementation).
  module Sha256Spy
    def digest(*args)
      Thread.current[:kit_api_sha]&.push(args.first.to_s.dup)
      super
    end

    def hexdigest(*args)
      Thread.current[:kit_api_sha]&.push(args.first.to_s.dup)
      super
    end
  end
  Digest::SHA256.singleton_class.prepend(Sha256Spy)

  def capture_sha256
    Thread.current[:kit_api_sha] = []
    result = yield
    [result, Thread.current[:kit_api_sha].dup]
  ensure
    Thread.current[:kit_api_sha] = nil
  end

  # Set (or unset, value nil) environment variables for the block; restores the previous values.
  def with_env(vars)
    ENV_LOCK.synchronize do
      saved = vars.keys.to_h { |k| [k, ENV[k]] }
      begin
        vars.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v.to_s }
        yield
      ensure
        saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
      end
    end
  end

  # Query-string text built from a JSON object, parsed back by Rack like a real request.
  def query_text(query)
    return nil if query.blank?

    Rack::Utils.build_nested_query(query)
  end

  # A one-shot local HTTP endpoint. mode :respond answers `status`, :hang never answers, :close drops the connection.
  def with_http_endpoint(status: 200, body: "", mode: :respond)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    captured = {}
    thread = Thread.new do
      sock = server.accept
      begin
        sock.binmode
        captured["request_line"] = sock.gets("\r\n").to_s.chomp("\r\n")
        headers = {}
        while (line = sock.gets("\r\n")) && line != "\r\n"
          k, v = line.chomp("\r\n").split(":", 2)
          headers[k.strip] = v.to_s.strip
        end
        captured["headers"] = headers
        len = headers.find { |k, _| k.casecmp?("content-length") }&.last.to_i
        captured["body"] = (len.positive? ? sock.read(len) : "").force_encoding("UTF-8")
        case mode
        when :respond
          payload = body.to_s.b
          sock.write("HTTP/1.1 #{status} KIT\r\nContent-Type: text/plain\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n")
          sock.write(payload)
        when :hang then sleep 10
        end
      rescue IOError, SystemCallError
        nil
      ensure
        begin
          sock.close
        rescue IOError
          nil
        end
      end
    end
    yield "http://127.0.0.1:#{port}/kit-hook", captured
  ensure
    thread&.join(0.5)
    thread&.kill
    server&.close
  end

  # A closed local port (connection refused).
  def closed_port_url
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    "http://127.0.0.1:#{port}/kit-hook"
  end

  def ids_label_map(records_by_label)
    records_by_label.to_h { |label, rec| [rec.id, label] }
  end
end

# ---------------------------------------------------------------------------------------------------------------
# api.pagination_meta
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("api.pagination_meta") do |input, ctx|
  total = input.fetch("total_count")
  ctx.bad_input!("total_count must be a non-negative integer") unless total.is_a?(Integer) && total >= 0 && total <= 100_000
  page = input["page"].nil? ? nil : input["page"].to_s
  per_page = input["per_page"].nil? ? nil : input["per_page"].to_s
  cached = input["cached_count"]
  ctx.bad_input!("cached_count must be an integer") unless cached.nil? || cached.is_a?(Integer)

  ctx.rollback do
    # A real relation whose row source yields `total` rows; paginated like every index endpoint.
    scope = IdempotencyRecord.unscoped.select(:id).from(
      "(SELECT gen_random_uuid() AS id FROM generate_series(1, #{total})) AS idempotency_records"
    )
    records = scope.page(page).per(per_page || Pagination::PER_PAGE)
    ctl = KitApiOps.controller(query: KitApiOps.query_text({"page" => page, "per_page" => per_page}.compact))
    begin
      meta =
        if cached.nil?
          ctl.pagination_metadata(records)
        else
          params = ctl.params.permit(*InvoiceIndex::WHITELIST)
          org_id = "00000000-0000-0000-0000-000000000000"
          KitApiOps.with_memory_cache do
            ctl.send(:_count_total, key: "invoices", organization_id: org_id, params:) { cached }
            ctl.pagination_metadata(records, key: "invoices", organization_id: org_id, params:)
          end
        end
      {"meta" => meta, "items" => records.to_a.size}
    rescue Kaminari::ZeroPerPageOperation, FloatDomainError, ZeroDivisionError => e
      ctx.domain_error!("server_error", nil, "#{e.class}: #{e.message}")
    end
  end
end

# ---------------------------------------------------------------------------------------------------------------
# api.count_cache_key
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("api.count_cache_key") do |input, ctx|
  index = input.fetch("index")
  org_id = input.fetch("organization_id")
  query = input["query"] || {}
  ctx.bad_input!("query must be an object") unless query.is_a?(Hash)

  case index
  when "invoices"
    ctl = KitApiOps.controller(::Api::V1::InvoicesController, path: "/api/v1/invoices", query: KitApiOps.query_text(query))
    params = ctl.params.permit(*InvoiceIndex::WHITELIST)
    key = "invoices"
  when "customer_invoices"
    cust = input.fetch("customer_external_id")
    ctl = KitApiOps.controller(::Api::V1::Customers::InvoicesController, path: "/api/v1/customers/#{cust}/invoices",
      query: KitApiOps.query_text(query), path_params: {"customer_external_id" => cust})
    params = ctl.params.permit(*InvoiceIndex::WHITELIST)
    key = "invoices"
  when "fees"
    ctl = KitApiOps.controller(::Api::V1::FeesController, path: "/api/v1/fees", query: KitApiOps.query_text(query))
    # the fees index passes its permitted filters merged with the two paging parameters
    params = ctl.send(:index_filters).merge(page: ctl.params[:page], per_page: ctl.params[:per_page])
    key = "fees"
  else
    ctx.bad_input!("index must be invoices|customer_invoices|fees")
  end

  written, seen = KitApiOps.capture_sha256 do
    KitApiOps.with_memory_cache do |store|
      ctl.send(:_count_total, key:, organization_id: org_id, params:) { 1 }
      store.instance_variable_get(:@data).keys
    end
  end
  ctx.bad_input!("no cache key written") unless written.size == 1
  {"key" => written.first, "preimage" => seen.last}
end

# ---------------------------------------------------------------------------------------------------------------
# api.error_body
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("api.error_body") do |input, ctx|
  f = input.fetch("failure")
  ctx.bad_input!("failure must be an object") unless f.is_a?(Hash)
  ctl = KitApiOps.controller(::Api::BaseController)
  result = BaseService::Result.new
  begin
    case f.fetch("type")
    when "not_found" then ctl.render_error_response(result.not_found_failure!(resource: f.fetch("resource")))
    when "method_not_allowed" then ctl.render_error_response(result.not_allowed_failure!(code: f.fetch("code")))
    when "validation" then ctl.render_error_response(result.validation_failure!(errors: f.fetch("messages")))
    when "single_validation"
      args = {error_code: f.fetch("code")}
      args[:field] = f["field"].to_sym if f["field"]
      ctl.render_error_response(result.single_validation_failure!(**args))
    when "forbidden"
      ctl.render_error_response(f["code"] ? result.forbidden_failure!(code: f["code"]) : result.forbidden_failure!)
    when "unauthorized"
      ctl.render_error_response(f["message"] ? result.unauthorized_failure!(message: f["message"]) : result.unauthorized_failure!)
    when "lock_acquisition"
      args = {message: f.fetch("message", "locked")}
      args[:code] = f["code"] if f["code"]
      ctl.render_error_response(result.lock_acquisition_failure!(**args))
    when "third_party"
      ctl.render_error_response(result.third_party_failure!(third_party: f.fetch("third_party"),
        error_code: f.fetch("code"), error_message: f.fetch("message")))
    when "too_many_provider_requests"
      ctl.render_error_response(result.too_many_provider_requests_failure!(provider_name: f.fetch("provider_name"),
        error: StandardError.new(f.fetch("message"))))
    when "service" then ctl.render_error_response(result.service_failure!(code: f.fetch("code"), message: f.fetch("message")))
    when "missing_root" then ctl.send(:bad_request_error, ActionController::ParameterMissing.new(f.fetch("param").to_sym))
    when "unauthenticated" then ctl.send(:unauthorized_error)
    when "route_not_found"
      ctl = KitApiOps.controller(::ApplicationController)
      ctl.not_found
    else ctx.bad_input!("unknown failure type #{f["type"].inspect}")
    end
  rescue BaseService::FailedResult => e
    ctx.domain_error!("server_error", nil, "#{e.class}: #{e.message}")
  end
  KitApiOps.rendered(ctl)
end

# ---------------------------------------------------------------------------------------------------------------
# api.auth_token
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("api.auth_token") do |input, _ctx|
  header = input["authorization"]
  ctl = KitApiOps.controller(::Api::BaseController, headers: header.nil? ? {} : {"Authorization" => header})
  {"token" => ctl.send(:auth_token)}
end

# ---------------------------------------------------------------------------------------------------------------
# api.authorize
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("api.authorize") do |input, ctx|
  method = input.fetch("method").to_s.upcase
  resource = input.fetch("resource")
  integrations = input["premium_integrations"] || []
  org = Organization.new(premium_integrations: integrations)
  key = ApiKey.new(organization: org)
  key.permissions = input["permissions"] unless input["permissions"].nil?
  klass = Class.new(::Api::BaseController) do
    define_method(:resource_name) { resource }
  end
  ctl = KitApiOps.controller(klass, method:)
  ctl.instance_variable_set(:@current_api_key, key)
  ctx.premium(input.fetch("premium", false)) do
    ctl.send(:authorize)
  end
  body = ctl.response.body.to_s
  if body.empty?
    {"allowed" => true}
  else
    {"allowed" => false}.merge(KitApiOps.rendered(ctl))
  end
end
