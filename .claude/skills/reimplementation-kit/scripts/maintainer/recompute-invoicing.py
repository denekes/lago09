#!/usr/bin/env python3
# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
"""recompute-invoicing.py — independent model of the invoicing chapters (07 invoices/taxes/coupons, 08 credit notes),
served over the kit adapter protocol so kitrun can grade it like any implementation.

It is written from the chapter rules (BE-IV-*, BE-CN-*), not from the reference code, and serves as the second opinion
on every invoice.* and credit_notes.* vector: a vector that the oracle passes and this model fails points at a rule
that the chapter states wrongly or incompletely (or at a vector defect).

Profiles: `compat` reproduces the binary64 islands the chapters document (RBD-68: invoice tax rate, percentage coupon
amount, coupon and credit-note shares, credit-note item rates, void item scaling, available-to-credit; chapter 07
section 10.1); `corrected` uses exact decimals everywhere. The credit note's tax rate is decimal in both (BE-CN-8).

Usage:
    python3 reimplementation-kit/scripts/kitrun.py --areas invoice,credit_notes \
        --impl-cmd "python3 reimplementation-kit/scripts/maintainer/recompute-invoicing.py"
    python3 reimplementation-kit/scripts/kitrun.py --areas invoice,credit_notes --profile corrected --impl-cmd "..."
Exit codes: 0 after `bye` or end of input.

Covered ops: invoice.totals, invoice.apply_taxes, invoice.fee_tax_selection, invoice.coupon_amount,
invoice.coupon_order, invoice.coupon_distribution, invoice.coupon_create, invoice.coupon_apply, invoice.final_status,
invoice.issuing_date, invoice.payment_due_date, invoice.available_to_credit, invoice.void, credit_notes.compute,
credit_notes.estimate, credit_notes.validate, credit_notes.termination (monthly/weekly/quarterly/yearly calendar and
anniversary periods). Not covered: invoice.commitment_true_up (it runs whole billing runs, chapter 06 periods
included); exclude it with --only '^(?!invoice\.commitment\.)'.
"""
from __future__ import annotations

import datetime as dt
import math
import os
import sys
from decimal import ROUND_DOWN, ROUND_HALF_UP, Decimal as D
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import adapter_ref as ar  # noqa: E402

KitError = ar.KitError
Q5 = D("0.00001")


def _currency_codes():
    """Accepted currency codes (billing-engine-spec appendix-currencies table)."""
    import re
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "billing-engine-spec", "reference",
                        "appendix-currencies.md")
    try:
        return {m.group(1) for m in re.finditer(r"^\| ([A-Z]{3}) \|", open(path, encoding="utf-8").read(), re.M)}
    except OSError:
        return None


CURRENCIES = _currency_codes()


def known_currency(code):
    return CURRENCIES is None or code in CURRENCIES
Q15 = D("0.000000000000001")


# ---------------------------------------------------------------------------------------------------------------- numbers
class Num:
    """Arithmetic switch: compat reproduces the binary64 islands, corrected stays exact."""

    def __init__(self, profile):
        self.compat = profile != "corrected"

    def fdiv(self, a, b):
        """Division that the reference performs in binary64 (returns a value usable as Decimal)."""
        if not self.compat:
            return D(a) / D(b)
        return D(repr(float(D(a) / D(b))))

    def fl(self, x):
        """A binary64 value seen as the shortest decimal (compat) or the exact value (corrected)."""
        return D(repr(float(x))) if self.compat else D(x)

    def dec16(self, x):
        """`dec16` of chapter 07 (compat): the shortest decimal text of the binary64 value cut (truncated, not rounded)
        to its first 16 significant digits, which is how a binary64 value enters an exact product or sum; corrected:
        the exact value."""
        if not self.compat:
            return D(x)
        d = D(repr(float(x)))
        if d == 0:
            return d
        return d.quantize(D(1).scaleb(d.adjusted() - 15), rounding=ROUND_DOWN)

    def fdiv16(self, a, b):
        """A binary64 quotient entering an exact product or sum: dec16(a / b) (compat), exact (corrected)."""
        return self.dec16(self.fdiv(a, b)) if self.compat else D(a) / D(b)

    def round5_float(self, x):
        """Rounding of a binary64 value to 5 places as the reference's float rounding does (compat)."""
        if not self.compat:
            return D(x).quantize(Q5, rounding=ROUND_HALF_UP)
        f = x if isinstance(x, float) else float(x)
        s = 1e5
        xs = f * s
        # round half away from zero on the exact binary64 product (floor(xs + 0.5) is wrong from 2^52 up)
        r = float(D(xs).to_integral_value(rounding=ROUND_HALF_UP))
        # the correction adds 0.5 in binary64: from 2^52 up the sum lands on the even neighbour (BE-IV-14)
        if f > 0 and (r + 0.5) / s <= f:
            r += 1
        elif f < 0 and (r - 0.5) / s >= f:
            r -= 1
        return D(repr(r / s))

    def store_col5(self, x):
        """A binary64 value assigned to a 5-place decimal column (BE-IV-42, BE-CN-7; chapter 07 notation): the float is
        rounded by round5, the exact value of that binary64 (not its shortest text) converted to decimal at 16 significant
        digits (nearest, ties to even: format ".16g"), then rounded half away to 5 places (compat); from 2^36 up this can
        differ from round5's text (78096345254.9564 -> 78096345254.95641) and from 1e11 up it drops the fifth decimal
        (102880657510.79861 -> 102880657510.7986)."""
        if not self.compat:
            return store5(x)
        return store5(D(format(float(self.round5_float(x)), ".16g")))


def rha(x, places=0):
    return D(x).quantize(D(1).scaleb(-places), rounding=ROUND_HALF_UP)


def i(x):
    return int(rha(x))


def trunc(x, places=0):
    return D(x).quantize(D(1).scaleb(-places), rounding=ROUND_DOWN)


def store5(x):
    return D(x).quantize(Q5, rounding=ROUND_HALF_UP)


# ---------------------------------------------------------------------------------------------------------------- model
class Fee:
    def __init__(self, f, cur):
        self.id = f["id"]
        self.type = f.get("fee_type", "charge")
        self.amount = int(f["amount_cents"])
        self.precise = D(f.get("precise_amount_cents", self.amount))
        self.pc = D(f.get("precise_coupons_amount_cents", 0))
        self.plan = f.get("plan_code", "plan")
        self.bm = f.get("billable_metric_code") or ("__bm_" + self.id)
        self.taxes = [(t["code"], D(t["rate"])) for t in f.get("taxes", [])]
        self.tax_rows = []
        self.taxes_amount = 0
        self.taxes_precise = D(0)
        self.taxes_rate = D(0)
        self.pcn = D(0)
        self.cn_items = 0
        self.currency = cur

    @property
    def sub_excl(self):
        return D(self.amount) - self.pc


