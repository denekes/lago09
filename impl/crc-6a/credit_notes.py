"""Credit notes (billing spec chapter 08)."""
from __future__ import annotations

import datetime as dt
from decimal import ROUND_DOWN, Decimal

import invoice as iv
import periods as pr
from common import KitError, ZERO, dec, exact, float_round, frnd, rint, rnd, store5, trunc

Q5 = Decimal("0.00001")


def d16(f: float) -> Decimal:
    """A float read back at 16 significant digits."""
    return Decimal(format(f, ".15e"))


class Inv:
    """An invoice as the credit-note code sees it: the priced fees plus the notes already issued."""

    def __init__(self, inp, ctx, prev=None):
        self.ex = exact(ctx)
        self.inp = inp
        self.status = inp.get("status", "finalized")
        self.version = int(inp.get("version_number", 4))
        run_in = dict(inp)
        run_in.pop("status", None)
        run_in.pop("payment_status", None)
        run_in.pop("total_paid_amount_cents", None)
        run_in.pop("plans", None)
        run_in.pop("subscriptions", None)
        res = iv.run_totals(run_in, ctx, context="draft" if self.status == "draft" else "finalize")
        self.res = res
        self.fees = {f.id: f for f in res.fees}
        self.fee_list = res.fees
        t = res.invoice
        self.total = t["total_amount_cents"]
        self.fees_amount = t["fees_amount_cents"]
        self.disc = t["coupons_amount_cents"] + t["progressive_billing_credit_amount_cents"]
        self.paid = int(inp.get("total_paid_amount_cents", 0))
        self.payment_status = inp.get("payment_status", t["payment_status"])
        self.credited = {f.id: 0 for f in res.fees}
        self.notes = []
        self.ctx = ctx
        for req in prev or []:
            items = [(i["fee_id"], i["amount_cents"]) for i in req["items"]]
            n = make_note(self, items, int(req.get("credit_amount_cents", 0)), int(req.get("refund_amount_cents", 0)),
                          int(req.get("offset_amount_cents", 0)), validate=False)
            self.add(n)

    def add(self, n):
        for fid, cents in n["_item_cents"]:
            self.credited[fid] += cents
        self.notes.append(n)

    def avail(self, credited=None):
        credited = credited or self.credited
        return iv.avail_core(self.version, self.status, self.fees_amount, self.disc,
                             [(f.amount, credited[f.id], f.tax_rate) for f in self.fee_list], self.ex)

    def finalized_notes(self):
        return [n for n in self.notes if n["status"] == "finalized"]

    def refundable(self):
        creditable = self.avail()
        if self.version < 2 or self.status == "draft" or (self.payment_status != "succeeded" and self.paid >= self.total and self.total > 0):
            return 0
        refunds = sum(n["refund_amount_cents"] for n in self.finalized_notes())
        return max(min(self.paid - refunds, creditable), 0)

    def fee_total(self):
        return sum(f.amount for f in self.fee_list) + rint(sum((Decimal(f.amount) * f.tax_rate / 100 for f in self.fee_list), ZERO))


def note_core(inv: Inv, items, residue_check=True):
    """Items -> adjustments, taxes, sub total. items: list of (fee, precise Decimal, cents). Returns dict."""
    ex = inv.ex
    adj = ZERO
    bases = {}
    rates = {}
    ratef = []
    for fee, precise, cents in items:
        if fee.amount == 0:
            rate = 0.0
        else:
            rate = float(precise) / fee.amount
        r16 = Decimal(precise) / fee.amount if ex and fee.amount else (d16(rate) if rate else ZERO)
        a = fee.pc * r16 if inv.version >= 3 else ZERO
        adj += fee.pc * r16
        share = precise - fee.pc * r16
        for code, trate in fee.taxes:
            bases[code] = bases.get(code, ZERO) + share
            rates[code] = trate
    if inv.version < 3:
        adj = ZERO
        # the tax base still excludes the coupon share
    padj = store5(adj) if inv.version >= 3 else ZERO
    if inv.version < 3:
        padj = ZERO
    rows = []
    ptax = 0.0 if not ex else ZERO
    for code in sorted(bases):
        base = bases[code]
        if ex:
            t = base * rates[code] / 100
        else:
            t = float(base) * float(rates[code]) / 100
        rows.append({"code": code, "amount_cents": rint(t) if ex else frnd(t), "base_amount_cents": rint(base)})
        ptax += t
    ptax = store5(ptax) if ex else store5(d16(ptax))
    sum_precise = sum((p for _, p, _ in items), ZERO)
    return {"rows": rows, "ptax": ptax, "padj": padj, "adj": adj, "sum_precise": sum_precise, "bases": bases, "rates": rates}


