#!/usr/bin/env python3.12
"""Clean-room adapter (JSON-lines protocol v1) for the areas `invoice` and `credit_notes`.

Implemented from the kit chapters 07/08 (billing-engine-spec) only.
Exact values are `fractions.Fraction`; the documented binary64 islands (compat profile)
are computed with Python floats, and with exact fractions in the corrected profile.
"""
import json
import math
import sys
from fractions import Fraction
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal, ROUND_HALF_UP, ROUND_DOWN
from zoneinfo import ZoneInfo

from periods import (period_of, days_between, local_date, end_of_local_day_utc,
                     start_of_local_day_utc, parse_instant, fmt_instant)

COMPAT = True  # set per call from the profile


# ----------------------------------------------------------------------------- numbers
def F(x):
    """Exact value from a JSON number / string / Fraction."""
    if isinstance(x, Fraction):
        return x
    if isinstance(x, float):
        return Fraction(repr(x))
    if isinstance(x, (int,)):
        return Fraction(x)
    if isinstance(x, Decimal):
        return Fraction(x)
    return Fraction(str(x))


def N(x):
    """Binary64 island value: float in compat, exact fraction in corrected."""
    x = F(x) if not isinstance(x, float) else x
    if COMPAT:
        return float(x)
    return F(x)


def rnd(x):
    """Round half away from zero, to an int (exact on the value)."""
    fr = Fraction(x) if not isinstance(x, Fraction) else x
    neg = fr < 0
    a = -fr if neg else fr
    r = (2 * a.numerator + a.denominator) // (2 * a.denominator)
    return -r if neg else r


def trunc(x):
    fr = Fraction(x)
    return int(fr.numerator // fr.denominator) if fr >= 0 else -int((-fr).numerator // (-fr).denominator)


def round_places(x, places):
    fr = Fraction(x)
    scale = 10 ** places
    return Fraction(rnd(fr * scale), scale)


def trunc_places(x, places):
    fr = Fraction(x)
    scale = 10 ** places
    return Fraction(trunc(fr * scale), scale)


def q5(x):
    return round_places(x, 5)


def col5(x):
    """Column rule (ch.07 notation): round5, then 16 significant digits (nearest), then 5 places half away."""
    from decimal import Decimal, ROUND_HALF_EVEN, localcontext
    r = ruby_round_float(x, 5)
    if r == 0:
        return r
    if isinstance(x, float):
        r = Fraction(repr(_round5_float(x)))  # the binary64 round5 result; its text is what gets cast
    with localcontext() as c:
        c.prec = 16
        c.rounding = ROUND_HALF_EVEN
        d = +Decimal(float(r))  # nearest on the exact binary64 value
    return round_places(Fraction(d), 5)


def _round5_float(x):
    s = 10.0 ** 5
    f = float(rnd(Fraction(x * s)))
    # binary64 sum (BE-IV-14): from f >= 2^52 f + 0.5 lands on the even neighbour, so an even f is raised
    if x > 0 and (f + 0.5) / s <= x:
        f += 1
    elif x < 0 and (f - 0.5) / s >= x:
        f -= 1
    return f / s


def ruby_round_float(x, places):
    """Float#round(places) as the reference does it (binary64, half away)."""
    if not isinstance(x, float):
        return round_places(x, places)
    s = 10.0 ** places
    xs = x * s
    f = float(rnd(Fraction(xs)))
    if x > 0:
        if (f + 0.5) / s <= x:
            f += 1
    elif x < 0:
        if (f - 0.5) / s >= x:
            f -= 1
    return Fraction(repr(f / s)) if False else Fraction(int(f), 10 ** places)


def sig16(x):
    """dec16 (BE-IV-6 reading guide): cut after 16 significant digits, never rounded."""
    fr = Fraction(x)
    if fr == 0:
        return Fraction(0)
    d = Decimal(fr.numerator) / Decimal(fr.denominator)
    exp = d.adjusted()
    places = 15 - exp
    q = Decimal(1).scaleb(-places)
    return Fraction(d.quantize(q, rounding=ROUND_DOWN))


def dec_str(x, places=None):
    """Canonical decimal string of an exact/float value."""
    if isinstance(x, float):
        d = Decimal(repr(x))
        if places is not None:
            d = d.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)
        s = format(d, "f")
        return s
    fr = Fraction(x)
    if fr.denominator == 1:
        return str(fr.numerator)
    if places is None:
        places = 15
    scale = 10 ** places
    n = rnd(fr * scale)
    neg = n < 0
    n = abs(n)
    ip, fp = divmod(n, scale)
    s = str(ip)
    if places:
        fs = str(fp).rjust(places, "0").rstrip("0")
        if fs:
            s += "." + fs
    return ("-" if neg else "") + s


def out_num(x):
    """Cents-valued output that may be an int or a float."""
    if isinstance(x, float):
        return dec_str(x)
    fr = Fraction(x)
    if fr.denominator == 1:
        return int(fr)
    return dec_str(fr)


class DomainError(Exception):
    def __init__(self, code, field=None):
        self.code = code
        self.field = field


# ----------------------------------------------------------------------------- models
class Fee:
    pass


def mkfee(d, currency="EUR"):
    f = Fee()
    f.id = d["id"]
    f.type = d.get("fee_type", "charge")
    f.amount = F(d["amount_cents"])
    f.precise = F(d["precise_amount_cents"]) if "precise_amount_cents" in d else f.amount
    f.pc = F(d.get("precise_coupons_amount_cents", 0))
    f.plan_code = d.get("plan_code", "plan")
    f.bm = d.get("billable_metric_code", "__bm_" + str(f.id))
    f.taxes = [(t["code"], F(t["rate"])) for t in d.get("taxes", [])]
    f.pcn = Fraction(0)
    f.tax_rows = []
    f.taxes_amount = 0
    f.taxes_precise = Fraction(0)
    f.taxes_rate = Fraction(0)
    f.raw = d
    return f


def pct_amount(base, rate):
    """base * rate / 100 (binary64 division in compat)."""
    if COMPAT:
        return float(F(base) * F(rate)) / 100.0
    return F(base) * F(rate) / 100


def apply_fee_taxes(f):
    """Fee tax rows (BE-DM-27..29, BE-IV-11)."""
    base = f.amount - f.pc
    pbase = f.precise - f.pc
    rows = []
    tot = 0 if not COMPAT else 0.0
    ptot = Fraction(0)
    rate_sum = Fraction(0)
    for code, rate in sorted(f.taxes, key=lambda t: t[0]):
        c = pct_amount(base, rate)
        pr = pbase * rate / 100
        rows.append({"code": code, "amount_cents": rnd(c), "precise_amount_cents": dec_str(pr, 15)})
        tot += c
        ptot += pr
        rate_sum += rate
    f.tax_rows = rows
    f.taxes_amount = rnd(tot) if rows else 0
    f.taxes_precise = ptot
    f.taxes_rate = rate_sum