def fee_taxes(n, fee):
    """BE-DM-27..29 / BE-IV-11: rows rounded each, fee total rounded once from the unrounded rows."""
    rows, tot, ptot, rate = [], D(0), D(0), D(0)
    for code, r in fee.taxes:
        unr = n.fdiv(fee.sub_excl * r, 100)
        pre = (fee.precise - fee.pc) * r / 100
        rows.append({"code": code, "amount_cents": i(unr), "precise_amount_cents": pre})
        tot += unr
        ptot += pre
        rate += r
    fee.tax_rows, fee.taxes_amount, fee.taxes_precise, fee.taxes_rate = rows, i(tot), ptot, rate


def invoice_taxes(n, fees, sub_total):
    """BE-IV-12..14."""
    codes = []
    for f in fees:
        for c, r in f.taxes:
            if c not in [x[0] for x in codes]:
                codes.append((c, r))
    rows, total = [], D(0)
    rate = 0.0 if n.compat else D(0)
    for c, r in sorted(codes):
        with_tax = [f for f in fees if c in [x[0] for x in f.taxes]]
        base = sum((f.sub_excl for f in with_tax), D(0))
        unr = n.fdiv(base * r, 100)
        rows.append({"code": c, "tax_rate": r, "fees_amount_cents": int(trunc(base)), "amount_cents": i(unr)})
        total += unr
        if n.compat:
            share = float(base) / float(sub_total) if sub_total > 0 else len(with_tax) / len(fees)
            rate += share * float(r)
        else:
            share = base / D(sub_total) if sub_total > 0 else D(len(with_tax)) / D(len(fees))
            rate += share * r
    return rows, i(total), n.round5_float(rate)


class Coupon:
    def __init__(self, c, cur):
        self.id = c.get("id", "c")
        self.type = c["coupon_type"]
        self.amount = int(c.get("amount_cents", 0) or 0)
        self.currency = c.get("amount_currency", cur)
        self.rate = D(c["percentage_rate"]) if "percentage_rate" in c else None
        self.freq = c.get("frequency", "once")
        self.remaining_periods = c.get("frequency_duration_remaining", c.get("frequency_duration"))
        self.used = int(c.get("used_amount_cents", 0))
        self.plans = c.get("limited_plan_codes", []) or []
        self.bms = c.get("limited_billable_metric_codes", []) or []
        self.status = c.get("status", "active")

    @property
    def limited(self):
        return bool(self.plans or self.bms)

    @property
    def remaining(self):
        return self.amount - self.used


def coupon_amount(n, cp, base):
    """BE-IV-23."""
    if cp.type == "percentage":
        if isinstance(base, int):
            v = D(repr(base * float(cp.rate / 100))) if n.compat else D(base) * cp.rate / 100
        else:
            v = D(base) * n.dec16(n.fdiv(cp.rate, 100))
        return base if v >= base else i(v)
    if cp.freq in ("recurring", "forever"):
        return base if cp.amount > base else cp.amount
    return base if cp.remaining > base else cp.remaining


def coupon_targets(cp, fees):
    if cp.bms:
        return [f for f in fees if f.type == "charge" and f.bm in cp.bms]
    if cp.plans:
        return [f for f in fees if f.type in ("subscription", "charge") and f.plan in cp.plans]
    return list(fees)


def apply_coupon(n, inv, cp):
    """BE-IV-21..27 for one coupon. Returns the credit (int) or None when skipped."""
    if cp.type == "fixed_amount" and cp.currency != inv["currency"]:
        return None
    targets = coupon_targets(cp, inv["fees"])
    if not targets:
        return None
    # BE-IV-22/23: a limited coupon's base is a decimal even when whole (exact product, decimal share division); an
    # unlimited coupon's base is the integer sub-total (binary64 product and share division in compat)
    base = sum((f.sub_excl for f in targets), D(0)) if cp.limited else int(inv["sub"])
    amt = coupon_amount(n, cp, base)
    credit = int(trunc(amt))
    for f in targets:
        if base != 0:
            if n.compat and not cp.limited:
                share = n.fdiv16(D(amt) * f.sub_excl, base)
            else:
                share = D(amt) * f.sub_excl / D(base)
            f.pc = store5(f.pc + share)
        if f.amount < f.pc:
            f.pc = D(f.amount)
    if cp.freq == "recurring":
        cp.remaining_periods = max((cp.remaining_periods or 0) - 1, 0)
    if cp.freq == "once":
        if cp.type == "percentage" or credit >= cp.remaining:
            cp.status = "terminated"
    elif cp.freq == "recurring" and cp.remaining_periods <= 0:
        cp.status = "terminated"
    cp.used += credit
    inv["coupons"] += credit
    inv["sub"] -= credit
    return credit


def coupon_sort_key(idx_cp):
    idx, cp = idx_cp
    return (0 if cp.bms else 1 if cp.plans else 2, idx)


