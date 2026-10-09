# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/clock.rb — oracle handlers for the `clock` area (billing-engine-spec chapter 13, rules BE-CK-*). Uses KitApiOps
# from ops/api.rb (loaded earlier: file-name order).
#
#   clock.termination_alert_due  the reference's hourly termination-alert job run at the vector's instant over
#                                subscriptions (factories) and previously recorded alert webhook rows; the answer is
#                                the set of subscriptions for which it enqueues the alert webhook
#   clock.jobs_due               the reference's clock file (clock.rb) driven by the clockwork test harness over
#                                [from, to) with 1-second ticks under the vector's environment; a run counts only
#                                when the scheduled block really enqueues its job (the block is invoked once)
#   clock.idempotency_key        the idempotency-key service; the SHA-256 pre-image is captured from the digest call
#
# Stand-ins (stated so the evidence stays honest): job uniqueness locks run in the gem's test mode; the clockwork test
# harness advances a simulated clock (real elapsed time adds sub-second drift, so vectors keep away from tick edges).

require "json"

module KitApiOps
  module Clock
    module_function

    CLOCK_ENV = %w[
      LAGO_SUBSCRIPTION_ACTIVITY_PROCESSING_INTERVAL_SECONDS LAGO_LIFETIME_USAGE_REFRESH_INTERVAL_SECONDS
      LAGO_DISABLE_LIFETIME_USAGE_REFRESH LAGO_MEMCACHE_SERVERS LAGO_REDIS_CACHE_URL LAGO_DISABLE_WALLET_REFRESH
      LAGO_WALLET_ONGOING_BALANCE_REFRESH_INTERVAL_SECONDS LAGO_DISABLE_EVENTS_VALIDATION LAGO_REDIS_STORE_URL
      LAGO_CLICKHOUSE_ENABLED
    ].freeze

    def uniqueness_test_mode!
      return if @uniq

      ActiveJob::Uniqueness.test_mode! if defined?(ActiveJob::Uniqueness)
      @uniq = true
    end

    def enqueued_count
      ActiveJob::Base.queue_adapter.enqueued_jobs.size
    end
  end
end

# ---------------------------------------------------------------------------------------------------------------
# clock.termination_alert_due
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("clock.termination_alert_due") do |input, ctx|
  KitApiOps.install!
  KitApiOps::Clock.uniqueness_test_mode!
  now = ctx.instant(input.fetch("now"))
  days = input.fetch("days", [15, 45])
  ctx.bad_input!("days must be a list of integers") unless days.is_a?(Array) && days.all?(Integer)
  subs_in = input.fetch("subscriptions")
  sent = input.fetch("alerts_sent", [])

  ctx.rollback do
    subs = {}
    org = customer = nil
    ctx.travel(now - 40.days) do
      org = FactoryBot.create(:organization) # its factory endpoint makes the organization "have endpoints"
      customer = FactoryBot.create(:customer, organization: org)
    end
    plan = FactoryBot.create(:plan, organization: org)
    subs_in.each do |s|
      label = s.fetch("id")
      status = s.fetch("status", "active")
      attrs = {customer:, plan:, organization: org, status:, external_id: "kit-#{label}",
               subscription_at: now - 30.days, started_at: (status == "pending") ? nil : now - 30.days,
               ending_at: s["ending_at"] && ctx.instant(s["ending_at"])}
      attrs[:terminated_at] = now - 1.day if status == "terminated"
      attrs[:canceled_at] = now - 1.day if status == "canceled"
      sub = Subscription.new(attrs)
      sub.save!(validate: false)
      subs[label] = sub
    end
    ep = org.webhook_endpoints.first
    sent.each do |a|
      sub = subs.fetch(a.fetch("subscription"))
      Webhook.create!(organization: org, webhook_endpoint: ep, webhook_type: "subscription.termination_alert",
        object: sub, status: :succeeded, created_at: ctx.instant(a.fetch("created_at")))
    end

    adapter = ActiveJob::Base.queue_adapter
    adapter.enqueued_jobs.clear
    KitApiOps.with_env("LAGO_SUBSCRIPTION_TERMINATION_ALERT_SENT_AT_DAYS" => days.join(",")) do
      ctx.travel(now) { ::Clock::SubscriptionsToBeTerminatedJob.perform_now }
    end
    by_id = subs.to_h { |label, sub| [sub.id, label] }
    due = adapter.enqueued_jobs.select { |j| j[:job] == SendWebhookJob }.filter_map do |j|
      type, object = ActiveJob::Arguments.deserialize(j[:args])
      by_id[object.id] if type == "subscription.termination_alert"
    end
    {"due" => due.sort}
  end
end

# ---------------------------------------------------------------------------------------------------------------
# clock.jobs_due
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("clock.jobs_due") do |input, ctx|
  require "clockwork/test"
  KitApiOps::Clock.uniqueness_test_mode!
  from = ctx.instant(input.fetch("from"))
  to = ctx.instant(input.fetch("to"))
  ctx.bad_input!("from must precede to") unless from < to
  # the test harness ticks at from + k s; production ticks at whole seconds: they agree only for a whole-second start
  ctx.bad_input!("from must be a whole second (fractional starts are not graded, BE-CK-2)") unless from.subsec.zero?
  ctx.bad_input!("window longer than 6 hours") if to - from > 6.hours
  env_in = input.fetch("env", {})
  ctx.bad_input!("env must be an object") unless env_in.is_a?(Hash)
  unknown = env_in.keys - KitApiOps::Clock::CLOCK_ENV
  ctx.bad_input!("unsupported env keys #{unknown.join(",")}") if unknown.any?
  env = KitApiOps::Clock::CLOCK_ENV.to_h { |k| [k, env_in[k]] }.merge("TZ" => "UTC")

  runs = {}
  KitApiOps.with_env(env) do
    ::Clockwork::Test.clear!
    begin
      ::Clockwork::Test.run(file: Rails.root.join("clock.rb"), start_time: from, end_time: to, tick_speed: 1.second)
      history = ::Clockwork::Test.manager.send(:history)
      history.jobs.each do |job|
        count = ::Clockwork::Test.times_run(job)
        next if count.zero?

        before = KitApiOps::Clock.enqueued_count
        ::Clockwork::Test.block_for(job).call
        enqueues = KitApiOps::Clock.enqueued_count > before
        runs[job.delete_prefix("schedule:")] = count if enqueues
      end
    ensure
      ::Clockwork::Test.clear!
    end
  end
  {"runs" => runs.sort.to_h}
end

# ---------------------------------------------------------------------------------------------------------------
# clock.idempotency_key
# ---------------------------------------------------------------------------------------------------------------
KitOracle.op("clock.idempotency_key") do |input, ctx|
  parts = input.fetch("parts")
  ctx.bad_input!("parts must be a non-empty object") unless parts.is_a?(Hash) && parts.any?
  result, seen = KitApiOps.capture_sha256 do
    IdempotencyRecords::KeyService.call!(**parts.transform_keys(&:to_sym))
  end
  {"preimage" => seen.last, "sha256_hex" => result.idempotency_key.unpack1("H*")}
end
