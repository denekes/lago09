# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# system.rb — the scenario tier's stateful ops (system.reset / set_clock / api / tick / snapshot) answered by the
# full lago-api application at the pin, inside the oracle adapter process (rails runner, RAILS_ENV=test).
#
# It reproduces the environment the reference's own scenario specs run in (spec_helper + scenarios/queues helpers):
#   * every REST call goes through the real Rack stack with the tenant's API key (Bearer), and afterwards ALL enqueued
#     ActiveJob and Sidekiq jobs are performed until both queues are empty (async flattened like the specs do);
#   * the wall clock is frozen at the instant given by system.set_clock (time travel) for every later call;
#   * PDF rendering is stubbed over HTTP (WebMock), all other outbound HTTP is refused, Kafka producers are captured
#     in memory, ActiveJob uniqueness runs in test mode, Sidekiq in fake mode;
#   * system.tick runs the named clock jobs (kit vocabulary, table JOBS below) at the frozen clock, then drains.
#
# WARNING: system.reset DELETES EVERY ROW of the oracle database ($ORACLE_DB, which must be a lago_api_test* database)
# and, for store "ch", every row of the ClickHouse event tables (under $LAGO_SKILLS_CACHE/k7-state/ch.lock, held until
# the next reset or process exit). Use your own ORACLE_DB.
#
# State lives in this process between calls (one scenario at a time). The adapter's per-call reset (travel back,
# premium off, enqueued jobs cleared) is compensated here: every op re-enters the frozen clock and the premium flag.

require "json"