def invoice_taxes(fees, sub_total):
    """BE-IV-12..14. Returns (rows, taxes_amount, taxes_rate)."""
    codes = {}
    for f in fees:
        for code, rate in f.taxes:
            codes.setdefault(code, rate)
    rows = []
    tot = 0.0 if COMPAT else Fraction(0)
    rate_acc = 0.0 if COMPAT else Fraction(0)
    for code in sorted(codes):
        rate = codes[code]
        taxed = [f for f in fees if any(c == code for c, _ in f.taxes)]
        base = sum((f.amount - f.pc for f in taxed), Fraction(0))
        contrib = pct_amount(base, rate)
        rows.append({"code": code, "tax_rate": dec_str(rate, 5), "fees_amount_cents": trunc(base),
                     "amount_cents": rnd(contrib)})
        tot += contrib
        if sub_total > 0:
            share = N(base) / N(sub_total)
        else:
            share = N(len(taxed)) / N(len(fees))
        rate_acc += share * N(rate)
    taxes_amount = rnd(tot)
    if COMPAT:
        taxes_rate = ruby_round_float(float(rate_acc), 5)
    else:
        taxes_rate = round_places(rate_acc, 5)
    return rows, taxes_amount, taxes_rate


# ----------------------------------------------------------------------------- coupons
class Coupon:
    pass


def mkcoupon(d, currency):
    c = Coupon()
    c.id = d.get("id")
    c.type = d["coupon_type"]
    c.amount = F(d["amount_cents"]) if d.get("amount_cents") is not None else None
    c.currency = d.get("amount_currency", currency)
    rate = d.get("percentage_rate", d.get("coupon_percentage_rate"))
    c.rate = F(rate) if rate is not None else None
    c.frequency = d.get("frequency", "once")
    c.duration = d.get("frequency_duration")
    c.remaining = d.get("frequency_duration_remaining", c.duration)
    c.used = F(d.get("used_amount_cents", 0))
    c.plans = d.get("limited_plan_codes", [])
    c.metrics = d.get("limited_billable_metric_codes", [])
    c.status = d.get("status", "active")
    c.raw = d
    return c


def coupon_amount(c, B, limited=None):
    """BE-IV-23. Returns amount (exact)."""
    B = F(B)
    if limited is None:
        limited = bool(c.metrics or c.plans) or B.denominator != 1
    if c.type == "percentage":
        rate = c.rate
        if not limited:
            if COMPAT:
                v = float(B) * (float(rate) / 100.0)
                vf = Fraction(v)
            else:
                vf = B * rate / 100
        else:
            r16 = round_sig(rate / 100, 16)
            vf = B * r16
        if vf >= B:
            return B
        return Fraction(rnd(vf))
    # fixed
    if c.frequency == "once":
        remaining = c.amount - c.used
        return min(remaining, B)
    return min(c.amount, B)


def round_sig(x, n):
    fr = Fraction(x)
    if fr == 0:
        return fr
    d = Decimal(fr.numerator) / Decimal(fr.denominator)
    exp = d.adjusted()
    q = Decimal(1).scaleb(exp - n + 1)
    return Fraction(d.quantize(q, rounding=ROUND_HALF_UP))


def coupon_order_key(c):
    if c.metrics:
        return 0
    if c.plans:
        return 1
    return 2


def apply_coupon(c, fees, sub_total, currency, credited_ids):
    """One coupon on an invoice (BE-IV-21..27). Returns (credit_int or None, applied)."""
    if c.type == "fixed_amount" and c.currency != currency:
        return None
    if c.metrics:
        targets = [f for f in fees if f.type == "charge" and f.bm in c.metrics]
        limited = True
    elif c.plans:
        targets = [f for f in fees if f.plan_code in c.plans]
        limited = True
    else:
        targets = list(fees)
        limited = False
    if not targets:
        return None
    if limited:
        B = sum((f.amount - f.pc for f in targets), Fraction(0))
    else:
        B = F(sub_total)
    amount = coupon_amount(c, B, limited)
    credit = trunc(amount)
    if B != 0:
        for f in targets:
            if COMPAT:
                share = float(amount) * float(f.amount - f.pc) / float(B)
            else:
                share = amount * (f.amount - f.pc) / B
            f.pc = q5(f.pc + F(share) if COMPAT else f.pc + share)
            if f.pc > f.amount:
                f.pc = f.amount
    consume_coupon(c, credit)
    return credit


def consume_coupon(c, credit):
    if c.frequency == "recurring":
        rem = max((c.remaining if c.remaining is not None else 0) - 1, 0)
        c.remaining = rem
        if rem == 0:
            c.status = "terminated"
    elif c.frequency == "once":
        if c.type == "percentage":
            c.status = "terminated"
        else:
            remaining = c.amount - c.used
            if credit >= remaining:
                c.status = "terminated"
    # forever: never terminated