def residue_applies(inv: Inv, item_cents):
    credited = dict(inv.credited)
    for fid, c in item_cents:
        credited[fid] += c
    return inv.avail(credited) == 0


def eligibility(inv: Inv, premium=True):
    errs = []
    if not premium:
        errs.append(("base", "feature_unavailable"))
        return errs
    if inv.version < 2:
        errs.append(("base", "invalid_type_or_status"))
    return errs


def build_items(inv: Inv, raw_items, truncate=False):
    items, errs = [], []
    work_credited = dict(inv.credited)
    for fid, amount in raw_items:
        fee = inv.fees.get(fid)
        if fee is None:
            errs.append(("base", "fee_not_found"))
            return items, errs
        precise = dec(amount)
        if truncate:
            precise = Decimal(trunc(precise))
        cents = rint(precise)
        if cents < 0:
            errs.append(("amount_cents", "invalid_value"))
            return items, errs
        if cents > fee.amount - work_credited[fid]:
            errs.append(("amount_cents", "higher_than_remaining_fee_amount"))
            return items, errs
        work_credited[fid] += cents
        items.append((fee, precise, cents))
    return items, errs


def make_note(inv: Inv, raw_items, credit, refund, offset, validate=True, premium=True, estimate=False,
              auto=False):
    """Create a note on `inv`; returns the result dict (with private keys) or raises KitError (first error)."""
    all_errs = []
    if validate:
        e = eligibility(inv, premium)
        if e:
            return {"_errors": e}
    items, ierrs = build_items(inv, raw_items, truncate=estimate)
    if ierrs and validate:
        return {"_errors": ierrs}
    core = note_core(inv, items)
    item_cents = [(f.id, c) for f, _, c in items]
    ptax = core["ptax"]
    if residue_applies(inv, item_cents):
        ptax = ptax - sum((Decimal(n["taxes_amount_cents"]) - n["precise_taxes_amount_cents"] for n in inv.notes), ZERO)
    taxes = rint(ptax)
    sub = rint(core["sum_precise"] - core["padj"])
    total = credit + refund + offset
    balance = credit
    refund_status = "pending" if refund > 0 else None
    out_credit, out_refund, out_offset = credit, refund, offset
    if validate:
        errs = validate_amounts(inv, core, ptax, total, credit, refund, offset, items, sub)
        if errs:
            return {"_errors": errs}
    if total - taxes != sub:
        delta = -1 if total - taxes > sub else 1
        total += delta
        if inv.ex:
            if credit > 0:
                out_credit = credit + delta
            elif offset > 0:
                out_offset = offset + delta
            else:
                out_refund = refund + delta
        else:
            if credit > 0:
                out_credit = total - refund
            else:
                out_refund = total
        balance = out_credit
    # taxes rate (BE-CN-8)
    denom = core["sum_precise"] - core["padj"]
    if denom != 0:
        if inv.ex:
            tr = rnd(sum((core["bases"][c] * core["rates"][c] for c in core["bases"]), ZERO) / denom, 5)
        else:
            tr = Decimal(repr(float_round(sum(float(core["bases"][c]) * float(core["rates"][c]) for c in core["bases"]) / float(denom), 5)))
    else:
        tr = ZERO
    status = "draft" if inv.status == "draft" else "finalized"
    note = {
        "status": status,
        "credit_status": "available",
        "refund_status": refund_status,
        "items": [{"fee_id": f.id, "amount_cents": c, "precise_amount_cents": p} for f, p, c in items],
        "coupons_adjustment_amount_cents": rint(core["padj"]),
        "precise_coupons_adjustment_amount_cents": core["padj"],
        "taxes_amount_cents": taxes,
        "precise_taxes_amount_cents": ptax,
        "taxes_rate": tr,
        "sub_total_excluding_taxes_amount_cents": sub,
        "credit_amount_cents": out_credit,
        "refund_amount_cents": out_refund,
        "offset_amount_cents": out_offset,
        "total_amount_cents": total,
        "balance_amount_cents": balance,
        "applied_taxes": core["rows"],
        "_item_cents": item_cents,
        "_core": core,
    }
    return note


