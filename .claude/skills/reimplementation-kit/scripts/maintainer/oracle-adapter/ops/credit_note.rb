# frozen_string_literal: true

# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
#
# ops/credit_note.rb — oracle handlers for the `credit_notes` area (billing-engine-spec chapter 08, rules BE-CN-*).
# The invoice a credit note refers to is built by KitOracleInvoicing.run_totals (ops/invoice.rb, same fee/coupon/tax
# pipeline as invoice.totals), then set to the requested status/payment state. Every credit-note value comes from the
# reference services at the pin, inside ctx.rollback with the premium licence flag on:
#   credit_notes.compute      CreditNotes::CreateService (items, coupon adjustment, taxes, last-note tax residue,
#                             validation, rounding adjustment); earlier notes of the invoice are created the same way
#   credit_notes.estimate     CreditNotes::EstimateService
#   credit_notes.termination  CreditNotes::CreateFromTermination (real subscription, plan, dates service, paid share)
#   credit_notes.validate     CreditNotes::CreateService, reporting its validation errors instead of raising them

module KitOracleCreditNotes
  module_function

  def build_invoice(ctx, inv_in)
    _book, invoice, _ex = KitOracleInvoicing.run_totals(ctx, inv_in.merge("context" => "finalize"))
    book = _book
    status = inv_in.fetch("status", "finalized")
    invoice.update!(
      status:,
      payment_status: inv_in.fetch("payment_status", invoice.payment_status),
      total_paid_amount_cents: Integer(inv_in.fetch("total_paid_amount_cents", 0)),
      version_number: inv_in.fetch("version_number", 4)
    )
    [book, invoice.reload]
  end

  def items_for(book, items)
    Array(items).map do |it|
      raw = it.fetch("amount_cents")
      amount = raw.is_a?(String) ? BigDecimal(raw) : raw
      real = book.fee_ids.key(it.fetch("fee_id")) || SecureRandom.uuid # an unknown kit fee id stays unknown
      {fee_id: real, amount_cents: amount}
    end
  end

  def create(ctx, book, invoice, cn_in)
    CreditNotes::CreateService.call(
      invoice: invoice.reload,
      items: items_for(book, cn_in["items"]),
      credit_amount_cents: Integer(cn_in.fetch("credit_amount_cents", 0)),
      refund_amount_cents: Integer(cn_in.fetch("refund_amount_cents", 0)),
      offset_amount_cents: Integer(cn_in.fetch("offset_amount_cents", 0)),
      reason: :other,
      automatic: cn_in.fetch("automatic", false)
    )
  end

  def errors_of(result)
    err = result.error
    case err
    when BaseService::ValidationFailure then err.messages.transform_keys(&:to_s).transform_values { |v| Array(v).map(&:to_s) }
    when BaseService::MethodNotAllowedFailure then {"base" => [err.code.to_s]}
    when BaseService::ForbiddenFailure then {"base" => [err.code.to_s.presence || "feature_unavailable"]}
    when BaseService::NotFoundFailure then {"base" => [err.error_code.to_s]}
    else {"base" => [err.class.name]}
    end
  end

  def first_error!(ctx, result)
    errs = errors_of(result)
    field, codes = errs.first
    ctx.domain_error!(codes.first, field)
  end

  def cn_out(book, cn)
    {
      "status" => cn.status,
      "credit_status" => cn.credit_status,
      "refund_status" => cn.refund_status,
      "items" => cn.items.sort_by(&:created_at).map do |i|
        {"fee_id" => book.fee_ids[i.fee_id], "amount_cents" => i.amount_cents, "precise_amount_cents" => i.precise_amount_cents}
      end,
      "coupons_adjustment_amount_cents" => cn.coupons_adjustment_amount_cents,
      "precise_coupons_adjustment_amount_cents" => cn.precise_coupons_adjustment_amount_cents,
      "taxes_amount_cents" => cn.taxes_amount_cents,
      "precise_taxes_amount_cents" => cn.precise_taxes_amount_cents,
      "taxes_rate" => cn.taxes_rate,
      "sub_total_excluding_taxes_amount_cents" => cn.sub_total_excluding_taxes_amount_cents,
      "credit_amount_cents" => cn.credit_amount_cents,
      "refund_amount_cents" => cn.refund_amount_cents,
      "offset_amount_cents" => cn.offset_amount_cents,
      "total_amount_cents" => cn.total_amount_cents,
      "balance_amount_cents" => cn.balance_amount_cents,
      "applied_taxes" => cn.applied_taxes.sort_by(&:tax_code).map do |at|
        {"code" => at.tax_code, "amount_cents" => at.amount_cents, "base_amount_cents" => at.base_amount_cents}
      end
    }
  end

  def setup_previous(ctx, book, invoice, prev)
    Array(prev).each do |p|
      r = create(ctx, book, invoice, p)
      ctx.bad_input!("previous credit note rejected: #{errors_of(r)}") unless r.success?
    end
  end
end

