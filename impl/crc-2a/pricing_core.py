"""Charge models, fee money and helpers of the pricing engine (billing-engine-spec chapter 05)."""
from __future__ import annotations

import math
import re
from decimal import Decimal, Context, ROUND_HALF_UP, ROUND_CEILING, ROUND_FLOOR, ROUND_DOWN, localcontext
import decimal

from currencies import CURRENCIES

decimal.getcontext().prec = 200
decimal.getcontext().traps[decimal.InvalidOperation] = True

ZERO = Decimal(0)
ONE = Decimal(1)
HUNDRED = Decimal(100)


class OpError(Exception):
    def __init__(self, code, field=None, message=""):
        super().__init__(message or code)
        self.code = code
        self.field = field
        self.message = message or code


# --------------------------------------------------------------------------- decimals

def D(x):
    """Exact decimal from a JSON value (str, int, Decimal, bool excluded); None stays None."""
    if x is None:
        return None
    if isinstance(x, Decimal):
        return x
    if isinstance(x, bool):
        raise OpError("bad_input", message="boolean where a decimal was expected")
    if isinstance(x, int):
        return Decimal(x)
    if isinstance(x, float):
        return Decimal(repr(x))
    if isinstance(x, str):
        s = x.strip().replace("_", "")
        try:
            return Decimal(s)
        except Exception:
            raise OpError("bad_input", message=f"not a decimal: {x!r}")
    raise OpError("bad_input", message=f"not a decimal: {x!r}")


def div(a, b, min_prec=32):
    """Exact-decimal quotient keeping at least 32 significant digits, the last one rounded half up."""
    a, b = D(a), D(b)
    if b == 0:
        raise OpError("charge_model_error", message="division by zero")
    nd = max(len(a.as_tuple().digits), len(b.as_tuple().digits))
    prec = max(min_prec, 2 * nd) if nd > 16 else min_prec
    return Context(prec=prec, rounding=ROUND_HALF_UP).divide(a, b)


def safe_div(a, b):
    return ZERO if D(b) == 0 else div(a, b)


def round_half_away(x, places=0):
    x = D(x)
    q = Decimal(1).scaleb(-places)
    return x.quantize(q, rounding=ROUND_HALF_UP)


def trunc(x):
    return int(D(x).to_integral_value(rounding=ROUND_DOWN))


def float_to_dec(f: float) -> Decimal:
    """binary64 -> decimal: shortest round-trip text truncated to 16 significant digits (BE-PR-85)."""
    d = Decimal(repr(float(f)))
    if d == 0:
        return ZERO
    digits = d.as_tuple().digits
    if len(digits) <= 16:
        return d
    with localcontext() as c:
        c.prec = 16
        c.rounding = ROUND_DOWN
        return +d


def dec_to_float(d) -> float:
    return float(D(d))


def q15(d):
    """Stored precision of precise amounts and unit amounts: 15 decimal places."""
    return D(d).quantize(Decimal(1).scaleb(-15), rounding=ROUND_HALF_UP)


def fmt(d) -> str:
    d = D(d)
    if d == 0:
        return "0"
    s = format(d, "f")
    return s


def ds(d) -> str:
    """Stored-details decimal text: at least one fraction digit."""
    s = fmt(d)
    return s if "." in s else s + ".0"


def cur_exp(currency):
    c = CURRENCIES.get(currency or "EUR")
    if c is None:
        raise OpError("bad_input", "currency", f"unknown currency {currency}")
    return c


def subunit(currency) -> Decimal:
    e, m = cur_exp(currency)
    return Decimal(m)


def exponent(currency) -> int:
    return cur_exp(currency)[0]


def is_float_lit(x) -> bool:
    return isinstance(x, Decimal)


def num(x):
    """A properties value that is a JSON number or a decimal string, as an exact decimal."""
    return D(x)


