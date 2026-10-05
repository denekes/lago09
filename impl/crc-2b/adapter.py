#!/usr/bin/env python3.12
"""Pricing engine adapter (area `pricing`) for the Lago re-implementation kit. Standard library only."""
from __future__ import annotations

import json
import math
import re
import sys
import traceback
from datetime import datetime, timedelta, timezone
from decimal import ROUND_DOWN, ROUND_HALF_UP, Context, Decimal, InvalidOperation, getcontext
from zoneinfo import ZoneInfo

getcontext().prec = 120
D0 = Decimal(0)
D1 = Decimal(1)
D100 = Decimal(100)


class JF(Decimal):
    """A JSON float literal (kept distinct so binary64 islands can be reproduced)."""


class KitError(Exception):
    def __init__(self, code, field=None, message=None):
        super().__init__(message or code)
        self.code, self.field, self.message = code, field, message


class Unsupported(Exception):
    pass


class BadInput(Exception):
    pass


# ---------------------------------------------------------------- numbers
EXPONENTS = {"BHD": 3, "JOD": 3, "KWD": 3, "CLF": 4, "MRO": 1}
for _c in "BIF CLP DJF GNF HUF ISK JPY KMF KRW MGA PYG RWF UGX VND VUV XAF XOF XPF".split():
    EXPONENTS[_c] = 0


def exponent(cur):
    return EXPONENTS.get(cur or "EUR", 2)


def subunit(cur):
    return Decimal(10) ** exponent(cur)


def dec(x):
    if isinstance(x, bool) or x is None:
        raise BadInput(f"not a decimal: {x!r}")
    if isinstance(x, Decimal):
        return Decimal(x) if isinstance(x, JF) else x
    if isinstance(x, int):
        return Decimal(x)
    if isinstance(x, float):
        return f2d(x)
    if isinstance(x, str):
        try:
            return Decimal(x)
        except InvalidOperation:
            raise BadInput(f"not a decimal: {x!r}")
    raise BadInput(f"not a decimal: {x!r}")


def ndig(d):
    return len(d.as_tuple().digits)


def div(a, b):
    """Decimal division keeping >= 32 significant digits (more for long operands)."""
    a, b = dec(a), dec(b)
    prec = max(32, 2 * max(ndig(a), ndig(b)))
    return Context(prec=prec, rounding=ROUND_HALF_UP).divide(a, b)


_C16 = Context(prec=16, rounding=ROUND_DOWN)


def f2d(x: float) -> Decimal:
    """binary64 -> decimal: shortest round-trip text truncated to 16 significant digits (BE-PR-85)."""
    return _C16.plus(Decimal(repr(float(x))))


def d2f(d) -> float:
    return float(dec(d))


def rnd(d, places=0):
    return dec(d).quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)


def trunc(d):
    return int(dec(d).to_integral_value(rounding=ROUND_DOWN))


def q15(d):
    return rnd(d, 15)


def out_dec(d):
    d = dec(d)
    s = format(d, "f")
    if s.startswith("-") and Decimal(s) == 0:
        s = s[1:]
    return s


def fmt(d):
    """Stored detail form: decimal string with at least one fraction digit."""
    s = out_dec(d)
    if "." not in s:
        s += ".0"
    return s


def num(x):
    """Numeric property value (int / JF / Decimal) -> Decimal."""
    return dec(x)


def is_float(x):
    return isinstance(x, (JF, float))


def arith(op, a, b):
    """a op b following the reference's mixed-type rules: Float with Integer/Float -> binary64 (then converted);
    Float with BigDecimal -> the float is converted first."""
    fa = is_float(a)
    fb = is_float(b)
    ia = isinstance(a, int) and not isinstance(a, bool)
    ib = isinstance(b, int) and not isinstance(b, bool)
    if (fa and (fb or ib)) or (fb and ia):
        x, y = float(a), float(b)
        r = x + y if op == "+" else x - y
        return f2d(r)
    return dec(a) + dec(b) if op == "+" else dec(a) - dec(b)


# ---------------------------------------------------------------- permissive decimal reader (BE-PR-73)
_RUN = r"\d+(?:_\d+)*_?"
_DEC_RE = re.compile(rf"^[+-]?(?:{_RUN}(?:\.(?:{_RUN})?)?|\.{_RUN})(?:[eEdD][+-]?\d+)?$")


def read_decimal(s):
    """Return Decimal or None (invalid / not finite)."""
    if not isinstance(s, str):
        return None
    t = s.strip()
    if not _DEC_RE.match(t):
        return None
    t = t.replace("_", "").replace("d", "e").replace("D", "e")
    if t.endswith("."):
        t += "0"
    t = t.replace(".e", ".0e").replace(".E", ".0E")
    try:
        d = Decimal(t)
    except InvalidOperation:
        return None
    return d if d.is_finite() else None


def valid_amount(v):
    d = read_decimal(v)
    return d is not None and d >= 0


def pd(v, default=D0):
    """Property decimal (string or number) -> Decimal; default when absent/blank/unreadable."""
    if v is None:
        return default
    if isinstance(v, str):
        d = read_decimal(v)
        return default if d is None else d
    if isinstance(v, bool):
        return default
    return dec(v)


def blank(v):
    return v is None or (isinstance(v, str) and v.strip() == "") or (isinstance(v, (list, dict)) and not v)


# ---------------------------------------------------------------- charge models
def agg_get(agg, key, default=None):
    v = agg.get(key)
    return default if v is None else v


def dnum(x):
    return None if x is None else dec(x)


def unit_amount_of(amount, units, fu):
    d = fu if fu is not None else units
    return D0 if d == 0 else div(amount, d)


def ranges_of(props, key):
    r = props.get(key)
    return r if isinstance(r, list) else []


def adjacent(ranges):
    if len(ranges) < 2:
        return False
    prev_to = None
    for i, r in enumerate(ranges):
        if i > 0:
            pt = D0 if prev_to is None else num(prev_to)
            if num(r.get("from_value", 0)) != pt:
                return False
        prev_to = r.get("to_value")
    return True


def jv(x):
    """JSON-ish value for echo in details (None, int, or decimal-string)."""
    if x is None:
        return None
    if isinstance(x, bool):
        return x
    if isinstance(x, int):
        return x
    return x  # JF / Decimal encoded by the output encoder


def stops(r, units):
    to = r.get("to_value")
    return to is None or num(to) >= units


def model_standard(props, agg, ctx):
    units = dec(agg["units"])
    amount = units * pd(props.get("amount"))
    return amount, {}


def model_package(props, agg, ctx):
    units = dec(agg["units"])
    price = pd(props.get("amount"))
    size_raw = props.get("package_size", 1)
    size = num(size_raw)
    free = pd(props.get("free_units"))
    if units == 0:
        return D0, {"free_units": "0.0", "paid_units": "0.0", "per_package_size": 0, "per_package_unit_amount": "0.0"}, None
    paid = units - free
    if paid < 0:
        return D0, {"free_units": jv(props.get("free_units")), "paid_units": "0.0", "per_package_size": int(size),
                    "per_package_unit_amount": out_dec(price)}, D0
    if ctx.get("profile") == "corrected":
        packages = int((paid / size).to_integral_value(rounding="ROUND_CEILING"))
    else:
        packages = math.ceil(d2f(paid) / float(size))
    amount = Decimal(packages) * price
    ua = div(amount, paid) if paid > 0 else D0
    details = {"free_units": fmt(free), "paid_units": fmt(paid), "per_package_size": int(size),
               "per_package_unit_amount": fmt(price)}
    return amount, details, ua