# ----------------------------------------------------------------------------- totals
def run_totals(inp):
    currency = inp.get("currency", "EUR")
    itype = inp.get("invoice_type", "subscription")
    ctx = inp.get("context", "finalize")
    fees = [mkfee(f) for f in inp["fees"]]
    coupons = [mkcoupon(c, currency) for c in inp.get("applied_coupons", [])]
    fees_amount = sum((f.amount for f in fees), Fraction(0))
    sub = fees_amount
    credits = []

    # progressive billing credit
    prog_credit = Fraction(0)
    pb = inp.get("progressive_billing")
    if pb and itype in ("subscription", "progressive_billing"):
        for pf in pb["fees"]:
            tgt = [f for f in fees if f.id == pf["same_charge_as"]]
            for f in tgt:
                give = min(F(pf["amount_cents"]), f.amount - f.pc)
                if give > 0:
                    f.pc = f.pc + give
                    prog_credit += give
        if prog_credit > 0:
            credits.append({"kind": "progressive_billing", "id": None, "amount_cents": int(prog_credit)})
        sub -= prog_credit

    coupons_amount = 0
    do_coupons = False
    if itype == "subscription":
        do_coupons = ctx == "finalize" and fees_amount > 0
    elif itype == "pay_in_advance_charge":
        do_coupons = fees_amount > 0
    elif itype == "progressive_billing":
        do_coupons = True
    if do_coupons:
        active = [c for c in coupons if c.status == "active"]
        active = sorted(active, key=coupon_order_key)  # stable: input order = creation order
        for c in active:
            if sub <= 0:
                break
            credit = apply_coupon(c, fees, sub, currency, None)
            if credit is None:
                continue
            credits.append({"kind": "coupon", "id": c.id, "amount_cents": credit})
            coupons_amount += credit
            sub -= credit

    # taxes
    for f in fees:
        apply_fee_taxes(f)
    rows, taxes_amount, taxes_rate = invoice_taxes(fees, sub)
    sub_incl = sub + taxes_amount
    total = sub_incl

    cn_amount = 0
    notes_after = None
    notes = inp.get("credit_notes")
    if notes is not None:
        notes_after = [{"id": n["id"], "balance_amount_cents": int(n["balance_amount_cents"]),
                        "credit_status": "available"} for n in notes]
    if ctx == "finalize" and itype != "one_off" and notes:
        remaining = total
        for n, na in zip(notes, notes_after):
            if remaining <= 0:
                break
            if n.get("currency", currency) != currency:
                continue
            bal = F(n["balance_amount_cents"])
            if bal <= 0:
                continue
            credit = min(bal, remaining)
            for f in fees:
                after = f.amount - f.pc + f.taxes_amount - f.pcn
                if remaining != 0:
                    share = N(credit) * N(after) / N(remaining)
                    f.pcn = min(q5(f.pcn + F(share)), f.amount - f.pc + f.taxes_amount)
            na["balance_amount_cents"] = int(bal - credit)
            if bal - credit == 0:
                na["credit_status"] = "consumed"
            credits.append({"kind": "credit_note", "id": n["id"], "amount_cents": int(credit)})
            cn_amount += int(credit)
            remaining -= credit
        total -= cn_amount

    prepaid = 0
    wtx = None
    wallets = inp.get("wallets")
    if wallets is not None:
        wtx = []
    if ctx == "finalize" and itype not in ("one_off",) and wallets and total > 0:
        order = sorted(range(len(wallets)), key=lambda i: (wallets[i].get("priority", 50), i))
        remaining = total
        for i in order:
            w = wallets[i]
            if remaining <= 0:
                break
            if w.get("currency", currency) != currency:
                continue
            bal = F(w["balance_cents"])
            if bal <= 0:
                continue
            take = min(bal, remaining)
            wtx.append({"wallet": w["id"], "amount_cents": int(take)})
            prepaid += int(take)
            remaining -= take
        total -= prepaid
    if total < 0:
        total = Fraction(0)

    out = {
        "fees": [fee_out(f) for f in fees],
        "invoice": {
            "fees_amount_cents": int(fees_amount),
            "coupons_amount_cents": coupons_amount,
            "progressive_billing_credit_amount_cents": int(prog_credit),
            "sub_total_excluding_taxes_amount_cents": int(sub),
            "taxes_amount_cents": taxes_amount,
            "sub_total_including_taxes_amount_cents": int(sub_incl),
            "credit_notes_amount_cents": cn_amount,
            "prepaid_credit_amount_cents": prepaid,
            "total_amount_cents": int(total),
            "taxes_rate": dec_str(taxes_rate, 5),
            "payment_status": "pending" if total > 0 else "succeeded",
        },
        "applied_taxes": rows,
        "credits": credits,
    }
    if inp.get("applied_coupons") is not None:
        out["applied_coupons_after"] = [
            {"id": c.id, "status": c.status,
             "frequency_duration_remaining": (c.remaining if c.frequency == "recurring" else None)}
            for c in coupons]
    if notes_after is not None:
        out["credit_notes_after"] = notes_after
    if wtx is not None:
        out["wallet_transactions"] = wtx
    out["_state"] = {"fees": fees, "coupons": coupons, "sub_incl": sub_incl, "total": total,
                     "taxes_amount": taxes_amount, "credits": credits}
    return out


def fee_out(f):
    return {
        "id": f.id,
        "precise_coupons_amount_cents": dec_str(f.pc, 5),
        "taxes_amount_cents": f.taxes_amount,
        "taxes_precise_amount_cents": dec_str(f.taxes_precise, 15),
        "taxes_rate": dec_str(f.taxes_rate, 5),
        "precise_credit_notes_amount_cents": dec_str(f.pcn, 5),
        "applied_taxes": f.tax_rows,
    }


def strip_state(o):
    return {k: v for k, v in o.items() if not k.startswith("_")}


# ----------------------------------------------------------------------------- op: apply_taxes etc.
def op_apply_taxes(inp):
    fees = [mkfee(f) for f in inp["fees"]]
    for f in fees:
        apply_fee_taxes(f)
    if "sub_total_excluding_taxes_amount_cents" in inp:
        sub = F(inp["sub_total_excluding_taxes_amount_cents"])
    else:
        sub = sum((f.amount for f in fees), Fraction(0))
    rows, amount, rate = invoice_taxes(fees, sub)
    return {"fees": [fee_out(f) for f in fees], "applied_taxes": rows, "taxes_amount_cents": amount,
            "taxes_rate": dec_str(rate, 5)}


def op_coupon_amount(inp):
    c = mkcoupon(inp["applied_coupon"], inp.get("currency", "EUR"))
    B = F(inp["base_amount_cents"])
    amt = coupon_amount(c, B)
    out = {"amount": dec_str(amt, 5), "amount_cents": trunc(amt)}
    if c.type == "fixed_amount" and c.frequency == "once":
        out["remaining_amount_cents"] = int(c.amount - c.used)
    return out


def op_coupon_order(inp):
    cs = []
    for i, c in enumerate(inp["applied_coupons"]):
        if c.get("status", "active") != "active":
            continue
        k = 0 if c.get("limited_billable_metrics") else 1 if c.get("limited_plans") else 2
        cs.append((k, i, c["id"]))
    cs.sort()
    return {"order": [c[2] for c in cs]}


def op_coupon_distribution(inp):
    currency = inp.get("currency", "EUR")
    fees = [mkfee(f) for f in inp["fees"]]
    c = mkcoupon(inp["applied_coupon"], currency)
    if "sub_total_excluding_taxes_amount_cents" in inp:
        sub = F(inp["sub_total_excluding_taxes_amount_cents"])
    else:
        sub = sum((f.amount for f in fees), Fraction(0))
    credit = apply_coupon(c, fees, sub, currency, None)
    if credit is None:
        return {"applied": False, "credit_amount_cents": None,
                "fees": [{"id": f.id, "precise_coupons_amount_cents": dec_str(f.pc, 5)} for f in fees],
                "sub_total_excluding_taxes_amount_cents": int(sub),
                "applied_coupon_after": {"status": c.status, "frequency_duration_remaining": None}}
    return {"applied": True, "credit_amount_cents": credit,
            "fees": [{"id": f.id, "precise_coupons_amount_cents": dec_str(f.pc, 5)} for f in fees],
            "sub_total_excluding_taxes_amount_cents": int(sub - credit),
            "applied_coupon_after": {"status": c.status,
                                     "frequency_duration_remaining": c.remaining if c.frequency == "recurring" else None}}


def op_fee_tax_selection(inp):
    ft = inp["fee_type"]
    explicit = inp.get("explicit_tax_codes")
    chain = []
    if explicit:
        return {"taxes": list(explicit)}
    if ft == "add_on":
        chain = [inp.get("add_on_taxes", [])]
    elif ft == "charge":
        chain = [inp.get("charge_taxes", []), inp.get("plan_taxes", [])]
    elif ft == "fixed_charge":
        chain = [inp.get("fixed_charge_taxes", []), inp.get("plan_taxes", [])]
    elif ft == "commitment":
        chain = [inp.get("commitment_taxes", []), inp.get("plan_taxes", [])]
    elif ft == "subscription":
        chain = [inp.get("plan_taxes", [])]
    chain += [inp.get("customer_taxes", []), inp.get("billing_entity_taxes", [])]
    for c in chain:
        if c:
            return {"taxes": list(c)}
    return {"taxes": []}