def ceil_dec(x) -> Decimal:
    return D(x).to_integral_value(rounding=ROUND_CEILING)


def blank(x) -> bool:
    return x is None or (isinstance(x, str) and x.strip() == "")


# --------------------------------------------------------------------------- aggregation

class Agg:
    def __init__(self, d: dict):
        self.units = D(d.get("units", 0))
        self.count = int(d.get("count", 0) or 0)
        self.fu = D(d["full_units_number"]) if d.get("full_units_number") is not None else None
        self.cur = D(d["current_usage_units"]) if d.get("current_usage_units") is not None else None
        self.tot = D(d["total_aggregated_units"]) if d.get("total_aggregated_units") is not None else None
        self.rt = [D(v) for v in d.get("running_total", [])]
        self.pev = [D(v) for v in d["per_event_values"]] if d.get("per_event_values") is not None else None
        self.event_value = D(d["event_value"]) if d.get("event_value") is not None else None
        self.event_units = D(d["event_units"]) if d.get("event_units") is not None else None
        self.full = [D(v) for v in d["per_event_full"]] if d.get("per_event_full") is not None else None
        self.pro = [D(v) for v in d["per_event_prorated"]] if d.get("per_event_prorated") is not None else None
        self.precise_total = D(d["precise_total_amount_cents"]) if d.get("precise_total_amount_cents") is not None else None
        self.event_precise = D(d["event_precise_total_amount_cents"]) if d.get("event_precise_total_amount_cents") is not None else None
        self.custom_amount = D(d["custom_amount"]) if d.get("custom_amount") is not None else None
        self.cached = d.get("cached")

    def copy(self, **kw):
        a = Agg.__new__(Agg)
        a.__dict__.update(self.__dict__)
        a.__dict__.update(kw)
        return a


class Ctx:
    def __init__(self, currency="EUR", prorated=False, premium=False, profile="compat",
                 period_ratio=ONE, project=False, flags=None):
        self.currency = currency or "EUR"
        self.prorated = bool(prorated)
        self.premium = bool(premium)
        self.profile = profile
        self.period_ratio = D(period_ratio) if period_ratio is not None else ONE
        self.project = bool(project)
        self.flags = flags or {}

    @property
    def corrected(self):
        return self.profile == "corrected"

    @property
    def exclude_event(self):
        return bool(self.flags.get("exclude_event"))

    @property
    def include_event_value(self):
        return bool(self.flags.get("include_event_value"))


class Result:
    def __init__(self, amount, unit_amount, details=None):
        self.amount = amount
        self.unit_amount = unit_amount
        self.details = details if details is not None else {}
        self.projected_amount = None
        self.projected_units = None


def unit_amount_of(amount, agg):
    d = agg.fu if agg.fu is not None else agg.units
    return safe_div(amount, d)


# --------------------------------------------------------------------------- standard / package

def standard(props, agg, ctx):
    amount = agg.units * D(props.get("amount"))
    return Result(amount, unit_amount_of(amount, agg), {})


def package(props, agg, ctx):
    amt = D(props.get("amount"))
    size = D(props.get("package_size"))
    free = D(props.get("free_units"))
    U = agg.units
    paid = U - free
    if U == 0:
        details = {"free_units": "0.0", "paid_units": "0.0", "per_package_size": 0, "per_package_unit_amount": "0.0"}
    elif paid < 0:
        details = {"free_units": ds(free), "paid_units": "0.0", "per_package_size": int(size),
                   "per_package_unit_amount": ds(amt)}
    else:
        details = {"free_units": ds(free), "paid_units": ds(paid), "per_package_size": int(size),
                   "per_package_unit_amount": ds(amt)}
    if paid < 0:
        amount = ZERO
    else:
        if ctx.corrected:
            packages = ceil_dec(div(paid, size))
        else:
            packages = Decimal(math.ceil(dec_to_float(paid) / float(size)))
        amount = packages * amt
    unit_amount = div(amount, paid) if paid > 0 else ZERO
    return Result(amount, unit_amount, details)


