"""Op handlers of the pricing area."""
from __future__ import annotations

import re
from datetime import datetime, timedelta, timezone, date
from decimal import Decimal, ROUND_HALF_UP
from zoneinfo import ZoneInfo

from pricing_core import (
    D, ZERO, ONE, HUNDRED, OpError, Agg, Ctx, Result, div, safe_div, round_half_away, trunc, ds, fmt,
    float_to_dec, dec_to_float, q15, exponent, subunit, money_fields, fee_money, pu_convert, price_bucket,
    price_grouped, group_keys, project_units, blank, MODELS, _clamp_tx,
)
import validation

# --------------------------------------------------------------------------- time

_INST = re.compile(r"^(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:?\d{2})?$")


def parse_instant(s) -> datetime:
    m = _INST.match(s.strip())
    if not m:
        raise OpError("bad_input", message=f"bad instant {s!r}")
    d, t, frac, z = m.groups()
    frac = (frac or "")[:6].ljust(6, "0")
    z = z or "Z"
    if z == "Z":
        tz = "+00:00"
    else:
        tz = z if ":" in z else z[:3] + ":" + z[3:]
    return datetime.fromisoformat(f"{d}T{t}.{frac}{tz}")


def tzinfo(name):
    try:
        return ZoneInfo(name or "UTC")
    except Exception:
        raise OpError("bad_input", "timezone", f"unknown time zone {name}")


def days_between(frm: datetime, to: datetime, tz: str, upgraded=False) -> int:
    z = tzinfo(tz)
    f = frm.astimezone(z)
    t = to.astimezone(z)
    if t.hour == 0 and t.minute == 0 and t.second == 0 and t.microsecond == 0:
        t = t + timedelta(seconds=1)
    delta = (t.replace(tzinfo=None) - f.replace(tzinfo=None))
    secs = Decimal(delta.days * 86400 + delta.seconds) + Decimal(delta.microseconds) / Decimal(1000000)
    n = int((secs / Decimal(86400)).to_integral_value(rounding="ROUND_CEILING"))
    if upgraded:
        n = max(n - 1, 0)
    return n


# --------------------------------------------------------------------------- helpers

def ctx_of(inp, profile, **kw):
    return Ctx(currency=inp.get("currency", "EUR"), prorated=inp.get("prorated", False),
               premium=inp.get("premium", False), profile=profile, **kw)


def jd(x):
    """Serialisable copy: decimals kept (the encoder renders them)."""
    return x


# --------------------------------------------------------------------------- charge_model

def op_charge_model(inp, profile):
    model = inp["model"]
    props = inp.get("properties") or {}
    ctx = Ctx(currency=inp.get("currency", "EUR"), prorated=inp.get("prorated", False),
              premium=inp.get("premium", False), profile=profile,
              period_ratio=inp.get("period_ratio", "1"), project=inp.get("calculate_projected_usage", False),
              flags=inp.get("flags") or {})
    res, agg, groups = price_grouped(model, props, inp["aggregation"], ctx)
    out = {"amount": res.amount, "unit_amount": res.unit_amount,
           "units": getattr(res, "units_override", agg.units)}
    if groups is None:
        out["amount_details"] = res.details
        if agg.fu is not None:
            out["full_units_number"] = agg.fu
        if agg.cur is not None:
            out["current_usage_units"] = agg.cur
        if agg.tot is not None:
            out["total_aggregated_units"] = agg.tot
        out["count"] = agg.count
    else:
        out["groups"] = [{"grouped_by": gb, "units": ga.units, "amount": gr.amount, "unit_amount": gr.unit_amount,
                          "amount_details": gr.details} for gb, ga, gr in groups]
    if ctx.project:
        out["projected_units"] = res.projected_units
        out["projected_amount"] = res.projected_amount
    return out


# --------------------------------------------------------------------------- pay in advance