# ---------------------------------------------------------------------------------------------------------------- totals
def run_totals(inp, n):
    cur = inp.get("currency", "EUR")
    itype = inp.get("invoice_type", "subscription")
    ctx_final = inp.get("context", "finalize") == "finalize"
    fees = [Fee(f, cur) for f in inp["fees"]]
    coupons = [Coupon(c, cur) for c in inp.get("applied_coupons", [])]
    cns = [{"id": c["id"], "bal": int(c["balance_amount_cents"]), "cur": c.get("currency", cur), "status": "available"}
           for c in inp.get("credit_notes", [])]
    wallets = [{"id": w["id"], "bal": int(w["balance_cents"]), "prio": int(w.get("priority", 50)), "seq": k,
                "cur": w.get("currency", cur)} for k, w in enumerate(inp.get("wallets", []))]
    inv = {"currency": cur, "fees": fees, "fees_amount": sum(f.amount for f in fees), "coupons": 0, "pb": 0, "cn": 0,
           "prepaid": 0, "credits": []}
    inv["sub"] = inv["fees_amount"]
    # progressive billing credit (BE-IV-32): what the earlier invoice billed for the same charges, capped by them
    pb = inp.get("progressive_billing")
    if pb and itype in ("subscription", "progressive_billing"):
        billed = sum(int(x["amount_cents"]) for x in pb["fees"]) - int(pb.get("coupons_amount_cents", 0))
        charge_ids = {x["same_charge_as"] for x in pb["fees"]}
        same = [f for f in fees if f.type == "charge" and f.id in charge_ids]
        cap = sum(f.amount for f in same)
        credit = max(min(billed, cap), 0)
        if credit > 0:
            for x in pb["fees"]:
                f = next(f for f in fees if f.id == x["same_charge_as"])
                f.pc += int(x["amount_cents"])
                if f.amount < f.pc:
                    f.pc = D(f.amount)
            inv["sub"] -= credit
            inv["pb"] += credit
            inv["credits"].append({"kind": "progressive_billing", "amount_cents": credit})
    do_coupons = (itype == "subscription" and ctx_final and inv["fees_amount"] > 0) or \
                 (itype == "pay_in_advance_charge" and inv["fees_amount"] > 0) or itype == "progressive_billing"
    if do_coupons and inv["fees_amount"] != 0:
        active = [(k, c) for k, c in enumerate(coupons) if c.status == "active"]
        for _, cp in sorted(active, key=coupon_sort_key):
            if inv["sub"] <= 0:
                break
            cr = apply_coupon(n, inv, cp)
            if cr is not None:
                inv["credits"].append({"kind": "coupon", "id": cp.id, "amount_cents": cr})
    for f in fees:
        fee_taxes(n, f)
    sub = inv["fees_amount"] - inv["pb"] - inv["coupons"]
    rows, taxes, rate = invoice_taxes(n, fees, sub)
    inv.update(sub=sub, rows=rows, taxes=taxes, rate=rate, sub_incl=sub + taxes)
    total = sub + taxes
    if ctx_final and itype in ("subscription", "pay_in_advance_charge", "progressive_billing"):
        remaining = total
        for c in cns:
            if c["cur"] != cur or c["status"] != "available" or remaining <= 0:
                continue
            cr = min(c["bal"], remaining)
            if cr <= 0:
                continue
            for f in fees:
                after_tax = f.sub_excl + f.taxes_amount
                f.pcn += n.fdiv16(D(cr) * (after_tax - f.pcn), remaining)
                f.pcn = store5(f.pcn)
                if after_tax < f.pcn:
                    f.pcn = after_tax
            c["bal"] -= cr
            if c["bal"] == 0:
                c["status"] = "consumed"
            remaining -= cr
            inv["cn"] += cr
            inv["credits"].append({"kind": "credit_note", "id": c["id"], "amount_cents": cr})
        total -= inv["cn"]
        if total > 0:
            wtx = []
            for w in sorted([w for w in wallets if w["cur"] == cur and w["bal"] > 0], key=lambda w: (w["prio"], w["seq"])):
                if total <= 0:
                    break
                take = min(w["bal"], total)
                w["bal"] -= take
                total -= take
                inv["prepaid"] += take
                wtx.append({"wallet": w["id"], "amount_cents": take})
            inv["wtx"] = wtx
    inv["total"] = total
    inv["payment_status"] = "pending" if total > 0 else "succeeded"
    return inv, coupons, cns


def totals_out(inv, coupons, cns, inp):
    out = {
        "fees": [{"id": f.id, "precise_coupons_amount_cents": f.pc, "taxes_amount_cents": f.taxes_amount,
                  "taxes_precise_amount_cents": f.taxes_precise, "taxes_rate": f.taxes_rate,
                  "precise_credit_notes_amount_cents": f.pcn, "applied_taxes": sorted(f.tax_rows, key=lambda r: r["code"])}
                 for f in inv["fees"]],
        "invoice": {"fees_amount_cents": inv["fees_amount"], "coupons_amount_cents": inv["coupons"],
                    "progressive_billing_credit_amount_cents": inv["pb"],
                    "sub_total_excluding_taxes_amount_cents": inv["sub"], "taxes_amount_cents": inv["taxes"],
                    "taxes_rate": inv["rate"], "sub_total_including_taxes_amount_cents": inv["sub_incl"],
                    "credit_notes_amount_cents": inv["cn"], "prepaid_credit_amount_cents": inv["prepaid"],
                    "total_amount_cents": inv["total"], "payment_status": inv["payment_status"]},
        "applied_taxes": inv["rows"], "credits": inv["credits"],
    }
    if coupons:
        out["applied_coupons_after"] = [{"id": c.id, "status": c.status,
                                         "frequency_duration_remaining": c.remaining_periods if c.freq == "recurring" else None}
                                        for c in coupons]
    if cns:
        out["credit_notes_after"] = [{"id": c["id"], "balance_amount_cents": c["bal"], "credit_status": c["status"]} for c in cns]
    if inp.get("wallets"):
        out["wallet_transactions"] = inv.get("wtx", [])
    return out


def op_totals(inp, ctx):
    n = Num(ctx["profile"])
    inv, coupons, cns = run_totals(inp, n)
    return totals_out(inv, coupons, cns, inp)


def op_apply_taxes(inp, ctx):
    n = Num(ctx["profile"])
    fees = [Fee(f, inp.get("currency", "EUR")) for f in inp["fees"]]
    for f in fees:
        fee_taxes(n, f)
    sub = int(inp.get("sub_total_excluding_taxes_amount_cents", sum(f.amount for f in fees)))
    rows, taxes, rate = invoice_taxes(n, fees, sub)
    return {"fees": [{"id": f.id, "precise_coupons_amount_cents": f.pc, "taxes_amount_cents": f.taxes_amount,
                      "taxes_precise_amount_cents": f.taxes_precise, "taxes_rate": f.taxes_rate,
                      "applied_taxes": sorted(f.tax_rows, key=lambda r: r["code"])} for f in fees],
            "applied_taxes": rows, "taxes_amount_cents": taxes, "taxes_rate": rate}


def op_fee_tax_selection(inp, ctx):
    t = inp["fee_type"]
    order = [("explicit", inp.get("explicit_tax_codes"))]
    if t == "add_on":
        order.append(("add_on", inp.get("add_on_taxes")))
    if t == "charge":
        order.append(("charge", inp.get("charge_taxes")))
    if t == "fixed_charge":
        order.append(("fixed_charge", inp.get("fixed_charge_taxes")))
    if t == "commitment":
        order.append(("commitment", inp.get("commitment_taxes")))
    if t in ("charge", "subscription", "commitment", "fixed_charge"):
        order.append(("plan", inp.get("plan_taxes")))
    order += [("customer", inp.get("customer_taxes")), ("billing_entity", inp.get("billing_entity_taxes"))]
    for _, lst in order:
        if lst:
            return {"taxes": list(lst)}
    return {"taxes": []}


def op_coupon_amount(inp, ctx):
    n = Num(ctx["profile"])
    cp = Coupon(dict(inp["applied_coupon"], id="c"), inp.get("currency", "EUR"))
    raw = inp["base_amount_cents"]
    base = int(raw) if not isinstance(raw, str) else D(raw)
    amt = coupon_amount(n, cp, base)
    out = {"amount": D(amt), "amount_cents": int(trunc(amt))}
    if cp.type == "fixed_amount":
        out["remaining_amount_cents"] = cp.remaining
    return out


