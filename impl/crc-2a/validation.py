"""Property and charge validation, defaults and slicing (BE-PR-73..82)."""
from __future__ import annotations

import json
import re
from decimal import Decimal

from pricing_core import D, blank, OpError

_DEC_RE = re.compile(
    r"^\s*([+-]?)(?:(\d+(?:_\d+)*_?)(\.(?:\d+(?:_\d+)*_?)?)?|(\.\d+(?:_\d+)*_?))(?:[eEdD]([+-]?\d+))?\s*$"
)

MODELS = ("standard", "graduated", "graduated_percentage", "package", "percentage", "volume", "dynamic", "custom")


def parse_decimal(x):
    """Permissive decimal reader of BE-PR-73; returns a Decimal >= 0 or None when rejected."""
    if not isinstance(x, str):
        return None
    m = _DEC_RE.match(x)
    if not m:
        return None
    sign, ipart, fpart, fonly, exp = m.groups()
    ip = (ipart or "").replace("_", "")
    fp = ((fpart or fonly or "")[1:]).replace("_", "")
    if not ip and not fp:
        return None
    try:
        v = Decimal(f"{ip or '0'}.{fp or '0'}" + (f"e{exp}" if exp else ""))
    except Exception:
        return None
    if sign == "-" and v != 0:
        return -v
    return v


def valid_decimal(x):
    v = parse_decimal(x)
    return v is not None and v >= 0


def is_json_int(x):
    return isinstance(x, int) and not isinstance(x, bool)


def is_json_num(x):
    return (isinstance(x, (int, Decimal))) and not isinstance(x, bool)


class Errors:
    def __init__(self):
        self.fields = {}
        self.messages = []

    def add(self, field, code):
        codes = self.fields.setdefault(field, [])
        if code not in codes:
            codes.append(code)
        self.messages.append(code)


def _group_keys(props, errs):
    pk = props.get("pricing_group_keys")
    key = "pricing_group_keys" if "pricing_group_keys" in props and pk is not None else None
    if key is None:
        if "pricing_group_keys" in props:
            key = "pricing_group_keys"
        elif "grouped_by" in props:
            key = "grouped_by"
    if key is not None:
        v = props.get(key)
        ok = v is None or (isinstance(v, list) and all(isinstance(i, str) and i != "" for i in v))
        if not ok:
            errs.add(key, "invalid_type")
    pg = props.get("presentation_group_keys")
    if not blank(pg) and pg != [] and pg != {}:
        ok = isinstance(pg, list) and all(
            isinstance(e, dict) and set(e) <= {"value", "options"} and isinstance(e.get("value"), str) and e.get("value") != ""
            and (e.get("options") is None or (isinstance(e["options"], dict) and set(e["options"]) <= {"display_in_invoice"}
                                              and all(isinstance(v, bool) for v in e["options"].values())))
            for e in pg)
        if not ok:
            errs.add("presentation_group_keys", "invalid_type")
        elif len(pg) > 2:
            errs.add("presentation_group_keys", "too_many_keys")
        elif len({e["value"] for e in pg}) != len(pg):
            errs.add("presentation_group_keys", "value_is_duplicated")


def _ranges(props, key, errs, kind, percentage=False, latest=False):
    ranges = props.get(key)
    if not isinstance(ranges, list) or len(ranges) == 0:
        errs.add(key, f"missing_{key}")
        return
    if percentage and latest:
        errs.add("billable_metric", "invalid_value")
    for r in ranges:
        if not isinstance(r, dict):
            continue
        if percentage:
            if not valid_decimal(r.get("flat_amount")):
                errs.add("flat_amount", "invalid_amount")
            if not valid_decimal(r.get("rate")):
                errs.add("rate", "invalid_rate")
        else:
            if not valid_decimal(r.get("per_unit_amount")):
                errs.add("per_unit_amount", "invalid_amount")
            if not valid_decimal(r.get("flat_amount")):
                errs.add("flat_amount", "invalid_amount")
    # bounds
    nxt = Decimal(0)
    ok = True
    last = len(ranges) - 1
    for i, r in enumerate(ranges):
        if not isinstance(r, dict):
            ok = False
            break
        fv = r.get("from_value")
        tv = r.get("to_value")
        if not is_json_num(fv):
            ok = False
            break
        fv = D(fv)
        if fv != nxt and fv != nxt + 1:
            ok = False
            break
        if i != last:
            if not is_json_num(tv) or not D(tv) > fv:
                ok = False
                break
            nxt = D(tv) if key != "volume_ranges" else D(tv) + 1
        else:
            if tv is not None:
                ok = False
                break
    if not ok:
        errs.add(key, f"invalid_{key}")