KitOracle.op("credit_notes.compute") do |input, ctx|
  ctx.rollback do
    ctx.travel(KitOracleInvoicing::BASE_TIME + 7200) do
      ctx.premium(input.fetch("premium", true)) do
        book, invoice = KitOracleCreditNotes.build_invoice(ctx, input.fetch("invoice"))
        KitOracleCreditNotes.setup_previous(ctx, book, invoice, input["previous_credit_notes"])
        r = KitOracleCreditNotes.create(ctx, book, invoice, input)
        KitOracleCreditNotes.first_error!(ctx, r) unless r.success?
        cn = r.credit_note.reload
        out = KitOracleCreditNotes.cn_out(book, cn)
        invoice.reload
        out["invoice_after"] = {
          "creditable_amount_cents" => invoice.creditable_amount_cents,
          "total_due_amount_cents" => invoice.total_due_amount_cents,
          "payment_status" => invoice.payment_status
        }
        out
      end
    end
  end
end

KitOracle.op("credit_notes.validate") do |input, ctx|
  ctx.rollback do
    ctx.travel(KitOracleInvoicing::BASE_TIME + 7200) do
      ctx.premium(input.fetch("premium", true)) do
        book, invoice = KitOracleCreditNotes.build_invoice(ctx, input.fetch("invoice"))
        KitOracleCreditNotes.setup_previous(ctx, book, invoice, input["previous_credit_notes"])
        r = KitOracleCreditNotes.create(ctx, book, invoice, input.fetch("request"))
        r.success? ? {"valid" => true, "errors" => {}} : {"valid" => false, "errors" => KitOracleCreditNotes.errors_of(r)}
      end
    end
  end
end

KitOracle.op("credit_notes.estimate") do |input, ctx|
  ctx.rollback do
    ctx.travel(KitOracleInvoicing::BASE_TIME + 7200) do
      ctx.premium(input.fetch("premium", true)) do
        book, invoice = KitOracleCreditNotes.build_invoice(ctx, input.fetch("invoice"))
        KitOracleCreditNotes.setup_previous(ctx, book, invoice, input["previous_credit_notes"])
        r = CreditNotes::EstimateService.call(invoice: invoice.reload,
          items: KitOracleCreditNotes.items_for(book, input.fetch("items")))
        KitOracleCreditNotes.first_error!(ctx, r) unless r.success?
        cn = r.credit_note
        {
          "items" => cn.items.map { |i| {"fee_id" => book.fee_ids[i.fee_id], "amount_cents" => i.amount_cents} },
          "coupons_adjustment_amount_cents" => cn.coupons_adjustment_amount_cents,
          "precise_coupons_adjustment_amount_cents" => cn.precise_coupons_adjustment_amount_cents,
          "taxes_amount_cents" => cn.taxes_amount_cents,
          "precise_taxes_amount_cents" => cn.precise_taxes_amount_cents,
          "taxes_rate" => cn.taxes_rate,
          "sub_total_excluding_taxes_amount_cents" => cn.sub_total_excluding_taxes_amount_cents,
          "max_creditable_amount_cents" => cn.credit_amount_cents,
          "max_refundable_amount_cents" => cn.refund_amount_cents,
          "applied_taxes" => cn.applied_taxes.sort_by(&:tax_code).map do |at|
            {"code" => at.tax_code, "amount_cents" => at.amount_cents, "base_amount_cents" => at.base_amount_cents}
          end
        }
      end
    end
  end
end

KitOracle.op("credit_notes.termination") do |input, ctx|
  ctx.rollback do
    term_at = ctx.instant(input.fetch("terminated_at"))
    ctx.travel(term_at) do
      plan_in = input.fetch("plan")
      sub_in = input.fetch("subscription")
      inv_in = input.fetch("invoice")
      fee_in = {"id" => "sub_fee", "fee_type" => "subscription", "plan_code" => "plan",
                "amount_cents" => inv_in.fetch("subscription_fee_amount_cents"), "taxes" => inv_in.fetch("taxes", [])}
      totals_in = {
        "currency" => input.fetch("currency", "EUR"),
        "customer" => {"timezone" => input["timezone"]}.compact,
        "fees" => [fee_in] + Array(inv_in["other_fees"]),
        "applied_coupons" => inv_in["applied_coupons"],
        "plans" => {"plan" => plan_in},
        "subscriptions" => {"plan" => sub_in.merge("status" => "terminated", "terminated_at" => input.fetch("terminated_at"))},
        "status" => "finalized",
        "payment_status" => inv_in.fetch("payment_status", "pending"),
        "total_paid_amount_cents" => inv_in.fetch("total_paid_amount_cents", 0)
      }.compact
      book, invoice = KitOracleCreditNotes.build_invoice(ctx, totals_in)
      ctx.premium(true) { KitOracleCreditNotes.setup_previous(ctx, book, invoice, input["previous_credit_notes"]) }
      sub = book.subscription("plan").reload
      r = CreditNotes::CreateFromTermination.call(subscription: sub, upgrade: input.fetch("upgrade", false),
        on_termination: input.fetch("on_termination", "credit").to_sym)
      KitOracleCreditNotes.first_error!(ctx, r) unless r.success?
      cn = r.credit_note
      {"credit_note" => cn && KitOracleCreditNotes.cn_out(book, cn.reload)}
    end
  end
end
