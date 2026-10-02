"""Invoice totals pipeline, taxes, coupons and lifecycle helpers (billing spec chapter 07)."""
from __future__ import annotations

import datetime as dt
from decimal import Decimal
from zoneinfo import ZoneInfo

from common import (KitError, ZERO, dec, exact, float_round, frnd, pct16, rint, rnd, store5, trunc)


# ---------------------------------------------------------------------------------------------- parsing
class Fee:
    def __init__(self, d, idx=0):
        self.idx = idx
        self.id = d["id"]
        self.fee_type = d.get("fee_type", "charge")
        self.amount = int(d["amount_cents"])
        self.precise = dec(d["precise_amount_cents"]) if "precise_amount_cents" in d else Decimal(self.amount)
        self.pc = dec(d.get("precise_coupons_amount_cents", 0))
        self.plan_code = d.get("plan_code", "plan")
        self.metric = d.get("billable_metric_code")
        self.taxes = [(t["code"], dec(t["rate"])) for t in d.get("taxes", [])]
        self.cn = ZERO
        # results
        self.rows = []
        self.tax_amount = 0
        self.tax_precise = ZERO
        self.tax_rate = ZERO


class Coupon:
    def __init__(self, d):
        self.id = d.get("id")
        self.type = d["coupon_type"]
        self.amount = d.get("amount_cents")
        self.currency = d.get("amount_currency")
        self.rate = dec(d["percentage_rate"]) if d.get("percentage_rate") is not None else None
        self.frequency = d.get("frequency", "once")
        self.duration = d.get("frequency_duration")
        rem = d.get("frequency_duration_remaining")
        self.remaining = rem if rem is not None else self.duration
        self.used = d.get("used_amount_cents", 0)
        self.plans = list(d.get("limited_plan_codes", []))
        self.metrics = list(d.get("limited_billable_metric_codes", []))
        self.status = d.get("status", "active")
        self.coupon_status = d.get("coupon_status", "active")


# ---------------------------------------------------------------------------------------------- taxes
def factor(rate, ex):
    return dec(rate) / 100 if ex else pct16(rate)


def fee_taxes(f: Fee, ex=False):
    base = f.amount - f.pc
    pbase = f.precise - f.pc
    rows, tot, ptot, rate = [], ZERO, ZERO, ZERO
    for code, r in sorted(f.taxes, key=lambda t: t[0]):
        fac = factor(r, ex)
        amt = base * fac
        pamt = pbase * fac
        rows.append({"code": code, "amount_cents": rint(amt), "precise_amount_cents": pamt})
        tot += amt
        ptot += pamt
        rate += r
    f.rows = rows
    f.tax_amount = rint(tot)
    f.tax_precise = ptot
    f.tax_rate = rate


def invoice_taxes(fees, sub_total, ex=False):
    codes = {}
    for f in fees:
        for code, r in f.taxes:
            codes.setdefault(code, r)
    rows, unrounded, rate = [], ZERO, ZERO if ex else 0.0
    for code in sorted(codes):
        r = codes[code]
        taxed = [f for f in fees if any(c == code for c, _ in f.taxes)]
        base = sum((f.amount - f.pc for f in taxed), ZERO)
        contrib = base * factor(r, ex)
        rows.append({"code": code, "tax_rate": r, "fees_amount_cents": trunc(base), "amount_cents": rint(contrib)})
        unrounded += contrib
        if ex:
            share = base / dec(sub_total) if sub_total > 0 else Decimal(len(taxed)) / Decimal(len(fees))
            rate += share * r
        else:
            share = float(base) / float(sub_total) if sub_total > 0 else len(taxed) / len(fees)
            rate += share * float(r)
    if ex:
        trate = rnd(rate, 5)
    else:
        trate = Decimal(repr(float_round(rate, 5))) if fees else ZERO
    return rows, rint(unrounded), trate


def fee_out(f: Fee):
    return {
        "id": f.id,
        "precise_coupons_amount_cents": f.pc,
        "taxes_amount_cents": f.tax_amount,
        "taxes_precise_amount_cents": f.tax_precise,
        "taxes_rate": f.tax_rate,
        "precise_credit_notes_amount_cents": f.cn,
        "applied_taxes": f.rows,
    }


def apply_taxes(inp, ctx):
    ex = exact(ctx)
    fees = [Fee(d, i) for i, d in enumerate(inp["fees"])]
    sub = inp.get("sub_total_excluding_taxes_amount_cents")
    sub = sum(f.amount for f in fees) if sub is None else int(sub)
    for f in fees:
        fee_taxes(f, ex)
    rows, total, rate = invoice_taxes(fees, sub, ex)
    return {"fees": [fee_out(f) for f in fees], "applied_taxes": rows, "taxes_amount_cents": total, "taxes_rate": rate}


