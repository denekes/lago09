"""Coupon creation and application to a customer (BE-IV-17, BE-IV-18)."""
from __future__ import annotations

from common import KitError, dec
from periods import parse_instant


def validate_values(c, frequency=None, duration=None, amount=None, rate=None, currency=None, mandatory_dur_field="frequency_duration"):
    """Required values per type and frequency; raises the first error."""
    ctype = c["coupon_type"]
    if ctype == "fixed_amount":
        if amount is None:
            raise KitError("value_is_mandatory", "amount_cents")
        if currency is None:
            raise KitError("value_is_mandatory", "amount_currency")
        if amount <= 0:
            raise KitError("value_is_out_of_range", "amount_cents")
    else:
        if rate is None:
            raise KitError("value_is_mandatory", "percentage_rate")
        if rate <= 0 or rate > 100:
            raise KitError("value_is_out_of_range", "percentage_rate")
    if frequency == "recurring":
        if duration is None:
            raise KitError("value_is_mandatory", mandatory_dur_field)
        if duration <= 0:
            raise KitError("value_is_out_of_range", mandatory_dur_field)


def coupon_create(inp, ctx):
    c = inp["coupon"]
    cat = inp.get("catalog", {})
    now = parse_instant(inp.get("now", "2024-03-01T10:00:00Z"))
    rate = dec(c["percentage_rate"]) if c.get("percentage_rate") is not None else None
    validate_values(c, c["frequency"], c.get("frequency_duration"), c.get("amount_cents"), rate, c.get("amount_currency"))
    if c.get("expiration", "no_expiration") == "time_limit":
        ea = c.get("expiration_at")
        if ea is None:
            raise KitError("invalid_date", "expiration_at")
        if parse_instant(ea) <= now:
            raise KitError("invalid_date", "expiration_at")
    plans, metrics = list(c.get("plan_codes", [])), list(c.get("billable_metric_codes", []))
    if plans and metrics:
        raise KitError("only_one_limitation_type_per_coupon_allowed")
    if plans and not set(plans) <= set(cat.get("plan_codes", [])):
        raise KitError("plans_not_found")
    if metrics and not set(metrics) <= set(cat.get("billable_metric_codes", [])):
        raise KitError("billable_metrics_not_found")
    return {"coupon": {
        "status": "active",
        "reusable": c.get("reusable", True),
        "limited_plans": bool(plans),
        "limited_billable_metrics": bool(metrics),
        "frequency_duration": c.get("frequency_duration") if c["frequency"] == "recurring" else c.get("frequency_duration"),
        "targets": len(set(plans)) if plans else len(set(metrics)),
    }}


def targets_overlap(a, b, plan_metrics):
    ap, am = set(a.get("plan_codes", [])), set(a.get("billable_metric_codes", []))
    bp, bm = set(b.get("plan_codes", [])), set(b.get("billable_metric_codes", []))
    if not (ap or am) or not (bp or bm):
        return False
    if ap & bp or am & bm:
        return True
    for p in ap:
        if plan_metrics.get(p, set()) & bm:
            return True
    for p in bp:
        if plan_metrics.get(p, set()) & am:
            return True
    return False


def coupon_apply(inp, ctx):
    c = inp["coupon"]
    plan_metrics = {p["code"]: set(p.get("billable_metric_codes", [])) for p in inp.get("plans", [])}
    if c.get("status", "active") != "active":
        raise KitError("coupon_not_found")
    before = inp.get("applied_before", [])
    if not c.get("reusable", True) and any("coupon" not in b for b in before):
        raise KitError("coupon_is_not_reusable", "coupon")
    for b in before:
        if "coupon" in b and b.get("status", "active") == "active":
            if targets_overlap(c, b["coupon"], plan_metrics):
                raise KitError("plan_overlapping")
    o = inp.get("overrides", {})
    amount = o.get("amount_cents", c.get("amount_cents"))
    currency = o.get("amount_currency", c.get("amount_currency"))
    rate = dec(o["percentage_rate"]) if o.get("percentage_rate") is not None else (
        dec(c["percentage_rate"]) if c.get("percentage_rate") is not None else None)
    freq = o.get("frequency", c["frequency"])
    dur = o.get("frequency_duration", c.get("frequency_duration"))
    validate_values(c, freq, dur, amount, rate, currency)
    cc = inp.get("customer_currency", "EUR")
    if c["coupon_type"] == "fixed_amount" and cc is None:
        cc = currency
    fixed = c["coupon_type"] == "fixed_amount"
    return {
        "applied_coupon": {
            "status": "active",
            "amount_cents": amount if fixed else None,
            "amount_currency": currency if fixed else None,
            "percentage_rate": rate if not fixed else None,
            "frequency": freq,
            "frequency_duration": dur if freq == "recurring" else None,
            "frequency_duration_remaining": dur if freq == "recurring" else None,
        },
        "customer_currency": cc,
    }


HANDLERS = {"invoice.coupon_create": coupon_create, "invoice.coupon_apply": coupon_apply}
