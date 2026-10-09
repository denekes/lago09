# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/webhook.rb — oracle handlers for the `webhooks` area (billing-engine-spec chapter 12, rules BE-WH-*). Uses
# KitApiOps from ops/api.rb (loaded earlier: file-name order).
#
# Every delivery-shaped op runs the reference's real path inside a rolled-back transaction: an organization and a
# webhook endpoint (factories), a Webhook row whose payload goes through the model's own storage round trip, then
# the real HTTP delivery service POSTing to a one-shot local TCP endpoint that records the exact request bytes and
# answers the status the vector asks for.
#
#   webhooks.encode                 body bytes POSTed for a payload (storage round trip + transport encoding)
#   webhooks.payload_envelope       a webhook-emission service (subclass of the reference base service with the
#                                   vector's type/object type and a serializer returning the object) fans out to the
#                                   endpoint; the POSTed body is returned
#   webhooks.sign                   headers the delivery service sends (HMAC with the organization key, or RS256 JWT
#                                   with the RSA key given in the vector, swapped in for the installation key)
#   webhooks.public_key             the public-key endpoints' bodies for the RSA key given in the vector
#   webhooks.retry_step             delivery outcome for a response status / network error at a given retry count;
#                                   the back-off window is read from the scheduled retry job (randomness pinned to
#                                   the low end) and from the service's wait computation (randomness at the high end)
#   webhooks.normalize_event_types  the endpoint-creation service with the vector's event_types
#   webhooks.endpoint_receives      fan-out of a webhook-emission service to an endpoint with a stored filter
#   webhooks.type_info              the event-name -> service map of the webhook job and the service's type/object type
#
# Stand-ins (stated so the evidence stays honest): the emission subclass replaces the per-type serializer by the
# vector's object JSON; randomness of the back-off is pinned (Kernel.rand stubbed to 0.0 and 1.0); an exception
# raised by the reference's own model code during endpoint creation (a JSON number or boolean as event_types) is
# reported as the kit domain error `server_error` (an HTTP 500 for an API client).

require "json"
require "base64"
require "openssl"

module KitApiOps
  module Webhooks
    module_function

    DEFAULT_ISS = "https://api.lago.dev"

    def org(id: nil, hmac_key: nil)
      KitApiOps.install!
      attrs = {}
      attrs[:id] = id if id
      o = FactoryBot.create(:organization, **attrs)
      o.update_column(:hmac_key, hmac_key) if hmac_key
      o
    end

    # The organization's only endpoint (the organization factory creates one of its own: removed).
    def endpoint(org, url:, algo: :hmac, event_types: :unset)
      ep = WebhookEndpoint.create!(organization: org, webhook_url: url, signature_algo: algo)
      WebhookEndpoint.where(organization_id: org.id).where.not(id: ep.id).delete_all
      ep.update_column(:event_types, event_types) unless event_types == :unset
      org.reload
      ep.reload
    end

    # The RSA key of the installation, swapped for the block.
    def with_rsa(pem)
      return yield if pem.nil?

      key = OpenSSL::PKey::RSA.new(pem)
      saved_priv = Object.send(:remove_const, :RsaPrivateKey)
      saved_pub = Object.send(:remove_const, :RsaPublicKey)
      Object.const_set(:RsaPrivateKey, key)
      Object.const_set(:RsaPublicKey, key.public_key)
      yield
    ensure
      if saved_priv
        Object.send(:remove_const, :RsaPrivateKey)
        Object.send(:remove_const, :RsaPublicKey)
        Object.const_set(:RsaPrivateKey, saved_priv)
        Object.const_set(:RsaPublicKey, saved_pub)
      end
    end

    def with_rand(value)
      saved = Kernel.method(:rand)
      Kernel.define_singleton_method(:rand) { |*_args| value }
      yield
    ensure
      Kernel.define_singleton_method(:rand, saved)
    end

    def cleanup_blobs(webhook)
      [webhook.payload_key, webhook.response_key].compact.each do |k|
        Webhook.payload_storage.delete(k)
      rescue StandardError
        nil
      end
    end

    # Deliver an existing webhook row through the real HTTP service to a local endpoint; returns [result, captured].
    def deliver(webhook, status: 200, response_body: "ok", mode: :respond)
      captured = nil
      KitApiOps.with_http_endpoint(status:, body: response_body, mode:) do |url, cap|
        webhook.webhook_endpoint.update_column(:webhook_url, url)
        webhook.webhook_endpoint.reload
        ::Webhooks::SendHttpService.call(webhook:)
        captured = cap
      end
      captured
    end

    # A webhook-emission service of the reference with the vector's type, object type and serialized object.
    def emitter(webhook_type, object_type, object_hash)
      Class.new(::Webhooks::BaseService) do
        define_method(:webhook_type) { webhook_type }
        define_method(:object_type) { object_type }
        define_method(:object_serializer) { Struct.new(:serialize).new(object_hash) }
        private :webhook_type, :object_type, :object_serializer
      end
    end

    # The object a webhook is about (only organization, id and class are read by the base service).
    def subject_for(org)
      Struct.new(:organization, :id).new(org, SecureRandom.uuid)
    end

    def header(captured, name)
      captured["headers"].find { |k, _| k.casecmp?(name) }&.last
    end
  end