def fee_tax_selection(inp, ctx):
    explicit = inp.get("explicit_tax_codes")
    ft = inp["fee_type"]
    chain = []
    if explicit:
        chain.append(explicit)
    if ft == "add_on":
        chain.append(inp.get("add_on_taxes", []))
    if ft == "charge":
        chain.append(inp.get("charge_taxes", []))
    if ft == "fixed_charge":
        chain.append(inp.get("fixed_charge_taxes", []))
    if ft == "commitment":
        chain.append(inp.get("commitment_taxes", []))
    if ft in ("charge", "subscription", "commitment", "fixed_charge"):
        chain.append(inp.get("plan_taxes", []))
    if ft != "credit":
        chain.append(inp.get("customer_taxes", []))
        chain.append(inp.get("billing_entity_taxes", []))
    for c in chain:
        if c:
            return {"taxes": list(c)}
    return {"taxes": []}


# ---------------------------------------------------------------------------------------------- coupons
def coupon_amount_value(B, ac: Coupon, ex=False):
    """Returns (amount Decimal, remaining_amount or None)."""
    remaining = None
    if ac.type == "percentage":
        rate = ac.rate
        if isinstance(B, int) and not ex:
            v = float(B) * (float(rate) / 100.0)
            amt = Decimal(B) if v >= B else Decimal(frnd(v))
        else:
            Bd = dec(B)
            v = Bd * (rate / 100 if ex else pct16(rate))
            amt = Bd if v >= Bd else rnd(v)
    else:
        total = Decimal(ac.amount or 0)
        if ac.frequency == "once":
            remaining = total - ac.used
            amt = min(remaining, dec(B))
        else:
            amt = min(total, dec(B))
    return amt, remaining


def consume(ac: Coupon, credit, remaining):
    """Status and remaining periods after a credit (BE-IV-27)."""
    status, rem = "active", (ac.remaining if ac.frequency == "recurring" else None)
    if ac.frequency == "recurring":
        rem = max((ac.remaining or 0) - 1, 0)
        if rem == 0:
            status = "terminated"
    elif ac.frequency == "once":
        if ac.type == "percentage" or (remaining is not None and credit >= remaining):
            status = "terminated"
    return status, rem


def apply_one_coupon(ac: Coupon, fees, sub_total, currency, ex=False):
    """Apply one coupon; returns None when skipped, else dict(credit, amount, status, remaining)."""
    if ac.type == "fixed_amount" and ac.currency and ac.currency != currency:
        return None
    if ac.metrics:
        targets = [f for f in fees if f.fee_type == "charge" and f.metric in ac.metrics]
    elif ac.plans:
        targets = [f for f in fees if f.plan_code in ac.plans]
    else:
        targets = list(fees)
    if not targets:
        return None
    limited = bool(ac.metrics or ac.plans)
    B = sum((f.amount - f.pc for f in targets), ZERO) if limited else sub_total
    amount, remaining = coupon_amount_value(B, ac, ex)
    credit = trunc(amount)
    if dec(B) != 0:
        for f in targets:
            if ex:
                share = amount * (f.amount - f.pc) / dec(B)
            else:
                share = Decimal(repr(float(amount) * float(f.amount - f.pc) / float(B)))
            f.pc = min(store5(f.pc + share), Decimal(f.amount))
    status, rem = consume(ac, credit, remaining)
    return {"credit": credit, "amount": amount, "status": status, "remaining": rem}


def coupon_amount(inp, ctx):
    ac = Coupon(inp["applied_coupon"])
    B = inp["base_amount_cents"]
    if isinstance(B, str):
        B = dec(B)
    amt, remaining = coupon_amount_value(B, ac, exact(ctx))
    out = {"amount": amt, "amount_cents": trunc(amt)}
    if remaining is not None:
        out["remaining_amount_cents"] = trunc(remaining)
    return out