def _adv_run(model, props, base: Agg, ctx, units, count, precise, pev, flags):
    c = Ctx(currency=ctx.currency, prorated=False, premium=ctx.premium, profile=ctx.profile, flags=flags)
    agg = base.copy(units=units, count=count, precise_total=precise, pev=pev, fu=None)
    return price_bucket(model, props, agg, c)


def _dd(x):
    return D(x) if isinstance(x, str) else x


def _pct_details(w, wo):
    a, b = w.details, wo.details
    g = lambda d, k: D(d[k])
    units = g(a, "units") - g(b, "units")
    paid_units = g(a, "paid_units") - g(b, "paid_units")
    det = {"units": ds(units), "paid_units": ds(paid_units), "free_units": ds(units - paid_units)}
    for k in ("free_events", "paid_events", "fixed_fee_total_amount", "min_max_adjustment_total_amount",
              "per_unit_total_amount"):
        det[k] = ds(g(a, k) - g(b, k))
    det["rate"] = a["rate"]
    det["fixed_fee_unit_amount"] = a["fixed_fee_unit_amount"]
    return det


def _gp_details(w, wo, corrected):
    prev = wo.details.get("graduated_percentage_ranges", [])
    out = []
    for r in w.details.get("graduated_percentage_ranges", []):
        m = next((p for p in prev if D(p["from_value"]) == D(r["from_value"]) and
                  ((p["to_value"] is None and r["to_value"] is None) or
                   (p["to_value"] is not None and r["to_value"] is not None and D(p["to_value"]) == D(r["to_value"])))), None)
        z = {"flat_unit_amount": "0", "units": "0", "total_with_flat_amount": "0", "per_unit_total_amount": "0"}
        m = m or z
        du = D(r["units"]) - D(m["units"])
        df = D(r["flat_unit_amount"]) - D(m["flat_unit_amount"])
        dt = D(r["total_with_flat_amount"]) - D(m["total_with_flat_amount"])
        if corrected:
            put = D(r["per_unit_total_amount"]) - D(m["per_unit_total_amount"])
        else:
            put = round_half_away(div(dt, du), 2) if du > 0 else ZERO
        out.append({"from_value": r["from_value"], "to_value": r["to_value"], "flat_unit_amount": ds(df),
                    "rate": r["rate"], "units": ds(du), "per_unit_total_amount": ds(put), "total_with_flat_amount": ds(dt)})
    return {"graduated_percentage_ranges": out}


