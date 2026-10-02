# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# scenario-recorder.rb (recorder v4) — records the reference's own scenario specs as black-box traces that
# convert-scenarios.py turns into kit scenarios. Loaded with rspec -r AFTER spec_helper, so nothing in the lago-api
# checkout changes; a no-op unless KIT_SCENARIO_RECORD_DIR is set:
#
#   KIT_SCENARIO_RECORD_DIR=/some/dir ORACLE_DB=<your db> oracle.sh run -j 1 -r scenario-recorder.rb spec/scenarios/<file>
#
# For every PASSING example that made at least one REST call it writes <dir>/<example id>.json:
#   {spec, example_id, description, recorded_with {lago_api, ruby, recorder: "v4"},
#    recorded_at: <the machine's real clock, never used as a scenario instant>,                 <- new in v4
#    kit_clock: {epoch, rebased: <number of steps that ran on the kit clock>},                    <- new in v4
#    settings: {organization: {...setting columns}, billing_entity: {...}, premium, store},
#    given:  {t, organization, billable_metrics, plans, customers, taxes, coupons, add_ons, wallets, subscriptions}
#            (V1 serialisations of the state that existed just before the first REST call: factory-made objects),
#    steps:  [ {t, kind: "api", method, path, query, body, status, response, perform_jobs, before}
#            | {t, kind: "clock", job: "<helper name>", before}                                 (perform_billing, …)
#            | {t, kind: "clock_direct", job: "<Clock::…Job>", before}                          (called from the spec)
#            | {t, kind: "drain", before}                                                       (bare job drains)
#            | {t, kind: "service", name: "<Service class>"}                                    (direct service calls)
#            | {t, kind: "factory", name: "<factory>"} ],                                       (factories after 1st call)
#    final_state: {invoices, credit_notes, wallets, wallet_transactions, subscriptions, fees}  (V1 serialisations;
#                 fees = fees not attached to an invoice, e.g. non-invoiceable pay-in-advance fees),
#    catalog_end: same shape as given, taken after the example (lets the converter pick up catalogue objects that
#                 factories created after the first REST call)}
#
# v4 (1) "before" = the final_state shape taken when the step starts (at the step's own clock "t"), i.e. after the
#    previous step and its job drains: the state the spec saw when it asserted between two steps (the converter turns
#    it into intermediate snapshot steps on request, replayed at that same clock because a few serialised fields,
#    such as a pending downgrade's date, depend on "now");
# (2) the KIT CLOCK: the machine's wall clock never reaches a recording. Every example starts frozen at KIT_EPOCH
#    (a fixed "present" after the specs' own timelines, like the real wall clock it replaces). A step that the spec
#    runs outside its own time travel (on the frozen kit clock, or on the real clock after an explicit travel_back) is
#    moved to the next whole second after the latest instant seen in the example (the kit clock, or a travelled
#    instant later than it), so order and distinctness are kept and a re-mint gives the same instants. A spec's own
#    travel_to block ends on the kit clock again (ActiveSupport restores the outer frozen instant). Known effect: an
#    example that orders records created within one step by creation time sees equal instants and may fail (it is
#    then not recorded); at the pin, void_invoice_spec "partial credit and refund" is one.
#
# "service", "factory" and non-helper steps mark state changes a REST replay cannot reproduce: the converter
# rejects such examples unless a manifest row maps them. Only the outermost helper/tap of a nesting is recorded.

require "json"
require "fileutils"