def validate_amounts(inv: Inv, core, ptax, total, credit, refund, offset, items, sub):
    errs = []
    paid, tot = inv.paid, inv.total
    others = [n for n in inv.finalized_notes()]
    fee_total = inv.fee_total()
    o_credit = sum(n["credit_amount_cents"] for n in others)
    o_refund = sum(n["refund_amount_cents"] for n in others)
    o_offset = sum(n["offset_amount_cents"] for n in others)
    remaining_credit = fee_total - o_credit - o_offset
    if refund > 0 and inv.payment_status != "succeeded" and paid == tot and tot > 0:
        errs.append(("refund_amount_cents", "cannot_refund_unpaid_invoice"))
    if abs(total - rint(core["sum_precise"] - core["padj"] + ptax)) > 1:
        errs.append(("base", "does_not_match_item_amounts"))
    if refund > 0:
        if paid == 0:
            errs.append(("refund_amount_cents", "cannot_refund_unpaid_invoice"))
        elif refund > paid - o_refund:
            errs.append(("refund_amount_cents", "higher_than_remaining_invoice_amount"))
    if credit > 0 and credit - remaining_credit > 1:
        errs.append(("credit_amount_cents", "higher_than_remaining_invoice_amount"))
    if offset > 0:
        if offset > min(tot - paid - o_offset, remaining_credit):
            errs.append(("offset_amount_cents", "higher_than_remaining_invoice_amount"))
    if total - (fee_total - (o_credit + o_refund + o_offset)) > 1:
        errs.append(("base", "higher_than_remaining_invoice_amount"))
    if total <= 0:
        errs.append(("base", "total_amount_must_be_positive"))
    return errs


def raise_first(errs):
    f, c = errs[0]
    raise KitError(c, f)


def after(inv: Inv, n, credited_extra=True):
    credited = dict(inv.credited)
    for fid, c in n["_item_cents"]:
        credited[fid] += c
    creditable = inv.avail(credited)
    offsets = sum(x["offset_amount_cents"] for x in inv.finalized_notes()) + (n["offset_amount_cents"] if n["status"] == "finalized" else 0)
    due = inv.total - inv.paid - offsets
    ps = inv.payment_status
    if n["offset_amount_cents"] > 0 and due <= 0:
        ps = "succeeded"
    return {"creditable_amount_cents": Decimal(repr(creditable)) if isinstance(creditable, float) else creditable,
            "total_due_amount_cents": due, "payment_status": ps}


def public(n):
    return {k: v for k, v in n.items() if not k.startswith("_")}


def compute(inp, ctx):
    inv = Inv(inp["invoice"], ctx, inp.get("previous_credit_notes"))
    items = [(i["fee_id"], i["amount_cents"]) for i in inp["items"]]
    n = make_note(inv, items, int(inp.get("credit_amount_cents", 0)), int(inp.get("refund_amount_cents", 0)),
                  int(inp.get("offset_amount_cents", 0)), premium=inp.get("premium", True))
    if "_errors" in n:
        raise_first(n["_errors"])
    out = public(n)
    out["invoice_after"] = after(inv, n)
    return out