# ----------------------------------------------------------------------------- coupon create / apply
KNOWN_CURRENCIES = frozenset("""
AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN BHD BIF BMD BND BOB BRL BSD BWP BYN BZD CAD CDF CHF CLF CLP CNY COP CRC CVE CZK DJF DKK DOP DZD EGP ETB EUR FJD FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HRK HTG HUF IDR ILS INR IRR ISK JMD JOD JPY KES KGS KHR KMF KRW KWD KYD KZT LAK LBP LKR LRD LSL MAD MDL MGA MKD MMK MNT MOP MRO MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK NPR NZD PAB PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR SEK SGD SHP SLL SOS SRD STD SZL THB TJS TOP TRY TTD TWD TZS UAH UGX USD UYU UZS VND VUV WST XAF XCD XOF XPF YER ZAR ZMW
""".split())


def op_coupon_create(inp):
    c = inp["coupon"]
    cat = inp.get("catalog", {})
    now = parse_instant(inp.get("now", "2024-03-01T10:00:00Z"))
    ea = c.get("expiration_at")
    if ea is not None and parse_instant(ea) <= now:
        raise DomainError("invalid_date", "expiration_at")
    plans = c.get("plan_codes", [])
    bms = c.get("billable_metric_codes", [])
    if plans and any(p not in cat.get("plan_codes", []) for p in plans):
        raise DomainError("plans_not_found", "base")
    if bms and any(b not in cat.get("billable_metric_codes", []) for b in bms):
        raise DomainError("billable_metrics_not_found", "base")
    if plans and bms:
        raise DomainError("only_one_limitation_type_per_coupon_allowed", "base")
    validate_coupon(c, now)
    return {"coupon": {"status": "active", "reusable": c.get("reusable", True),
                       "limited_plans": bool(plans), "limited_billable_metrics": bool(bms),
                       "frequency_duration": c.get("frequency_duration"),
                       "targets": len(set(plans)) + len(set(bms))}}


def validate_coupon(c, now, vals=None):
    """BE-IV-17 value checks: amount_cents, amount_currency, percentage_rate, frequency_duration."""
    v = dict(c)
    if vals:
        v.update(vals)
    fixed = v["coupon_type"] == "fixed_amount"
    amt = v.get("amount_cents")
    cur = v.get("amount_currency")
    if fixed and amt is None:
        raise DomainError("value_is_mandatory", "amount_cents")
    if amt is not None and F(amt) <= 0:
        raise DomainError("value_is_out_of_range", "amount_cents")
    if fixed and not cur:
        raise DomainError("value_is_mandatory", "amount_currency")
    if cur and cur not in KNOWN_CURRENCIES:
        raise DomainError("value_is_invalid", "amount_currency")
    if not fixed and v.get("percentage_rate") is None:
        raise DomainError("value_is_mandatory", "percentage_rate")
    if v.get("frequency") == "recurring":
        if v.get("frequency_duration") is None:
            raise DomainError("value_is_mandatory", "frequency_duration")
        if v["frequency_duration"] <= 0:
            raise DomainError("value_is_out_of_range", "frequency_duration")


def op_coupon_apply(inp):
    coupon = inp["coupon"]
    plans = {p["code"]: p.get("billable_metric_codes", []) for p in inp.get("plans", [])}
    before = inp.get("applied_before", [])
    ov = inp.get("overrides", {})
    now = parse_instant(inp.get("now", "2024-03-01T10:00:00Z"))
    cur = inp.get("customer_currency", "EUR")
    if coupon.get("status", "active") != "active":
        raise DomainError("coupon_not_found", "base")
    # overlap
    cplans = set(coupon.get("plan_codes", []))
    cbms = set(coupon.get("billable_metric_codes", []))
    if cplans or cbms:
        for b in before:
            if b.get("status", "active") != "active":
                continue
            bc = b.get("coupon", coupon)
            bplans = set(bc.get("plan_codes", []))
            bbms = set(bc.get("billable_metric_codes", []))
            if not (bplans or bbms):
                continue
            if "coupon" not in b:
                bc = coupon
            if overlaps(cplans, cbms, bplans, bbms, plans):
                raise DomainError("plan_overlapping", "base")
    # reusability
    if coupon.get("reusable", True) is False:
        if any("coupon" not in b for b in before):
            raise DomainError("coupon_is_not_reusable", "coupon")
    vals = {}
    for k in ("amount_cents", "amount_currency", "percentage_rate", "frequency", "frequency_duration"):
        if k in ov:
            vals[k] = ov[k]
    applied = {
        "coupon_type": coupon["coupon_type"],
        "amount_cents": vals.get("amount_cents", coupon.get("amount_cents")),
        "amount_currency": vals.get("amount_currency", coupon.get("amount_currency")),
        "percentage_rate": vals.get("percentage_rate", coupon.get("percentage_rate")),
        "frequency": vals.get("frequency", coupon.get("frequency")),
        "frequency_duration": vals.get("frequency_duration", coupon.get("frequency_duration")),
    }
    if applied["amount_cents"] is not None and F(applied["amount_cents"]) < 0:
        raise DomainError("value_is_out_of_range", "amount_cents")
    ac = applied["amount_currency"]
    if ac and ac not in KNOWN_CURRENCIES:
        raise DomainError("value_is_invalid", "amount_currency")
    if applied["frequency"] == "recurring":
        fd = applied["frequency_duration"]
        if fd is None:
            raise DomainError("value_is_mandatory", "frequency_duration")
        if fd <= 0:
            raise DomainError("value_is_out_of_range", "frequency_duration")
    if applied["frequency"] != "recurring":
        pass
    out_cur = cur
    if applied["coupon_type"] == "fixed_amount" and not cur:
        out_cur = applied["amount_currency"]
    return {"applied_coupon": {
        "status": "active",
        "amount_cents": applied["amount_cents"] if applied["coupon_type"] == "fixed_amount" else applied["amount_cents"],
        "amount_currency": applied["amount_currency"],
        "percentage_rate": dec_str(F(applied["percentage_rate"]), 5) if applied["percentage_rate"] is not None else None,
        "frequency": applied["frequency"],
        "frequency_duration": applied["frequency_duration"],
        "frequency_duration_remaining": applied["frequency_duration"],
    }, "customer_currency": out_cur}


def overlaps(cplans, cbms, bplans, bbms, plans):
    if cplans & bplans:
        return True
    if cbms & bbms:
        return True
    for p in cplans:
        if set(plans.get(p, [])) & bbms:
            return True
    for p in bplans:
        if set(plans.get(p, [])) & cbms:
            return True
    return False


# ----------------------------------------------------------------------------- lifecycle
def eff(customer, be, key, default):
    if key in customer and customer[key] is not None:
        return customer[key]
    if key in be and be[key] is not None:
        return be[key]
    return default


