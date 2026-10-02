# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/domain.rb — oracle handlers for the `domain` area (billing-engine-spec chapter 01, rules BE-DM-*).
# Every handler drives lago-api code at the pin: model methods, model callbacks (numbering, slugs, prefixes),
# model validations (code uniqueness), class methods (charge-filter codes) and services (fee taxes). Records are
# created with FactoryBot inside ctx.rollback, so nothing persists. The built-ins domain.days_between and
# domain.round (oracle_adapter.rb) are kept as they are.
#
# Two handlers evaluate an identity inside the pinned runtime instead of a reference method, and say so:
#   domain.to_minor_units  precise_amount_cents = amount x subunit_to_unit (amount_cents comes from the Fee money
#                          attribute setter, the real path)
#   domain.currency_exponent  reads the currency table of the pinned bundle (Money::Currency) and the accepted list.

module KitOracleDomain
  module_function

  FINALIZING_FROM = %w[draft generating open failed pending].freeze

  def fb
    FactoryBot
  end

  def str_or_nil(v)
    v.nil? ? nil : v.to_s
  end

  # The first message of an attribute's errors (the reference's error code, e.g. value_already_exist).
  def first_error(record, attr)
    record.valid?
    msgs = record.errors.to_hash[attr.to_sym] || []
    msgs.first
  end

  def organization(ctx, prefix: nil, name: "Kit Org")
    org = fb.create(:organization, name:, webhook_url: nil)
    org.update_columns(document_number_prefix: prefix) if prefix # rubocop:disable Rails/SkipsModelValidations
    org
  end
end

# --- time ------------------------------------------------------------------------------------------------------

KitOracle.op("domain.effective_timezone") do |input, ctx|
  be = BillingEntity.new(timezone: input["billing_entity_timezone"])
  customer = Customer.new(timezone: input["customer_timezone"], billing_entity: be)
  {"timezone" => customer.applicable_timezone}
end

KitOracle.op("domain.applicable_settings") do |input, ctx|
  c_in = input.fetch("customer")
  be_in = input.fetch("billing_entity")
  keys = %w[timezone invoice_grace_period net_payment_term subscription_invoice_issuing_date_anchor
    subscription_invoice_issuing_date_adjustment document_locale]
  be = BillingEntity.new(be_in.slice(*keys))
  customer = Customer.new(c_in.slice(*keys).merge(billing_entity: be))
  {
    "timezone" => customer.applicable_timezone,
    "invoice_grace_period" => customer.applicable_invoice_grace_period,
    "net_payment_term" => customer.applicable_net_payment_term,
    "subscription_invoice_issuing_date_anchor" => customer.applicable_subscription_invoice_issuing_date_anchor,
    "subscription_invoice_issuing_date_adjustment" => customer.applicable_subscription_invoice_issuing_date_adjustment,
    "document_locale" => customer.preferred_document_locale.to_s
  }
end

# An instant expressed in a zone: the reference converts with in_time_zone (customer-timezone helpers). The kit's
# encoding of the result is fixed here: seconds precision, numeric offset (never "Z").
KitOracle.op("domain.to_local") do |input, ctx|
  t = ctx.instant(input.fetch("instant"))
  probe = Struct.new(:applicable_timezone).new(input.fetch("timezone"))
  local = t.in_time_zone(probe.applicable_timezone)
  {
    "local" => local.strftime("%Y-%m-%dT%H:%M:%S%:z"),
    "local_date" => local.to_date.iso8601,
    "utc_offset_seconds" => local.utc_offset
  }
end

KitOracle.op("domain.terminated_at_reached") do |input, ctx|
  sub = Subscription.new(status: input.fetch("status", "terminated"), terminated_at: ctx.instant(input.fetch("terminated_at")))
  {"reached" => sub.terminated_at?(ctx.instant(input.fetch("at")))}
end

# --- money -----------------------------------------------------------------------------------------------------

KitOracle.op("domain.currency_exponent") do |input, ctx|
  code = input.fetch("currency")
  cur = Money::Currency.find(code)
  ctx.domain_error!("value_is_invalid", "currency") unless cur
  {
    "exponent" => cur.exponent,
    "subunit_to_unit" => cur.subunit_to_unit,
    "accepted" => Currencies::ACCEPTED_CURRENCIES.key?(code.to_sym)
  }
end

KitOracle.op("domain.to_minor_units") do |input, ctx|
  amount = ctx.dec(input.fetch("amount"))
  code = input.fetch("currency")
  fee = Fee.new(amount_currency: code)
  fee.amount = amount # money attribute setter of the fee model (configured rounding mode)
  cur = fee.amount.currency
  ctx.bad_input!("currency #{code} has a non-decimal minor unit") unless cur.subunit_to_unit == 10**cur.exponent
  {"amount_cents" => fee.amount_cents, "precise_amount_cents" => amount * cur.subunit_to_unit}
end