def op_coupon_order(inp, ctx):
    lst = [(k, c) for k, c in enumerate(inp["applied_coupons"]) if c.get("status", "active") == "active"]
    lst.sort(key=lambda kc: (0 if kc[1].get("limited_billable_metrics") else 1 if kc[1].get("limited_plans") else 2, kc[0]))
    return {"order": [c["id"] for _, c in lst]}


def op_coupon_distribution(inp, ctx):
    n = Num(ctx["profile"])
    cur = inp.get("currency", "EUR")
    fees = [Fee(f, cur) for f in inp["fees"]]
    fa = sum(f.amount for f in fees)
    inv = {"currency": cur, "fees": fees, "coupons": 0, "sub": int(inp.get("sub_total_excluding_taxes_amount_cents", fa))}
    cp = Coupon(dict(inp["applied_coupon"], id="c"), cur)
    cr = apply_coupon(n, inv, cp)
    return {"applied": cr is not None, "credit_amount_cents": cr,
            "fees": [{"id": f.id, "precise_coupons_amount_cents": f.pc} for f in fees],
            "sub_total_excluding_taxes_amount_cents": inv["sub"],
            "applied_coupon_after": {"status": cp.status,
                                     "frequency_duration_remaining": cp.remaining_periods if cp.freq == "recurring" else None}}


def coupon_errors(c):
    """BE-IV-17 field checks shared by creation and application, in the order the record validates them."""
    if c["coupon_type"] == "fixed_amount":
        if c.get("amount_cents") is None:
            return "value_is_mandatory", "amount_cents"
    if c.get("amount_cents") is not None and int(c["amount_cents"]) <= 0:
        return "value_is_out_of_range", "amount_cents"
    if c["coupon_type"] == "fixed_amount" and not c.get("amount_currency"):
        return "value_is_mandatory", "amount_currency"
    if c.get("amount_currency") and not known_currency(c["amount_currency"]):
        return "value_is_invalid", "amount_currency"
    if c["coupon_type"] == "percentage" and c.get("percentage_rate") is None:
        return "value_is_mandatory", "percentage_rate"
    if c.get("frequency") == "recurring":
        if c.get("frequency_duration") is None:
            return "value_is_mandatory", "frequency_duration"
        if int(c["frequency_duration"]) <= 0:
            return "value_is_out_of_range", "frequency_duration"
    return None


def op_coupon_create(inp, ctx):
    """BE-IV-17."""
    c = inp["coupon"]
    now = dt.datetime.fromisoformat(inp.get("now", "2024-03-01T10:00:00Z").replace("Z", "+00:00"))
    if c.get("expiration_at") and dt.datetime.fromisoformat(c["expiration_at"].replace("Z", "+00:00")) <= now:
        raise KitError("invalid_date", "expiration_at")
    cat = inp.get("catalog", {})
    plans, bms = c.get("plan_codes") or [], c.get("billable_metric_codes") or []
    if plans and set(plans) - set(cat.get("plan_codes", [])):
        raise KitError("plans_not_found", "base")
    if bms and set(bms) - set(cat.get("billable_metric_codes", [])):
        raise KitError("billable_metrics_not_found", "base")
    if plans and bms:
        raise KitError("only_one_limitation_type_per_coupon_allowed", "base")
    err = coupon_errors(c)
    if err:
        raise KitError(*err)
    return {"coupon": {"status": "active", "reusable": c.get("reusable", True), "limited_plans": bool(plans),
                       "limited_billable_metrics": bool(bms), "frequency_duration": c.get("frequency_duration"),
                       "targets": len(set(plans)) + len(set(bms))}}


def op_coupon_apply(inp, ctx):
    """BE-IV-18."""
    c = inp["coupon"]
    if c.get("status", "active") != "active":
        raise KitError("coupon_not_found", "base")
    charges = {p["code"]: set(p.get("billable_metric_codes", [])) for p in inp.get("plans", [])}

    def targets(cp):
        plans, bms = set(cp.get("plan_codes") or []), set(cp.get("billable_metric_codes") or [])
        reach_bms = bms | {m for p in plans for m in charges.get(p, ())}
        reach_plans = plans | {p for p, ms in charges.items() if ms & bms}
        return plans, bms, reach_plans, reach_bms

    plans, bms, reach_plans, reach_bms = targets(c)
    before = inp.get("applied_before", [])
    if plans or bms:
        for e in before:
            other = e.get("coupon") or c
            if e.get("status", "active") != "active":
                continue
            o_plans, o_bms, _, _ = targets(other)
            if (o_plans & reach_plans) or (o_bms & reach_bms):
                raise KitError("plan_overlapping", "base")
    if not c.get("reusable", True) and any("coupon" not in e for e in before):
        raise KitError("coupon_is_not_reusable", "coupon")
    ov = inp.get("overrides", {})
    keys = ("amount_cents", "amount_currency", "percentage_rate", "frequency", "frequency_duration")
    applied = {k: ov.get(k, c.get(k)) for k in keys}
    if applied["amount_cents"] is not None and int(applied["amount_cents"]) < 0:
        raise KitError("value_is_out_of_range", "amount_cents")
    if applied["amount_currency"] and not known_currency(applied["amount_currency"]):
        raise KitError("value_is_invalid", "amount_currency")
    if applied["frequency"] == "recurring":
        if applied["frequency_duration"] is None:
            raise KitError("value_is_mandatory", "frequency_duration")
        if int(applied["frequency_duration"]) <= 0:
            raise KitError("value_is_out_of_range", "frequency_duration")
    cur = inp.get("customer_currency", "EUR")
    if c["coupon_type"] == "fixed_amount" and not cur:
        cur = applied["amount_currency"]
    if applied["percentage_rate"] is not None:
        applied["percentage_rate"] = D(applied["percentage_rate"])
    applied.update(status="active", frequency_duration_remaining=applied["frequency_duration"])
    return {"applied_coupon": applied, "customer_currency": cur}


# ---------------------------------------------------------------------------------------------------------------- lifecycle
def settings(inp):
    c, b = inp.get("customer") or {}, inp.get("billing_entity") or {}

    def eff(k, default):
        if k in c and c[k] is not None:
            return c[k]
        return b.get(k, default)
    return eff


def op_final_status(inp, ctx):
    eff = settings(inp)
    fees = int(inp["fees_amount_cents"])
    total = int(inp.get("total_amount_cents", fees))
    gated = inp.get("subscription_gated", False)
    if not gated and int(eff("invoice_grace_period", 0)) > 0:
        return {"status": "draft", "subscription_gated": False}
    if gated and (total > 0 or inp.get("tax_pending")):
        return {"status": "open", "subscription_gated": True}
    if fees != 0:
        st = "finalized"
    else:
        cs = (inp.get("customer") or {}).get("finalize_zero_amount_invoice", "inherit")
        ok = (inp.get("billing_entity") or {}).get("finalize_zero_amount_invoice", True) if cs == "inherit" else cs == "finalize"
        st = "finalized" if ok else "closed"
    return {"status": st, "subscription_gated": False}