def op_final_status(inp):
    cust = inp.get("customer", {})
    be = inp.get("billing_entity", {})
    fees = inp["fees_amount_cents"]
    total = inp.get("total_amount_cents", fees)
    gated = inp.get("subscription_gated", False)
    tax_pending = inp.get("tax_pending", False)
    grace = eff(cust, be, "invoice_grace_period", 0)
    if grace > 0 and not gated:
        status = "draft"
    elif gated and (total > 0 or tax_pending):
        status = "open"
    elif tax_pending:
        status = "pending"
    elif fees != 0:
        status = "finalized"
    else:
        z = cust.get("finalize_zero_amount_invoice", "inherit")
        if z == "finalize":
            status = "finalized"
        elif z == "skip":
            status = "closed"
        else:
            status = "finalized" if be.get("finalize_zero_amount_invoice", True) else "closed"
    return {"status": status, "subscription_gated": gated}


def op_issuing_date(inp):
    cust = inp.get("customer", {})
    be = inp.get("billing_entity", {})
    tz = inp.get("timezone", "UTC")
    dt = parse_instant(inp["datetime"])
    d = local_date(dt, tz)
    itype = inp.get("invoice_type", "subscription")
    reason = inp.get("invoicing_reason", "subscription_periodic")
    gated = inp.get("subscription_gated", False)
    grace = eff(cust, be, "invoice_grace_period", 0)
    net = eff(cust, be, "net_payment_term", 0)
    adjusted = (itype == "subscription" and not gated and not inp.get("charge_in_advance", False)
                and reason not in ("in_advance_charge", "in_advance_charge_periodic"))
    if adjusted:
        exp_fin = d + timedelta(days=grace)
        if reason != "subscription_periodic":
            issuing = d + timedelta(days=grace)
        else:
            anchor = eff(cust, be, "subscription_invoice_issuing_date_anchor", "next_period_start")
            adj = eff(cust, be, "subscription_invoice_issuing_date_adjustment", "align_with_finalization_date")
            if anchor == "current_period_end":
                if adj == "keep_anchor":
                    issuing = d - timedelta(days=1)
                else:
                    issuing = d + timedelta(days=grace) if grace > 0 else d - timedelta(days=1)
            else:
                issuing = d if adj == "keep_anchor" else d + timedelta(days=grace)
    else:
        issuing = d
        exp_fin = d
    due = issuing + timedelta(days=net)
    return {"issuing_date": issuing.isoformat(), "expected_finalization_date": exp_fin.isoformat(),
            "payment_due_date": due.isoformat(), "net_payment_term": net}


def op_payment_due_date(inp):
    cust = inp.get("customer", {})
    be = inp.get("billing_entity", {})
    tz = inp.get("timezone", "UTC")
    drafted = date.fromisoformat(inp["drafted_issuing_date"])
    now = parse_instant(inp["now"])
    recurring = inp.get("recurring", True)
    adj = eff(cust, be, "subscription_invoice_issuing_date_adjustment", "align_with_finalization_date")
    net = eff(cust, be, "net_payment_term", 0)
    if recurring and adj == "keep_anchor":
        issuing = drafted
    else:
        issuing = local_date(now, tz)
    return {"issuing_date": issuing.isoformat(),
            "payment_due_date": (issuing + timedelta(days=net)).isoformat()}


# ----------------------------------------------------------------------------- invoice amounts bounds
def available_to_credit(inv, fees, notes):
    """BE-IV-46..50. inv/fees/notes are raw dicts as in the op input. Returns dict."""
    version = inv.get("version_number", 4)
    status = inv.get("status", "finalized")
    itype = inv.get("invoice_type", "subscription")
    fees_amount = F(inv["fees_amount_cents"])
    coupons = F(inv.get("coupons_amount_cents", 0))
    prog = F(inv.get("progressive_billing_credit_amount_cents", 0))
    total = F(inv.get("total_amount_cents", 0))
    paid = F(inv.get("total_paid_amount_cents", 0))
    pstatus = inv.get("payment_status", "pending")
    fin = [n for n in notes if n.get("status", "finalized") == "finalized"]
    offsets = sum((F(n.get("offset_amount_cents", 0)) for n in fin), Fraction(0))
    refunds = sum((F(n.get("refund_amount_cents", 0)) for n in notes), Fraction(0))
    if status == "voided":
        due = Fraction(0)
    else:
        due = total - paid - offsets
    avail = creditable_value(version, status, fees_amount, coupons, prog, fees)
    creditable = Fraction(0) if itype == "credit" else avail
    if itype == "credit" and due > 0 and paid == 0:
        offsettable = total
    else:
        offsettable = min(due, creditable) if not isinstance(creditable, float) else min(float(due), creditable)
    if version < 2 or status == "draft" or (pstatus != "succeeded" and paid == total and total > 0):
        refundable = Fraction(0)
    else:
        refundable = min(paid - refunds, creditable) if not isinstance(creditable, float) else min(float(paid - refunds), creditable)
        if refundable < 0:
            refundable = Fraction(0)
    fee_total = sum((F(f["amount_cents"]) for f in fees), Fraction(0)) + rnd(
        sum((F(f["amount_cents"]) * F(f.get("taxes_rate", 0)) / 100 for f in fees), Fraction(0)))
    voidable = (status == "finalized" and pstatus in ("pending", "failed") and paid == 0
                and not any(n.get("credit_status", "available") != "voided" for n in notes))
    return {"available": avail, "creditable": creditable, "refundable": refundable,
            "offsettable": offsettable, "due": due, "fee_total": fee_total, "voidable": voidable}


def creditable_value(version, status, fees_amount, coupons, prog, fees, extra_credited=None):
    if version < 2 or status == "draft":
        return Fraction(0)
    cf = []
    for i, f in enumerate(fees):
        c = F(f["amount_cents"]) - F(f.get("credited_amount_cents", 0))
        if extra_credited:
            c -= extra_credited.get(i, 0)
        cf.append((c, F(f.get("taxes_rate", 0))))
    Fsum = sum((c for c, _ in cf), Fraction(0))
    if Fsum == 0:
        return Fraction(0)
    if version < 3 or fees_amount == 0:
        adj = Fraction(0) if not COMPAT else 0.0
    else:
        adj = N(coupons + prog) / N(fees_amount) * N(Fsum)
    tot = 0.0 if COMPAT else Fraction(0)
    for c, rate in cf:
        tot += (N(c) - adj * N(c) / N(Fsum)) * N(rate) / 100 if COMPAT else (c - adj * c / Fsum) * rate / 100
    return N(Fsum) - adj + rnd(tot)


def op_available_to_credit(inp):
    r = available_to_credit(inp["invoice"], inp["fees"], inp.get("credit_notes", []))
    out = {
        "available_to_credit_amount_cents": out_num(r["available"]),
        "creditable_amount_cents": out_num(r["creditable"]),
        "refundable_amount_cents": out_num(r["refundable"]),
        "offsettable_amount_cents": out_num(r["offsettable"]),
        "total_due_amount_cents": int(r["due"]),
        "fee_total_amount_cents": int(r["fee_total"]),
        "voidable": r["voidable"],
    }
    return out


# ----------------------------------------------------------------------------- credit notes
class Note:
    pass