def model_graduated(props, agg, ctx):
    units = dec(agg["units"])
    ranges = ranges_of(props, "graduated_ranges")
    adj = adjacent(ranges)
    zero_flat = ctx.get("exclude_event") and units == 0
    total = D0
    details = []
    for r in ranges:
        frm = num(r.get("from_value", 0))
        to = r.get("to_value")
        eff = num(to) if (to is not None and units >= num(to)) else units
        u = eff if frm == 0 else eff - frm + (0 if adj else 1)
        price = pd(r.get("per_unit_amount"))
        flat = pd(r.get("flat_amount"))
        pu = D0 if u == 0 else price
        ptot = u * price
        tot = ptot + flat
        details.append({"from_value": jv(r.get("from_value")), "to_value": jv(to), "flat_unit_amount": fmt(flat),
                        "per_unit_amount": fmt(pu), "units": fmt(u), "per_unit_total_amount": fmt(ptot),
                        "total_with_flat_amount": fmt(tot)})
        total += tot
        if stops(r, units):
            break
    if zero_flat:
        total = D0
    return total, {"graduated_ranges": details}


def model_gp(props, agg, ctx):
    units = dec(agg["units"])
    ranges = ranges_of(props, "graduated_percentage_ranges")
    zero_flat = ctx.get("exclude_event") and units == 0
    adj = adjacent(ranges)
    total = D0
    details = []
    for r in ranges:
        frm_raw = r.get("from_value", 0)
        frm = num(frm_raw)
        to = r.get("to_value")
        if ctx.get("profile") == "corrected":
            eff = num(to) if (to is not None and units >= num(to)) else units
            u = eff if frm == 0 else eff - frm + (0 if adj else 1)
        elif to is not None and units >= num(to):
            x = 1 if frm == 0 else frm_raw
            if is_float(to) and (is_float(x) or isinstance(x, int)):
                u = f2d((float(to) - float(x)) + 1.0)
            else:
                u = (dec(to) - dec(x)) + 1
        elif frm == 0:
            u = units
        else:
            u = arith("+", units - num(frm_raw), 1) if not is_float(frm_raw) else units - num(frm_raw) + 1
        rate = pd(r.get("rate"))
        flat = D0 if zero_flat else pd(r.get("flat_amount"))
        ptot = u * rate / 100
        tot = ptot + flat
        details.append({"from_value": jv(frm_raw), "to_value": jv(to), "flat_unit_amount": 0 if zero_flat else fmt(flat),
                        "rate": fmt(rate), "units": fmt(u), "per_unit_total_amount": fmt(ptot),
                        "total_with_flat_amount": 0 if zero_flat else fmt(tot)})
        total += tot if not zero_flat else ptot
        if stops(r, units):
            break
    return total, {"graduated_percentage_ranges": details}


def volume_match(ranges, n):
    rs = sorted(ranges, key=lambda r: num(r.get("from_value", 0)))
    c = n.to_integral_value(rounding="ROUND_CEILING")
    for r in rs:
        to = r.get("to_value")
        if num(r.get("from_value", 0)) <= c and (to is None or n <= num(to)):
            return r
    return None


def model_volume(props, agg, ctx):
    units = dec(agg["units"])
    fu = dnum(agg.get("full_units_number"))
    n = fu if (ctx.get("prorated") and fu is not None) else units
    r = volume_match(ranges_of(props, "volume_ranges"), n)
    if r is None:
        if ctx.get("profile") == "corrected" and n < 0:
            return D0, {"flat_unit_amount": "0.0", "per_unit_amount": "0.0", "per_unit_total_amount": "0.0"}, D0
        raise KitError("charge_model_error", message="no volume range matches")
    price = pd(r.get("per_unit_amount"))
    flat = pd(r.get("flat_amount"))
    ptot = units * price
    amount = ptot + flat
    ua = D0 if n == 0 else div(amount, n)
    pua = D0 if n == 0 else div(f2d(d2f(ptot)), n)
    details = {"flat_unit_amount": fmt(flat), "per_unit_amount": fmt(pua), "per_unit_total_amount": fmt(ptot)}
    return amount, details, ua


def pct_free(props, agg):
    rt = [dec(x) for x in (agg.get("running_total") or [])]
    fe = int(num(props.get("free_units_per_events") or 0))
    fa = pd(props.get("free_units_per_total_aggregation"))
    last = rt[-1] if rt else D0
    if last == 0:
        free = D0
    elif fe > 0 and fe < len(rt):
        free = rt[fe - 1]
    elif fa == 0:
        free = last
    elif last <= fa:
        free = last
    else:
        free = fa
    below = sum(1 for x in rt if x < fa)
    cands = [x for x in (fe, below) if x != 0]
    fc = min(cands) if cands else 0
    return free, fc, fe, fa


def model_percentage(props, agg, ctx):
    units = dec(agg["units"])
    count = int(agg.get("count") or 0)
    rate = pd(props.get("rate"))
    fixed = pd(props.get("fixed_amount"))
    free, fc, fe, fa = pct_free(props, agg)
    p = 0 if free > units else (units - free) * rate / 100
    f = D0 if (units == 0 or fc >= count) else Decimal(count - fc) * fixed
    amount = p + f
    adjustment = D0
    mn, mx = props.get("per_transaction_min_amount"), props.get("per_transaction_max_amount")
    if ctx.get("premium") and (not blank(mn) or not blank(mx)):
        vals = agg.get("per_event_values")
        if vals is not None:
            vals = [dec(v) for v in vals]
            rfe, rfa = fe, fa
            total = D0
            mnd = pd(mn) if not blank(mn) else None
            mxd = pd(mx) if not blank(mx) else None
            for idx, v in enumerate(vals):
                paid = True
                if ctx.get("profile") == "corrected" and fe > 0:
                    if idx < fe:
                        continue
                elif rfe > 0 or rfa > 0:
                    rfe -= 1
                    if rfa <= 0:
                        paid = False
                    elif rfa > v:
                        rfa -= v
                        paid = False
                    else:
                        v = v - rfa
                        rfa = D0
                        rfe = 0
                if not paid:
                    continue
                e = v * rate / 100 + fixed
                if mnd is not None and e < mnd:
                    e = mnd
                elif mxd is not None and e > mxd:
                    e = mxd
                total += e
            amount = total
            adjustment = amount - p - f
    free_events = min(count, fc)
    paid_events = count - free_events
    details = {"units": fmt(units), "free_units": fmt(free), "free_events": free_events, "paid_events": paid_events,
               "paid_units": fmt(max(units - free, D0)), "rate": fmt(rate), "per_unit_total_amount": 0 if p == 0 and isinstance(p, int) else fmt(p),
               "fixed_fee_unit_amount": fmt(fixed if paid_events > 0 else D0), "fixed_fee_total_amount": fmt(f),
               "min_max_adjustment_total_amount": fmt(adjustment)}
    return amount, details


def model_dynamic(props, agg, ctx):
    units = dec(agg["units"])
    fu = dnum(agg.get("full_units_number"))
    d = fu if fu is not None else units
    if d == 0:
        return D0, {}
    total = dnum(agg.get("precise_total_amount_cents")) or D0
    return total / subunit(ctx.get("currency")), {}


def model_custom(props, agg, ctx):
    return dnum(agg.get("custom_amount")) or D0, {}