def local_date(instant, tz):
    t = dt.datetime.fromisoformat(instant.replace("Z", "+00:00"))
    return t.astimezone(ZoneInfo(tz)).date()


def op_issuing_date(inp, ctx):
    eff = settings(inp)
    tz = inp.get("timezone", "UTC")
    d0 = local_date(inp["datetime"], tz)
    grace = int(eff("invoice_grace_period", 0))
    net = int(eff("net_payment_term", 0))
    subscription_like = inp.get("invoice_type", "subscription") == "subscription" and not inp.get("subscription_gated", False)
    if not subscription_like or inp.get("charge_in_advance", False):
        iss, exp = d0, d0
    else:
        if inp.get("invoicing_reason", "subscription_periodic") != "subscription_periodic":
            adj = grace
        else:
            anchor = eff("subscription_invoice_issuing_date_anchor", "next_period_start")
            how = eff("subscription_invoice_issuing_date_adjustment", "align_with_finalization_date")
            adj = {("current_period_end", "keep_anchor"): -1,
                   ("current_period_end", "align_with_finalization_date"): grace if grace else -1,
                   ("next_period_start", "keep_anchor"): 0,
                   ("next_period_start", "align_with_finalization_date"): grace}[(anchor, how)]
        iss, exp = d0 + dt.timedelta(days=adj), d0 + dt.timedelta(days=grace)
    return {"issuing_date": iss.isoformat(), "expected_finalization_date": exp.isoformat(),
            "payment_due_date": (iss + dt.timedelta(days=net)).isoformat(), "net_payment_term": net}


def op_payment_due_date(inp, ctx):
    eff = settings(inp)
    tz = inp.get("timezone", "UTC")
    keep = inp.get("recurring", True) and eff("subscription_invoice_issuing_date_adjustment", "align_with_finalization_date") == "keep_anchor"
    iss = dt.date.fromisoformat(inp["drafted_issuing_date"]) if keep else local_date(inp["now"], tz)
    return {"issuing_date": iss.isoformat(),
            "payment_due_date": (iss + dt.timedelta(days=int(eff("net_payment_term", 0)))).isoformat()}


def available_to_credit(n, version, draft, fees, coupons, pb, fees_amount):
    """BE-IV-47. fees: [(creditable, taxes_rate)]"""
    if version < 2 or draft:
        return D(0)
    F = sum(c for c, _ in fees)
    if F == 0:
        return D(0)
    if n.compat:
        adj = 0.0 if version < 3 else ((coupons + pb) / fees_amount) * F
        vat = math.fsum((c - adj * (c / F)) * float(r) for c, r in fees) / 100
        res = F - adj + float(math.floor(abs(vat) + 0.5) * (1 if vat >= 0 else -1))
        return D(repr(res)) if isinstance(res, float) else D(res)
    adj = D(0) if version < 3 else D(coupons + pb) / D(fees_amount) * F
    vat = sum(((D(c) - adj * D(c) / F) * D(r) for c, r in fees), D(0)) / 100
    return D(F) - adj + rha(vat)


def op_available_to_credit(inp, ctx):
    n = Num(ctx["profile"])
    iv = inp["invoice"]
    st = iv.get("status", "finalized")
    fees = [(int(f["amount_cents"]) - int(f.get("credited_amount_cents", 0)), D(f.get("taxes_rate", "0"))) for f in inp["fees"]]
    atc = available_to_credit(n, int(iv.get("version_number", 4)), st == "draft", fees, int(iv.get("coupons_amount_cents", 0)),
                              int(iv.get("progressive_billing_credit_amount_cents", 0)), int(iv["fees_amount_cents"]))
    credit_inv = iv.get("invoice_type", "subscription") == "credit"
    creditable = D(0) if credit_inv else atc
    cns = [c for c in inp.get("credit_notes", []) if c.get("status", "finalized") == "finalized"]
    offsets = sum(int(c.get("offset_amount_cents", 0)) for c in cns)
    total = int(iv.get("total_amount_cents", 0))
    paid = int(iv.get("total_paid_amount_cents", 0))
    due = 0 if st == "voided" else total - paid - offsets
    pay = iv.get("payment_status", "pending")
    if int(iv.get("version_number", 4)) < 2 or st == "draft" or (pay != "succeeded" and paid == total):
        refundable = D(0)
    else:
        refunded = sum(int(c.get("refund_amount_cents", 0)) for c in inp.get("credit_notes", []))
        refundable = max(min(D(paid - refunded), creditable), D(0))
    offsettable = min(D(due), creditable)
    fee_total = sum(int(f["amount_cents"]) for f in inp["fees"]) + i(
        D(repr(math.fsum(int(f["amount_cents"]) * float(D(f.get("taxes_rate", "0"))) for f in inp["fees"]) / 100)))
    live = [c for c in inp.get("credit_notes", []) if c.get("credit_status", "available") != "voided"]
    voidable = st == "finalized" and pay in ("pending", "failed") and paid == 0 and not live
    return {"available_to_credit_amount_cents": atc, "creditable_amount_cents": creditable, "refundable_amount_cents": refundable,
            "offsettable_amount_cents": offsettable, "total_due_amount_cents": due, "fee_total_amount_cents": fee_total,
            "voidable": voidable}


# ---------------------------------------------------------------------------------------------------------------- credit notes
class Inv:
    """An invoice after the totals pipeline, with the credit-note bookkeeping of chapter 08."""

    def __init__(self, spec, n):
        self.n = n
        t, coupons, cns = run_totals(dict(spec, context="finalize"), n)
        self.fees = t["fees"]
        self.by_id = {f.id: f for f in self.fees}
        self.status = spec.get("status", "finalized")
        self.version = int(spec.get("version_number", 4))
        self.total = t["total"]
        self.sub_incl = t["sub_incl"]
        self.fees_amount = t["fees_amount"]
        self.coupons = t["coupons"] + 0
        self.pb = t["pb"]
        self.rows = {r["code"]: r for r in t["rows"]}
        self.payment = spec.get("payment_status", t["payment_status"])
        self.paid = int(spec.get("total_paid_amount_cents", 0))
        self.notes = []  # finalized notes created on this invoice
        self.coupon_objs = coupons

    def creditable_fee(self, f):
        return f.amount - f.cn_items

    def available(self):
        return available_to_credit(self.n, self.version, self.status == "draft",
                                   [(self.creditable_fee(f), f.taxes_rate) for f in self.fees], self.coupons, self.pb,
                                   self.fees_amount)

    def refundable(self):
        if self.version < 2 or self.status == "draft" or (self.payment != "succeeded" and self.paid == self.total):
            return D(0)
        refunded = sum(c["refund"] for c in self.notes)
        return max(min(D(self.paid - refunded), self.available()), D(0))

    def fee_total(self):
        return sum(f.amount for f in self.fees) + i(D(repr(math.fsum(f.amount * float(f.taxes_rate) for f in self.fees) / 100)))