def op_pay_in_advance(inp, profile):
    if inp.get("pay_in_advance", True) is False:
        raise OpError("apply_charge_model_error", message="charge is not pay in advance")
    model = inp["model"]
    if model == "volume":
        raise OpError("charge_model_error", message="volume has no in-advance algorithm")
    props = inp.get("properties") or {}
    ctx = ctx_of(inp, profile)
    ad = inp["aggregation"]
    base = Agg(ad)
    persisted = inp.get("persisted", True)
    a = base.event_units if base.event_units is not None else ZERO
    p = base.event_precise if base.event_precise is not None else ZERO
    if persisted:
        pev = base.pev
        w = _adv_run(model, props, base, ctx, base.units, base.count, base.precise_total, pev, {})
        wo = _adv_run(model, props, base, ctx, base.units - a, base.count - 1,
                      None if base.precise_total is None else base.precise_total - p,
                      None if pev is None else pev[:-1], {"exclude_event": True})
    else:
        pev = base.pev
        ev = base.event_value if base.event_value is not None else a
        w = _adv_run(model, props, base, ctx, base.units + a, base.count + 1,
                     None if base.precise_total is None else base.precise_total + p,
                     (list(pev) + [ev]) if pev is not None else None, {})
        wo = _adv_run(model, props, base, ctx, base.units, base.count, base.precise_total, pev, {})
    delta = w.amount - wo.amount
    e, s = exponent(ctx.currency), subunit(ctx.currency)
    rounded = round_half_away(delta, e)
    # units shown
    ch = base.cached
    shown = a
    if ch and all(ch.get(k) is not None for k in ("current_aggregation", "max_aggregation", "units_applied")) \
            and D(ch["current_aggregation"]) <= D(ch["max_aggregation"]):
        shown = max(D(ch["units_applied"]), ZERO)
    elif inp.get("prorated") and base.fu is not None:
        shown = base.fu
    unit_amount = ZERO if rounded == 0 else safe_div(rounded, shown)
    amount_cents = int(rounded * s)
    out = {}
    rate = inp.get("pricing_unit_conversion_rate")
    if rate is not None:
        if ctx.corrected:
            A, u = delta, safe_div(delta, shown)
        else:
            A, u = Decimal(amount_cents) / 100, unit_amount
        pu, fiat = pu_convert(A, u, rate, ctx.currency, ctx.corrected)
        out.update({"amount_cents": int(fiat["amount_cents"]), "precise_amount_cents": q15(fiat["precise_amount_cents"]),
                    "unit_amount_cents": trunc(fiat["unit_amount_cents"]),
                    "precise_unit_amount": q15(fiat["precise_unit_amount"])})
        out["pricing_unit_usage"] = {"amount_cents": int(pu["amount_cents"]),
                                     "precise_amount_cents": pu["precise_amount_cents"],
                                     "unit_amount_cents": int(pu["unit_amount_cents"]),
                                     "precise_unit_amount": pu["precise_unit_amount"], "conversion_rate": D(rate)}
    else:
        out.update({"amount_cents": amount_cents, "precise_amount_cents": q15(delta * s),
                    "unit_amount_cents": trunc(unit_amount * s), "precise_unit_amount": q15(unit_amount)})
    out["units"] = shown
    if persisted:
        out["total_aggregated_units"] = shown
        out["events_count"] = 1
        out["pay_in_advance"] = True
        if model == "percentage":
            out["amount_details"] = _pct_details(w, wo)
        elif model == "graduated_percentage":
            out["amount_details"] = _gp_details(w, wo, ctx.corrected)
        else:
            out["amount_details"] = {}
    return out


# --------------------------------------------------------------------------- fee_money / pricing_unit / true_up

def op_fee_money(inp, profile):
    return fee_money(inp, profile)


def op_pricing_unit(inp, profile):
    # a shipped `both` vector (pricing_unit.006) pins the double rounding in the corrected profile too (KIT-GAPS)
    pu, fiat = pu_convert(D(inp["amount"]), D(inp["unit_amount"]), inp["conversion_rate"],
                          inp.get("currency", "EUR"), False)
    pu = dict(pu, amount_cents=int(pu["amount_cents"]), unit_amount_cents=int(pu["unit_amount_cents"]))
    return {"pricing_unit_usage": pu, "fiat": fiat}


def op_true_up(inp, profile):
    mn = D(inp["min_amount_cents"])
    used = D(inp["used_amount_cents"])
    used_p = D(inp["used_precise_amount_cents"])
    currency = inp.get("currency", "EUR")
    s = subunit(currency)
    duration = int(inp["charges_duration_days"])
    days = days_between(parse_instant(inp["charges_from"]), parse_instant(inp["charges_to"]),
                        inp.get("timezone") or "UTC", bool(inp.get("terminated_upgraded", False)))
    rate = inp.get("pricing_unit_conversion_rate")
    if profile == "corrected":
        pmin = safe_div(mn * days, duration)
        no_fee = used >= pmin
        diff = pmin - used
        precise = pmin - used_p
    else:
        fmin = float(mn) / duration * days
        no_fee = float(used) >= fmin
        pmin_dec = float_to_dec(fmin)
        diff = Decimal(fmin - float(used))
        precise = pmin_dec - used_p
        pmin = pmin_dec
        diff_for_cents = diff
    if no_fee:
        return {"fee": None}
    if profile != "corrected":
        diff = float_to_dec(fmin - float(used))
        amount_cents = int(round_half_away(Decimal(fmin - float(used)), 0))
    else:
        amount_cents = int(round_half_away(diff, 0))
    fee = {"units": ONE, "total_aggregated_units": ONE, "events_count": 0}
    if rate is not None:
        A = diff / 100
        u = precise / 100
        pu, fiat = pu_convert(A, u, rate, currency, profile == "corrected")
        fee.update({"amount_cents": int(fiat["amount_cents"]), "precise_amount_cents": q15(fiat["precise_amount_cents"]),
                    "unit_amount_cents": trunc(fiat["unit_amount_cents"]),
                    "precise_unit_amount": q15(fiat["precise_unit_amount"]),
                    "pricing_unit_usage": {"amount_cents": int(pu["amount_cents"]),
                                           "precise_amount_cents": pu["precise_amount_cents"],
                                           "unit_amount_cents": int(pu["unit_amount_cents"]),
                                           "precise_unit_amount": pu["precise_unit_amount"],
                                           "conversion_rate": D(rate)}})
    else:
        fee.update({"amount_cents": amount_cents, "precise_amount_cents": q15(precise),
                    "unit_amount_cents": amount_cents, "precise_unit_amount": q15(precise / s)})
    return {"fee": fee}