KitOracle.op("domain.fee_taxes") do |input, ctx|
  ctx.rollback do
    currency = input.fetch("currency", "EUR")
    org = KitOracleDomain.organization(ctx)
    customer = FactoryBot.create(:customer, organization: org, currency:)
    taxes = input.fetch("taxes").map do |t|
      FactoryBot.create(:tax, organization: org, code: t.fetch("code"), rate: Float(t.fetch("rate")))
    end
    subscription = FactoryBot.create(:subscription, customer:, organization: org)
    amount_cents = Integer(input.fetch("amount_cents"))
    precise = ctx.dec(input.fetch("precise_amount_cents", amount_cents))
    fee = FactoryBot.build(:fee, organization: org, billing_entity: customer.billing_entity, invoice: nil, subscription:,
      amount_cents:, precise_amount_cents: precise, amount_currency: currency,
      precise_coupons_amount_cents: ctx.dec(input.fetch("precise_coupons_amount_cents")), taxes_amount_cents: 0)
    Fees::ApplyTaxesService.call!(fee:, tax_codes: taxes.map(&:code))
    order = taxes.map(&:code)
    applied = fee.applied_taxes.sort_by { |at| order.index(at.tax_code) }.map do |at|
      {"code" => at.tax_code, "amount_cents" => at.amount_cents, "precise_amount_cents" => at.precise_amount_cents}
    end
    {
      "applied" => applied,
      "taxes_amount_cents" => fee.taxes_amount_cents,
      "taxes_precise_amount_cents" => fee.taxes_precise_amount_cents,
      "taxes_rate" => fee.taxes_rate
    }
  end
end

# --- numbering -------------------------------------------------------------------------------------------------

KitOracle.op("domain.document_prefix") do |input, ctx|
  ctx.rollback do
    org = KitOracleDomain.organization(ctx)
    be = FactoryBot.build(:billing_entity, organization: org, id: input.fetch("record_id"), name: input.fetch("name"),
      document_number_prefix: input["supplied_prefix"])
    ctx.domain_error!(be.errors.to_hash.values.flatten.first, be.errors.to_hash.keys.first) unless be.save
    {"prefix" => be.reload.document_number_prefix}
  end
end

KitOracle.op("domain.customer_slug") do |input, ctx|
  ctx.rollback do
    org = KitOracleDomain.organization(ctx, prefix: input.fetch("organization_prefix"))
    customer = FactoryBot.create(:customer, organization: org, sequential_id: Integer(input.fetch("sequential_id")))
    {"slug" => customer.reload.slug}
  end
end

KitOracle.op("domain.next_sequential_id") do |input, ctx|
  existing = input.fetch("existing")
  ctx.rollback do
    org = KitOracleDomain.organization(ctx)
    case input.fetch("scope")
    when "customer"
      other = KitOracleDomain.organization(ctx, name: "Other Org")
      existing.each do |row|
        c = FactoryBot.create(:customer, organization: row["other_scope"] ? other : org, sequential_id: Integer(row.fetch("seq")))
        c.discard! if row["deleted"]
      end
      {"next" => FactoryBot.create(:customer, organization: org).sequential_id}
    when "invoice", "billing_entity_invoice"
      be_scope = input.fetch("scope") == "billing_entity_invoice"
      be = org.default_billing_entity
      be.update!(document_numbering: be_scope ? "per_billing_entity" : "per_customer")
      other_be = FactoryBot.create(:billing_entity, organization: org, document_numbering: be.document_numbering)
      customer = FactoryBot.create(:customer, organization: org, billing_entity: be)
      existing.each do |row|
        seq = row["seq"].nil? ? nil : Integer(row["seq"])
        attrs = {customer:, organization: org, billing_entity: row["other_scope"] ? other_be : be,
                 status: row.fetch("status", "finalized"), self_billed: row.fetch("self_billed", false), number: "KIT-#{SecureRandom.hex(4)}"}
        attrs[be_scope ? :billing_entity_sequential_id : :sequential_id] = seq
        attrs[:sequential_id] ||= 900_000 + rand(99_999) if be_scope # keep the per-customer counter out of the way
        FactoryBot.create(:invoice, **attrs)
      end
      inv = FactoryBot.create(:invoice, customer:, organization: org, billing_entity: be, status: :draft,
        self_billed: input.fetch("self_billed", false), sequential_id: nil, number: nil)
      inv.update!(status: :finalized)
      {"next" => be_scope ? inv.billing_entity_sequential_id : inv.sequential_id}
    when "credit_note"
      customer = FactoryBot.create(:customer, organization: org)
      invoice = FactoryBot.create(:invoice, customer:, organization: org, number: "INV-001")
      other_invoice = FactoryBot.create(:invoice, customer:, organization: org, number: "INV-002")
      existing.each do |row|
        FactoryBot.create(:credit_note, customer:, invoice: row["other_scope"] ? other_invoice : invoice,
          organization: org, sequential_id: Integer(row.fetch("seq")), status: row.fetch("status", "finalized"))
      end
      {"next" => FactoryBot.create(:credit_note, customer:, invoice:, organization: org).sequential_id}
    else
      ctx.bad_input!("scope must be customer|invoice|billing_entity_invoice|credit_note")
    end
  end
end