module KitScenarioRecorder
  DIR = ENV["KIT_SCENARIO_RECORD_DIR"]
  VERSION = "v4"
  # Frozen start of every example's kit clock: one week after the pin's commit (2026-09-08), mid-month and mid-day,
  # later than every fixed date the in-scope scenario specs travel to (they assume "now" is after their timelines,
  # e.g. subscription_at: 5.days.from_now must stay in the future of a travelled creation date).
  KIT_EPOCH = Time.utc(2026, 9, 15, 10, 0, 0)
  # Time.current within this many seconds of the machine's real clock = the spec un-stubbed time (travel_back).
  REAL_CLOCK_SLACK = 300
  SETTING_COLUMNS = %w[timezone default_currency document_numbering document_number_prefix invoice_grace_period
    net_payment_term finalize_zero_amount_invoice premium_integrations max_wallets clickhouse_events_store
    clickhouse_deduplication_enabled document_locale eu_tax_management].freeze
  ENTITY_COLUMNS = %w[timezone default_currency document_numbering document_number_prefix invoice_grace_period
    net_payment_term finalize_zero_amount_invoice document_locale eu_tax_management
    subscription_invoice_issuing_date_anchor subscription_invoice_issuing_date_adjustment].freeze
  SERVICES = %w[Subscriptions::TerminateService Subscriptions::CreateService Subscriptions::ActivateAllPendingService
    AdjustedFees::CreateService Payments::ManualCreateService Payments::CreateService Invoices::RegenerateFromVoidedService
    Invoices::RetryService Invoices::CustomerUsageService DailyUsages::FillHistoryService
    Subscriptions::UpdateOrOverrideFixedChargeService FixedCharges::UpdateService FixedCharges::CreateService
    Fees::CreatePayInAdvanceService Customers::RefreshWalletsService ActivationRules::BillCurrentPeriodService
    Organizations::UpdateService BillingEntities::UpdateService Stripe::HandleEventService PaymentProviders::DestroyService
    WalletTransactions::CreateService Wallets::CreateService CreditNotes::CreateService].freeze

  class << self
    attr_accessor :steps, :depth, :given, :settings, :in_api, :jobs_flag, :org, :kit_now, :kit_instants, :latest,
      :rebased

    def reset!
      self.steps = []
      self.depth = 0
      self.given = nil
      self.settings = nil
      self.in_api = false
      self.jobs_flag = nil
      self.org = nil
      self.kit_now = nil
      self.kit_instants = []
      self.latest = nil
      self.rebased = 0
    end

    # ---- kit clock -------------------------------------------------------------------------------------------
    def real_now = Time.at(Process.clock_gettime(Process::CLOCK_REALTIME)).utc

    # Freeze the example at KIT_EPOCH (example = the RSpec example instance, which owns the time stubs), unless an
    # around hook of the spec already travels: that frozen instant is then the example's own timeline.
    def start_clock!(example)
      self.kit_now = KIT_EPOCH
      self.kit_instants = [KIT_EPOCH.to_r]
      if (Time.current - real_now).abs < REAL_CLOCK_SLACK
        example.travel_to(KIT_EPOCH)
        self.latest = KIT_EPOCH
      else
        self.latest = [KIT_EPOCH, Time.current.utc].max
      end
    end

    def on_kit_clock?
      t = Time.current
      kit_instants.include?(t.to_r) || (t - real_now).abs < REAL_CLOCK_SLACK
    end

    # Called when a top-level step starts: a travelled instant is remembered; a step on the kit (or real) clock is
    # moved to the next whole second after everything seen so far.
    def clock_step!(example)
      return if kit_now.nil? || example.nil?

      if on_kit_clock?
        base = [kit_now, latest].compact.max
        nxt = Time.at(base.to_i + 1).utc
        example.travel_to(nxt)
        self.kit_now = nxt
        kit_instants << nxt.to_r
        self.latest = nxt
        self.rebased += 1
      else
        t = Time.current.utc
        self.latest = t if latest.nil? || t > latest
      end
    end

    def example_instance
      RSpec.current_example&.example_group_instance
    end

    def active? = !steps.nil?
    def started? = active? && !given.nil?

    # t = the clock when the step STARTED; before = the state at that moment (v4).
    def record(step, t = nil, before = nil)
      return unless steps

      step = step.merge(t: (t || Time.current).utc.iso8601(6))
      step[:before] = before if before
      steps << step
    end

    # The state when a step starts (after the previous step's job drains), for intermediate snapshots.
    def state_now
      org ? final_state(org.reload) : nil
    end

    # A service called by the spec itself (or a helper), not by a request, a clock helper or a job drain.
    def direct_service?
      started? && !in_api && jobs_flag.nil? && depth.to_i.zero?
    end

    def from_spec?(locations)
      locations.any? { |l| l.path.to_s.include?("/spec/scenarios/") } &&
        locations.none? { |l| l.path.to_s.include?("/spec/support/") }
    end

    def ser(klass, rel, root, includes)
      rel.map { |x| klass.new(x, root_name: root, includes:).serialize.as_json }
    end

    def snapshot(org)
      {
        t: Time.current.utc.iso8601(6),
        organization: ::V1::OrganizationSerializer.new(org, root_name: "organization", includes: %i[taxes]).serialize.as_json,
        billable_metrics: ser(::V1::BillableMetricSerializer, org.billable_metrics.order(:created_at), "billable_metric", []),
        plans: ser(::V1::PlanSerializer, org.plans.order(:created_at), "plan",
          %i[charges fixed_charges usage_thresholds applicable_usage_thresholds taxes minimum_commitment]),
        customers: ser(::V1::CustomerSerializer, org.customers.order(:created_at), "customer", %i[taxes]),
        taxes: ser(::V1::TaxSerializer, org.taxes.order(:created_at), "tax", []),
        coupons: ser(::V1::CouponSerializer, org.coupons.order(:created_at), "coupon", []),
        add_ons: ser(::V1::AddOnSerializer, org.add_ons.order(:created_at), "add_on", %i[taxes]),
        wallets: ser(::V1::WalletSerializer, Wallet.where(organization_id: org.id).order(:created_at), "wallet", []),
        subscriptions: ser(::V1::SubscriptionSerializer, org.subscriptions.order(:created_at), "subscription", [])
      }
    rescue => e
      {error: "#{e.class}: #{e.message}"}
    end

    def capture_settings(org)
      be = org.default_billing_entity
      {
        organization: org.attributes.slice(*SETTING_COLUMNS),
        billing_entity: be ? be.attributes.slice(*ENTITY_COLUMNS) : nil,
        billing_entities_count: org.billing_entities.count,
        billing_entities: org.billing_entities.order(:created_at).to_h do |e|
          [e.code, e.attributes.slice(*ENTITY_COLUMNS).merge("tax_codes" => e.taxes.order(:created_at).pluck(:code))]
        end,
        billing_entity_tax_codes: be ? be.taxes.order(:created_at).pluck(:code) : [],
        premium: License.premium?,
        store: org.clickhouse_events_store? ? "ch" : "pg"
      }
    rescue => e
      {error: "#{e.class}: #{e.message}"}
    end

    def final_state(org)
      {
        invoices: ser(::V1::InvoiceSerializer, org.invoices.order(:created_at, :sequential_id, :number, :id), "invoice",
          %i[customer billing_periods subscriptions fees credits applied_taxes]),
        credit_notes: ser(::V1::CreditNoteSerializer, CreditNote.where(organization_id: org.id).order(:created_at, :sequential_id, :id),
          "credit_note", %i[items applied_taxes]),
        wallets: ser(::V1::WalletSerializer, Wallet.where(organization_id: org.id).order(:created_at, :id), "wallet", []),
        wallet_transactions: ser(::V1::WalletTransactionSerializer,
          WalletTransaction.where(organization_id: org.id).order(:created_at, :id), "wallet_transaction", []),
        subscriptions: ser(::V1::SubscriptionSerializer, org.subscriptions.order(:created_at, :id), "subscription", []),
        fees: ser(::V1::FeeSerializer, Fee.where(organization_id: org.id, invoice_id: nil).order(:created_at, :id), "fee", [])
      }
    rescue => e
      {error: "#{e.class}: #{e.message}"}
    end
  end

  module ApiTap
    %i[get_with_token post_with_token put_with_token patch_with_token delete_with_token].each do |m|
      define_method(m) do |organization, path, params = {}, headers = {}|
        rec = KitScenarioRecorder
        top = rec.active? && rec.depth.to_i.zero?
        rec.clock_step!(self) if top
        if rec.active? && rec.given.nil?
          rec.org = organization
          rec.given = rec.snapshot(organization)
          rec.settings = rec.capture_settings(organization)
        end
        before = top ? rec.state_now : nil
        rec.in_api = true
        t0 = Time.current
        begin
          out = super(organization, path, params, headers)
        ensure
          rec.in_api = false
        end
        body = begin
          response.body.present? && response.media_type.to_s.include?("json") ? JSON.parse(response.body) : response.body
        rescue JSON::ParserError
          response.body
        end
        bare, _, qs = path.partition("?")
        query = qs.empty? ? nil : Rack::Utils.parse_nested_query(qs)
        query = (query || {}).merge(params.as_json) if m == :get_with_token && params.present?
        rec.record({kind: "api", method: m.to_s.sub("_with_token", "").upcase, path: bare, query:,
          body: (m == :get_with_token) ? nil : params.as_json, status: response.status, response: body,
          perform_jobs: rec.jobs_flag}, t0, before)
        out
      end
    end
  end

  module ScenarioTap
    def api_call(perform_jobs: true, raise_on_error: true, &)
      KitScenarioRecorder.jobs_flag = perform_jobs
      super
    ensure
      KitScenarioRecorder.jobs_flag = nil
    end

    %i[perform_billing perform_invoices_refresh perform_finalize_refresh perform_usage_update perform_wallet_refresh
      perform_overdue_balance_update perform_dunning recalculate_wallet_balances].each do |m|
      define_method(m) do |*args, **kw, &blk|
        rec = KitScenarioRecorder
        if rec.started? && rec.depth.to_i.zero?
          rec.clock_step!(self)
          rec.record({kind: "clock", job: m.to_s}, nil, rec.state_now)
        end
        rec.depth = rec.depth.to_i + 1
        begin
          super(*args, **kw, &blk)
        ensure
          rec.depth -= 1
        end
      end
    end
  end

  module QueuesTap
    def perform_all_enqueued_jobs(...)
      rec = KitScenarioRecorder
      if rec.started? && rec.depth.to_i.zero? && rec.jobs_flag.nil? && rec.from_spec?(caller_locations(1, 2))
        rec.record({kind: "drain"}, nil, rec.state_now)
      end
      rec.depth = rec.depth.to_i + 1
      begin
        super
      ensure
        rec.depth -= 1
      end
    end
  end

  module ClockJobTap
    def perform_later(...)
      kit_clock_job_step
      super
    end

    def perform_now(...)
      kit_clock_job_step
      super
    end

    private

    def kit_clock_job_step
      rec = KitScenarioRecorder
      return unless rec.started? && rec.depth.to_i.zero? && name.to_s.start_with?("Clock::") &&
        rec.from_spec?(caller_locations(2, 3))

      rec.clock_step!(rec.example_instance)
      rec.record({kind: "clock_direct", job: name}, nil, rec.state_now)
    end
  end

  module ServiceTap
    def call(...)
      rec = KitScenarioRecorder
      rec.record(kind: "service", name: name) if rec.direct_service?
      super
    end

    def call!(...)
      rec = KitScenarioRecorder
      rec.record(kind: "service", name: name) if rec.direct_service?
      super
    end
  end

  module FactoryTap
    def create(name, *args, **kw, &blk)
      rec = KitScenarioRecorder
      rec.record(kind: "factory", name: name.to_s) if rec.started? && rec.from_spec?(caller_locations(1, 3))
      super
    end
  end