def cn_taxes(inv, items):
    """BE-CN-6..8. items: [(fee, precise)] -> (coupon_adj, rows, precise_taxes, rate)."""
    n = inv.n
    adj = D(0)
    if inv.version >= 3:
        for f, p in items:
            r = D(0) if f.amount == 0 else n.fdiv16(p, f.amount)
            adj += f.pc * r
    codes = []
    for f, _ in items:
        for c, r in f.taxes:
            if c not in [x[0] for x in codes]:
                codes.append((c, r))
    rows, ptot = [], D(0)
    rate = D(0)  # BE-CN-8: decimal in both profiles (unlike the invoice's binary64 rate, BE-IV-14)
    total_items = sum((p for _, p in items), D(0)) - adj
    for c, r in codes:
        base = D(0)
        for f, p in items:
            if c in [x[0] for x in f.taxes]:
                fr = D(0) if f.amount == 0 else n.fdiv16(p, f.amount)
                base += p - f.pc * fr
        pt = n.fdiv(base * r, 100)
        rows.append({"code": c, "amount_cents": i(pt), "base_amount_cents": i(base)})
        ptot += pt
        rate += D(0) if total_items == 0 else base / total_items * r
    return adj, rows, ptot, rate.quantize(Q5, rounding=ROUND_HALF_UP)


def cn_create(inv, req, automatic=False, premium=True):
    if not automatic and not premium:
        raise KitError("feature_unavailable", "base")
    if inv.version < 2:
        raise KitError("invalid_type_or_status", "base")
    items = []
    for it in req["items"]:
        f = inv.by_id.get(it["fee_id"])
        if f is None:
            raise KitError("fee_not_found", "base")
        p = D(it["amount_cents"])
        cents = i(p)
        if cents < 0:
            raise KitError("invalid_value", "amount_cents")
        if cents > inv.creditable_fee(f):
            raise KitError("higher_than_remaining_fee_amount", "amount_cents")
        items.append((f, p, cents))
    for f, _, cents in items:
        f.cn_items += cents
    credit, refund, offset = (int(req.get(k, 0)) for k in ("credit_amount_cents", "refund_amount_cents", "offset_amount_cents"))
    adj, rows, ptax, rate = cn_taxes(inv, [(f, p) for f, p, _ in items])
    ptax = inv.n.store_col5(ptax)
    if inv.available() == 0:
        ptax -= sum((c["taxes"] - c["ptaxes"] for c in inv.notes), D(0))
    taxes = i(ptax)
    padj = store5(adj)
    sub = i(sum((p for _, p, _ in items), D(0)) - padj)
    # validation (BE-CN-12)
    errs = {}
    total = credit + refund + offset
    if refund > 0 and inv.payment != "succeeded" and inv.paid == inv.total and inv.total > 0:
        errs.setdefault("refund_amount_cents", []).append("cannot_refund_unpaid_invoice")
    if abs(total - i(sum((p for _, p, _ in items), D(0)) - padj + ptax)) > 1:
        errs.setdefault("base", []).append("does_not_match_item_amounts")
    if refund > 0:
        if inv.paid <= 0:
            errs.setdefault("refund_amount_cents", []).append("cannot_refund_unpaid_invoice")
        elif refund > inv.paid - sum(c["refund"] for c in inv.notes):
            errs.setdefault("refund_amount_cents", []).append("higher_than_remaining_invoice_amount")
    credited = sum(c["credit"] for c in inv.notes)
    offs = sum(c["offset"] for c in inv.notes)
    creditable = inv.fee_total() - credited - offs
    if credit > creditable and abs(credit - creditable) > 1:
        errs.setdefault("credit_amount_cents", []).append("higher_than_remaining_invoice_amount")
    if offset > 0:
        due = inv.total - inv.paid - offs
        if offset > min(due, creditable):
            errs.setdefault("offset_amount_cents", []).append("higher_than_remaining_invoice_amount")
    remaining = inv.fee_total() - (credited + sum(c["refund"] for c in inv.notes) + offs)
    if total > remaining and abs(total - remaining) > 1:
        errs.setdefault("base", []).append("higher_than_remaining_invoice_amount")
    if total <= 0:
        errs.setdefault("base", []).append("total_amount_must_be_positive")
    if errs:
        for f, _, cents in items:
            f.cn_items -= cents
        return None, errs
    balance = credit
    refund_status = "pending" if refund > 0 else None  # set from the requested refund, before the correction
    if total - taxes != sub:
        total = total - 1 if total - taxes > sub else total + 1
        if inv.n.compat:  # BE-CN-11 at the pin (RBD-106): the offset is ignored
            if credit > 0:
                credit = total - refund
            else:
                refund = total
        elif credit > 0:  # corrected (RBD-106, proposed): one requested field absorbs the cent
            credit = total - refund - offset
        elif offset > 0:
            offset = total - refund
        else:
            refund = total
        balance = credit
    note = {"status": "finalized" if inv.status in ("finalized", "voided") else inv.status,
            "credit_status": "available", "refund_status": refund_status,
            "items": [{"fee_id": f.id, "amount_cents": c, "precise_amount_cents": p} for f, p, c in items],
            "coupons_adjustment_amount_cents": i(adj), "precise_coupons_adjustment_amount_cents": padj,
            "taxes_amount_cents": taxes, "precise_taxes_amount_cents": ptax, "taxes_rate": rate,
            "sub_total_excluding_taxes_amount_cents": sub, "credit_amount_cents": credit, "refund_amount_cents": refund,
            "offset_amount_cents": offset, "total_amount_cents": total, "balance_amount_cents": balance,
            "applied_taxes": sorted(rows, key=lambda r: r["code"]),
            "credit": credit, "refund": refund, "offset": offset, "taxes": taxes, "ptaxes": ptax}
    inv.notes.append(note)
    if offset > 0 and inv.total - inv.paid - sum(c["offset"] for c in inv.notes) <= 0:
        inv.payment = "succeeded"
    return note, None


PUBLIC = ["status", "credit_status", "refund_status", "items", "coupons_adjustment_amount_cents",
          "precise_coupons_adjustment_amount_cents", "taxes_amount_cents", "precise_taxes_amount_cents", "taxes_rate",
          "sub_total_excluding_taxes_amount_cents", "credit_amount_cents", "refund_amount_cents", "offset_amount_cents",
          "total_amount_cents", "balance_amount_cents", "applied_taxes"]