# --------------------------------------------------------------------------- graduated

def _adjacent(ranges):
    if len(ranges) < 2:
        return False
    prev_to = None
    for i, r in enumerate(ranges):
        if i > 0:
            pt = ZERO if prev_to is None else D(prev_to)
            if D(r["from_value"]) != pt:
                return False
        prev_to = r.get("to_value")
    return True


def graduated(props, agg, ctx):
    ranges = props.get("graduated_ranges") or []
    U = agg.units
    adjacent = _adjacent(ranges)
    zero_exclude = ctx.exclude_event and U == 0
    details = []
    total = ZERO
    for r in ranges:
        frm = D(r["from_value"])
        to = r.get("to_value")
        toD = D(to) if to is not None else None
        eff = toD if (toD is not None and U >= toD) else U
        units = eff if frm == 0 else eff - frm
        if not adjacent and frm != 0:
            units += 1
        price = D(r.get("per_unit_amount"))
        flat = D(r.get("flat_amount"))
        per_unit = price if units != 0 else ZERO
        ptotal = units * price
        tot = ptotal + flat
        flat_shown = flat
        details.append({"from_value": r["from_value"], "to_value": to, "flat_unit_amount": ds(flat_shown),
                        "per_unit_amount": ds(per_unit), "units": ds(units),
                        "per_unit_total_amount": ds(ptotal), "total_with_flat_amount": ds(tot)})
        total += tot
        if toD is None or toD >= U:
            break
    amount = ZERO if zero_exclude else total
    return Result(amount, unit_amount_of(amount, agg), {"graduated_ranges": details})


def _float_or_dec(x):
    return float(x) if isinstance(x, Decimal) else x


def graduated_percentage(props, agg, ctx):
    ranges = props.get("graduated_percentage_ranges") or []
    U = agg.units
    zero_exclude = ctx.exclude_event and U == 0
    adjacent = _adjacent(ranges) if ctx.corrected else False
    details = []
    total = ZERO
    for r in ranges:
        frm_raw = r["from_value"]
        to_raw = r.get("to_value")
        frm = D(frm_raw)
        toD = D(to_raw) if to_raw is not None else None
        if ctx.corrected:
            eff = toD if (toD is not None and U >= toD) else U
            units = eff if frm == 0 else eff - frm
            if not adjacent and frm != 0:
                units += 1
        elif toD is not None and U >= toD:
            if isinstance(to_raw, Decimal) or isinstance(frm_raw, Decimal) and frm != 0:
                sub = frm_raw if frm != 0 else 1
                units = float_to_dec(float(to_raw) - float(sub) + 1)
            else:
                units = toD - (ONE if frm == 0 else frm) + 1
        elif frm == 0:
            units = U
        else:
            units = U - frm + 1
        rate = D(r.get("rate"))
        flat = D(r.get("flat_amount"))
        ptotal = units * rate / HUNDRED
        tot = ptotal + flat
        if zero_exclude:
            flat, tot = ZERO, 0
        details.append({"from_value": r["from_value"], "to_value": to_raw, "flat_unit_amount": 0 if zero_exclude else ds(flat),
                        "rate": ds(rate), "units": ds(units), "per_unit_total_amount": ds(ptotal),
                        "total_with_flat_amount": ds(tot) if tot != 0 or not zero_exclude else 0})
        total += tot
        if toD is None or toD >= U:
            break
    amount = ZERO if zero_exclude else total
    return Result(amount, unit_amount_of(amount, agg), {"graduated_percentage_ranges": details})


# --------------------------------------------------------------------------- volume

def _volume_sorted(props):
    return sorted(props.get("volume_ranges") or [], key=lambda r: D(r["from_value"]))