class CNInvoice:
    """An invoice built by the totals pipeline, with the state credit notes need."""

    def __init__(self, inv):
        self.raw = inv
        self.version = inv.get("version_number", 4)
        self.status = inv.get("status", "finalized")
        self.currency = inv.get("currency", "EUR")
        self.itype = inv.get("invoice_type", "subscription")
        pin = {k: inv[k] for k in ("currency", "invoice_type", "version_number", "customer", "billing_entity",
                                   "fees", "applied_coupons", "credit_notes", "wallets", "progressive_billing")
               if k in inv}
        pin["context"] = "draft" if self.status == "draft" else "finalize"
        res = run_totals(pin)
        st = res["_state"]
        self.fees = st["fees"]
        self.by_id = {f.id: f for f in self.fees}
        self.inv_out = res["invoice"]
        self.total = F(self.inv_out["total_amount_cents"])
        self.paid = F(inv.get("total_paid_amount_cents", 0))
        self.payment_status = inv.get("payment_status", self.inv_out["payment_status"])
        self.fees_amount = F(self.inv_out["fees_amount_cents"])
        self.coupons_amount = F(self.inv_out["coupons_amount_cents"])
        self.prog_amount = F(self.inv_out["progressive_billing_credit_amount_cents"])
        self.notes = []  # created notes (Note)
        self.credited = {f.id: Fraction(0) for f in self.fees}  # sum of item cents per fee
        # taxes_base_rate: invoice row taxable / fees amount (1 for local taxes)

    def fee_creditable(self, f):
        return f.amount - self.credited[f.id]

    def creditable_amount(self, extra=None):
        """available-to-credit for the current state (BE-IV-47)."""
        fees = []
        for f in self.fees:
            fees.append({"amount_cents": int(f.amount), "taxes_rate": f.taxes_rate,
                         "credited_amount_cents": self.credited[f.id] + (extra or {}).get(f.id, 0)})
        return creditable_value(self.version, self.status, self.fees_amount, self.coupons_amount,
                                self.prog_amount, fees)

    def due(self):
        offs = sum((n.offset for n in self.notes if n.status == "finalized"), Fraction(0))
        return Fraction(0) if self.status == "voided" else self.total - self.paid - offs

    def refundable(self):
        creditable = self.creditable_amount()
        if self.itype == "credit":
            creditable = Fraction(0)
        if self.version < 2 or self.status == "draft" or (
                self.payment_status != "succeeded" and self.paid == self.total and self.total > 0):
            return Fraction(0)
        refunds = sum((n.refund for n in self.notes), Fraction(0))
        v = min(N(self.paid - refunds), N(creditable)) if COMPAT else min(self.paid - refunds, creditable)
        return max(v, 0)

    def fee_total(self):
        s = sum((f.amount for f in self.fees), Fraction(0))
        t = sum((f.amount * f.taxes_rate / 100 for f in self.fees), Fraction(0))
        return s + rnd(t)


def build_items(inv, items, whole_cents=False):
    out = []
    for it in items:
        f = inv.by_id.get(it["fee_id"])
        if f is None:
            raise DomainError("fee_not_found", "base")
        amt = F(it["amount_cents"])
        if whole_cents:
            amt = Fraction(trunc(amt))
        out.append({"fee": f, "precise": amt, "cents": rnd(amt)})
    return out


def validate_items(inv, items):
    """Returns the first item error as (field, code) or None."""
    for it in items:
        f = it["fee"]
        if it["cents"] < 0:
            return ("amount_cents", "invalid_value")
        if it["cents"] > inv.fee_creditable(f):
            return ("amount_cents", "higher_than_remaining_fee_amount")
    return None


def note_amounts(inv, items, residue_check):
    """BE-CN-6..10: adjustment, taxes rows, taxes. Returns dict."""
    adj = N(0)
    sum_precise = Fraction(0)
    per_code = {}
    code_rate = {}
    for it in items:
        f = it["fee"]
        sum_precise += it["precise"]
        if f.amount != 0:
            item_rate = N(it["precise"]) / N(f.amount)
        else:
            item_rate = N(0)
        if COMPAT:
            # BE-CN-6: the binary64 rate enters the product at 16 digits, the product is exact
            share = F(f.pc) * sig16(F(item_rate))
        else:
            share = N(f.pc) * item_rate
        if inv.version >= 3:
            adj += share
        for code, rate in f.taxes:
            code_rate[code] = rate
            b = (F(it["precise"]) - F(share)) if COMPAT else N(it["precise"]) - share  # BE-CN-7: exact base
            per_code[code] = per_code.get(code, F(0) if COMPAT else N(0)) + b
    adj_stored = q5(F(adj) if COMPAT else adj)
    adj_cents = rnd(adj)
    rows = []
    ptax = N(0)
    for code in sorted(per_code):
        base = per_code[code]
        t = (float(F(base) * sig16(F(code_rate[code]))) / 100.0) if COMPAT else base * N(code_rate[code]) / 100  # BE-CN-7: exact product, binary64 /100
        rows.append({"code": code, "amount_cents": rnd(t), "base_amount_cents": rnd(base)})
        ptax += t
    ptax_stored = col5(ptax) if COMPAT else q5(ptax)  # round5 (BE-IV-14) of the binary64 sum
    # taxes rate
    denom = N(sum_precise) - adj
    if per_code and denom != 0:
        tr = N(0)
        for code in per_code:
            tr += N(code_rate[code]) * per_code[code]
        tr = tr / denom
        taxes_rate = ruby_round_float(float(tr), 5) if COMPAT else round_places(tr, 5)
    else:
        taxes_rate = Fraction(0)
    return {"adj": adj_stored, "adj_cents": adj_cents, "rows": rows, "ptax": ptax_stored,
            "sum_precise": sum_precise, "taxes_rate": taxes_rate, "adj_raw": adj}