# --------------------------------------------------------------------------- fixed charges

def _local_date(dt: datetime, tz):
    return dt.astimezone(tz).date()


def fixed_units(inp, profile):
    prorated = bool(inp.get("prorated", False))
    tz = tzinfo(inp.get("timezone") or "UTC")
    w = inp["window"]
    frm, to = parse_instant(w["from"]), parse_instant(w["to"])
    duration = int(w["duration_days"])
    evs = [(int(e["created_seq"]), parse_instant(e["timestamp"]), D(e["units"])) for e in inp.get("events", [])]
    inside = [e for e in evs if frm <= e[1] < to]
    before = [e for e in evs if e[1] < frm]
    if before:
        inside.append(max(before, key=lambda e: e[0]))
    inside.sort(key=lambda e: e[0])
    if not inside:
        return ZERO, ZERO, [], []
    fu = inside[-1][2]
    if not prorated:
        return fu, fu, None, None
    kept = [e for e in inside if not any(o[0] > e[0] and o[1] < e[1] for o in inside)]
    total = ZERO
    for i, (seq, ts, units) in enumerate(kept):
        start = _local_date(max(ts, frm), tz)
        if i + 1 < len(kept):
            end = _local_date(max(kept[i + 1][1], frm), tz)
        else:
            end = _local_date(to + timedelta(days=1), tz)
        days = (end - start).days
        contrib = round_half_away(div(Decimal(days) * units, Decimal(duration)), 6)
        total += max(ZERO, contrib)
    return total, fu, [fu], [total]


def op_fixed_charge_units(inp, profile):
    units, fu, full, pro = fixed_units(inp, profile)
    out = {"units": units, "full_units_number": fu}
    if full is not None:
        out["per_event_full"] = full
        out["per_event_prorated"] = pro
    return out


def op_fixed_charge_fee(inp, profile):
    model = inp["model"]
    props = inp.get("properties") or {}
    prorated = bool(inp.get("prorated", False))
    currency = inp.get("currency", "EUR")
    units, fu, full, pro = fixed_units(inp, profile)
    ctx = Ctx(currency=currency, prorated=prorated, premium=True, profile=profile)
    agg = {"units": units, "full_units_number": fu, "count": 0}
    if full is not None:
        agg["per_event_full"] = full
        agg["per_event_prorated"] = pro
    elif prorated and model == "graduated":
        agg["per_event_full"] = [fu] if fu != 0 else []
        agg["per_event_prorated"] = [units] if fu != 0 else []
    res = price_bucket(model, props, Agg(agg), ctx)
    amount, unit_amount, stored, tot = res.amount, res.unit_amount, fu, fu
    if units < 0 or amount < 0:
        amount = unit_amount = stored = tot = ZERO
    mf = money_fields(amount, unit_amount, currency)
    out = dict(mf)
    out["units"] = stored
    out["total_aggregated_units"] = tot
    out["events_count"] = 0
    out["amount_details"] = res.details
    out["persisted"] = bool(stored != 0 or mf["amount_cents"] != 0)
    return out