def volume_match(ranges, n):
    cn = ceil_dec(n)
    for r in ranges:
        to = r.get("to_value")
        if D(r["from_value"]) <= cn and (to is None or n <= D(to)):
            return r
    return None


def volume(props, agg, ctx):
    ranges = _volume_sorted(props)
    U = agg.units
    N = agg.fu if (ctx.prorated and agg.fu is not None) else U
    r = volume_match(ranges, N)
    if r is None:
        if N < 0 and ctx.corrected:
            return Result(ZERO, ZERO, {})
        raise OpError("charge_model_error", message="no volume range matches")
    price = D(r.get("per_unit_amount"))
    flat = D(r.get("flat_amount"))
    ptotal = U * price
    amount = ptotal + flat
    unit_amount = safe_div(amount, N)
    if N == 0:
        pu = ZERO
    else:
        # kept in the corrected profile too: a shipped `both` vector pins the binary64 text (KIT-GAPS)
        pu = div(float_to_dec(dec_to_float(ptotal)), N)
    return Result(amount, unit_amount, {"flat_unit_amount": ds(flat), "per_unit_amount": ds(pu),
                                        "per_unit_total_amount": ds(ptotal)})


# --------------------------------------------------------------------------- percentage

def _percentage_free(RT, FE, FA):
    last = RT[-1] if RT else ZERO
    if last == 0:
        free = ZERO
    elif FE > 0 and FE < len(RT):
        free = RT[FE - 1]
    elif FA == 0:
        free = last
    elif last <= FA:
        free = last
    else:
        free = FA
    below = sum(1 for v in RT if v < FA)
    cands = [x for x in (FE, below) if x != 0]
    FC = min(cands) if cands else 0
    return free, FC


def percentage(props, agg, ctx):
    r = D(props.get("rate"))
    f = D(props.get("fixed_amount")) if not blank(props.get("fixed_amount")) else ZERO
    FE = int(D(props.get("free_units_per_events"))) if not blank(props.get("free_units_per_events")) else 0
    FA = D(props.get("free_units_per_total_aggregation")) if not blank(props.get("free_units_per_total_aggregation")) else ZERO
    mn = props.get("per_transaction_min_amount")
    mx = props.get("per_transaction_max_amount")
    U, C = agg.units, agg.count
    free, FC = _percentage_free(agg.rt, FE, FA)
    P = 0 if free > U else (U - free) * r / HUNDRED
    F = ZERO if (U == 0 or FC >= C) else (C - FC) * f
    per_tx = ctx.premium and (not blank(mn) or not blank(mx))
    if per_tx and ctx.corrected:
        amount = _per_tx_corrected(agg, r, f, free, FC, mn, mx)
        mm = amount - P - F
    elif per_tx:
        amount = _percentage_per_tx(agg, r, f, FE, FA, mn, mx)
        mm = amount - P - F
    else:
        amount = P + F
        mm = ZERO
    free_events = min(C, FC)
    paid_events = C - free_events
    details = {"units": ds(U), "free_units": ds(free), "free_events": free_events,
               "paid_units": ds(max(U - free, ZERO)), "rate": ds(r), "per_unit_total_amount": ds(P) if P != 0 or not isinstance(P, int) else 0,
               "paid_events": paid_events, "fixed_fee_unit_amount": ds(f if paid_events > 0 else ZERO),
               "fixed_fee_total_amount": ds(F), "min_max_adjustment_total_amount": ds(mm)}
    return Result(amount, unit_amount_of(amount, agg), details)


def _clamp_tx(e, mn, mx):
    if not blank(mn) and e < D(mn):
        return D(mn)
    if not blank(mx) and e > D(mx):
        return D(mx)
    return e


def _percentage_per_tx(agg, r, f, FE, FA, mn, mx):
    rfe, rfa = FE, FA
    total = ZERO
    for v in (agg.pev or []):
        v = D(v)
        if rfe > 0 or rfa > 0:
            rfe -= 1
            if rfa <= 0:
                continue
            if rfa > v:
                rfa -= v
                continue
            v = v - rfa
            rfa = ZERO
            rfe = 0
        total += _clamp_tx(v * r / HUNDRED + f, mn, mx)
    return total