def prepare(inp, ctx):
    inv = Inv(inp["invoice"], Num(ctx["profile"]))
    for p in inp.get("previous_credit_notes", []):
        note, errs = cn_create(inv, p)
        if errs:
            raise ar.BadInput(f"previous credit note rejected: {errs}")
    return inv


def op_cn_compute(inp, ctx):
    inv = prepare(inp, ctx)
    note, errs = cn_create(inv, inp, premium=inp.get("premium", True))
    if errs:
        field, codes = next(iter(errs.items()))
        raise KitError(codes[0], field)
    out = {k: note[k] for k in PUBLIC}
    out["invoice_after"] = {"creditable_amount_cents": inv.available(),
                            "total_due_amount_cents": inv.total - inv.paid - sum(c["offset"] for c in inv.notes),
                            "payment_status": inv.payment}
    return out


def op_cn_validate(inp, ctx):
    inv = prepare(inp, ctx)
    try:
        note, errs = cn_create(inv, inp["request"], premium=inp.get("premium", True))
    except KitError as e:
        return {"valid": False, "errors": {e.field or "base": [e.code]}}
    return {"valid": not errs, "errors": errs or {}}


def op_cn_estimate(inp, ctx):
    if not inp.get("premium", True):
        raise KitError("feature_unavailable", "base")
    inv = prepare(inp, ctx)
    items = []
    for it in inp["items"]:
        f = inv.by_id.get(it["fee_id"])
        if f is None:
            raise KitError("fee_not_found", "base")
        c = int(D(str(it["amount_cents"])))  # BE-CN-14: a fraction is truncated toward zero
        if c > inv.creditable_fee(f):
            raise KitError("higher_than_remaining_fee_amount", "amount_cents")
        items.append((f, D(c)))
    adj, rows, ptax, rate = cn_taxes(inv, items)
    ptax = inv.n.store_col5(ptax)
    if sum((p for _, p in items), D(0)) == sum(inv.creditable_fee(f) for f in inv.fees):
        ptax -= sum((c["taxes"] - c["ptaxes"] for c in inv.notes), D(0))
    taxes = i(ptax)
    credit = i(sum((p for _, p in items), D(0)) - adj + ptax)
    refundable = inv.refundable()
    refund = credit if credit <= refundable else int(trunc(refundable))
    padj = store5(adj)
    sub = i(sum((p for _, p in items), D(0)) - padj)
    total = credit
    if total - taxes != sub:
        if total - taxes > sub:
            total -= 1
        elif taxes > 0:
            taxes -= 1
        credit = total
    return {"items": [{"fee_id": f.id, "amount_cents": int(p)} for f, p in items], "coupons_adjustment_amount_cents": i(adj),
            "precise_coupons_adjustment_amount_cents": padj, "taxes_amount_cents": taxes, "precise_taxes_amount_cents": ptax,
            "taxes_rate": rate, "sub_total_excluding_taxes_amount_cents": sub, "max_creditable_amount_cents": credit,
            "max_refundable_amount_cents": refund, "applied_taxes": sorted(rows, key=lambda r: r["code"])}


# ---------------------------------------------------------------------------------------------------------------- void
def op_void(inp, ctx):
    n = Num(ctx["profile"])
    inv = prepare(inp, ctx)
    paid_live = [c for c in inv.notes if c["credit_status"] != "voided"]
    voidable = inv.status == "finalized" and inv.payment in ("pending", "failed") and inv.paid == 0 and not paid_live
    if inv.status != "finalized":
        raise KitError("not_voidable")
    out_notes = []
    if inp.get("generate_credit_note"):
        credit, refund = int(inp.get("credit_amount_cents", 0)), int(inp.get("refund_amount_cents", 0))
        if credit > inv.available() or refund > inv.refundable() or credit + refund > inv.available():
            raise KitError("total_amount_exceeds_invoice_amount", "credit_refund_amount")
        req_total = credit + refund
        if req_total > 0:
            base_items = [(f, inv.creditable_fee(f)) for f in inv.fees if inv.creditable_fee(f) > 0]
            est = op_cn_estimate({"invoice": None, "items": []}, ctx) if False else None
            full = cn_estimate_total(inv, base_items)
            ratio = req_total / float(full)
            # BE-IV-42: the binary64 item is stored by the 5-place column rule (round5, then 16 significant digits), not
            # by rounding its text: 533 x (14 / 640) = 11.659374999999999 -> 11.65938; 102880657510.79861 -> .7986
            items = [{"fee_id": f.id, "amount_cents": n.store_col5(c * ratio) if n.compat else store5(D(c) * req_total / D(full))}
                     for f, c in base_items]
            note, errs = cn_create(inv, {"items": items, "credit_amount_cents": credit, "refund_amount_cents": refund})
            if errs:
                raise KitError(next(iter(errs.values()))[0], next(iter(errs)))
            out_notes.append(note)
        rem = inv.available()
        if i(rem) > 0:
            base_items = [(f, inv.creditable_fee(f)) for f in inv.fees if inv.creditable_fee(f) > 0]
            full = cn_estimate_total(inv, base_items)
            note, errs = cn_create(inv, {"items": [{"fee_id": f.id, "amount_cents": c} for f, c in base_items],
                                         "credit_amount_cents": full})
            if errs:
                raise KitError(next(iter(errs.values()))[0], next(iter(errs)))
            note["credit_status"] = "voided"
            note["balance_amount_cents"] = 0
            out_notes.append(note)
    for c in inv.coupon_objs:
        if c.used and c.freq != "forever" and c.status == "terminated":
            c.status = "active"
            if c.freq == "recurring":
                c.remaining_periods = (c.remaining_periods or 0) + 1
    return {"status": "voided", "voidable_before": voidable,
            "credit_notes": [{"credit_amount_cents": x["credit_amount_cents"], "refund_amount_cents": x["refund_amount_cents"],
                              "total_amount_cents": x["total_amount_cents"], "credit_status": x["credit_status"],
                              "items": [{"fee_id": it["fee_id"], "amount_cents": it["amount_cents"],
                                         "precise_amount_cents": it["precise_amount_cents"]} for it in x["items"]]}
                             for x in out_notes],
            "applied_coupons_after": [{"status": c.status, "frequency_duration_remaining": c.remaining_periods if c.freq == "recurring" else None}
                                      for c in inv.coupon_objs]}


def cn_estimate_total(inv, items):
    adj, rows, ptax, rate = cn_taxes(inv, [(f, D(c)) for f, c in items])
    ptax = inv.n.store_col5(ptax)
    total = i(sum((D(c) for _, c in items), D(0)) - adj + ptax)
    taxes = i(ptax)
    sub = i(sum((D(c) for _, c in items), D(0)) - store5(adj))
    if total - taxes > sub:
        total -= 1
    return total