def flat_for_peak(ranges, peak):
    tot = D0
    for r in ranges:
        tot += pd(r.get("flat_amount"))
        if stops(r, peak):
            break
    return tot


def model_prorated_graduated(props, agg, ctx):
    units = dec(agg["units"])
    ranges = ranges_of(props, "graduated_ranges")
    full = [dec(x) for x in (agg.get("per_event_full") or [])]
    pro = [dec(x) for x in (agg.get("per_event_prorated") or agg.get("per_event_full") or [])]
    n = len(full)
    sumfull = sum(full, D0)
    if units == 0:
        amount = flat_for_peak(ranges, D0)
        return amount, {}, (D0 if sumfull == 0 else div(amount, sumfull))
    if n == 0:
        if ctx.get("profile") == "corrected":
            return D0, {}, D0
        raise KitError("charge_model_error", message="prorated graduated without per-event data")
    rs = [{"from": num(r.get("from_value", 0)), "to": None if r.get("to_value") is None else num(r.get("to_value")),
           "price": pd(r.get("per_unit_amount"))} for r in ranges]

    def coef(k):
        if full[k] == 0:
            return D0
        return div(f2d(d2f(pro[k])), full[k])

    def select(fs, ov, nxt):
        if fs <= 0:
            return 0
        u = fs if ov == 0 else (fs - ov + 1 if ov > 0 else fs + ov)
        for idx, r in enumerate(rs):
            if r["to"] is not None and u == r["to"]:
                if nxt is not None and nxt > 0 and idx + 1 < len(rs):
                    return idx + 1
                return idx
            if u >= r["from"] and (r["to"] is None or u < r["to"]):
                return idx
        return 0

    i = 0
    overflow = D0
    fs = D0
    peak = D0
    ps = D0
    acc = D0
    ri = 0
    guard = 0
    while i < n or overflow != 0:
        guard += 1
        if guard > 10000:
            break
        ri = select(fs, overflow, full[i] if i < n else None)
        r = rs[ri]
        if overflow != 0:
            ps += overflow * coef(i - 1)
            if r["to"] is not None and fs >= r["to"]:
                overflow = fs - r["to"]
                ps -= overflow * coef(i - 1)
                acc += ps * r["price"]
                ps = D0
                continue
            overflow = D0
        if i >= n:
            break
        if pro[i] == 0 and full[i] > 0:
            i += 1
            continue
        if pro[i] == 0 and full[i] < 0 and fs + full[i] < 0:
            i += 1
            continue
        fs += full[i]
        peak = max(peak, fs)
        ps += pro[i]
        i += 1
        if (r["to"] is None and fs >= r["from"] - 1) or (r["to"] is not None and r["from"] <= fs < r["to"]):
            continue
        if r["to"] is None:
            overflow = fs - r["from"] + 1
        else:
            overflow = fs - r["to"] if fs >= r["to"] else fs - r["from"] + 1
        ps -= overflow * coef(i - 1)
        acc += ps * r["price"]
        ps = D0
    acc += ps * rs[ri]["price"]
    if fs < 0:
        amount = D0
    else:
        amount = max(acc, D0) + flat_for_peak(ranges, peak)
    return amount, {}, (D0 if sumfull == 0 else div(amount, sumfull))


MODELS = {"standard": model_standard, "package": model_package, "graduated": model_graduated,
          "graduated_percentage": model_gp, "volume": model_volume, "percentage": model_percentage,
          "dynamic": model_dynamic, "custom": model_custom}


def price_bucket(model, props, agg, ctx):
    """Price one aggregation (no grouping). Returns dict amount/unit_amount/units/amount_details/..."""
    if model not in MODELS:
        raise KitError("charge_model_error", message=f"unknown model {model}")
    units = dec(agg["units"])
    fu = dnum(agg.get("full_units_number"))
    use_pg = (model == "graduated" and ctx.get("prorated") and agg.get("per_event_full") is not None
              and not ctx.get("in_advance"))
    ua = None
    if use_pg:
        res = model_prorated_graduated(props, agg, ctx)
    else:
        res = MODELS[model](props, agg, ctx)
    if len(res) == 3:
        amount, details, ua = res
    else:
        amount, details = res
    if ua is None:
        ua = unit_amount_of(amount, units, fu)
    out = {"amount": amount, "unit_amount": ua, "units": units, "amount_details": details,
           "full_units_number": fu, "current_usage_units": dnum(agg.get("current_usage_units")),
           "count": int(agg.get("count") or 0), "total_aggregated_units": dnum(agg.get("total_aggregated_units"))}
    return out


def project(model, props, agg, ctx, bucket, ratio):
    units = bucket["units"]
    pu = D0 if (units == 0 or ratio <= 0) else rnd(div(units, ratio), 2)
    amount = bucket["amount"]
    if model == "standard":
        pa = pu * pd(props.get("amount"))
    elif model == "package":
        free = pd(props.get("free_units"))
        size = num(props.get("package_size", 1))
        paid = pu - free
        pa = D0 if paid <= 0 else (paid / size).to_integral_value(rounding="ROUND_CEILING") * pd(props.get("amount"))
    elif model == "graduated" and not (ctx.get("prorated") and ctx.get("has_pg")):
        pa = D0
        if pu != 0:
            remaining, priced = pu, D0
            for r in ranges_of(props, "graduated_ranges"):
                to = r.get("to_value")
                cap = None if to is None else num(to) - priced
                take = remaining if cap is None else min(remaining, cap)
                if take > 0:
                    pa += take * pd(r.get("per_unit_amount")) + pd(r.get("flat_amount"))
                    priced += take
                    remaining -= take
                if remaining <= 0:
                    break
    elif model == "volume":
        r = volume_match(ranges_of(props, "volume_ranges"), pu)
        pa = D0 if r is None else pu * pd(r.get("per_unit_amount")) + pd(r.get("flat_amount"))
    else:
        pa = D0 if (amount == 0 or ratio == 0) else div(amount, ratio)
    return pu, pa


def charge_model(inp, ctx):
    model = inp["model"]
    props = inp.get("properties") or {}
    agg = inp["aggregation"]
    c = {"profile": ctx["profile"], "currency": inp.get("currency") or "EUR", "prorated": bool(inp.get("prorated")),
         "premium": bool(inp.get("premium")), **(inp.get("flags") or {})}
    gk = props.get("pricing_group_keys")
    if gk is None:
        gk = props.get("grouped_by")
    groups = agg.get("groups")
    ratio = dec(inp["period_ratio"]) if inp.get("period_ratio") is not None else D1
    proj = bool(inp.get("calculate_projected_usage"))
    out = {}
    if groups is not None and not blank(gk):
        glist = []
        tot_a = tot_u = tot_pu = tot_pa = D0
        for g in groups:
            ga = {k: v for k, v in g.items() if k != "grouped_by"}
            b = price_bucket(model, props, ga, {**c, "has_pg": ga.get("per_event_full") is not None})
            entry = {"grouped_by": g.get("grouped_by"), "units": b["units"], "amount": b["amount"],
                     "unit_amount": b["unit_amount"], "amount_details": b["amount_details"]}
            if proj:
                pu, pa = project(model, props, ga, {**c, "has_pg": ga.get("per_event_full") is not None}, b, ratio)
                entry["projected_units"], entry["projected_amount"] = pu, pa
                tot_pu += pu
                tot_pa += pa
            glist.append(entry)
            tot_a += b["amount"]
            tot_u += b["units"]
        out = {"amount": tot_a, "units": tot_u, "unit_amount": unit_amount_of(tot_a, tot_u, None),
               "amount_details": {}, "groups": glist}
        if proj:
            out["projected_units"], out["projected_amount"] = tot_pu, tot_pa
        return out
    b = price_bucket(model, props, agg, {**c, "has_pg": agg.get("per_event_full") is not None})
    out = {"amount": b["amount"], "unit_amount": b["unit_amount"], "units": b["units"],
           "amount_details": b["amount_details"], "full_units_number": b["full_units_number"],
           "current_usage_units": b["current_usage_units"], "count": b["count"],
           "total_aggregated_units": b["total_aggregated_units"]}
    if proj:
        out["projected_units"], out["projected_amount"] = project(
            model, props, agg, {**c, "has_pg": agg.get("per_event_full") is not None}, b, ratio)
    return out