end

# ---------------------------------------------------------------------------------------------------------------
# webhooks.encode
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("webhooks.encode") do |input, ctx|
  payload = JSON.parse(input.fetch("payload_json"))
  ctx.bad_input!("payload_json must be a JSON object") unless payload.is_a?(Hash)
  ctx.rollback do
    org = KitApiOps::Webhooks.org(hmac_key: "kit-hmac-key")
    ep = KitApiOps::Webhooks.endpoint(org, url: "http://127.0.0.1:9/kit", algo: :hmac)
    wh = Webhook.new(webhook_endpoint: ep, organization: org, webhook_type: payload["webhook_type"] || "kit.test")
    wh.store_payload(payload)
    wh.save!
    begin
      cap = KitApiOps::Webhooks.deliver(wh)
      {"body" => cap["body"], "content_type" => KitApiOps::Webhooks.header(cap, "Content-Type")}
    ensure
      KitApiOps::Webhooks.cleanup_blobs(wh)
    end
  end
end

# ---------------------------------------------------------------------------------------------------------------
# webhooks.payload_envelope
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("webhooks.payload_envelope") do |input, ctx|
  object = JSON.parse(input.fetch("object_json"))
  org_id = input.fetch("organization_id")
  ctx.bad_input!("organization_id must be a UUID") unless org_id.match?(BaseQuery::UUID_REGEX)
  ctx.rollback do
    org = KitApiOps::Webhooks.org(id: org_id)
    ep = KitApiOps::Webhooks.endpoint(org, url: "http://127.0.0.1:9/kit", algo: :hmac)
    svc = KitApiOps::Webhooks.emitter(input.fetch("webhook_type"), input.fetch("object_type"), object)
    svc.new(object: KitApiOps::Webhooks.subject_for(org)).call
    wh = Webhook.where(webhook_endpoint_id: ep.id).sole
    begin
      cap = KitApiOps::Webhooks.deliver(wh)
      {"body" => cap["body"], "webhook_type" => wh.webhook_type}
    ensure
      KitApiOps::Webhooks.cleanup_blobs(wh)
    end
  end
end