def coupon_distribution(inp, ctx):
    ex = exact(ctx)
    fees = [Fee(d, i) for i, d in enumerate(inp["fees"])]
    sub = inp.get("sub_total_excluding_taxes_amount_cents")
    sub = sum(f.amount for f in fees) if sub is None else int(sub)
    ac = Coupon(inp["applied_coupon"])
    r = apply_one_coupon(ac, fees, sub, inp.get("currency", "EUR"), ex)
    if r is None:
        return {"applied": False, "credit_amount_cents": None,
                "fees": [{"id": f.id, "precise_coupons_amount_cents": f.pc} for f in fees],
                "sub_total_excluding_taxes_amount_cents": sub,
                "applied_coupon_after": {"status": ac.status, "frequency_duration_remaining": ac.remaining if ac.frequency == "recurring" else None}}
    return {"applied": True, "credit_amount_cents": r["credit"],
            "fees": [{"id": f.id, "precise_coupons_amount_cents": f.pc} for f in fees],
            "sub_total_excluding_taxes_amount_cents": sub - r["credit"],
            "applied_coupon_after": {"status": r["status"], "frequency_duration_remaining": r["remaining"]}}


def coupon_order(inp, ctx):
    acs = [a for a in inp["applied_coupons"] if a.get("status", "active") == "active"]
    groups = ([a for a in acs if a.get("limited_billable_metrics")],
              [a for a in acs if a.get("limited_plans") and not a.get("limited_billable_metrics")],
              [a for a in acs if not a.get("limited_plans") and not a.get("limited_billable_metrics")])
    return {"order": [a["id"] for g in groups for a in g]}


# ---------------------------------------------------------------------------------------------- totals
class Result:
    pass


def run_totals(inp, ctx, context=None):
    """Totals pipeline; returns a Result with fees/amounts for further use."""
    ex = exact(ctx)
    currency = inp.get("currency", "EUR")
    itype = inp.get("invoice_type", "subscription")
    context = context or inp.get("context", "finalize")
    fees = [Fee(d, i) for i, d in enumerate(inp["fees"])]
    coupons = [Coupon(d) for d in inp.get("applied_coupons", [])]
    fees_amount = sum(f.amount for f in fees)
    sub = fees_amount
    credits = []
    pb_credit = 0
    pb = inp.get("progressive_billing")
    if pb and itype in ("subscription", "progressive_billing"):
        total_pb = sum(int(x["amount_cents"]) for x in pb["fees"])
        to_credit = max(total_pb - int(pb.get("coupons_amount_cents", 0)), 0)
        by_id = {f.id: f for f in fees}
        matched = [(by_id[x["same_charge_as"]], int(x["amount_cents"])) for x in pb["fees"] if x["same_charge_as"] in by_id]
        charges_total = sum({id(f): f.amount for f, _ in matched}.values())
        pb_credit = min(to_credit, charges_total)
        if pb_credit > 0:
            for f, a in matched:
                f.pc = min(f.pc + a, Decimal(f.amount))
            credits.append({"kind": "progressive_billing", "amount_cents": pb_credit})
            sub -= pb_credit
    coupons_total = 0
    after = {}
    if itype != "one_off":
        run = False
        if itype == "subscription":
            run = context == "finalize" and fees_amount > 0
        elif itype == "pay_in_advance_charge":
            run = fees_amount > 0
        elif itype == "progressive_billing":
            run = True
        if run:
            active = [c for c in coupons if c.status == "active"]
            order = (coupon_order({"applied_coupons": [{"id": i, "limited_plans": bool(c.plans), "limited_billable_metrics": bool(c.metrics)}
                                                       for i, c in enumerate(active)]}, ctx))["order"]
            for i in order:
                if sub <= 0:
                    break
                c = active[i]
                r = apply_one_coupon(c, fees, sub, currency, ex)
                if r is None:
                    continue
                coupons_total += r["credit"]
                sub -= r["credit"]
                credits.append({"kind": "coupon", "id": c.id, "amount_cents": r["credit"]})
                after[id(c)] = (r["status"], r["remaining"])
    for f in fees:
        fee_taxes(f, ex)
    rows, taxes, trate = invoice_taxes(fees, sub, ex)
    incl = sub + taxes
    total = incl
    cn_total = 0
    cn_after = []
    cns = inp.get("credit_notes", [])
    cn_bal = {n["id"]: int(n["balance_amount_cents"]) for n in cns}
    if context == "finalize" and itype != "one_off":
        remaining = total
        for n in cns:
            if remaining <= 0:
                break
            if n.get("currency", currency) != currency or cn_bal[n["id"]] <= 0:
                continue
            credit = min(cn_bal[n["id"]], remaining)
            for f in fees:
                avail = f.amount - f.pc + f.tax_amount - f.cn
                if remaining > 0:
                    sh = Decimal(repr(credit * float(avail) / remaining)) if not ex else Decimal(credit) * avail / remaining
                    f.cn = min(store5(f.cn + sh), Decimal(f.amount) - f.pc + f.tax_amount)
            cn_bal[n["id"]] -= credit
            remaining -= credit
            cn_total += credit
            credits.append({"kind": "credit_note", "id": n["id"], "amount_cents": credit})
        total -= cn_total
    cn_after = [{"id": n["id"], "balance_amount_cents": cn_bal[n["id"]],
                 "credit_status": "consumed" if cn_bal[n["id"]] == 0 else "available"} for n in cns]
    prepaid = 0
    wtx = []
    wallets = inp.get("wallets", [])
    if context == "finalize" and itype != "one_off" and total > 0:
        order = sorted(range(len(wallets)), key=lambda i: (wallets[i].get("priority", 50), i))
        for i in order:
            w = wallets[i]
            if total <= 0:
                break
            if w.get("currency", currency) != currency or int(w["balance_cents"]) <= 0:
                continue
            take = min(int(w["balance_cents"]), total)
            prepaid += take
            total -= take
            wtx.append({"wallet": w["id"], "amount_cents": take})
    res = Result()
    res.fees, res.credits, res.coupons, res.coupon_after = fees, credits, coupons, after
    res.cn_after, res.wtx, res.rows = cn_after, wtx, rows
    res.invoice = {
        "fees_amount_cents": fees_amount,
        "coupons_amount_cents": coupons_total,
        "progressive_billing_credit_amount_cents": pb_credit,
        "sub_total_excluding_taxes_amount_cents": sub,
        "taxes_amount_cents": taxes,
        "sub_total_including_taxes_amount_cents": incl,
        "credit_notes_amount_cents": cn_total,
        "prepaid_credit_amount_cents": prepaid,
        "total_amount_cents": total,
        "taxes_rate": trate,
        "payment_status": "pending" if total > 0 else "succeeded",
    }
    return res