def _per_tx_corrected(agg, r, f, free, FC, mn, mx):
    """Corrected profile (RBD-41): free units and free events follow the BE-PR-27/28 semantics; the bounds
    apply to each paid event."""
    fl = free
    total = ZERO
    for idx, v in enumerate(agg.pev or []):
        v = D(v)
        if idx < FC:
            fl = max(fl - v, ZERO)
            continue
        if fl > 0:
            take = min(fl, v)
            v -= take
            fl -= take
        if v <= 0:
            continue
        total += _clamp_tx(v * r / HUNDRED + f, mn, mx)
    return total


# --------------------------------------------------------------------------- dynamic / custom

def dynamic(props, agg, ctx):
    d = agg.fu if agg.fu is not None else agg.units
    if d == 0 or agg.precise_total is None:
        amount = ZERO
    else:
        amount = agg.precise_total / subunit(ctx.currency)
    return Result(amount, unit_amount_of(amount, agg), {})


def custom(props, agg, ctx):
    amount = agg.custom_amount if agg.custom_amount is not None else ZERO
    return Result(amount, unit_amount_of(amount, agg), {})


# --------------------------------------------------------------------------- prorated graduated

def prorated_graduated(props, agg, ctx):
    ranges = props.get("graduated_ranges") or []
    full = agg.full
    pro = agg.pro if agg.pro is not None else full
    U = agg.units
    n = len(full)

    def flat_of(peak):
        total = ZERO
        for r in ranges:
            total += D(r.get("flat_amount"))
            to = r.get("to_value")
            if to is None or D(to) >= peak:
                break
        return total

    sum_full = sum(full, ZERO)
    if U == 0:
        amount = flat_of(ZERO)
        return Result(amount, safe_div(amount, sum_full), {})
    if n == 0:
        if ctx.corrected:
            return Result(ZERO, ZERO, {})
        raise OpError("charge_model_error", message="prorated graduated without per-event data")

    def coef(k):
        if full[k] == 0:
            return ZERO
        return div(float_to_dec(dec_to_float(pro[k])), full[k])

    def select(fs, ov, nxt):
        if fs <= 0:
            return 0
        if ov == 0:
            u = fs
        elif ov > 0:
            u = fs - ov + 1
        else:
            u = fs + ov
        for idx, r in enumerate(ranges):
            to = r.get("to_value")
            toD = D(to) if to is not None else None
            if toD is not None and u == toD and nxt is not None and nxt > 0:
                return min(idx + 1, len(ranges) - 1)
            if toD is not None and u == toD:
                return idx
            if u >= D(r["from_value"]) and (toD is None or u < toD):
                return idx
        return 0

    i = 0
    overflow = ZERO
    fs = ZERO
    peak = ZERO
    ps = ZERO
    acc = ZERO
    last_idx = 0
    guard = 0
    while i < n or overflow != 0:
        guard += 1
        if guard > 100000:
            raise OpError("charge_model_error", message="prorated graduated did not converge")
        ri = select(fs, overflow, full[i] if i < n else None)
        r = ranges[ri]
        last_idx = ri
        rto = D(r["to_value"]) if r.get("to_value") is not None else None
        rfrom = D(r["from_value"])
        price = D(r.get("per_unit_amount"))
        if overflow != 0:
            ps += overflow * coef(i - 1)
            if rto is not None and fs >= rto:
                overflow = fs - rto
                ps -= overflow * coef(i - 1)
                acc += ps * price
                ps = ZERO
                continue
            overflow = ZERO
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
        if (rto is None and fs >= rfrom - 1) or (rto is not None and rfrom <= fs < rto):
            continue
        if rto is None:
            overflow = fs - rfrom + 1
        else:
            overflow = fs - rto if fs >= rto else fs - rfrom + 1
        ps -= overflow * coef(i - 1)
        acc += ps * price
        ps = ZERO
    acc += ps * D(ranges[last_idx].get("per_unit_amount"))
    if fs < 0:
        return Result(ZERO, ZERO, {})
    amount = max(acc, ZERO) + flat_of(peak)
    return Result(amount, safe_div(amount, sum_full), {})