def validate(inp, ctx):
    inv = Inv(inp["invoice"], ctx, inp.get("previous_credit_notes"))
    req = inp["request"]
    items = [(i["fee_id"], i["amount_cents"]) for i in req["items"]]
    n = make_note(inv, items, int(req.get("credit_amount_cents", 0)), int(req.get("refund_amount_cents", 0)),
                  int(req.get("offset_amount_cents", 0)), premium=inp.get("premium", True))
    if "_errors" in n:
        errors = {}
        for f, c in n["_errors"]:
            errors.setdefault(f, []).append(c)
        return {"valid": False, "errors": errors}
    return {"valid": True, "errors": {}}


def estimate_core(inv: Inv, raw_items):
    """BE-CN-14 on whole-cent items; returns the estimate dict."""
    items, errs = build_items(inv, [(fid, a) for fid, a in raw_items], truncate=True)
    if errs:
        raise_first(errs)
    core = note_core(inv, items)
    item_cents = [(f.id, c) for f, _, c in items]
    ptax = core["ptax"]
    if residue_applies(inv, item_cents):
        ptax = ptax - sum((Decimal(n["taxes_amount_cents"]) - n["precise_taxes_amount_cents"] for n in inv.notes), ZERO)
    taxes = rint(ptax)
    sub = rint(core["sum_precise"] - core["padj"])
    max_cred = rint(core["sum_precise"] - core["padj"] + ptax)
    refundable = inv.refundable()
    max_ref = trunc(min(max_cred, refundable))
    if max_cred - taxes > sub:
        max_cred -= 1
    elif taxes > 0 and max_cred - taxes < sub:
        taxes -= 1
    denom = core["sum_precise"] - core["padj"]
    if denom != 0:
        if inv.ex:
            tr = rnd(sum((core["bases"][c] * core["rates"][c] for c in core["bases"]), ZERO) / denom, 5)
        else:
            tr = Decimal(repr(float_round(sum(float(core["bases"][c]) * float(core["rates"][c]) for c in core["bases"]) / float(denom), 5)))
    else:
        tr = ZERO
    return {
        "items": [{"fee_id": f.id, "amount_cents": c} for f, _, c in items],
        "coupons_adjustment_amount_cents": rint(core["padj"]),
        "precise_coupons_adjustment_amount_cents": core["padj"],
        "taxes_amount_cents": taxes,
        "precise_taxes_amount_cents": ptax,
        "taxes_rate": tr,
        "sub_total_excluding_taxes_amount_cents": sub,
        "applied_taxes": core["rows"],
        "max_creditable_amount_cents": max_cred,
        "max_refundable_amount_cents": max_ref,
    }


def estimate(inp, ctx):
    inv = Inv(inp["invoice"], ctx, inp.get("previous_credit_notes"))
    if not inp.get("premium", True):
        raise KitError("feature_unavailable", "base")
    if inv.version < 2:
        raise KitError("invalid_type_or_status", "base")
    return estimate_core(inv, [(i["fee_id"], i["amount_cents"]) for i in inp["items"]])