# ---------------------------------------------------------------- fee money
def pu_convert(amount, unit_amount, rate, cur, corrected=False):
    """BE-PR-63. Returns (pricing_unit_usage, fiat) with fiat values before the integer cast."""
    e, s = exponent(cur), subunit(cur)
    rate = q15(rate)
    pu_cents = rnd(amount, 2) * 100
    pu_precise = amount * 100
    pu_ucents = Decimal(trunc(unit_amount * 100))
    if corrected:
        adj = amount * rate
        adj_u = unit_amount * rate
    else:
        adj = pu_cents * rate / 100
        adj_u = pu_ucents * rate / 100
    pu = {"amount_cents": int(pu_cents), "precise_amount_cents": q15(pu_precise), "unit_amount_cents": int(pu_ucents),
          "precise_unit_amount": q15(unit_amount)}
    fiat = {"amount_cents": rnd(adj, e) * s, "precise_amount_cents": adj * s, "unit_amount_cents": adj_u * s,
            "precise_unit_amount": adj_u}
    return pu, fiat


def money_fields(amount, unit_amount, cur):
    e, s = exponent(cur), subunit(cur)
    return {"amount_cents": int(rnd(amount, e) * s), "precise_amount_cents": q15(amount * s),
            "unit_amount_cents": trunc(unit_amount * s), "precise_unit_amount": q15(unit_amount)}


def fee_money(inp, ctx):
    cur = inp.get("currency") or "EUR"
    amount, ua, units = dec(inp["amount"]), dec(inp["unit_amount"]), dec(inp["units"])
    fu = dnum(inp.get("full_units_number"))
    cu = dnum(inp.get("current_usage_units"))
    tau = dnum(inp.get("total_aggregated_units"))
    events = int(inp.get("events_count") or 0)
    context = inp.get("context") or "invoice"
    pia = bool(inp.get("pay_in_advance"))
    prorated = bool(inp.get("prorated"))
    rate = dnum(inp.get("pricing_unit_conversion_rate"))
    if units < 0 or amount < 0:
        amount = ua = units = D0
        if fu is not None:
            fu = D0
    if context == "current_usage" and (pia or prorated) and cu is not None:
        stored = cu
    elif prorated:
        stored = fu if fu is not None else units
    else:
        stored = units
    out = {}
    if rate is not None:
        pu, fiat = pu_convert(amount, ua, rate, cur)
        out.update({"amount_cents": int(fiat["amount_cents"]), "precise_amount_cents": q15(fiat["precise_amount_cents"]),
                    "unit_amount_cents": trunc(fiat["unit_amount_cents"]),
                    "precise_unit_amount": q15(fiat["precise_unit_amount"])})
        pu["conversion_rate"] = q15(rate)
        out["pricing_unit_usage"] = pu
    else:
        out.update(money_fields(amount, ua, cur))
    out["units"] = stored
    out["total_aggregated_units"] = tau if tau is not None else stored
    out["events_count"] = events
    out["pay_in_advance"] = pia
    out["persisted"] = bool(context == "recurring" or stored != 0 or out["amount_cents"] != 0 or events != 0)
    return out


def pricing_unit(inp, ctx):
    pu, fiat = pu_convert(dec(inp["amount"]), dec(inp["unit_amount"]), dec(inp["conversion_rate"]), inp.get("currency") or "EUR")
    return {"pricing_unit_usage": pu, "fiat": fiat}


# ---------------------------------------------------------------- time
def parse_instant(s):
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    m = re.match(r"^(.*?)(\.\d+)?([+-]\d\d:\d\d)$", s)
    frac = ""
    if m:
        s = m.group(1) + m.group(3)
        frac = m.group(2) or ""
    dt = datetime.fromisoformat(s)
    if frac:
        dt = dt.replace(microsecond=int((frac[1:] + "000000")[:6]))
    return dt


def tz_of(name):
    return ZoneInfo(name or "UTC")


def offset_of(dt, tz):
    return dt.astimezone(tz).utcoffset()


def days_between(frm, to, tzname, upgraded=False):
    tz = tz_of(tzname)
    lf, lt = frm.astimezone(tz), to.astimezone(tz)
    if lt.hour == 0 and lt.minute == 0 and lt.second == 0 and lt.microsecond == 0:
        to = to + timedelta(seconds=1)
        lt = to.astimezone(tz)
    delta = (to - frm) + (lf.utcoffset() - lt.utcoffset())
    secs = delta.total_seconds()
    days = math.ceil(secs / 86400) if secs > 0 else 0
    if secs <= 0:
        days = -math.ceil(-secs / 86400) if secs < 0 else 0
    if upgraded:
        days = max(days - 1, 0)
    return days


def local_date(dt, tzname):
    return dt.astimezone(tz_of(tzname)).date()


# ---------------------------------------------------------------- true-up
def true_up(inp, ctx):
    cur = inp.get("currency") or "EUR"
    s = subunit(cur)
    mn = dec(inp["min_amount_cents"])
    used = dec(inp["used_amount_cents"])
    used_p = dec(inp["used_precise_amount_cents"])
    dur = int(inp["charges_duration_days"])
    days = days_between(parse_instant(inp["charges_from"]), parse_instant(inp["charges_to"]),
                        inp.get("timezone"), bool(inp.get("terminated_upgraded")))
    rate = dnum(inp.get("pricing_unit_conversion_rate"))
    if ctx["profile"] == "corrected":
        pmin = mn * days / dur
        if used >= pmin:
            return {"fee": None}
        diff = rnd(pmin - used, 0)
        precise = pmin - used_p
    else:
        fmin = float(mn) / dur * days
        if float(used) >= fmin:
            return {"fee": None}
        diff = Decimal(math.floor(abs(fmin - float(used)) + 0.5))
        precise = f2d(fmin) - used_p
        unit_precise = q15((Decimal(repr(fmin)) - used_p) / s)
        pmin = None
    fee = {"units": D1, "total_aggregated_units": D1, "events_count": 0}
    if rate is not None:
        if ctx["profile"] == "corrected":
            amt = (pmin - used) / 100
            uamt = (pmin - used_p) / 100
        else:
            amt = (f2d(fmin) - used) / 100
            uamt = (f2d(fmin) - used_p) / 100
        pu, fiat = pu_convert(amt, uamt, rate, cur, ctx["profile"] == "corrected")
        pu["conversion_rate"] = rate
        fee.update({"amount_cents": int(fiat["amount_cents"]), "precise_amount_cents": fiat["precise_amount_cents"],
                    "unit_amount_cents": int(fiat["amount_cents"]), "precise_unit_amount": fiat["precise_amount_cents"] / s,
                    "pricing_unit_usage": pu})
        return {"fee": fee}
    fee.update({"amount_cents": int(diff), "precise_amount_cents": precise, "unit_amount_cents": int(diff),
                "precise_unit_amount": q15(precise / s) if ctx["profile"] == "corrected" else unit_precise})
    return {"fee": fee}