def op_fixed_charge_in_advance(inp, profile):
    model = inp["model"]
    props = inp.get("properties") or {}
    prorated = bool(inp.get("prorated", False))
    currency = inp.get("currency", "EUR")
    delta = D(inp["new_units"]) - D(inp["already_billed_units"])
    e, s = exponent(currency), subunit(currency)
    if delta <= 0:
        return {"amount_cents": 0, "precise_amount_cents": ZERO, "unit_amount_cents": 0,
                "precise_unit_amount": ZERO, "units": ZERO, "total_aggregated_units": ZERO, "events_count": 0}
    units = delta
    if prorated:
        duration = int(inp["fixed_charges_duration_days"])
        ts, to = parse_instant(inp["timestamp"]), parse_instant(inp["fixed_charges_to"])
        if profile == "corrected":
            tz = tzinfo(inp.get("timezone") or "UTC")
            n = (_local_date(to, tz) - _local_date(ts, tz)).days + 1
            coef = div(Decimal(n), Decimal(duration))
        else:
            n = (to.astimezone(timezone.utc).date() - ts.astimezone(timezone.utc).date()).days + 1
            coef = float_to_dec(n / duration)
        units = delta * coef
    ctx = Ctx(currency=currency, prorated=False, premium=True, profile=profile)
    res = price_bucket(model, props, Agg({"units": units, "count": 0}), ctx)
    amount = res.amount
    cents = int(round_half_away(amount, e) * s)
    return {"amount_cents": cents, "precise_amount_cents": q15(amount * s),
            "unit_amount_cents": int(round_half_away(Decimal(cents) / delta, 0)),
            "precise_unit_amount": q15(amount / delta), "units": delta, "total_aggregated_units": delta,
            "events_count": 0}


# --------------------------------------------------------------------------- projection / estimate / simulate

def op_projection(inp, profile):
    model = inp["model"]
    props = inp.get("properties") or {}
    currency = inp.get("currency", "EUR")
    tz = inp.get("timezone") or "UTC"
    frm, to, now = parse_instant(inp["from"]), parse_instant(inp["to"]), parse_instant(inp["now"])
    duration = int(inp["charges_duration_days"])
    if now >= to:
        rho = ONE
    elif now < frm:
        rho = ZERO
    else:
        rho = div(Decimal(days_between(frm, now, tz)), Decimal(duration))
        rho = min(max(rho, ZERO), ONE)
    e, s = exponent(currency), subunit(currency)
    if inp.get("recurring"):
        cur = inp.get("current") or {"amount_cents": 0, "units": "0"}
        return {"period_ratio": rho, "projected_units": D(cur.get("units", 0)),
                "projected_amount_cents": D(cur.get("amount_cents", 0))}
    ctx = Ctx(currency=currency, prorated=inp.get("prorated", False), premium=inp.get("premium", False),
              profile=profile, period_ratio=rho, project=True)
    if rho <= 0:
        return {"period_ratio": rho, "projected_units": ZERO, "projected_amount_cents": ZERO}
    res, agg, groups = price_grouped(model, props, inp["aggregation"], ctx)
    pu = res.projected_units if res.projected_units is not None else ZERO
    pa = res.projected_amount if res.projected_amount is not None else ZERO
    cents = ZERO if pa < 0 else round_half_away(pa, e) * s
    return {"period_ratio": rho, "projected_units": max(pu, ZERO), "projected_amount_cents": cents}