module KitSystem
  # Kit tick name -> reference clock jobs, run in this order (each list drained before the next).
  JOBS = {
    "billing" => [%w[Clock::SubscriptionsBillerJob Clock::FreeTrialSubscriptionsBillerJob],
      %w[Clock::ComputeAllDailyUsagesJob Clock::RefreshLifetimeUsagesJob Clock::ProcessAllSubscriptionActivitiesJob]],
    "usage_update" => [%w[Clock::ComputeAllDailyUsagesJob Clock::RefreshLifetimeUsagesJob
      Clock::ProcessAllSubscriptionActivitiesJob]],
    "refresh_drafts" => [%w[Clock::RefreshDraftInvoicesJob]],
    "finalize_drafts" => [%w[Clock::FinalizeInvoicesJob]],
    "wallet_refresh" => [%w[Clock::RefreshWalletsOngoingBalanceJob]],
    "overdue" => [%w[Clock::MarkInvoicesAsPaymentOverdueJob]],
    "terminate_ended" => [%w[Clock::TerminateEndedSubscriptionsJob]],
    "activate_subscriptions" => [%w[Clock::ActivateSubscriptionsJob]],
    "terminate_coupons" => [%w[Clock::TerminateCouponsJob]],
    "terminate_wallets" => [%w[Clock::TerminateWalletsJob]],
    "interval_topups" => [%w[Clock::CreateIntervalWalletTransactionsJob]],
    "termination_alerts" => [%w[Clock::SubscriptionsToBeTerminatedJob]],
    "lifetime_usage" => [%w[Clock::RefreshLifetimeUsagesJob]],
    "subscription_activity" => [%w[Clock::ProcessAllSubscriptionActivitiesJob]]
  }.freeze

  # Organization / billing-entity settings system.reset accepts (kit name => [org column?, billing entity column?]).
  ORG_SETTINGS = %w[timezone default_currency document_numbering document_number_prefix invoice_grace_period
    net_payment_term finalize_zero_amount_invoice premium_integrations max_wallets clickhouse_deduplication_enabled
    document_locale eu_tax_management].freeze
  ENTITY_SETTINGS = %w[timezone default_currency document_numbering document_number_prefix invoice_grace_period
    net_payment_term finalize_zero_amount_invoice document_locale eu_tax_management
    subscription_invoice_issuing_date_anchor subscription_invoice_issuing_date_adjustment].freeze
  CH_TABLES = %w[events_enriched events_enriched_expanded events_raw events_dead_letter].freeze

  # Kafka is a sink in the reference suite (captured by karafka-testing); captured here the same way.
  class FakeProducer
    attr_reader :messages

    def initialize = (@messages = [])
    def produce_async(msg) = (@messages << msg) && nil
    def produce_many_async(msgs) = @messages.concat(msgs) && nil
    def produce_sync(msg) = (@messages << msg) && nil
    def produce_many_sync(msgs) = @messages.concat(msgs) && nil
  end

  module ProducerHook
    def producer
      KitSystem.active ? KitSystem.producer : super
    end
  end

  class Drainer
    include ActiveJob::TestHelper

    def drain!
      100.times do
        adapter = ActiveJob::Base.queue_adapter
        return if adapter.enqueued_jobs.empty? && Sidekiq::Worker.jobs.empty?

        perform_enqueued_jobs
        Sidekiq::Worker.drain_all
      end
      raise "jobs still enqueued after 100 drain rounds"
    end
  end

  class << self
    attr_accessor :active, :producer, :org, :now, :premium, :store, :ch_lock, :api_key

    def install!
      return if @installed

      require "webmock"
      require "sidekiq/testing"
      WebMock.enable!
      WebMock.disable_net_connect!(allow_localhost: true)
      # PDF rendering (out of scope): answer like the reference suite's stub, with a tiny body.
      WebMock::API.stub_request(:post, "#{ENV["LAGO_PDF_URL"]}/forms/chromium/convert/html")
        .to_return { |_request| {status: 200, body: +"%PDF-1.4 kit-oracle\n"} }
      Sidekiq::Testing.fake!
      ActiveJob::Uniqueness.test_mode!
      self.producer = FakeProducer.new
      Karafka.singleton_class.prepend(ProducerHook)
      @drainer = Drainer.new
      @installed = true
    end

    def drain! = @drainer.drain!

    # Run a block at the frozen kit clock with the tenant's premium flag.
    def within(ctx)
      raise KitOracle::BadInput, "system.reset must come first" unless org

      self.active = true
      ctx.premium(premium) do
        now ? ctx.travel(now) { yield } : yield
      end
    ensure
      self.active = false
    end

    def wipe_pg!
      db = ActiveRecord::Base.connection_db_config.database.to_s
      raise "refusing to wipe database #{db.inspect}: system.reset needs a lago_api_test* database" unless db.start_with?("lago_api_test")

      conn = ActiveRecord::Base.connection
      tables = conn.tables - %w[schema_migrations ar_internal_metadata]
      conn.execute("TRUNCATE #{tables.map { |t| conn.quote_table_name(t) }.join(", ")} RESTART IDENTITY CASCADE")
    end

    def take_ch_lock!
      return if ch_lock

      dir = File.join(ENV.fetch("LAGO_SKILLS_CACHE", File.join(Dir.home, ".cache", "lago-skills")), "k7-state")
      FileUtils.mkdir_p(dir)
      f = File.open(File.join(dir, "ch.lock"), File::RDWR | File::CREAT, 0o644)
      f.flock(File::LOCK_EX)
      self.ch_lock = f
    end

    def release_ch_lock!
      return unless ch_lock

      ch_lock.flock(File::LOCK_UN)
      ch_lock.close
      self.ch_lock = nil
    end

    def wipe_ch!
      CH_TABLES.each { |t| Clickhouse::BaseRecord.connection.execute("TRUNCATE TABLE IF EXISTS #{t}") }
    end

    def reset!(input, ctx)
      install!
      self.org = nil
      self.now = nil
      self.premium = input.fetch("premium") ? true : false
      self.store = input.fetch("store")
      ctx.bad_input!("store must be pg or ch") unless %w[pg ch].include?(store)
      settings = input.fetch("organization")
      ctx.bad_input!("organization must be an object") unless settings.is_a?(Hash)
      unknown = settings.keys - ORG_SETTINGS - ENTITY_SETTINGS
      ctx.bad_input!("unknown organization settings: #{unknown.join(", ")}") if unknown.any?
      entity_over = input["billing_entity"] || {}
      unknown = entity_over.keys - ENTITY_SETTINGS
      ctx.bad_input!("unknown billing_entity settings: #{unknown.join(", ")}") if unknown.any?

      if store == "ch"
        take_ch_lock!
        wipe_ch!
      else
        release_ch_lock!
      end
      wipe_pg!
      producer.messages.clear

      self.active = true
      # Kit vocabulary is the billing entity's (per_customer | per_billing_entity); the organization column calls the
      # second value per_organization.
      org_numbering = (settings["document_numbering"] == "per_billing_entity") ? "per_organization" : "per_customer"
      created = ctx.premium(true) do
        Organizations::CreateService.call!(name: "Kit Organization", document_numbering: org_numbering)
      end
      o = created.organization
      org_attrs = settings.slice(*ORG_SETTINGS)
      org_attrs["document_numbering"] = org_numbering
      org_attrs["clickhouse_events_store"] = (store == "ch")
      o.update!(org_attrs)
      be = o.reload.default_billing_entity
      be.update!(code: "kit_entity", name: "Kit Organization", **settings.slice(*ENTITY_SETTINGS).symbolize_keys,
        **entity_over.symbolize_keys)
      self.org = o.reload
      self.api_key = org.api_keys.first.value
      {}
    ensure
      self.active = false
    end

    def api!(input, ctx)
      method = input.fetch("method").to_s.upcase
      ctx.bad_input!("unsupported method #{method}") unless %w[GET POST PUT PATCH DELETE].include?(method)
      path = input.fetch("path")
      ctx.bad_input!("path must start with /api/v1/") unless path.is_a?(String) && path.start_with?("/api/v1/")
      query = input["query"]
      body = input.key?("body") ? input["body"] : nil
      within(ctx) do
        session = ActionDispatch::Integration::Session.new(Rails.application)
        headers = {"Content-Type" => "application/json", "Accept" => "application/json",
                   "Authorization" => "Bearer #{api_key}"}
        url = path
        if method == "GET"
          params = query || {}
        else
          url = "#{path}?#{query.to_query}" if query.is_a?(Hash) && query.any?
          params = body.nil? ? nil : JSON.generate(body)
        end
        session.process(method.downcase.to_sym, url, params:, headers:)
        resp = session.response
        text = resp.body.to_s
        parsed = if text.empty?
          nil
        elsif resp.media_type.to_s.include?("json")
          JSON.parse(text)
        else
          text
        end
        mirror_clickhouse_event!(method, path, resp.status, body, parsed) if store == "ch"
        drain!
        {"status" => resp.status, "body" => parsed}
      end
    end

    # A ClickHouse-store tenant reads usage from enriched events that the events-processor writes. The reference
    # scenario helper writes that row itself after each accepted event; so does the oracle (same fields).
    def mirror_clickhouse_event!(method, path, status, body, parsed)
      return unless method == "POST" && path == "/api/v1/events" && status == 200 && body.is_a?(Hash)

      ev = body.fetch("event").with_indifferent_access
      sub = org.subscriptions.find_by!(external_id: ev[:external_subscription_id])
      bm = org.billable_metrics.find_by!(code: ev[:code])
      charge = sub.plan.charges.find_by(billable_metric: bm)
      ts = ev.key?(:timestamp) ? Time.zone.at(ev[:timestamp].to_d) : Time.iso8601(parsed.dig("event", "timestamp"))
      value = bm.count_agg? ? "1" : (ev[:properties] || {}).with_indifferent_access.fetch(bm.field_name).to_s
      enriched = Clickhouse::EventsEnriched.create!(ev.merge(organization_id: org.id, timestamp: ts, value:))
      return unless charge&.pay_in_advance?

      common = Events::Common.new(id: nil, organization_id: enriched.organization_id,
        transaction_id: enriched.transaction_id, external_subscription_id: enriched.external_subscription_id,
        timestamp: enriched.timestamp, code: enriched.code, properties: enriched.properties,
        precise_total_amount_cents: enriched.precise_total_amount_cents)
      Events::PayInAdvanceJob.perform_later(common.as_json)
    end

    def tick!(input, ctx)
      names = Array(input.fetch("jobs"))
      unknown = names - JOBS.keys
      ctx.bad_input!("unknown tick job(s): #{unknown.join(", ")}") if unknown.any?
      within(ctx) do
        names.each do |n|
          JOBS.fetch(n).each do |group|
            group.each { |klass| klass.constantize.perform_later }
            drain!
          end
        end
      end
      {}
    end

    def ser(klass, rel, root, includes)
      rel.map { |x| klass.new(x, root_name: root, includes:).serialize.as_json }
    end

    def snapshot!(_input, ctx)
      within(ctx) do
        o = org.reload
        {
          "invoices" => ser(::V1::InvoiceSerializer, o.invoices.order(:created_at, :sequential_id, :number, :id), "invoice",
            %i[customer billing_periods subscriptions fees credits applied_taxes]),
          "credit_notes" => ser(::V1::CreditNoteSerializer,
            CreditNote.where(organization_id: o.id).order(:created_at, :sequential_id, :id), "credit_note", %i[items applied_taxes]),
          "wallets" => ser(::V1::WalletSerializer, Wallet.where(organization_id: o.id).order(:created_at, :id), "wallet", []),
          "wallet_transactions" => ser(::V1::WalletTransactionSerializer,
            WalletTransaction.where(organization_id: o.id).order(:created_at, :id), "wallet_transaction", []),
          "subscriptions" => ser(::V1::SubscriptionSerializer, o.subscriptions.order(:created_at, :id), "subscription", []),
          "fees" => ser(::V1::FeeSerializer, Fee.where(organization_id: o.id, invoice_id: nil).order(:created_at, :id), "fee", [])
        }
      end
    end
  end
end

KitOracle.op("system.reset") { |input, ctx| KitSystem.reset!(input, ctx) }

KitOracle.op("system.set_clock") do |input, ctx|
  KitSystem.now = ctx.instant(input.fetch("now"))
  {}
end

KitOracle.op("system.api") { |input, ctx| KitSystem.api!(input, ctx) }
KitOracle.op("system.tick") { |input, ctx| KitSystem.tick!(input, ctx) }
KitOracle.op("system.snapshot") { |input, ctx| KitSystem.snapshot!(input, ctx) }