# ---------------------------------------------------------------- pay in advance
def sub_details_pct(w, wo):
    def g(d, k):
        return dec(d[k])

    units = g(w, "units") - g(wo, "units")
    paid_units = g(w, "paid_units") - g(wo, "paid_units")
    return {"units": fmt(units), "free_units": fmt(units - paid_units), "paid_units": fmt(paid_units),
            "free_events": w["free_events"] - wo["free_events"], "paid_events": w["paid_events"] - wo["paid_events"],
            "rate": w["rate"], "fixed_fee_unit_amount": w["fixed_fee_unit_amount"],
            "fixed_fee_total_amount": fmt(g(w, "fixed_fee_total_amount") - g(wo, "fixed_fee_total_amount")),
            "min_max_adjustment_total_amount": fmt(g(w, "min_max_adjustment_total_amount") - g(wo, "min_max_adjustment_total_amount")),
            "per_unit_total_amount": fmt(g(w, "per_unit_total_amount") - g(wo, "per_unit_total_amount"))}


def sub_details_gp(w, wo, ctx):
    out = []
    for r in w["graduated_percentage_ranges"]:
        m = None
        for o in wo["graduated_percentage_ranges"]:
            if dec(o["from_value"]) == dec(r["from_value"]) and (
                    (o["to_value"] is None and r["to_value"] is None)
                    or (o["to_value"] is not None and r["to_value"] is not None and dec(o["to_value"]) == dec(r["to_value"]))):
                m = o
                break
        z = {"flat_unit_amount": "0", "units": "0", "total_with_flat_amount": "0", "per_unit_total_amount": "0"}
        m = m or z
        du = dec(r["units"]) - dec(m["units"])
        dflat = dec(r["flat_unit_amount"]) - dec(m["flat_unit_amount"])
        dtot = dec(r["total_with_flat_amount"]) - dec(m["total_with_flat_amount"])
        if ctx["profile"] == "corrected":
            put = dec(r["per_unit_total_amount"]) - dec(m["per_unit_total_amount"])
        else:
            put = rnd(div(dtot, du), 2) if du > 0 else D0
        out.append({"from_value": r["from_value"], "to_value": r["to_value"], "rate": r["rate"],
                    "flat_unit_amount": fmt(dflat), "units": fmt(du), "total_with_flat_amount": fmt(dtot),
                    "per_unit_total_amount": fmt(put)})
    return {"graduated_percentage_ranges": out}


def pay_in_advance(inp, ctx):
    model = inp["model"]
    props = inp.get("properties") or {}
    cur = inp.get("currency") or "EUR"
    e, s = exponent(cur), subunit(cur)
    if inp.get("pay_in_advance") is False:
        raise KitError("apply_charge_model_error")
    if model == "volume":
        raise KitError("charge_model_error", message="volume has no in-advance algorithm")
    agg = inp["aggregation"]
    persisted = inp.get("persisted", True)
    A, a = dec(agg["units"]), dec(agg["event_units"])
    C = int(agg.get("count") or 0)
    P = dnum(agg.get("precise_total_amount_cents"))
    p = dnum(agg.get("event_precise_total_amount_cents"))
    pev = agg.get("per_event_values")
    base = {k: v for k, v in agg.items() if k not in ("event_units", "event_precise_total_amount_cents", "cached", "event_value")}
    c = {"profile": ctx["profile"], "currency": cur, "prorated": bool(inp.get("prorated")),
         "premium": bool(inp.get("premium")), "in_advance": True}
    if persisted:
        w_agg = dict(base)
        wo_agg = dict(base)
        wo_agg["units"] = A - a
        wo_agg["count"] = max(C - 1, 0)
        if P is not None:
            wo_agg["precise_total_amount_cents"] = P - (p or D0)
        if pev is not None:
            wo_agg["per_event_values"] = list(pev)[:-1]
        wo_ctx = {**c, "exclude_event": True}
        w_ctx = c
    else:
        ev = agg.get("event_value")
        ev = a if ev is None else dec(ev)
        w_agg = dict(base)
        w_agg["units"] = A + a
        w_agg["count"] = C + 1
        if P is not None:
            w_agg["precise_total_amount_cents"] = P + (p or D0)
        if pev is not None:
            w_agg["per_event_values"] = list(pev) + [ev]
        wo_agg = dict(base)
        wo_ctx = c
        w_ctx = {**c, "include_event_value": True}
    wb = price_bucket(model, props, w_agg, w_ctx)
    wob = price_bucket(model, props, wo_agg, wo_ctx)
    delta = wb["amount"] - wob["amount"]
    amount_cents = rnd(delta, e) * s
    precise = delta * s
    cached = agg.get("cached")
    cur_u = mx = ap = None
    if cached:
        cur_u = dnum(cached.get("current_aggregation"))
        mx = dnum(cached.get("max_aggregation"))
        ap = dnum(cached.get("units_applied"))
    if cached and cur_u is not None and mx is not None and ap is not None and cur_u <= mx:
        shown = max(ap, D0)
    elif inp.get("prorated"):
        fu = dnum(agg.get("full_units_number"))
        shown = fu if fu is not None else a
    else:
        shown = a
    unit_amount = D0 if rnd(delta, e) == 0 else (div(rnd(delta, e), shown) if shown != 0 else D0)
    details = {}
    if persisted:
        if model == "percentage":
            details = sub_details_pct(wb["amount_details"], wob["amount_details"])
        elif model == "graduated_percentage":
            details = sub_details_gp(wb["amount_details"], wob["amount_details"], ctx)
    out = {"units": shown, "total_aggregated_units": shown, "events_count": 1, "pay_in_advance": True,
           "amount_details": details}
    rate = dnum(inp.get("pricing_unit_conversion_rate"))
    if rate is not None:
        if ctx["profile"] == "corrected":
            pu, fiat = pu_convert(delta, unit_amount, rate, cur, True)
        else:
            pu, fiat = pu_convert(amount_cents / 100, unit_amount, rate, cur)
        pu["conversion_rate"] = rate
        out.update({"amount_cents": int(fiat["amount_cents"]), "precise_amount_cents": fiat["precise_amount_cents"],
                    "unit_amount_cents": trunc(fiat["unit_amount_cents"]), "precise_unit_amount": fiat["precise_unit_amount"],
                    "pricing_unit_usage": pu})
    else:
        out.update({"amount_cents": int(amount_cents), "precise_amount_cents": q15(precise),
                    "unit_amount_cents": trunc(unit_amount * s), "precise_unit_amount": q15(unit_amount)})
    return out