# ---------------------------------------------------------------------------------------------------------------
# webhooks.sign
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("webhooks.sign") do |input, ctx|
  algo = input.fetch("algorithm")
  ctx.bad_input!("algorithm must be hmac|jwt") unless %w[hmac jwt].include?(algo)
  body = input.fetch("body")
  payload = JSON.parse(body)
  ctx.bad_input!("body must be the canonical encoding of its payload") unless payload.to_json == body
  webhook_id = input["webhook_id"] || "00000000-0000-4000-8000-000000000000"
  ctx.rollback do
    org = KitApiOps::Webhooks.org(hmac_key: input["hmac_key"] || "kit-hmac-key")
    ep = KitApiOps::Webhooks.endpoint(org, url: "http://127.0.0.1:9/kit", algo: algo.to_sym)
    wh = Webhook.new(id: webhook_id, webhook_endpoint: ep, organization: org, webhook_type: payload["webhook_type"] || "kit.test")
    wh.store_payload(payload)
    wh.save!
    begin
      cap = nil
      KitApiOps.with_env("LAGO_API_URL" => input.fetch("iss", KitApiOps::Webhooks::DEFAULT_ISS)) do
        KitApiOps::Webhooks.with_rsa(input["rsa_private_key_pem"]) do
          cap = KitApiOps::Webhooks.deliver(wh)
        end
      end
      ctx.bad_input!("delivery did not reach the endpoint") if cap.nil? || cap["headers"].nil?
      headers = %w[Content-Type X-Lago-Signature X-Lago-Signature-Algorithm X-Lago-Unique-Key].to_h do |h|
        [h, KitApiOps::Webhooks.header(cap, h)]
      end
      {"signature" => headers["X-Lago-Signature"], "headers" => headers, "body" => cap["body"]}
    ensure
      KitApiOps::Webhooks.cleanup_blobs(wh)
    end
  end
end

# ---------------------------------------------------------------------------------------------------------------
# webhooks.public_key
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("webhooks.public_key") do |input, _ctx|
  out = {}
  KitApiOps::Webhooks.with_rsa(input.fetch("rsa_private_key_pem")) do
    plain = KitApiOps.controller(::Api::V1::WebhooksController)
    plain.public_key
    json = KitApiOps.controller(::Api::V1::WebhooksController)
    json.json_public_key
    out = {"text" => plain.response.body.to_s, "json_body" => json.response.body.to_s,
           "text_content_type" => plain.response.media_type.to_s}
  end
  out
end

# ---------------------------------------------------------------------------------------------------------------
# webhooks.retry_step
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("webhooks.retry_step") do |input, ctx|
  retries_before = input.fetch("retries_before")
  ctx.bad_input!("retries_before must be a non-negative integer") unless retries_before.is_a?(Integer) && retries_before >= 0
  attempts = input["attempts"]
  outcome = input.fetch("outcome")
  now = ctx.instant(input.fetch("now", "2026-01-01T00:00:00Z"))
  ctx.rollback do
    ctx.travel(now) do
      org = KitApiOps::Webhooks.org
      ep = KitApiOps::Webhooks.endpoint(org, url: "http://127.0.0.1:9/kit", algo: :hmac)
      wh = Webhook.new(webhook_endpoint: ep, organization: org, webhook_type: "kit.test", retries: retries_before,
        status: (retries_before.zero? ? :pending : :retrying))
      wh.store_payload({"webhook_type" => "kit.test", "object_type" => "kit", "organization_id" => org.id, "kit" => {}})
      wh.save!
      env = {"LAGO_WEBHOOK_ATTEMPTS" => attempts&.to_s, "LAGO_WEBHOOK_TIMEOUT_SECONDS" => input["timeout_seconds"]&.to_s}
      adapter = ActiveJob::Base.queue_adapter
      adapter.enqueued_jobs.clear
      begin
        KitApiOps.with_env(env) do
          KitApiOps::Webhooks.with_rand(0.0) do
            if outcome.key?("http_status")
              KitApiOps::Webhooks.deliver(wh, status: outcome.fetch("http_status"), response_body: outcome.fetch("body", "kit"))
            else
              case outcome.fetch("network_error")
              when "connection_refused"
                ep.update_column(:webhook_url, KitApiOps.closed_port_url)
                ::Webhooks::SendHttpService.call(webhook: wh.reload)
              when "timeout"
                KitApiOps::Webhooks.deliver(wh, mode: :hang)
              when "connection_closed"
                KitApiOps::Webhooks.deliver(wh, mode: :close)
              else ctx.bad_input!("network_error must be connection_refused|timeout|connection_closed")
              end
            end
          end
        end
        wh.reload
        jobs = adapter.enqueued_jobs.select { |j| j[:job] == SendHttpWebhookJob || j["job_class"] == "SendHttpWebhookJob" }
        wait = nil
        if jobs.any?
          at = jobs.first[:at] || jobs.first["scheduled_at"]
          low = at.is_a?(Numeric) ? at - now.to_f : (Time.zone.parse(at.to_s) - now)
          svc = ::Webhooks::SendHttpService.new(webhook: wh)
          high = KitApiOps::Webhooks.with_rand(1.0) { svc.send(:wait_value) }
          wait = {"min" => BigDecimal(low.round(6).to_s), "max" => BigDecimal(high.round(6).to_s)}
        end
        {"status" => wh.status, "retries" => wh.retries, "http_status" => wh.http_status,
         "retry_scheduled" => jobs.any?, "wait_seconds" => wait}
      ensure
        KitApiOps::Webhooks.cleanup_blobs(wh)
      end
    end
  end