# --------------------------------------------------------------------------- dispatch and grouping

MODELS = {
    "standard": standard, "package": package, "graduated": graduated,
    "graduated_percentage": graduated_percentage, "volume": volume, "percentage": percentage,
    "dynamic": dynamic, "custom": custom,
}


def group_keys(props):
    k = props.get("pricing_group_keys")
    if k is None:
        k = props.get("grouped_by")
    return [x for x in k if isinstance(x, str) and x] if isinstance(k, list) else []


def price_bucket(model, props, agg, ctx) -> Result:
    if model not in MODELS:
        raise OpError("charge_model_error", message=f"unknown model {model}")
    if ctx.include_event_value:
        ev = agg.event_value if agg.event_value is not None else agg.event_units
        if ev is not None:
            agg = agg.copy(pev=list(agg.pev or []) + [ev])
    if model == "graduated" and ctx.prorated and agg.full is not None:
        res = prorated_graduated(props, agg, ctx)
    else:
        res = MODELS[model](props, agg, ctx)
    if ctx.project:
        project(model, props, agg, ctx, res)
    return res


# --------------------------------------------------------------------------- projections

def project_units(U, rho):
    if U == 0 or rho <= 0:
        return ZERO
    return round_half_away(div(U, rho), 2)


def project(model, props, agg, ctx, res):
    rho = ctx.period_ratio
    PU = project_units(agg.units, rho)
    res.projected_units = PU
    if model == "standard":
        pa = PU * D(props.get("amount"))
    elif model == "package":
        left = PU - D(props.get("free_units"))
        pa = ZERO if left <= 0 else ceil_dec(div(left, D(props.get("package_size")))) * D(props.get("amount"))
    elif model == "graduated" and not (ctx.prorated and agg.full is not None):
        pa = ZERO
        if PU != 0:
            remaining, priced = PU, ZERO
            for r in props.get("graduated_ranges") or []:
                if remaining <= 0:
                    break
                to = r.get("to_value")
                cap = (D(to) - priced) if to is not None else remaining
                units = min(remaining, cap)
                if units > 0:
                    pa += units * D(r.get("per_unit_amount")) + D(r.get("flat_amount"))
                    priced += units
                    remaining -= units
    elif model == "volume":
        r = volume_match(_volume_sorted(props), PU)
        pa = ZERO if r is None else PU * D(r.get("per_unit_amount")) + D(r.get("flat_amount"))
    else:
        pa = ZERO if (res.amount == 0 or rho == 0) else div(res.amount, rho)
    res.projected_amount = pa


def price_grouped(model, props, aggd: dict, ctx):
    """Returns (Result, groups or None)."""
    agg = Agg(aggd)
    keys = group_keys(props)
    if keys and aggd.get("groups") is not None:
        groups = []
        tot_amount = ZERO
        tot_units = ZERO
        tot_pa = ZERO
        tot_pu = ZERO
        for g in aggd["groups"]:
            gagg = Agg(g)
            gres = price_bucket(model, props, gagg, ctx)
            groups.append((g.get("grouped_by"), gagg, gres))
            tot_amount += gres.amount
            tot_units += gagg.units
            if ctx.project:
                tot_pa += gres.projected_amount or ZERO
                tot_pu += gres.projected_units or ZERO
        res = Result(tot_amount, safe_div(tot_amount, tot_units), {})
        res.units_override = tot_units
        if ctx.project:
            res.projected_amount, res.projected_units = tot_pa, tot_pu
        return res, agg, groups
    return price_bucket(model, props, agg, ctx), agg, None