def totals(inp, ctx):
    r = run_totals(inp, ctx)
    out = {"fees": [fee_out(f) for f in r.fees], "invoice": r.invoice, "applied_taxes": r.rows, "credits": r.credits}
    if "applied_coupons" in inp:
        out["applied_coupons_after"] = [
            {"id": c.id, "status": r.coupon_after[id(c)][0] if id(c) in r.coupon_after else c.status,
             "frequency_duration_remaining": (r.coupon_after[id(c)][1] if id(c) in r.coupon_after
                                              else (c.remaining if c.frequency == "recurring" else None))}
            for c in r.coupons]
    if "credit_notes" in inp:
        out["credit_notes_after"] = r.cn_after
    if "wallets" in inp:
        out["wallet_transactions"] = r.wtx
    return out


# ---------------------------------------------------------------------------------------------- lifecycle
def eff(customer, be, key, default=None):
    v = customer.get(key)
    if v is None:
        v = be.get(key, default)
    return v


def grace_of(c, b):
    return int(eff(c, b, "invoice_grace_period", 0))


def final_status(inp, ctx):
    c, b = inp.get("customer", {}), inp.get("billing_entity", {})
    fees = int(inp["fees_amount_cents"])
    total = int(inp.get("total_amount_cents", fees))
    gated = bool(inp.get("subscription_gated", False))
    tax_pending = bool(inp.get("tax_pending", False))
    out = {"subscription_gated": gated}
    if grace_of(c, b) > 0 and not gated:
        out["status"] = "draft"
    elif gated and (total > 0 or tax_pending):
        out["status"] = "open"
    elif tax_pending:
        out["status"] = "pending"
    elif fees != 0:
        out["status"] = "finalized"
    else:
        setting = c.get("finalize_zero_amount_invoice", "inherit")
        if setting == "finalize":
            allow = True
        elif setting == "skip":
            allow = False
        else:
            allow = bool(b.get("finalize_zero_amount_invoice", True))
        out["status"] = "finalized" if allow else "closed"
    return out


def local_date(instant: str, tz: str) -> dt.date:
    s = instant.replace("Z", "+00:00")
    t = dt.datetime.fromisoformat(s)
    if t.tzinfo is None:
        t = t.replace(tzinfo=dt.timezone.utc)
    return t.astimezone(ZoneInfo(tz)).date()