# ---------------------------------------------------------------- fixed charges
def fixed_units(inp, ctx):
    events = [{"units": rnd(dec(x["units"]), 10), "ts": parse_instant(x["timestamp"]), "seq": int(x["created_seq"])}
              for x in inp["events"]]
    w = inp["window"]
    frm, to = parse_instant(w["from"]), parse_instant(w["to"])
    dur = int(w["duration_days"])
    tzname = inp.get("timezone")
    prorated = bool(inp.get("prorated"))
    inside = [x for x in events if frm <= x["ts"] < to]
    before = [x for x in events if x["ts"] < frm]
    sel = list(inside)
    if before:
        sel.append(max(before, key=lambda x: x["seq"]))
    sel.sort(key=lambda x: x["seq"])
    if not sel:
        return {"units": D0, "full_units_number": D0, "per_event_full": [D0], "per_event_prorated": [D0]}
    fu = sel[-1]["units"]
    if not prorated:
        return {"units": fu, "full_units_number": fu, "per_event_full": [fu], "per_event_prorated": [fu]}
    kept = []
    for i, x in enumerate(sel):
        if any(y["ts"] < x["ts"] for y in sel[i + 1:]):
            continue
        kept.append(x)
    total = D0
    for i, x in enumerate(kept):
        start = local_date(max(x["ts"], frm), tzname)
        if i + 1 < len(kept):
            end = local_date(max(kept[i + 1]["ts"], frm), tzname)
        else:
            end = local_date(to + timedelta(days=1), tzname)
        days = (end - start).days
        total += max(D0, rnd(Decimal(days) / dur * x["units"], 6))
    return {"units": total, "full_units_number": fu, "per_event_full": [fu], "per_event_prorated": [total]}


def fixed_charge_fee(inp, ctx):
    cur = inp.get("currency") or "EUR"
    model = inp["model"]
    props = inp.get("properties") or {}
    prorated = bool(inp.get("prorated"))
    fu_res = fixed_units({"events": inp["events"], "window": inp["window"], "timezone": inp.get("timezone"),
                          "prorated": prorated}, ctx)
    units, fu = fu_res["units"], fu_res["full_units_number"]
    agg = {"units": units, "full_units_number": fu}
    c = {"profile": ctx["profile"], "currency": cur, "prorated": prorated}
    if model == "graduated" and prorated:
        agg["per_event_full"] = fu_res["per_event_full"]
        agg["per_event_prorated"] = fu_res["per_event_prorated"]
    b = price_bucket(model, props, agg, c)
    amount, ua = b["amount"], b["unit_amount"]
    stored = fu
    tau = fu
    if units < 0 or amount < 0:
        amount = ua = D0
        stored = tau = D0
    m = money_fields(amount, ua, cur)
    out = dict(m)
    out.update({"units": stored, "total_aggregated_units": tau, "events_count": 0, "amount_details": b["amount_details"],
                "persisted": bool(stored != 0 or m["amount_cents"] != 0)})
    return out


def fixed_charge_in_advance(inp, ctx):
    cur = inp.get("currency") or "EUR"
    e, s = exponent(cur), subunit(cur)
    billed, new = rnd(dec(inp["already_billed_units"]), 10), rnd(dec(inp["new_units"]), 10)
    delta = new - billed
    if delta <= 0:
        return {"amount_cents": 0, "precise_amount_cents": D0, "unit_amount_cents": 0, "precise_unit_amount": D0,
                "units": D0, "total_aggregated_units": D0, "events_count": 0}
    prorated = bool(inp.get("prorated"))
    ts = parse_instant(inp["timestamp"])
    end = parse_instant(inp["fixed_charges_to"])
    dur = int(inp["fixed_charges_duration_days"])
    if prorated:
        tzname = inp.get("timezone") if ctx["profile"] == "corrected" else "UTC"
        days = (local_date(end, tzname) - local_date(ts, tzname)).days + 1
        if ctx["profile"] == "corrected":
            coef = Decimal(days) / dur
        else:
            coef = f2d(days / dur)
    else:
        coef = D1
    b = price_bucket(inp["model"], inp.get("properties") or {}, {"units": delta * coef}, {"profile": ctx["profile"], "currency": cur})
    amount = b["amount"]
    cents = rnd(amount, e) * s
    return {"amount_cents": int(cents), "precise_amount_cents": q15(amount * s),
            "unit_amount_cents": int(rnd(div(cents, delta), 0)), "precise_unit_amount": q15(div(amount, delta)), "units": delta, "total_aggregated_units": delta, "events_count": 0,
            "amount_details": {}}


# ---------------------------------------------------------------- projection, estimate, simulate
def projection(inp, ctx):
    cur = inp.get("currency") or "EUR"
    e, s = exponent(cur), subunit(cur)
    now, frm, to = parse_instant(inp["now"]), parse_instant(inp["from"]), parse_instant(inp["to"])
    dur = int(inp["charges_duration_days"])
    tzname = inp.get("timezone")
    if now >= to:
        ratio = D1
    elif now < frm:
        ratio = D0
    else:
        den = days_between(frm, to, tzname)
        ratio = D0 if den <= 0 else min(max(Decimal(repr(days_between(frm, now, tzname) / den)), D0), D1)
    if inp.get("recurring"):
        cur_v = inp.get("current") or {"amount_cents": 0, "units": "0"}
        return {"period_ratio": ratio, "projected_units": dec(cur_v.get("units", 0)),
                "projected_amount_cents": dec(cur_v.get("amount_cents", 0))}
    if ratio <= 0 or ratio > 1:
        return {"period_ratio": ratio, "projected_units": D0, "projected_amount_cents": D0}
    r = charge_model({"model": inp["model"], "properties": inp.get("properties"), "currency": cur,
                      "premium": inp.get("premium"), "prorated": inp.get("prorated"), "aggregation": inp["aggregation"],
                      "period_ratio": ratio, "calculate_projected_usage": True}, ctx)
    pa = r["projected_amount"]
    cents = D0 if pa < 0 else rnd(pa, e) * s
    return {"period_ratio": ratio, "projected_units": max(r["projected_units"], D0), "projected_amount_cents": cents}


def slice_props(model, props, kind="charge", metric_agg="sum_agg"):
    keys = {"standard": ["amount"], "graduated": ["graduated_ranges"], "volume": ["volume_ranges"],
            "graduated_percentage": ["graduated_percentage_ranges"],
            "package": ["amount", "free_units", "package_size"],
            "percentage": ["rate", "fixed_amount", "free_units_per_events", "free_units_per_total_aggregation",
                           "per_transaction_min_amount", "per_transaction_max_amount"],
            "dynamic": [], "custom": []}.get(model, [])
    if kind == "fixed_charge" and model not in ("standard", "graduated", "volume"):
        keys = []
    props = props or {}
    out = {k: props[k] for k in keys if k in props}
    pgk = props.get("pricing_group_keys")
    gb = props.get("grouped_by")
    if blank(pgk) and not blank(gb):
        pgk = gb
    if not blank(pgk):
        out["pricing_group_keys"] = [k for k in pgk if not blank(k)] if isinstance(pgk, list) else pgk
    if not blank(props.get("presentation_group_keys")):
        out["presentation_group_keys"] = props["presentation_group_keys"]
    if metric_agg == "custom_agg" and kind == "charge" and "custom_properties" in props:
        cp = props["custom_properties"]
        if isinstance(cp, str):
            try:
                cp = json.loads(cp, parse_float=JF, parse_int=int)
            except ValueError:
                cp = {}
        out["custom_properties"] = cp
    return out


def default_properties(inp, ctx):
    m = inp["model"]
    rng = {"from_value": 0, "to_value": None, "per_unit_amount": "0", "flat_amount": "0"}
    table = {"standard": {"amount": "0"}, "graduated": {"graduated_ranges": [dict(rng)]},
             "volume": {"volume_ranges": [dict(rng)]}, "package": {"package_size": 1, "amount": "0", "free_units": 0},
             "percentage": {"rate": "0"},
             "graduated_percentage": {"graduated_percentage_ranges": [
                 {"from_value": 0, "to_value": None, "rate": "0", "fixed_amount": "0", "flat_amount": "0"}]},
             "dynamic": {}, "custom": None}
    return {"properties": table.get(m)}