# ---------------------------------------------------------------------------------------------------------------- termination
MONTHS = {"monthly": 1, "quarterly": 3, "semiannual": 6, "yearly": 12}


def add_months(d, m, anchor_day):
    y, mo = divmod(d.month - 1 + m, 12)
    y, mo = d.year + y, mo + 1
    last = (dt.date(y + (mo == 12), mo % 12 + 1, 1) - dt.timedelta(days=1)).day
    return dt.date(y, mo, min(anchor_day, last))


def period_of(interval, billing_time, start_local, day):
    """(from, to_inclusive) local dates of the billing period containing `day` (chapter 06 period algebra)."""
    if interval == "weekly":
        if billing_time == "calendar":
            frm = day - dt.timedelta(days=day.weekday())
        else:
            frm = day - dt.timedelta(days=(day.weekday() - start_local.weekday()) % 7)
        return frm, frm + dt.timedelta(days=6)
    m = MONTHS[interval]
    if billing_time == "calendar":
        mo = ((day.month - 1) // m) * m + 1 if m != 1 else day.month
        frm = dt.date(day.year, mo, 1)
        return frm, add_months(frm, m, 1) - dt.timedelta(days=1)
    frm = add_months(start_local, 0, start_local.day)
    while True:
        nxt = add_months(start_local, m * (((frm.year - start_local.year) * 12 + frm.month - start_local.month) // m + 1), start_local.day)
        if nxt > day:
            return frm, nxt - dt.timedelta(days=1)
        frm = nxt


def op_termination(inp, ctx):
    n = Num(ctx["profile"])
    tz = inp.get("timezone", "UTC")
    plan, sub, iv = inp["plan"], inp["subscription"], inp["invoice"]
    fee_amount = int(iv["subscription_fee_amount_cents"])
    if fee_amount == 0 or iv.get("status", "finalized") == "voided":
        return {"credit_note": None}
    if inp.get("upgrade") and inp.get("on_termination", "credit") in ("refund", "offset"):
        raise KitError("server_error")
    spec = {"currency": inp.get("currency", "EUR"),
            "fees": [{"id": "sub_fee", "fee_type": "subscription", "amount_cents": fee_amount, "taxes": iv.get("taxes", [])}]
            + list(iv.get("other_fees", [])), "applied_coupons": iv.get("applied_coupons", []),
            "payment_status": iv.get("payment_status", "pending"), "total_paid_amount_cents": iv.get("total_paid_amount_cents", 0)}
    inv = Inv(spec, n)
    for p in inp.get("previous_credit_notes", []):
        cn_create(inv, p)
    fee = inv.by_id["sub_fee"]
    term = dt.datetime.fromisoformat(inp["terminated_at"].replace("Z", "+00:00"))
    zone = ZoneInfo(tz)
    term_local = term.astimezone(zone)
    start_local = dt.datetime.fromisoformat(sub["started_at"].replace("Z", "+00:00")).astimezone(zone).date()
    frm, to = period_of(plan["interval"], sub.get("billing_time", "calendar"), start_local, term_local.date())
    duration = (to - frm).days + 1

    def utc_date(local_day, end=True):
        t = dt.datetime.combine(local_day, dt.time(23, 59, 59) if end else dt.time(0, 0), zone)
        return t.astimezone(dt.timezone.utc).date()
    to_utc, frm_utc = utc_date(to), utc_date(frm, end=False)
    day_price = float(plan["amount_cents"]) / duration if n.compat else D(plan["amount_cents"]) / duration
    eod = dt.datetime.combine(term_local.date(), dt.time(23, 59, 59), zone).astimezone(dt.timezone.utc).date()
    billed_from = eod - dt.timedelta(days=1) if inp.get("upgrade") else eod
    remaining = max((to_utc - billed_from).days, 0)
    unused = day_price * remaining
    if not unused > 0:
        return {"credit_note": None}
    amount = min(D(repr(unused)) if n.compat else unused, D(fee.amount)) - sum(
        (D(it["amount_cents"]) for c in inv.notes for it in c["items"] if it["fee_id"] == "sub_fee"), D(0))
    if amount <= 0:
        return {"credit_note": None}
    item = trunc(amount, 5)

    def with_coupons_taxes(x):
        adj, rows, pt, _ = cn_taxes(inv, [(fee, trunc(x, 5))])
        return i(trunc(x, 5) - adj + pt)

    total = with_coupons_taxes(item)
    mode = inp.get("on_termination", "credit")
    refund = 0
    if mode in ("refund", "offset"):
        if inv.sub_incl:
            share = n.fdiv(fee.sub_excl + fee.taxes_precise, inv.sub_incl) * inv.paid
            used_days = (min(eod, to_utc) - frm_utc).days + 1
            used = with_coupons_taxes(D(repr(day_price * used_days)) if n.compat else day_price * used_days)
            pot = share - used
            refund = i(min(pot, D(total))) if pot > 0 else 0
    credit, offset = {"credit": (total, 0), "refund": (total - refund, 0), "offset": (0, total - refund)}[mode]
    if credit + refund + offset == 0:
        return {"credit_note": None}
    note, errs = cn_create(inv, {"items": [{"fee_id": "sub_fee", "amount_cents": item}], "credit_amount_cents": credit,
                                 "refund_amount_cents": refund, "offset_amount_cents": offset}, automatic=True)
    if errs:
        field, codes = next(iter(errs.items()))
        raise KitError(codes[0], field)
    return {"credit_note": {k: note[k] for k in PUBLIC}}


HANDLERS = {
    "invoice.totals": op_totals, "invoice.apply_taxes": op_apply_taxes, "invoice.fee_tax_selection": op_fee_tax_selection,
    "invoice.coupon_amount": op_coupon_amount, "invoice.coupon_order": op_coupon_order,
    "invoice.coupon_distribution": op_coupon_distribution, "invoice.coupon_create": op_coupon_create,
    "invoice.coupon_apply": op_coupon_apply, "invoice.final_status": op_final_status,
    "invoice.issuing_date": op_issuing_date, "invoice.payment_due_date": op_payment_due_date,
    "invoice.available_to_credit": op_available_to_credit, "invoice.void": op_void,
    "credit_notes.compute": op_cn_compute, "credit_notes.estimate": op_cn_estimate, "credit_notes.validate": op_cn_validate,
    "credit_notes.termination": op_termination,
}

if __name__ == "__main__":
    sys.exit(ar.serve(HANDLERS, impl="recompute-invoicing", impl_version="1.0.0", profiles=["compat", "corrected"]))