def issuing_date(inp, ctx):
    c, b = inp.get("customer", {}), inp.get("billing_entity", {})
    tz = inp.get("timezone", "UTC")
    date = local_date(inp["datetime"], tz)
    grace = grace_of(c, b)
    term = int(eff(c, b, "net_payment_term", 0))
    anchor = eff(c, b, "subscription_invoice_issuing_date_anchor", "next_period_start")
    adj = eff(c, b, "subscription_invoice_issuing_date_adjustment", "align_with_finalization_date")
    sub_inv = (inp.get("invoice_type", "subscription") == "subscription" and not inp.get("subscription_gated", False)
               and not inp.get("charge_in_advance", False))
    delta = 0
    if sub_inv:
        if inp.get("invoicing_reason", "subscription_periodic") != "subscription_periodic":
            delta = grace
        elif anchor == "current_period_end":
            delta = -1 if adj == "keep_anchor" else (grace if grace > 0 else -1)
        else:
            delta = 0 if adj == "keep_anchor" else grace
    issuing = date + dt.timedelta(days=delta)
    fin = date + dt.timedelta(days=grace if sub_inv else 0)
    return {"issuing_date": issuing.isoformat(), "expected_finalization_date": fin.isoformat(),
            "payment_due_date": (issuing + dt.timedelta(days=term)).isoformat(), "net_payment_term": term}


def payment_due_date(inp, ctx):
    c, b = inp.get("customer", {}), inp.get("billing_entity", {})
    tz = inp.get("timezone", "UTC")
    today = local_date(inp["now"], tz)
    adj = eff(c, b, "subscription_invoice_issuing_date_adjustment", "align_with_finalization_date")
    term = int(eff(c, b, "net_payment_term", 0))
    if inp.get("recurring", True) and adj == "keep_anchor":
        issuing = dt.date.fromisoformat(inp["drafted_issuing_date"])
    else:
        issuing = today
    return {"issuing_date": issuing.isoformat(), "payment_due_date": (issuing + dt.timedelta(days=term)).isoformat()}


# ---------------------------------------------------------------------------------------------- bounds
def available_to_credit(inp, ctx):
    ex = exact(ctx)
    inv, fees, notes = inp["invoice"], inp["fees"], inp.get("credit_notes", [])
    version = int(inv.get("version_number", 4))
    status = inv.get("status", "finalized")
    itype = inv.get("invoice_type", "subscription")
    total = int(inv.get("total_amount_cents", 0))
    paid = int(inv.get("total_paid_amount_cents", 0))
    pstat = inv.get("payment_status", "pending")
    fin = [n for n in notes if n.get("status", "finalized") == "finalized"]
    due = 0 if status == "voided" else total - paid - sum(int(n.get("offset_amount_cents", 0)) for n in fin)
    out = {"total_due_amount_cents": due}
    fee_total = sum(int(f["amount_cents"]) for f in fees) + rint(
        sum((Decimal(int(f["amount_cents"])) * dec(f.get("taxes_rate", "0")) / 100 for f in fees), ZERO))
    out["fee_total_amount_cents"] = fee_total
    # available to credit
    F = sum(int(f["amount_cents"]) - int(f.get("credited_amount_cents", 0)) for f in fees)
    if version < 2 or status == "draft" or F == 0:
        avail = 0
    else:
        fees_amount = int(inv["fees_amount_cents"])
        disc = int(inv.get("coupons_amount_cents", 0)) + int(inv.get("progressive_billing_credit_amount_cents", 0))
        if ex:
            adj = Decimal(disc) / fees_amount * F if (version >= 3 and fees_amount) else ZERO
            s = ZERO
            for f in fees:
                cr = int(f["amount_cents"]) - int(f.get("credited_amount_cents", 0))
                s += (cr - adj * cr / F) * dec(f.get("taxes_rate", "0")) / 100
            avail = F - adj + rint(s)
        else:
            adj = (disc / fees_amount * F) if (version >= 3 and fees_amount) else 0.0
            s = 0.0
            for f in fees:
                cr = int(f["amount_cents"]) - int(f.get("credited_amount_cents", 0))
                s += (cr - adj * cr / F) * float(dec(f.get("taxes_rate", "0"))) / 100
            avail = F - adj + frnd(s)
    avail_n = Decimal(repr(avail)) if isinstance(avail, float) else avail
    out["available_to_credit_amount_cents"] = avail_n
    creditable = 0 if itype == "credit" else avail_n
    out["creditable_amount_cents"] = creditable
    if itype == "credit" and pstat != "succeeded" and due > 0:
        off = total
    else:
        off = min(due, creditable)
    out["offsettable_amount_cents"] = off
    if version < 2 or status == "draft" or (pstat != "succeeded" and paid >= total and total > 0):
        ref = 0
    else:
        refunds = sum(int(n.get("refund_amount_cents", 0)) for n in fin)
        ref = max(min(paid - refunds, creditable), 0)
    out["refundable_amount_cents"] = ref
    out["voidable"] = (status == "finalized" and pstat in ("pending", "failed") and paid == 0
                       and not any(n.get("credit_status", "available") != "voided" for n in notes))
    return out