def filter_properties(inp, ctx):
    return {"properties": slice_props(inp["model"], inp.get("properties"), inp.get("kind") or "charge",
                                      inp.get("metric_aggregation_type") or "sum_agg")}


def estimate_instant(inp, ctx):
    cur = inp.get("currency") or "EUR"
    e, s = exponent(cur), subunit(cur)
    props = inp.get("properties") or {}
    metric = inp.get("metric") or {"field_name": "value"}
    evp = inp.get("event_properties") or {}
    if "field_name" in metric and metric["field_name"] is None:
        units = D1
    else:
        fname = metric.get("field_name", "value")
        v = evp.get(fname)
        units = D0 if v is None else (pd(v) if isinstance(v, str) else dec(v))
    fn = metric.get("rounding_function")
    if fn:
        prec = int(metric.get("rounding_precision") or 0)
        mode = {"round": ROUND_HALF_UP, "ceil": "ROUND_CEILING", "floor": "ROUND_FLOOR"}[fn]
        if prec >= 0:
            units = units.quantize(Decimal(1).scaleb(-prec), rounding=mode)
        else:
            f = Decimal(10) ** -prec
            units = (units / f).quantize(Decimal(1), rounding=mode) * f
    if inp["model"] == "standard":
        amount = units * pd(props.get("amount"))
    else:
        amount = units * pd(props.get("rate")) / 100 + pd(props.get("fixed_amount"))
        mn, mx = props.get("per_transaction_min_amount"), props.get("per_transaction_max_amount")
        if not blank(mn) and amount < pd(mn):
            amount = pd(mn)
        elif not blank(mx) and amount > pd(mx):
            amount = pd(mx)
    if units < 0:
        amount = D0
    r = rnd(amount, e)
    return {"amount_cents": r * s, "precise_amount": amount, "units": units,
            "precise_unit_amount": (div(r, units) * s) if (r != 0 and units != 0) else D0, "events_count": 1,
            "taxes_amount_cents": D0}


def simulate(inp, ctx):
    cur = inp.get("currency") or "EUR"
    e, s = exponent(cur), subunit(cur)
    model = inp["model"]
    props = inp.get("properties")
    if blank(props):
        props = default_properties({"model": model}, ctx)["properties"] or {}
    props = slice_props(model, props, "charge", inp.get("metric_aggregation_type") or "sum_agg")
    n = dec(inp["units"])
    agg = {"units": n, "full_units_number": n, "current_usage_units": n, "total_aggregated_units": n,
           "running_total": [], "count": 10}
    b = price_bucket(model, props, agg, {"profile": ctx["profile"], "currency": cur, "premium": bool(inp.get("premium"))})
    plan = dec(inp.get("plan_amount_cents") or 0)
    charge = rnd(b["amount"], e) * s if ctx["profile"] == "corrected" else b["amount"]
    return {"charge_amount_cents": charge, "subscription_amount_cents": plan, "total_amount_cents": charge + plan}


# ---------------------------------------------------------------- validation
def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def num_of(v):
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, (int, Decimal)):
        return dec(v)
    return None


def validate_ranges(props, key, volume, metric_agg, errs, gp=False):
    ranges = props.get(key)
    if not isinstance(ranges, list) or not ranges:
        errs.append((key, f"missing_{key}"))
        return
    if gp and metric_agg == "latest_agg":
        errs.append(("billable_metric", "invalid_value"))
    bad = False
    nxt = D0
    for i, r in enumerate(ranges):
        if not isinstance(r, dict):
            bad = True
            continue
        if gp:
            if not valid_amount(r.get("flat_amount")):
                errs.append(("flat_amount", "invalid_amount"))
            if not valid_amount(r.get("rate")):
                errs.append(("rate", "invalid_rate"))
        else:
            if not valid_amount(r.get("per_unit_amount")):
                errs.append(("per_unit_amount", "invalid_amount"))
            if not valid_amount(r.get("flat_amount")):
                errs.append(("flat_amount", "invalid_amount"))
        frm = num_of(r.get("from_value"))
        to_raw = r.get("to_value")
        to = num_of(to_raw)
        last = i == len(ranges) - 1
        if frm is None or not (frm == nxt or frm == nxt + 1):
            bad = True
            frm = frm if frm is not None else nxt
        if last:
            if to_raw is not None:
                bad = True
        else:
            if to is None or to <= frm:
                bad = True
        if to is not None:
            nxt = to + 1 if volume else to
    if bad:
        errs.append((key, f"invalid_{key}"))


def validate_group_keys(props, errs):
    key = "pricing_group_keys" if "pricing_group_keys" in props else "grouped_by"
    v = props.get(key)
    if v is not None:
        if not isinstance(v, list) or any(not isinstance(x, str) or x == "" for x in v):
            errs.append((key, "invalid_type"))
    pg = props.get("presentation_group_keys")
    if not blank(pg):
        ok = isinstance(pg, list)
        if ok:
            for x in pg:
                if not isinstance(x, dict) or set(x) - {"value", "options"} or not isinstance(x.get("value"), str) \
                        or x.get("value") == "":
                    ok = False
                    break
                o = x.get("options")
                if o is not None and (not isinstance(o, dict) or set(o) - {"display_in_invoice"}
                                      or ("display_in_invoice" in o and not isinstance(o["display_in_invoice"], bool))):
                    ok = False
                    break
        if not ok:
            errs.append(("presentation_group_keys", "invalid_type"))
        else:
            if len(pg) > 2:
                errs.append(("presentation_group_keys", "too_many_keys"))
            vals = [x["value"] for x in pg]
            if len(set(vals)) != len(vals):
                errs.append(("presentation_group_keys", "value_is_duplicated"))


def validate_properties_core(model, props, kind, metric_agg, premium):
    errs = []
    props = props if isinstance(props, dict) else {}
    if model == "standard":
        if not valid_amount(props.get("amount")):
            errs.append(("amount", "invalid_amount"))
    elif model == "package":
        if not valid_amount(props.get("amount")):
            errs.append(("amount", "invalid_amount"))
        fu = props.get("free_units")
        if not (is_int(fu) and fu >= 0):
            errs.append(("free_units", "invalid_free_units"))
        ps = props.get("package_size")
        if not (is_int(ps) and ps > 0):
            errs.append(("package_size", "invalid_package_size"))
    elif model == "percentage":
        if metric_agg == "latest_agg":
            errs.append(("billable_metric", "invalid_value"))
        if not valid_amount(props.get("rate")):
            errs.append(("rate", "invalid_rate"))
        if props.get("fixed_amount") is not None and not valid_amount(props.get("fixed_amount")):
            errs.append(("fixed_amount", "invalid_fixed_amount"))
        fe = props.get("free_units_per_events")
        if fe is not None and not (is_int(fe) and fe > 0):
            errs.append(("free_units_per_events", "invalid_free_units_per_events"))
        fa = props.get("free_units_per_total_aggregation")
        if fa is not None and not valid_amount(fa):
            errs.append(("free_units_per_total_aggregation", "invalid_free_units_per_total_aggregation"))
        if premium:
            mn, mx = props.get("per_transaction_min_amount"), props.get("per_transaction_max_amount")
            okmn = okmx = True
            if not blank(mn) and not valid_amount(mn):
                errs.append(("per_transaction_min_amount", "invalid_amount"))
                okmn = False
            if not blank(mx) and not valid_amount(mx):
                errs.append(("per_transaction_max_amount", "invalid_amount"))
                okmx = False
            if okmn and okmx and not blank(mn) and not blank(mx) and read_decimal(mn) > read_decimal(mx):
                errs.append(("per_transaction_max_amount", "per_transaction_max_lower_than_per_transaction_min"))
    elif model == "graduated":
        validate_ranges(props, "graduated_ranges", False, metric_agg, errs)
    elif model == "volume":
        validate_ranges(props, "volume_ranges", True, metric_agg, errs)
    elif model == "graduated_percentage":
        validate_ranges(props, "graduated_percentage_ranges", False, metric_agg, errs, gp=True)
    validate_group_keys(props, errs)
    return errs