end

if KitScenarioRecorder::DIR.present?
  FileUtils.mkdir_p(KitScenarioRecorder::DIR)
  ApiHelper.prepend(KitScenarioRecorder::ApiTap)
  ScenariosHelper.prepend(KitScenarioRecorder::ScenarioTap)
  QueuesHelper.prepend(KitScenarioRecorder::QueuesTap)
  ActiveJob::Base.singleton_class.prepend(KitScenarioRecorder::ClockJobTap)
  FactoryBot::Syntax::Methods.prepend(KitScenarioRecorder::FactoryTap)
  KitScenarioRecorder::SERVICES.each do |s|
    klass = s.safe_constantize
    klass&.singleton_class&.prepend(KitScenarioRecorder::ServiceTap)
  end

  RSpec.configure do |config|
    config.before do
      KitScenarioRecorder.reset!
      KitScenarioRecorder.start_clock!(self)
    end
    config.after do |example|
      rec = KitScenarioRecorder
      steps, given, settings = rec.steps, rec.given, rec.settings
      rec.steps = nil
      # aggregate_failures (on for every example at the pin) wraps the after hooks: its collected failures count too.
      agg = RSpec::Support.failure_notifier
      failed = example.exception || (agg.respond_to?(:failures) && agg.failures.any?)
      if failed || steps.blank? || given.nil?
        travel_back
        next
      end

      org = respond_to?(:organization) ? organization : nil
      doc = {
        spec: "#{example.metadata[:file_path].sub(%r{\A\./}, "")}:#{example.metadata[:line_number]}",
        example_id: example.id,
        description: example.full_description,
        recorded_with: {lago_api: "591ae9005110", ruby: RUBY_VERSION, recorder: rec::VERSION},
        recorded_at: rec.real_now.iso8601,
        kit_clock: {epoch: rec::KIT_EPOCH.iso8601, rebased: rec.rebased},
        settings:,
        given:,
        steps:,
        final_state: org ? rec.final_state(org.reload) : nil,
        catalog_end: org ? rec.snapshot(org) : nil
      }
      name = example.id.sub(%r{\A\./}, "").gsub(/[^A-Za-z0-9]+/, "_")
      File.write(File.join(rec::DIR, "#{name}.json"), JSON.pretty_generate(doc))
      travel_back
    end
  end
end