end

# ---------------------------------------------------------------------------------------------------------------
# webhooks.normalize_event_types
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("webhooks.normalize_event_types") do |input, ctx|
  raw = JSON.parse(input.fetch("event_types_json"))
  ctx.bad_input!("event_types_json must be an array, a string or null") if raw.is_a?(Hash)
  ctx.rollback do
    org = KitApiOps::Webhooks.org
    begin
      result = ::WebhookEndpoints::CreateService.call(organization: org,
        params: {webhook_url: "https://hooks.example.com/kit", event_types: raw})
    rescue NoMethodError, TypeError => e
      # An exception raised by the reference's own code (first frame under app/ or lib/) is the unhandled failure
      # an API client sees as HTTP 500; anything else is a defect of this module and stays an internal error.
      raise unless e.backtrace&.first.to_s.start_with?(Rails.root.join("app").to_s, Rails.root.join("lib").to_s)

      ctx.domain_error!("server_error", nil, "#{e.class}: #{e.message}")
    end
    if result.success?
      {"valid" => true, "stored" => result.webhook_endpoint.reload.event_types}
    else
      ctx.bad_input!("unexpected failure #{result.error.class}") unless result.error.is_a?(BaseService::ValidationFailure)
      {"valid" => false, "errors" => result.error.messages.to_h { |k, v| [k.to_s, v] }}
    end
  end
end

# ---------------------------------------------------------------------------------------------------------------
# webhooks.endpoint_receives
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("webhooks.endpoint_receives") do |input, ctx|
  types = input.fetch("event_types")
  ctx.bad_input!("event_types must be an array or null") unless types.nil? || types.is_a?(Array)
  ctx.rollback do
    org = KitApiOps::Webhooks.org
    ep = KitApiOps::Webhooks.endpoint(org, url: "http://127.0.0.1:9/kit", algo: :hmac, event_types: types)
    svc = KitApiOps::Webhooks.emitter(input.fetch("webhook_type"), "kit", {})
    svc.new(object: KitApiOps::Webhooks.subject_for(org)).call
    rows = Webhook.where(webhook_endpoint_id: ep.id).to_a
    rows.each { |w| KitApiOps::Webhooks.cleanup_blobs(w) }
    {"receives" => rows.any?}
  end
end

# ---------------------------------------------------------------------------------------------------------------
# webhooks.type_info
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("webhooks.type_info") do |input, ctx|
  name = input.fetch("event")
  klass = SendWebhookJob::WEBHOOK_SERVICES[name]
  ctx.domain_error!("unknown_event_type", "event") unless klass
  svc = klass.new(object: nil)
  configured = WebhookEndpoint::WEBHOOK_EVENT_TYPES.include?(name)
  {"webhook_type" => svc.send(:webhook_type), "object_type" => svc.send(:object_type), "configured" => configured}
end