KitOracle.op("domain.invoice_number") do |input, ctx|
  status = input.fetch("status")
  previous = input.fetch("previous_status", status)
  ctx.rollback do
    org = KitOracleDomain.organization(ctx)
    be = org.default_billing_entity
    be.update!(document_number_prefix: input.fetch("prefix"), document_numbering: input.fetch("numbering"),
      timezone: input.fetch("billing_entity_timezone"))
    customer = FactoryBot.create(:customer, organization: org, billing_entity: be,
      sequential_id: Integer(input.fetch("customer_sequential_id")))
    inv = nil
    ctx.travel(input.fetch("now")) do
      inv = FactoryBot.create(:invoice, customer:, organization: org, billing_entity: be, status: previous,
        self_billed: input.fetch("self_billed"), number: input.fetch("number", ""),
        sequential_id: input["invoice_sequential_id"], billing_entity_sequential_id: input["billing_entity_sequential_id"])
      inv.update!(status:) if status != previous
    end
    {"number" => inv.reload.number}
  end
end

KitOracle.op("domain.credit_note_number") do |input, ctx|
  status = input.fetch("status", "finalized")
  previous = input.fetch("previous_status", status)
  ctx.rollback do
    org = KitOracleDomain.organization(ctx)
    customer = FactoryBot.create(:customer, organization: org)
    invoice = FactoryBot.create(:invoice, customer:, organization: org, number: input.fetch("invoice_number"))
    cn = FactoryBot.create(:credit_note, customer:, invoice:, organization: org, status: previous,
      sequential_id: Integer(input.fetch("sequential_id")), number: input["number"])
    cn.update!(status:) if status != previous
    {"number" => cn.reload.number}
  end
end

# --- catalog ---------------------------------------------------------------------------------------------------

KitOracle.op("domain.code_reusable") do |input, ctx|
  kind = input.fetch("kind")
  code = input.fetch("code")
  ctx.rollback do
    org = KitOracleDomain.organization(ctx)
    plan = FactoryBot.create(:plan, organization: org, code: "kit_parent_plan")
    customer = FactoryBot.create(:customer, organization: org, external_id: "kit_wallet_owner")
    make = lambda do |c, persist|
      method = persist ? :create : :build
      case kind
      when "tax" then FactoryBot.send(method, :tax, organization: org, code: c)
      when "billable_metric" then FactoryBot.send(method, :billable_metric, organization: org, code: c)
      when "coupon" then FactoryBot.send(method, :coupon, organization: org, code: c)
      when "add_on" then FactoryBot.send(method, :add_on, organization: org, code: c)
      when "plan" then FactoryBot.send(method, :plan, organization: org, code: c)
      when "charge"
        FactoryBot.send(method, :standard_charge, plan:, organization: org, code: c,
          billable_metric: FactoryBot.create(:billable_metric, organization: org))
      when "fixed_charge"
        FactoryBot.send(method, :fixed_charge, plan:, organization: org, code: c,
          add_on: FactoryBot.create(:add_on, organization: org))
      when "billing_entity" then FactoryBot.send(method, :billing_entity, organization: org, code: c)
      when "customer" then FactoryBot.send(method, :customer, organization: org, external_id: c)
      when "wallet" then FactoryBot.send(method, :wallet, customer:, organization: org, code: c)
      else ctx.bad_input!("unknown kind #{kind}")
      end
    end
    attr = (kind == "customer") ? :external_id : :code
    input.fetch("existing").each do |row|
      rec = make.call(row.fetch("code"), true)
      rec.update!(archived_at: Time.current) if row["archived"]
      rec.update!(status: :terminated, terminated_at: Time.current) if row["status"] == "terminated"
      rec.discard! if row["deleted"]
    end
    candidate = make.call(code, false)
    err = KitOracleDomain.first_error(candidate, attr)
    {"valid" => err.nil?, "error" => err}
  end
end

KitOracle.op("domain.subscription_external_id_valid") do |input, ctx|
  ctx.rollback do
    org = KitOracleDomain.organization(ctx)
    customer = FactoryBot.create(:customer, organization: org)
    other_customer = FactoryBot.create(:customer, organization: org)
    plan = FactoryBot.create(:plan, organization: org)
    input.fetch("existing").each do |row|
      attrs = {organization: org, customer: row["other_customer"] ? other_customer : customer, plan:,
               external_id: row.fetch("external_id"), status: row.fetch("status")}
      attrs[:terminated_at] = Time.current if row.fetch("status") == "terminated"
      attrs[:canceled_at] = Time.current if row.fetch("status") == "canceled"
      FactoryBot.create(:subscription, **attrs)
    end
    cand = input.fetch("candidate")
    sub = FactoryBot.build(:subscription, organization: org, customer:, plan:, external_id: cand.fetch("external_id"),
      status: cand.fetch("status"))
    err = KitOracleDomain.first_error(sub, :external_id)
    {"valid" => err.nil?, "error" => err}
  end
end

KitOracle.op("domain.charge_filter_code") do |input, ctx|
  base = ChargeFilter.generate_code(input.fetch("values"))
  {"base_code" => base, "code" => ChargeFilter.next_free_code(base, input.fetch("taken", []).to_set)}
end