def errs_to_dict(errs):
    d = {}
    for f, c in errs:
        d.setdefault(f, []).append(c)
    return d


def record_codes(errs):
    out = []
    for codes in errs_to_dict(errs).values():
        for c in codes:
            if c not in out:
                out.append(c)
    return out


def validate_properties(inp, ctx):
    errs = validate_properties_core(inp["model"], inp.get("properties"), inp.get("kind") or "charge",
                                    inp.get("metric_aggregation_type") or "sum_agg", bool(inp.get("premium")))
    if not errs:
        return {"valid": True}
    return {"valid": False, "errors": errs_to_dict(errs), "property_messages": record_codes(errs)}


def validate_charge(inp, ctx):
    model = inp["model"]
    kind = inp.get("kind") or "charge"
    metric = inp.get("metric") or {}
    agg = metric.get("aggregation_type") or "sum_agg"
    recurring = bool(metric.get("recurring"))
    pia = bool(inp.get("pay_in_advance"))
    prorated = bool(inp.get("prorated"))
    premium = bool(inp.get("premium"))
    errs = []
    known = list(MODELS)
    if kind == "fixed_charge":
        if model not in ("standard", "graduated", "volume"):
            errs.append(("charge_model", "value_is_invalid"))
        if model == "volume" and pia:
            errs.append(("pay_in_advance", "invalid_charge_model"))
        if model == "graduated" and prorated and pia:
            errs.append(("prorated", "invalid_charge_model"))
        u = inp.get("units")
        if u is not None and dec(u) < 0:
            errs.append(("units", "value_is_out_of_range"))
    else:
        if model not in known:
            errs.append(("charge_model", "value_is_invalid"))
        if pia and (model == "volume" or agg not in ("count_agg", "sum_agg", "unique_count_agg", "custom_agg")):
            errs.append(("pay_in_advance", "invalid_aggregation_type_or_charge_model"))
        if inp.get("invoiceable") is False and not pia:
            errs.append(("invoiceable", "must_be_true_unless_pay_in_advance"))
        if inp.get("regroup_paid_fees") is not None and not (pia and inp.get("invoiceable") is False):
            errs.append(("regroup_paid_fees", "only_compatible_with_pay_in_advance_and_non_invoiceable"))
        mn = inp.get("min_amount_cents")
        if mn is not None:
            if pia and dec(mn) != 0:
                errs.append(("min_amount_cents", "not_compatible_with_pay_in_advance"))
            elif dec(mn) < 0:
                errs.append(("min_amount_cents", "value_is_out_of_range"))
        if prorated:
            ok = recurring and agg != "weighted_sum_agg"
            if ok:
                ok = model == "standard" if pia else model in ("standard", "volume", "graduated")
            if not ok:
                errs.append(("prorated", "invalid_billable_metric_or_charge_model"))
        if model == "dynamic" and agg != "sum_agg":
            errs.append(("charge_model", "invalid_aggregation_type_or_charge_model"))
        if model == "custom" and agg != "custom_agg":
            errs.append(("charge_model", "invalid_aggregation_type_or_charge_model"))
        if model == "graduated_percentage" and not premium:
            errs.append(("charge_model", "graduated_percentage_requires_premium_license"))
    if model in known:
        props = inp.get("properties")
        if props is None:
            props = default_properties({"model": model}, ctx)["properties"] or {}
        pe = validate_properties_core(model, props, kind, agg, premium)
        if pe:
            errs.append(("properties", record_codes(pe)))
    if not errs:
        return {"valid": True}
    d = {}
    for f, c in errs:
        if isinstance(c, list):
            d.setdefault(f, []).extend(c)
        else:
            d.setdefault(f, []).append(c)
    return {"valid": False, "errors": d}


# ---------------------------------------------------------------- protocol
HANDLERS = {
    "pricing.charge_model": charge_model, "pricing.pay_in_advance": pay_in_advance, "pricing.fee_money": fee_money,
    "pricing.true_up": true_up, "pricing.pricing_unit": pricing_unit, "pricing.fixed_charge_units": fixed_units,
    "pricing.fixed_charge_fee": fixed_charge_fee, "pricing.fixed_charge_in_advance": fixed_charge_in_advance,
    "pricing.projection": projection, "pricing.estimate_instant": estimate_instant, "pricing.simulate": simulate,
    "pricing.default_properties": default_properties, "pricing.filter_properties": filter_properties,
    "pricing.validate_properties": validate_properties, "pricing.validate_charge": validate_charge,
}


def _default(o):
    if isinstance(o, JF):
        return float(o)
    if isinstance(o, Decimal):
        return out_dec(o)
    raise TypeError(f"cannot encode {type(o).__name__}")


def _clean(o):
    """Drop None-valued optional passthroughs but keep explicit nulls in details."""
    return o


def encode(obj):
    return json.dumps(obj, default=_default, ensure_ascii=False, separators=(",", ":"))


def serve():
    out = sys.stdout

    def send(obj):
        out.write(encode(obj) + "\n")
        out.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line, parse_float=JF, parse_int=int)
        except ValueError as e:
            print(f"unparsable request: {e}", file=sys.stderr)
            continue
        kind = msg.get("type")
        if kind == "hello":
            send({"type": "hello", "proto": 1, "impl": "crc-2b-pricing", "impl_version": "1.0.0",
                  "profiles": ["compat", "corrected"], "ops": sorted(HANDLERS)})
        elif kind == "bye":
            break
        elif kind == "call":
            cid = msg.get("id")
            fn = HANDLERS.get(f"{msg.get('area')}.{msg.get('op')}")
            if fn is None:
                send({"type": "result", "id": cid, "error": {"code": "unsupported_op"}})
                continue
            try:
                res = fn(msg.get("input") or {}, {"profile": msg.get("profile") or "compat"})
                send({"type": "result", "id": cid, "output": res})
            except KitError as e:
                err = {"code": e.code}
                if e.field:
                    err["field"] = e.field
                if e.message:
                    err["message"] = e.message
                send({"type": "result", "id": cid, "error": err})
            except Unsupported as e:
                send({"type": "result", "id": cid, "error": {"code": "unsupported_op", "message": str(e)}})
            except (BadInput, KeyError) as e:
                traceback.print_exc(file=sys.stderr)
                send({"type": "result", "id": cid, "error": {"code": "bad_input", "message": repr(e)}})
            except Exception as e:  # noqa: BLE001
                traceback.print_exc(file=sys.stderr)
                send({"type": "result", "id": cid, "error": {"code": "internal", "message": f"{type(e).__name__}: {e}"}})
    return 0


if __name__ == "__main__":
    sys.exit(serve())