def compute_note(inv, req, premium=True, validate_only=False, automatic=False, estimate=False,
                 skip_validation=False):
    items_req = req["items"]
    credit = F(req.get("credit_amount_cents", 0))
    refund = F(req.get("refund_amount_cents", 0))
    offset = F(req.get("offset_amount_cents", 0))
    errors = {}

    def err(field, code):
        errors.setdefault(field, [])
        if code not in errors[field]:
            errors[field].append(code)

    if not premium and not automatic and not estimate:
        errors["base"] = ["feature_unavailable"]
        return None, errors
    if inv.version < 2:
        errors["base"] = ["invalid_type_or_status"]
        return None, errors
    try:
        items = build_items(inv, items_req, whole_cents=estimate)
    except DomainError as e:
        errors["base"] = [e.code]
        return None, errors
    ie = validate_items(inv, items)
    if ie:
        errors[ie[0]] = [ie[1]]
        return None, errors

    am = note_amounts(inv, items, None)
    ptax = am["ptax"]
    sum_precise = am["sum_precise"]

    # residue (BE-CN-9)
    if estimate:
        remaining_sum = sum((inv.fee_creditable(f) for f in inv.fees), Fraction(0))
        apply_residue = sum_precise == remaining_sum and len(inv.notes) > 0
        apply_residue = sum_precise == remaining_sum
    else:
        extra = {}
        for it in items:
            extra[it["fee"].id] = extra.get(it["fee"].id, 0) + it["cents"]
        cr = inv.creditable_amount(extra)
        apply_residue = cr == 0
    if apply_residue and inv.notes:
        ptax = ptax - sum((n.taxes - n.ptax for n in inv.notes), Fraction(0))
    taxes = rnd(ptax)
    sub = rnd(sum_precise - am["adj"])

    total = credit + refund + offset

    if not estimate and not skip_validation:
        # validation BE-CN-12
        ftotal = inv.fee_total()
        other = [n for n in inv.notes if n.status == "finalized"]
        o_credit = sum((n.credit for n in other), Fraction(0))
        o_refund = sum((n.refund for n in other), Fraction(0))
        o_offset = sum((n.offset for n in other), Fraction(0))
        remaining_credit = ftotal - o_credit - o_offset
        fully_paid = inv.total > 0 and inv.paid >= inv.total
        if refund > 0 and inv.payment_status != "succeeded" and fully_paid:
            err("refund_amount_cents", "cannot_refund_unpaid_invoice")
        expect = rnd(sum_precise - am["adj"] + ptax)
        if abs(total - expect) > 1:
            err("base", "does_not_match_item_amounts")
        if refund > 0:
            if inv.paid == 0:
                err("refund_amount_cents", "cannot_refund_unpaid_invoice")
            elif refund > inv.paid - o_refund:
                err("refund_amount_cents", "higher_than_remaining_invoice_amount")
        if credit > 0:
            if credit > remaining_credit + 1:
                err("credit_amount_cents", "higher_than_remaining_invoice_amount")
        if offset > 0:
            if offset > min(inv.total - inv.paid - o_offset, remaining_credit):
                err("offset_amount_cents", "higher_than_remaining_invoice_amount")
        if total > ftotal - (o_credit + o_refund + o_offset) + 1:
            err("base", "higher_than_remaining_invoice_amount")
        if total <= 0:
            err("base", "total_amount_must_be_positive")
        if errors:
            return None, errors
        if validate_only:
            return None, errors

    n = Note()
    n.items = items
    n.ptax = ptax
    n.taxes = taxes
    n.sub = sub
    n.adj = am["adj"]
    n.adj_cents = am["adj_cents"]
    n.rows = am["rows"]
    n.taxes_rate = am["taxes_rate"]
    n.status = "draft" if inv.status == "draft" else "finalized"
    n.credit_status = "available"
    n.refund_status = "pending" if refund > 0 else None
    # BE-CN-11
    balance = credit
    total0 = total
    if total - taxes != sub:
        total += -1 if total - taxes > sub else 1
        if COMPAT:
            if credit > 0:
                credit = total - refund
            else:
                refund = total
        else:
            delta = total - total0
            if credit > 0:
                credit += delta
            elif offset > 0:
                offset += delta
            else:
                refund += delta
        balance = credit
    n.credit, n.refund, n.offset, n.total, n.balance = credit, refund, offset, total, balance
    n.sum_precise = sum_precise
    return n, errors


def note_out(inv, n):
    out = {
        "status": n.status,
        "credit_status": n.credit_status,
        "refund_status": n.refund_status,
        "items": [{"fee_id": it["fee"].id, "amount_cents": it["cents"],
                   "precise_amount_cents": dec_str(it["precise"], 5)} for it in n.items],
        "coupons_adjustment_amount_cents": n.adj_cents,
        "precise_coupons_adjustment_amount_cents": dec_str(n.adj, 5),
        "taxes_amount_cents": n.taxes,
        "precise_taxes_amount_cents": dec_str(n.ptax, 5),
        "taxes_rate": dec_str(n.taxes_rate, 5),
        "sub_total_excluding_taxes_amount_cents": n.sub,
        "credit_amount_cents": int(n.credit),
        "refund_amount_cents": int(n.refund),
        "offset_amount_cents": int(n.offset),
        "total_amount_cents": int(n.total),
        "balance_amount_cents": int(n.balance),
        "applied_taxes": n.rows,
    }
    return out


def register_note(inv, n):
    for it in n.items:
        inv.credited[it["fee"].id] += it["cents"]
    inv.notes.append(n)
    if n.offset > 0 and inv.due() <= 0:
        inv.payment_status = "succeeded"


def prepare_invoice(inp):
    inv = CNInvoice(inp["invoice"])
    premium = inp.get("premium", True)
    for req in inp.get("previous_credit_notes", []):
        n, errs = compute_note(inv, req, premium=True, automatic=True)
        if n is not None:
            register_note(inv, n)
    return inv, premium


def first_error(errors):
    order = ["base", "amount_cents", "refund_amount_cents", "credit_amount_cents", "offset_amount_cents"]
    for k in order:
        if k in errors:
            return k, errors[k][0]
    k = next(iter(errors))
    return k, errors[k][0]


def op_cn_compute(inp):
    inv, premium = prepare_invoice(inp)
    req = {"items": inp["items"], "credit_amount_cents": inp.get("credit_amount_cents", 0),
           "refund_amount_cents": inp.get("refund_amount_cents", 0),
           "offset_amount_cents": inp.get("offset_amount_cents", 0)}
    n, errors = compute_note(inv, req, premium=premium)
    if errors:
        f, c = first_error(errors)
        raise DomainError(c, f)
    out = note_out(inv, n)
    register_note(inv, n)
    out["invoice_after"] = {"creditable_amount_cents": out_num(inv.creditable_amount()),
                            "total_due_amount_cents": int(inv.due()),
                            "payment_status": inv.payment_status}
    return out


def op_cn_validate(inp):
    inv, premium = prepare_invoice(inp)
    req = inp["request"]
    n, errors = compute_note(inv, req, premium=premium, validate_only=True)
    if errors:
        return {"valid": False, "errors": errors}
    return {"valid": True, "errors": {}}


def estimate_note(inv, items_req):
    n, errors = compute_note(inv, {"items": items_req}, estimate=True)
    if errors:
        f, c = first_error(errors)
        raise DomainError(c, f)
    items = n.items
    adj = n.adj
    taxes = n.taxes
    sub = n.sub
    sum_cents = sum((it["precise"] for it in items), Fraction(0))
    max_creditable = rnd(sum_cents - adj + n.ptax) if inv.itype != "credit" else 0
    refundable = inv.refundable()
    max_refundable = min(max_creditable, trunc(refundable))
    if max_creditable - taxes > sub:
        max_creditable -= 1
    elif taxes > 0 and max_creditable - taxes < sub:
        taxes -= 1
    return n, max_creditable, max_refundable, taxes


def op_cn_estimate(inp):
    inv, premium = prepare_invoice(inp)
    n, mc, mr, taxes = estimate_note(inv, inp["items"])
    return {
        "coupons_adjustment_amount_cents": n.adj_cents,
        "precise_coupons_adjustment_amount_cents": dec_str(n.adj, 5),
        "taxes_amount_cents": taxes,
        "precise_taxes_amount_cents": dec_str(n.ptax, 5),
        "taxes_rate": dec_str(n.taxes_rate, 5),
        "sub_total_excluding_taxes_amount_cents": n.sub,
        "applied_taxes": n.rows,
        "items": [{"fee_id": it["fee"].id, "amount_cents": it["cents"]} for it in n.items],
        "max_creditable_amount_cents": mc,
        "max_refundable_amount_cents": mr,
    }