# --------------------------------------------------------------------------- fee money

def pu_convert(A, u, rate, currency, corrected=False):
    """Pricing-unit conversion (BE-PR-63). A, u in pricing units. Returns (pu_record, fiat_record) decimals."""
    e = exponent(currency)
    s = subunit(currency)
    rate = D(rate)
    pu_cents = round_half_away(A, 2) * 100
    pu_unit_cents = Decimal(trunc(u * 100))
    rate = q15(rate)
    pu = {"amount_cents": pu_cents, "precise_amount_cents": q15(A * 100),
          "unit_amount_cents": pu_unit_cents, "precise_unit_amount": q15(u)}
    if corrected:
        adj, adj_u = A * rate, u * rate
    else:
        adj = pu_cents * rate / 100
        adj_u = pu_unit_cents * rate / 100
    fiat = {"amount_cents": round_half_away(adj, e) * s, "precise_amount_cents": adj * s,
            "unit_amount_cents": adj_u * s, "precise_unit_amount": adj_u}
    return pu, fiat


def money_fields(amount, unit_amount, currency):
    e, s = exponent(currency), subunit(currency)
    return {"amount_cents": int(round_half_away(amount, e) * s), "precise_amount_cents": q15(amount * s),
            "unit_amount_cents": trunc(unit_amount * s), "precise_unit_amount": q15(unit_amount)}


def fee_money(inp, profile="compat"):
    amount = D(inp["amount"])
    unit_amount = D(inp["unit_amount"])
    units = D(inp["units"])
    fu = D(inp["full_units_number"]) if inp.get("full_units_number") is not None else None
    cur = D(inp["current_usage_units"]) if inp.get("current_usage_units") is not None else None
    tot = D(inp["total_aggregated_units"]) if inp.get("total_aggregated_units") is not None else None
    events = int(inp.get("events_count") or 0)
    currency = inp.get("currency") or "EUR"
    context = inp.get("context") or "invoice"
    pia = bool(inp.get("pay_in_advance", False))
    prorated = bool(inp.get("prorated", False))
    invoiceable = inp.get("invoiceable", True)
    rate = inp.get("pricing_unit_conversion_rate")
    if units < 0 or amount < 0:
        amount = unit_amount = units = ZERO
        fu = ZERO if fu is not None else None
        if tot is not None:
            tot = ZERO
    if context == "current_usage" and (pia or prorated) and cur is not None:
        stored = cur
    elif prorated:
        stored = fu if fu is not None else units
    else:
        stored = units
    total_agg = tot if tot is not None else stored
    out = {}
    if rate is not None:
        pu, fiat = pu_convert(amount, unit_amount, rate, currency, profile == "corrected")
        mf = {"amount_cents": int(fiat["amount_cents"]), "precise_amount_cents": q15(fiat["precise_amount_cents"]),
              "unit_amount_cents": trunc(fiat["unit_amount_cents"]), "precise_unit_amount": q15(fiat["precise_unit_amount"])}
        out["pricing_unit_usage"] = {"amount_cents": int(pu["amount_cents"]),
                                     "precise_amount_cents": pu["precise_amount_cents"],
                                     "unit_amount_cents": int(pu["unit_amount_cents"]),
                                     "precise_unit_amount": pu["precise_unit_amount"],
                                     "conversion_rate": q15(D(rate))}
    else:
        mf = money_fields(amount, unit_amount, currency)
    out.update(mf)
    out["units"] = stored
    out["total_aggregated_units"] = total_agg
    out["events_count"] = events
    out["persisted"] = bool(context == "recurring" or stored != 0 or mf["amount_cents"] != 0 or events != 0)
    if not invoiceable:
        out["pay_in_advance"] = pia
    return out