def validate_properties(model, props, kind="charge", metric_agg=None, premium=False):
    errs = Errors()
    if not isinstance(props, dict):
        props = {}
    latest = metric_agg == "latest_agg"
    if model == "standard":
        if not valid_decimal(props.get("amount")):
            errs.add("amount", "invalid_amount")
    elif model == "package":
        if not valid_decimal(props.get("amount")):
            errs.add("amount", "invalid_amount")
        ps = props.get("package_size")
        if not (is_json_int(ps) and ps > 0):
            errs.add("package_size", "invalid_package_size")
        fu = props.get("free_units")
        if not (is_json_int(fu) and fu >= 0):
            errs.add("free_units", "invalid_free_units")
    elif model == "percentage":
        if latest:
            errs.add("billable_metric", "invalid_value")
        if not valid_decimal(props.get("rate")):
            errs.add("rate", "invalid_rate")
        if props.get("fixed_amount") is not None and not valid_decimal(props.get("fixed_amount")):
            errs.add("fixed_amount", "invalid_fixed_amount")
        fe = props.get("free_units_per_events")
        if fe is not None and not (is_json_int(fe) and fe > 0):
            errs.add("free_units_per_events", "invalid_free_units_per_events")
        fa = props.get("free_units_per_total_aggregation")
        if fa is not None and not valid_decimal(fa):
            errs.add("free_units_per_total_aggregation", "invalid_free_units_per_total_aggregation")
        if premium:
            mn = props.get("per_transaction_min_amount")
            mx = props.get("per_transaction_max_amount")
            for k, v in (("per_transaction_min_amount", mn), ("per_transaction_max_amount", mx)):
                if not blank(v) and not valid_decimal(v):
                    errs.add(k, "invalid_amount")
            if not blank(mn) and not blank(mx) and valid_decimal(mn) and valid_decimal(mx):
                if parse_decimal(mx) < parse_decimal(mn):
                    errs.add("per_transaction_max_amount", "per_transaction_max_lower_than_per_transaction_min")
    elif model == "graduated":
        _ranges(props, "graduated_ranges", errs, kind)
    elif model == "volume":
        _ranges(props, "volume_ranges", errs, kind)
    elif model == "graduated_percentage":
        _ranges(props, "graduated_percentage_ranges", errs, kind, percentage=True, latest=latest)
    _group_keys(props, errs)
    return errs


def default_properties(model):
    rng = {"from_value": 0, "to_value": None, "per_unit_amount": "0", "flat_amount": "0"}
    if model == "standard":
        return {"amount": "0"}
    if model in ("graduated",):
        return {"graduated_ranges": [dict(rng)]}
    if model == "volume":
        return {"volume_ranges": [dict(rng)]}
    if model == "package":
        return {"package_size": 1, "amount": "0", "free_units": 0}
    if model == "percentage":
        return {"rate": "0"}
    if model == "graduated_percentage":
        return {"graduated_percentage_ranges": [{"from_value": 0, "to_value": None, "rate": "0",
                                                  "fixed_amount": "0", "flat_amount": "0"}]}
    if model == "dynamic":
        return {}
    if model == "custom":
        return None
    raise OpError("bad_input", "model", f"unknown model {model}")


MODEL_KEYS = {
    "standard": ["amount"],
    "graduated": ["graduated_ranges"],
    "volume": ["volume_ranges"],
    "graduated_percentage": ["graduated_percentage_ranges"],
    "package": ["amount", "free_units", "package_size"],
    "percentage": ["rate", "fixed_amount", "free_units_per_events", "free_units_per_total_aggregation",
                   "per_transaction_min_amount", "per_transaction_max_amount"],
    "dynamic": [],
    "custom": [],
}