# ----------------------------------------------------------------------------- void
def op_void(inp):
    invraw = inp["invoice"]
    status = invraw.get("status", "finalized")
    if status != "finalized":
        raise DomainError("not_voidable")
    inv, _ = prepare_invoice(inp)
    pres = run_totals({k: invraw[k] for k in ("currency", "invoice_type", "version_number", "customer",
                                              "billing_entity", "fees", "applied_coupons", "credit_notes",
                                              "wallets", "progressive_billing") if k in invraw})
    coupons = pres["_state"]["coupons"]
    credits = pres["_state"]["credits"]
    paid = F(invraw.get("total_paid_amount_cents", 0))
    pstatus = invraw.get("payment_status", pres["invoice"]["payment_status"])
    voidable_before = (pstatus in ("pending", "failed") and paid == 0
                       and not any(n.credit_status != "voided" for n in inv.notes))
    created = []
    if inp.get("generate_credit_note"):
        credit_req = F(inp.get("credit_amount_cents", 0))
        refund_req = F(inp.get("refund_amount_cents", 0))
        creditable = inv.creditable_amount()
        refundable = inv.refundable()
        if credit_req > N(creditable) or refund_req > N(refundable) or credit_req + refund_req > N(creditable):
            raise DomainError("total_amount_exceeds_invoice_amount", "credit_refund_amount")
        if credit_req + refund_req > 0:
            items_req = [{"fee_id": f.id, "amount_cents": inv.fee_creditable(f)} for f in inv.fees
                         if inv.fee_creditable(f) > 0]
            _, tmax, _, _ = estimate_note(inv, [dict(i) for i in items_req])
            ratio = N(credit_req + refund_req) / N(tmax)
            scaled = []
            for it in items_req:
                if COMPAT:
                    v = col5(float(N(it["amount_cents"]) * ratio))  # BE-IV-42 round5
                else:
                    v = q5(it["amount_cents"] * ratio)
                scaled.append({"fee_id": it["fee_id"], "amount_cents": v})
            n, errors = compute_note(inv, {"items": scaled, "credit_amount_cents": credit_req,
                                           "refund_amount_cents": refund_req}, automatic=True)
            if n is not None:
                created.append(note_out(inv, n))
                register_note(inv, n)
        if rnd(inv.creditable_amount()) > 0:
            items_req = [{"fee_id": f.id, "amount_cents": inv.fee_creditable(f)} for f in inv.fees
                         if inv.fee_creditable(f) > 0]
            if items_req:
                _, tmax, _, _ = estimate_note(inv, items_req)
                n, errors = compute_note(inv, {"items": items_req, "credit_amount_cents": tmax}, automatic=True)
                if n is not None:
                    n.credit_status = "voided"
                    n.balance = Fraction(0)
                    o = note_out(inv, n)
                    o["credit_status"] = "voided"
                    o["balance_amount_cents"] = 0
                    created.append(o)
                    register_note(inv, n)
    # coupon re-credit (BE-IV-29)
    credited_ids = {c["id"] for c in credits if c["kind"] == "coupon"}
    for c in coupons:
        if c.id in credited_ids:
            if c.status == "terminated" and c.frequency != "forever":
                c.status = "active"
        if c.frequency == "recurring" and c.id in credited_ids:
            c.remaining = (c.remaining or 0) + 1
    return {"status": "voided", "voidable_before": voidable_before, "credit_notes": created,
            "applied_coupons_after": [{"id": c.id, "status": c.status,
                                       "frequency_duration_remaining": (c.remaining if c.frequency == "recurring" else None)}
                                      for c in coupons]}


# ----------------------------------------------------------------------------- termination note
def op_cn_termination(inp):
    from termination import termination_note
    return termination_note(inp, globals())


# ----------------------------------------------------------------------------- commitment
def op_commitment(inp):
    from commitment import commitment_true_up
    return commitment_true_up(inp, globals())


def op_totals(inp):
    return strip_state(run_totals(inp))


OPS = {
    "invoice.totals": op_totals,
    "invoice.apply_taxes": op_apply_taxes,
    "invoice.available_to_credit": op_available_to_credit,
    "invoice.commitment_true_up": op_commitment,
    "invoice.coupon_amount": op_coupon_amount,
    "invoice.coupon_apply": op_coupon_apply,
    "invoice.coupon_create": op_coupon_create,
    "invoice.coupon_distribution": op_coupon_distribution,
    "invoice.coupon_order": op_coupon_order,
    "invoice.fee_tax_selection": op_fee_tax_selection,
    "invoice.final_status": op_final_status,
    "invoice.issuing_date": op_issuing_date,
    "invoice.payment_due_date": op_payment_due_date,
    "invoice.void": op_void,
    "credit_notes.compute": op_cn_compute,
    "credit_notes.estimate": op_cn_estimate,
    "credit_notes.termination": op_cn_termination,
    "credit_notes.validate": op_cn_validate,
}


def handle(msg):
    global COMPAT
    COMPAT = msg.get("profile", "compat") != "corrected"
    key = msg["area"] + "." + msg["op"]
    fn = OPS.get(key)
    if fn is None:
        return {"type": "result", "id": msg["id"], "error": {"code": "unsupported_op"}}
    try:
        inp = json.loads(json.dumps(msg["input"]), parse_float=Fraction, parse_int=int) if False else msg["input"]
        out = fn(inp)
        return {"type": "result", "id": msg["id"], "output": out}
    except DomainError as e:
        err = {"code": e.code}
        if e.field:
            err["field"] = e.field
        return {"type": "result", "id": msg["id"], "error": err}
    except Exception as e:  # noqa
        import traceback
        traceback.print_exc(file=sys.stderr)
        return {"type": "result", "id": msg["id"], "error": {"code": "internal", "message": repr(e)}}


class FractionEncoder(json.JSONEncoder):
    def default(self, o):
        if isinstance(o, Fraction):
            return dec_str(o)
        if isinstance(o, Decimal):
            return format(o, "f")
        return super().default(o)


def main():
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        # exact numbers: JSON floats -> Fraction, so 1e3 / 2.0 keep their value
        msg = json.loads(line, parse_float=lambda s: Fraction(s), parse_int=int)
        t = msg.get("type")
        if t == "hello":
            resp = {"type": "hello", "proto": 1, "impl": "crc-6b-invoice-creditnotes", "impl_version": "0.1.0",
                    "profiles": ["compat", "corrected"],
                    "ops": ["invoice.*", "credit_notes.*"]}
        elif t == "call":
            resp = handle(msg)
        elif t == "bye":
            break
        else:
            continue
        out.write(json.dumps(resp, cls=FractionEncoder, separators=(",", ":")) + "\n")
        out.flush()


if __name__ == "__main__":
    main()