# ---------------------------------------------------------------------------------------------- termination
def termination(inp, ctx):
    ex = exact(ctx)
    tz = inp.get("timezone", "UTC")
    plan, sub, invd = inp["plan"], inp["subscription"], inp["invoice"]
    fee_amount = int(invd["subscription_fee_amount_cents"])
    if fee_amount == 0 or invd.get("voided"):
        return {"credit_note": None}
    term = pr.parse_instant(inp["terminated_at"])
    started = pr.parse_instant(sub["started_at"])
    sub_at = pr.parse_instant(sub.get("subscription_at", sub["started_at"]))
    anchor = pr.to_local_date(sub_at, tz)
    P = pr.Plan(plan["interval"], sub.get("billing_time", "calendar"), anchor)
    D = pr.to_local_date(term, tz)
    ps, pe = P.period(D)
    length = (pe - ps).days + 1
    E = pr.local_end(pe, tz).date()
    L = pr.local_end(D, tz).date()
    F = L - dt.timedelta(days=1) if inp.get("upgrade") else L
    trial = dec(plan.get("trial_period_days", "0"))
    TE = None
    if trial > 0:
        init_day = started.date().toordinal()
        TE = Decimal(init_day) + trial
    Fo, Eo = Decimal(F.toordinal()), Decimal(E.toordinal())
    if TE is not None and TE >= Fo:
        Fo = Eo if TE > Eo else TE - 1
    remaining = trunc(Eo - Fo)
    remaining = max(remaining, 0)
    if ex:
        sdp = Decimal(fee_amount) / length
        unused = remaining * sdp
    else:
        sdp = fee_amount / length
        unused = remaining * sdp
    if remaining <= 0:
        return {"credit_note": None}
    if unused <= 0:
        return {"credit_note": None}
    unused_d = Decimal(unused) if ex else Decimal(repr(unused))
    unused_d = min(unused_d, Decimal(fee_amount))
    inv_in = {
        "currency": inp.get("currency", "EUR"),
        "fees": [{"id": "sub_fee", "fee_type": "subscription", "amount_cents": fee_amount, "taxes": invd.get("taxes", []),
                  "plan_code": "plan"}] + list(invd.get("other_fees", [])),
        "applied_coupons": invd.get("applied_coupons", []),
        "payment_status": invd.get("payment_status", "pending"),
        "total_paid_amount_cents": invd.get("total_paid_amount_cents", 0),
    }
    inv = Inv(inv_in, ctx, inp.get("previous_credit_notes"))
    fee = inv.fees["sub_fee"]
    earlier = sum(i["amount_cents"] for n in inv.notes for i in n["items"] if i["fee_id"] == "sub_fee")
    unused_d = unused_d - earlier
    if unused_d <= 0:
        return {"credit_note": None}
    item = unused_d.quantize(Q5, rounding=ROUND_DOWN)
    # amount of the note (T)
    t_total = chain_total(inv, fee, item)
    mode = inp.get("on_termination", "credit")
    credit = refund = offset = 0
    if mode == "credit":
        credit = t_total
    else:
        if ex:
            share = (fee.precise - fee.pc + fee.tax_precise) / Decimal(inv.res.invoice["sub_total_including_taxes_amount_cents"] or 1) * inv.paid
        else:
            incl = inv.res.invoice["sub_total_including_taxes_amount_cents"]
            share = float(fee.precise - fee.pc + fee.tax_precise) / incl * inv.paid if incl else 0.0
        used_days = max(min(L, E).toordinal() - ps_utc_date(ps, started, tz).toordinal() + 1, 0)
        if TE is not None:
            s_ord = max(Decimal(ps_utc_date(ps, started, tz).toordinal()), TE)
            used_days = max(trunc(Decimal(min(L, E).toordinal()) - s_ord + 1), 0)
        used_amt = used_days * sdp
        used_d = Decimal(used_amt) if ex else Decimal(repr(used_amt))
        used_t = chain_total(inv, fee, used_d.quantize(Q5, rounding=ROUND_DOWN))
        diff = share - used_t
        r = frnd(diff) if not ex else rint(diff)
        r = min(r, t_total)
        r = max(r, 0)
        refund = r
        if mode == "refund":
            credit, refund, offset = t_total - r, r, 0
        else:
            credit, refund, offset = 0, r, t_total - r
    if credit == 0 and refund == 0 and offset == 0:
        return {"credit_note": None}
    n = make_note(inv, [("sub_fee", item)], credit, refund, offset, validate=False)
    out = public(n)
    out["invoice_after"] = after(inv, n)
    return {"credit_note": out}


def ps_utc_date(ps: dt.date, started, tz):
    start = pr.local_start(ps, tz)
    if start < started:
        start = pr.local_start(pr.to_local_date(started, tz), tz)
    return start.date()


def chain_total(inv: Inv, fee, x: Decimal) -> int:
    """round(x - adjustment + precise taxes) for one item on `fee`."""
    core = note_core(inv, [(fee, x, rint(x))])
    return rint(core["sum_precise"] - core["padj"] + core["ptax"])


HANDLERS = {
    "credit_notes.compute": compute,
    "credit_notes.estimate": estimate,
    "credit_notes.validate": validate,
    "credit_notes.termination": termination,
}
