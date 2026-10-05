"""Coupon creation and application to a customer (BE-IV-17, BE-IV-18)."""
from __future__ import annotations

from common import CURRENCIES, KitError, dec
from periods import parse_instant


def check_amount(amount, minimum_exclusive=True):
    if amount is not None and (amount <= 0 if minimum_exclusive else amount < 0):
        raise KitError("value_is_out_of_range", "amount_cents")


def check_currency(currency):
    if currency is not None and currency not in CURRENCIES:
        raise KitError("value_is_invalid", "amount_currency")


def check_duration(frequency, duration):
    if frequency == "recurring":
        if duration is None:
            raise KitError("value_is_mandatory", "frequency_duration")
        if duration <= 0:
            raise KitError("value_is_out_of_range", "frequency_duration")


def coupon_create(inp, ctx):
    c = inp["coupon"]
    cat = inp.get("catalog", {})
    now = parse_instant(inp.get("now", "2024-03-01T10:00:00Z"))
    ea = c.get("expiration_at")
    if ea is not None and parse_instant(ea) <= now:
        raise KitError("invalid_date", "expiration_at")
    plans, metrics = list(c.get("plan_codes", [])), list(c.get("billable_metric_codes", []))
    if plans and not set(plans) <= set(cat.get("plan_codes", [])):
        raise KitError("plans_not_found", "base")
    if metrics and not set(metrics) <= set(cat.get("billable_metric_codes", [])):
        raise KitError("billable_metrics_not_found", "base")
    if plans and metrics:
        raise KitError("only_one_limitation_type_per_coupon_allowed")
    amount, currency = c.get("amount_cents"), c.get("amount_currency")
    rate = c.get("percentage_rate")
    fixed = c["coupon_type"] == "fixed_amount"
    if fixed and amount is None:
        raise KitError("value_is_mandatory", "amount_cents")
    check_amount(amount)
    if fixed and currency is None:
        raise KitError("value_is_mandatory", "amount_currency")
    check_currency(currency)
    if not fixed and rate is None:
        raise KitError("value_is_mandatory", "percentage_rate")
    check_duration(c["frequency"], c.get("frequency_duration"))
    return {"coupon": {
        "status": "active",
        "reusable": c.get("reusable", True),
        "limited_plans": bool(plans),
        "limited_billable_metrics": bool(metrics),
        "frequency_duration": c.get("frequency_duration"),
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
        raise KitError("coupon_not_found", "base")
    before = inp.get("applied_before", [])
    for b in before:
        if b.get("status", "active") == "active":
            if targets_overlap(c, b.get("coupon", c), plan_metrics):
                raise KitError("plan_overlapping", "base")
    if not c.get("reusable", True) and any("coupon" not in b for b in before):
        raise KitError("coupon_is_not_reusable", "coupon")
    o = inp.get("overrides", {})
    amount = o.get("amount_cents", c.get("amount_cents"))
    currency = o.get("amount_currency", c.get("amount_currency"))
    rate = dec(o["percentage_rate"]) if o.get("percentage_rate") is not None else (
        dec(c["percentage_rate"]) if c.get("percentage_rate") is not None else None)
    freq = o.get("frequency", c["frequency"])
    dur = o.get("frequency_duration", c.get("frequency_duration"))
    check_amount(amount, minimum_exclusive=False)
    check_currency(currency)
    check_duration(freq, dur)
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