def op_estimate_instant(inp, profile):
    model = inp["model"]
    props = inp.get("properties") or {}
    currency = inp.get("currency", "EUR")
    metric = inp.get("metric")
    if metric is None:
        metric = {"field_name": "value"}
    field = metric.get("field_name", "value") if "field_name" in metric else "value"
    evp = inp.get("event_properties") or {}
    if field is None:
        units = ONE
    else:
        v = evp.get(field)
        units = D(v) if v is not None else ZERO
    fn = metric.get("rounding_function")
    if fn:
        prec = int(metric.get("rounding_precision") or 0)
        q = Decimal(1).scaleb(-prec)
        mode = {"round": "ROUND_HALF_UP", "ceil": "ROUND_CEILING", "floor": "ROUND_FLOOR"}[fn]
        units = units.quantize(q, rounding=mode) if prec >= 0 else (units / (10 ** -prec)).quantize(Decimal(1), rounding=mode) * (10 ** -prec)
    if units < 0:
        amount = ZERO
    elif model == "standard":
        amount = units * D(props.get("amount"))
    elif model == "percentage":
        f = D(props.get("fixed_amount")) if not blank(props.get("fixed_amount")) else ZERO
        amount = units * D(props.get("rate")) / HUNDRED + f
        amount = _clamp_tx(amount, props.get("per_transaction_min_amount"), props.get("per_transaction_max_amount"))
    else:
        raise OpError("bad_input", "model", "only standard and percentage are estimated")
    e, s = exponent(currency), subunit(currency)
    rounded = round_half_away(amount, e)
    unit_minor = ZERO if (rounded == 0 or units == 0) else rounded / units * s
    return {"amount_cents": rounded * s, "precise_amount": amount, "units": units,
            "precise_unit_amount": unit_minor, "events_count": 1}


def op_simulate(inp, profile):
    model = inp["model"]
    props = inp.get("properties") or {}
    currency = inp.get("currency", "EUR")
    if not props:
        props = validation.default_properties(model) or {}
    props = validation.filter_properties(model, props, "charge", inp.get("metric_aggregation_type"))
    n = D(inp["units"])
    ctx = Ctx(currency=currency, premium=inp.get("premium", False), profile=profile)
    agg = {"units": n, "full_units_number": n, "current_usage_units": n, "total_aggregated_units": n,
           "count": 10, "running_total": []}
    res = price_bucket(model, props, Agg(agg), ctx)
    plan = D(inp.get("plan_amount_cents", 0))
    if profile == "corrected":
        e, s = exponent(currency), subunit(currency)
        charge = round_half_away(res.amount, e) * s
    else:
        charge = res.amount
    return {"charge_amount_cents": charge, "subscription_amount_cents": plan, "total_amount_cents": charge + plan}


# --------------------------------------------------------------------------- validation ops

def op_validate_properties(inp, profile):
    errs = validation.validate_properties(inp["model"], inp["properties"], inp.get("kind", "charge"),
                                          inp.get("metric_aggregation_type"), bool(inp.get("premium", False)))
    out = {"valid": not errs.fields}
    if errs.fields:
        out["errors"] = errs.fields
        out["property_messages"] = errs.messages
    return out


def op_validate_charge(inp, profile):
    return validation.validate_charge(inp)


def op_default_properties(inp, profile):
    return {"properties": validation.default_properties(inp["model"])}


def op_filter_properties(inp, profile):
    return {"properties": validation.filter_properties(inp["model"], inp["properties"], inp.get("kind", "charge"),
                                                       inp.get("metric_aggregation_type"))}


OPS = {
    "pricing.charge_model": op_charge_model,
    "pricing.pay_in_advance": op_pay_in_advance,
    "pricing.fee_money": op_fee_money,
    "pricing.pricing_unit": op_pricing_unit,
    "pricing.true_up": op_true_up,
    "pricing.fixed_charge_units": op_fixed_charge_units,
    "pricing.fixed_charge_fee": op_fixed_charge_fee,
    "pricing.fixed_charge_in_advance": op_fixed_charge_in_advance,
    "pricing.projection": op_projection,
    "pricing.estimate_instant": op_estimate_instant,
    "pricing.simulate": op_simulate,
    "pricing.validate_properties": op_validate_properties,
    "pricing.validate_charge": op_validate_charge,
    "pricing.default_properties": op_default_properties,
    "pricing.filter_properties": op_filter_properties,
}