def filter_properties(model, props, kind="charge", metric_agg=None):
    props = props if isinstance(props, dict) else {}
    out = {}
    keys = MODEL_KEYS.get(model, [])
    if kind == "fixed_charge":
        keys = [k for k in keys if k in ("amount", "graduated_ranges", "volume_ranges")]
    for k in keys:
        if k in props:
            out[k] = props[k]
    pgk = props.get("pricing_group_keys")
    if blank(pgk) or pgk == []:
        pgk = props.get("grouped_by")
    if isinstance(pgk, list):
        pgk = [x for x in pgk if not blank(x)]
    if not blank(pgk) and pgk != []:
        out["pricing_group_keys"] = pgk
    pg = props.get("presentation_group_keys")
    if not blank(pg) and pg != [] and pg != {}:
        out["presentation_group_keys"] = pg
    if metric_agg == "custom_agg" and kind != "fixed_charge" and "custom_properties" in props:
        cp = props["custom_properties"]
        if isinstance(cp, str):
            try:
                cp = json.loads(cp)
            except Exception:
                cp = {}
            if not isinstance(cp, (dict, list)):
                cp = {}
        out["custom_properties"] = cp
    return out


def validate_charge(inp):
    model = inp["model"]
    kind = inp.get("kind", "charge")
    metric = inp.get("metric") or {"aggregation_type": "sum_agg", "recurring": False}
    agg_type = metric.get("aggregation_type", "sum_agg")
    recurring = bool(metric.get("recurring", False))
    pia = bool(inp.get("pay_in_advance", False))
    prorated = bool(inp.get("prorated", False))
    premium = bool(inp.get("premium", False))
    errs = Errors()
    if kind == "fixed_charge":
        if model not in ("standard", "graduated", "volume"):
            errs.add("charge_model", "value_is_invalid")
        else:
            if model == "volume" and pia:
                errs.add("pay_in_advance", "invalid_charge_model")
            if model == "graduated" and pia and prorated:
                errs.add("prorated", "invalid_charge_model")
            units = inp.get("units")
            if units is not None and D(units) < 0:
                errs.add("units", "value_is_out_of_range")
    else:
        if model not in MODELS:
            errs.add("charge_model", "value_is_invalid")
        else:
            if pia and (model == "volume" or agg_type not in ("count_agg", "sum_agg", "unique_count_agg", "custom_agg")):
                errs.add("pay_in_advance", "invalid_aggregation_type_or_charge_model")
            if not inp.get("invoiceable", True) and not pia:
                errs.add("invoiceable", "must_be_true_unless_pay_in_advance")
            if inp.get("regroup_paid_fees") is not None and not (pia and not inp.get("invoiceable", True)):
                errs.add("regroup_paid_fees", "only_compatible_with_pay_in_advance_and_non_invoiceable")
            mn = inp.get("min_amount_cents")
            if mn is not None:
                if pia and D(mn) != 0:
                    errs.add("min_amount_cents", "not_compatible_with_pay_in_advance")
                elif D(mn) < 0:
                    errs.add("min_amount_cents", "value_is_out_of_range")
            if prorated:
                ok = recurring and agg_type != "weighted_sum_agg" and (
                    (pia and model == "standard") or (not pia and model in ("standard", "volume", "graduated")))
                if not ok:
                    errs.add("prorated", "invalid_billable_metric_or_charge_model")
            if model == "dynamic" and agg_type != "sum_agg":
                errs.add("charge_model", "invalid_aggregation_type_or_charge_model")
            if model == "custom" and agg_type != "custom_agg":
                errs.add("charge_model", "invalid_aggregation_type_or_charge_model")
            if model == "graduated_percentage" and not premium:
                errs.add("charge_model", "graduated_percentage_requires_premium_license")
    if inp.get("properties") is not None and model in MODELS:
        pe = validate_properties(model, inp["properties"], kind, agg_type, premium)
        for c in pe.messages:
            errs.add("properties", c)
    out = {"valid": not errs.fields}
    if errs.fields:
        out["errors"] = errs.fields
    return out
