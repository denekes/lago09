#!/usr/bin/env python3.12
"""Usage aggregation engine adapter (kit areas: aggregation), JSON-lines protocol v1."""
import json
import re
import sys
from datetime import datetime, timedelta, timezone, date
from decimal import Decimal, ROUND_CEILING, ROUND_FLOOR, ROUND_HALF_UP, Context, localcontext, getcontext
from functools import cmp_to_key

try:
    from zoneinfo import ZoneInfo
except Exception:  # pragma: no cover
    ZoneInfo = None

getcontext().prec = 120

EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
US = timedelta(microseconds=1)
DAY_US = 86_400_000_000
SEC_US = 1_000_000

D0 = Decimal(0)
D1 = Decimal(1)

# --------------------------------------------------------------------------- decimals


def fmt(d):
    d = Decimal(d)
    if d.is_zero():
        return "0"
    s = format(d, "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def quant(d, places, mode):
    """Round to `places` decimals (negative allowed) using mode."""
    q = Decimal(1).scaleb(-places)
    return d.quantize(q, rounding=mode)


def ceil5(d):
    return quant(d, 5, ROUND_CEILING)


def sig_quot(num, den, digits=20):
    """Decimal quotient rounded to `digits` significant digits."""
    with localcontext(Context(prec=digits)):
        return Decimal(num) / Decimal(den)


# --------------------------------------------------------------------------- time


_INSTANT = re.compile(
    r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$")


def parse_instant(s):
    """ISO instant -> integer microseconds since the epoch (sub-microsecond digits truncated)."""
    m = _INSTANT.match(s)
    if not m:
        raise ValueError("bad instant %r" % s)
    y, mo, d, h, mi, se, frac, z = m.groups()
    micro = int((frac or "0").ljust(6, "0")[:6])
    dt = datetime(int(y), int(mo), int(d), int(h), int(mi), int(se), tzinfo=timezone.utc)
    us = (dt - EPOCH) // US + micro
    if z != "Z":
        sign = 1 if z[0] == "+" else -1
        off = sign * (int(z[1:3]) * 3600 + int(z[4:6]) * 60)
        us -= off * SEC_US
    return us


def fmt_instant(us):
    dt = EPOCH + timedelta(microseconds=us)
    s = dt.strftime("%Y-%m-%dT%H:%M:%S")
    if dt.microsecond:
        s += ".%06d" % dt.microsecond
    return s + "Z"


_TZ = {}


def get_tz(name):
    name = name or "UTC"
    if name not in _TZ:
        if name == "UTC" or ZoneInfo is None:
            _TZ[name] = timezone.utc
        else:
            _TZ[name] = ZoneInfo(name)
    return _TZ[name]


def local_dt(us, tz):
    return (EPOCH + timedelta(microseconds=us)).astimezone(tz)


def local_ordinal(us, tz):
    return local_dt(us, tz).date().toordinal()


def utc_offset_us(us, tz):
    off = local_dt(us, tz).utcoffset()
    return off // US if off is not None else 0


def days_between(frm, to, tz, upgraded=False):
    """BE-DM-15..18 day count between two instants (microseconds)."""
    ld = local_dt(to, tz)
    if ld.hour == 0 and ld.minute == 0 and ld.second == 0 and ld.microsecond == 0:
        to += SEC_US
    diff = to - frm + utc_offset_us(frm, tz) - utc_offset_us(to, tz)
    days = -((-diff) // DAY_US)  # ceil
    if upgraded:
        days = max(days - 1, 0)
    return days


# --------------------------------------------------------------------------- property texts


def float_text(f):
    r = repr(f)
    if "e" in r or "n" in r:
        return r
    if "." not in r:
        r += ".0"
    return r


def ptext(props, key):
    """Relational store property text; None when absent."""
    if not isinstance(props, dict) or key not in props:
        return None
    v = props[key]
    if v is None:
        return None
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return v
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return float_text(v)
    return json.dumps(v, separators=(",", ":"))


def maptext(props, key):
    """Columnar store property-map text: '' when absent, numbers normalised."""
    if not isinstance(props, dict) or key not in props:
        return ""
    v = props[key]
    if v is None:
        return ""
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return v
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v == int(v) and abs(v) < 1e15:
            return str(int(v))
        return repr(v)
    return json.dumps(v, separators=(",", ":"))


def go_float_text(f):
    """events-processor value text for a JSON number (EP-F2)."""
    if f == 0:
        return "0"
    r = repr(float(f))
    mant, _, exp = r.partition("e")
    # shortest digits and decimal exponent
    d = Decimal(r)
    sign, digits, e = d.as_tuple()
    digits = list(digits)
    while len(digits) > 1 and digits[-1] == 0:
        digits.pop()
        e += 1
    ndig = len(digits)
    x = e + ndig - 1  # decimal exponent of the first digit
    ds = "".join(map(str, digits))
    neg = "-" if sign else ""
    if x < -4 or x >= 21 or x >= 6 and False:
        pass
    if x < -4 or x >= 6:
        m = ds[0] + ("." + ds[1:] if ndig > 1 else "")
        return "%s%se%s%02d" % (neg, m, "+" if x >= 0 else "-", abs(x))
    if x >= 0:
        if ndig <= x + 1:
            return neg + ds + "0" * (x + 1 - ndig)
        return neg + ds[: x + 1] + "." + ds[x + 1:]
    return neg + "0." + "0" * (-x - 1) + ds


def ep_value_text(props, field):
    if not isinstance(props, dict) or field not in props or props[field] is None:
        return "<nil>"
    v = props[field]
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return v
    if isinstance(v, int):
        return go_float_text(float(v)) if abs(v) >= 10 ** 6 else str(v)
    if isinstance(v, float):
        return go_float_text(v)
    return json.dumps(v, separators=(",", ":"))


GATE = re.compile(r"^-?[0-9]+(\.[0-9]+)?$")
LOOSE = re.compile(r"^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$")
TWELVE = Decimal(10) ** 12


def json_key(v):
    """JSON value equality key (a string never equals a number, 1 == 1.0)."""
    if v is None:
        return ("null",)
    if isinstance(v, bool):
        return ("bool", v)
    if isinstance(v, (int, float)):
        return ("num", Decimal(repr(v)) if isinstance(v, float) else Decimal(v))
    if isinstance(v, str):
        return ("str", v)
    return ("json", json.dumps(v, sort_keys=True))


# --------------------------------------------------------------------------- events


class Ev:
    __slots__ = ("tx", "ts", "props", "seq", "deleted", "ext", "code", "enriched", "amount", "pos")


def parse_props(e):
    if e.get("properties_json") is not None:
        return json.loads(e["properties_json"])
    p = e.get("properties")
    return p if p is not None else {}


class Ctx:
    """Evaluation context shared by the ops."""

    def __init__(self, store="pg", profile="compat", metric=None, sub=None, window=None, deduplicate=False):
        self.profile = profile
        self.ch = store == "ch"
        # corrected profile: the columnar store takes the relational semantics
        self.rel = (not self.ch) or profile == "corrected"
        self.metric = metric or {}
        self.atype = self.metric.get("aggregation_type")
        self.field = self.metric.get("field_name") or "value"
        self.recurring = bool(self.metric.get("recurring"))
        self.sub = sub or {}
        self.deduplicate = deduplicate
        self.window = window
        self.exact = profile == "corrected"


def make_events(raw, ctx, sub_ext="sub_1", code=None):
    out = []
    for i, e in enumerate(raw or [], 1):
        ev = Ev()
        ev.pos = i
        ev.tx = e.get("transaction_id", "e%d" % i)
        ts = parse_instant(e["timestamp"])
        if ctx.ch:
            ts = ts // 1000 * 1000
        ev.ts = ts
        ev.props = parse_props(e)
        ev.seq = e.get("ingest_seq", i)
        ev.deleted = bool(e.get("deleted", False))
        ev.ext = e.get("external_subscription_id", sub_ext)
        ev.code = e.get("code", code)
        ev.enriched = e.get("enriched_value")
        amt = e.get("precise_total_amount_cents")
        ev.amount = Decimal(amt) if amt is not None else D0
        out.append(ev)
    return out


def ev_value_text(ev, ctx):
    """Value text of the event for the metric field (None = absent)."""
    if ctx.ch and not ctx.rel:
        if ev.enriched is not None:
            return ev.enriched
        if ctx.atype == "count_agg":
            return "1"
        return ep_value_text(ev.props, ctx.field)
    return ptext(ev.props, ctx.field)


def ev_value(ev, ctx):
    """Numeric value (Decimal) or None when the event is dropped by the gate."""
    t = ev_value_text(ev, ctx)
    if ctx.ch and not ctx.rel:
        if t is None or not LOOSE.match(t.strip() if False else t):
            return D0
        try:
            d = Decimal(t)
        except Exception:
            return D0
        if abs(d) >= TWELVE:
            return D0
        return d
    if t is None or not GATE.match(t):
        return None
    return Decimal(t)


def prop_for_match(ev, key, ctx):
    if ctx.ch and not ctx.rel:
        return maptext(ev.props, key)
    return ptext(ev.props, key)


def ev_matches(ev, matching, ignored, ctx):
    ch = ctx.ch and not ctx.rel
    for k, vals in (matching or {}).items():
        t = prop_for_match(ev, k, ctx)
        if t is None or t not in vals:
            return False
    for combo in ignored or []:
        items = [(k, v) for k, v in (combo or {}).items() if v]
        if not items:
            continue
        hit = True
        for k, vals in items:
            t = prop_for_match(ev, k, ctx)
            if t is None:
                t = ""
            if t not in vals:
                hit = False
                break
        if hit:
            return False
    return True


def order_key(ev):
    return (ev.ts, ev.seq)


def group_key(ev, keys, ctx):
    if ctx.ch and not ctx.rel:
        return tuple(maptext(ev.props, k) for k in keys)
    return tuple(ptext(ev.props, k) for k in keys)


def group_report(gk, keys):
    return {k: (None if v in (None, "") else v) for k, v in zip(keys, gk)}


def unique_value_key(ev, ctx):
    if ctx.ch and not ctx.rel:
        return ev_value_text(ev, ctx)
    return ptext(ev.props, ctx.field)


def unique_op(ev, ctx):
    if ctx.ch and not ctx.rel:
        t = maptext(ev.props, "operation_type")
        return "add" if t == "" else t
    t = ptext(ev.props, "operation_type")
    return "add" if t is None else t


def unique_adjustments(evs, ctx):
    """Per-event adjusted value (BE-AG-14 / BE-AG-63) for events of one partition in time order."""
    out = []
    prev = "remove"
    ch = ctx.ch and not ctx.rel
    for e in evs:
        op = unique_op(e, ctx)
        if ch:
            if op == "add":
                adj = 0 if prev == "add" else 1
            else:
                adj = 0 if prev == "remove" else -1
        else:
            if op == prev:
                adj = 0
            else:
                adj = 1 if op == "add" else -1
        prev = op
        out.append(adj)
    return out


def partition_unique(evs, ctx):
    parts = {}
    for e in sorted(evs, key=order_key):
        parts.setdefault(unique_value_key(e, ctx), []).append(e)
    return parts


# --------------------------------------------------------------------------- rounding


def apply_rounding(d, metric):
    fn = metric.get("rounding_function")
    if not fn:
        return d
    prec = metric.get("rounding_precision") or 0
    mode = {"round": ROUND_HALF_UP, "ceil": ROUND_CEILING, "floor": ROUND_FLOOR}[fn]
    return quant(d, prec, mode)


# --------------------------------------------------------------------------- aggregate


def get_window(w):
    w = w or {}
    frm = parse_instant(w.get("from", "2024-03-01T00:00:00Z"))
    to = parse_instant(w.get("to", "2024-03-31T23:59:59.999999Z"))
    dur = w.get("charges_duration_days")
    if dur is None:
        dur = ((EPOCH + timedelta(microseconds=to)).date() - (EPOCH + timedelta(microseconds=frm)).date()).days + 1
    return {"from": frm, "to": to, "dur": dur, "tz": get_tz(w.get("timezone"))}


def floor_ms(us):
    return us // 1000 * 1000


def proration_ratio(days, dur, ctx):
    """P = days / D (BE-AG-51, binary64 island in compat)."""
    if ctx.exact:
        return Decimal(days) / Decimal(dur)
    if days == dur:
        return D1
    return Decimal(repr(days / dur))


def p16(P, ctx):
    """P cut to 16 significant digits of its shortest text (BE-AG-56 island 3); exact profile keeps P."""
    if ctx.exact or P == D1:
        return P
    t = P.normalize()
    sign, digits, exp = t.as_tuple()
    if len(digits) <= 16:
        return P
    cut = Decimal((sign, digits[:16], exp + len(digits) - 16))
    return cut


def _r64(n):
    """Round a non-negative integer to 64 significant bits, ties to even."""
    b = n.bit_length()
    if b <= 64:
        return n
    sh = b - 64
    q, rem = divmod(n, 1 << sh)
    half = 1 << (sh - 1)
    if rem > half or (rem == half and q & 1):
        q += 1
    return q << sh


def store_convert(v):
    """Columnar store decimal -> binary64 conversion c(v) (BE-AG-74)."""
    x = int(abs(v) * (10 ** 26))
    h, l = x >> 64, x & ((1 << 64) - 1)
    y = _r64(_r64(_r64(h * ((1 << 64) - 1)) + h) + l)
    c = float(y) / float(10 ** 26)
    return -c if v < 0 else c


def cache_matches(cached, gdict):
    if cached is None:
        return False
    cg = cached.get("grouped_by") or {}
    gd = gdict or {}
    keys = set(cg) | set(gd)
    return all(cg.get(k) == gd.get(k) for k in keys)


def cached_state(cached, win):
    c = Decimal(cached["current_aggregation"])
    m = cached.get("max_aggregation")
    mp = cached.get("max_aggregation_with_proration")
    return {
        "c": c,
        "m": Decimal(m) if m is not None else None,
        "mp": Decimal(mp) if mp is not None else None,
        "ts": parse_instant(cached["timestamp"]) if cached.get("timestamp") else win["from"],
    }


def sum_in_advance(x, cache):
    """BE-AG-40 -> (units, new_state)."""
    if cache is None:
        units = max(x, D0)
        return units, {"current_aggregation": x, "max_aggregation": x, "units_applied": x}
    c = cache["c"]
    m = cache["m"] if cache["m"] is not None else c
    c2 = c + x
    if c2 > m:
        units = c2 - m
        return units, {"current_aggregation": c2, "max_aggregation": max(c2, c2 - m)}
    return D0, {"current_aggregation": c2, "max_aggregation": m, "units_applied": x}


def unique_in_advance(newly, active_before, is_add, cache):
    if cache is None:
        return Decimal(newly), {"current_aggregation": Decimal(newly), "max_aggregation": Decimal(newly),
                                "units_applied": Decimal(newly)}
    c = cache["c"]
    m = cache["m"] if cache["m"] is not None else c
    c2 = c + newly if is_add else c - (1 if active_before else 0)
    if c2 > m:
        return D1, {"current_aggregation": c2, "max_aggregation": c2}
    return D0, {"current_aggregation": c2, "max_aggregation": m, "units_applied": Decimal(newly)}


def event_active_before(ev, prior, ctx):
    """BE-AG-41: is there a strictly earlier event with the same value whose operation is add/missing."""
    cands = [p for p in prior if p.ts < ev.ts and p is not ev]
    if ctx.ch and not ctx.rel:
        vk = lambda e: ev_value_text(e, ctx)  # noqa: E731
    elif ctx.exact:
        vk = lambda e: ptext(e.props, ctx.field)  # noqa: E731
    else:
        vk = lambda e: json_key(e.props.get(ctx.field) if isinstance(e.props, dict) else None)  # noqa: E731
    same = [p for p in cands if vk(p) == vk(ev)]
    if not same:
        return False
    last = max(same, key=order_key)
    return unique_op(last, ctx) == "add"


def window_select(evs, ctx, win, lower_free, upper=None):
    """Select by time bounds only."""
    lo = floor_ms(win["from"])
    out = []
    for e in evs:
        if e.deleted:
            continue
        if upper is not None:
            if not upper(e):
                continue
        elif e.ts > win["to"]:
            continue
        if not lower_free and e.ts < lo:
            continue
        out.append(e)
    return out


def level_sum(evs, ctx):
    t = D0
    for e in evs:
        v = ev_value(e, ctx)
        if v is not None:
            t += v
    return t


def weighted(evs, ctx, win, init):
    """BE-AG-17. evs already gated; returns (aggregation, variation)."""
    frm = win["from"]
    T = -((-win["to"]) // SEC_US) * SEC_US
    rows = [(frm, init)]
    var = D0
    for e in sorted(evs, key=order_key):
        v = ev_value(e, ctx)
        if v is None:
            continue
        rows.append((e.ts, v))
        var += v
    rows.append((T, D0))
    level = D0
    acc = D0
    denom = Decimal(win["dur"]) * 86400
    for (t0, d0), (t1, _) in zip(rows, rows[1:]):
        level += d0
        if ctx.ch and not ctx.rel:
            dt = Decimal(t1 // SEC_US - t0 // SEC_US)
        else:
            dt = Decimal(t1 - t0) / SEC_US
        if dt == 0:
            continue
        acc += level * dt / denom
    return acc, var


def prorated_unique(evs, ctx, win, grouped):
    """BE-AG-52 / BE-AG-66: (prorated total, unprorated unique count) over all history events."""
    tz = win["tz"]
    frm, to, dur = win["from"], win["to"], win["dur"]
    lo = floor_ms(frm)
    total = D0
    ch = ctx.ch and not ctx.rel
    parts = partition_unique(evs, ctx)
    unprorated = D0
    for _, pe in parts.items():
        # step 1: drop removals
        keep = []
        for i, e in enumerate(pe):
            if unique_op(e, ctx) != "add":
                day = local_ordinal(e.ts, tz)
                later = [x for x in pe[i + 1:] if local_ordinal(x.ts, tz) == day]
                if ch:
                    if later:
                        continue
                else:
                    if any(unique_op(x, ctx) == "add" for x in later):
                        continue
            keep.append(e)
        adj = unique_adjustments(keep, ctx)
        unprorated += sum(adj)
        rem = [e for e, a in zip(keep, adj) if a != 0]
        for i, e in enumerate(rem):
            if unique_op(e, ctx) != "add":
                continue
            nxt = rem[i + 1] if i + 1 < len(rem) else None
            if nxt is not None and nxt.ts < lo:
                if grouped and not ch and not ctx.exact:
                    total += quotient_days(1, dur, ch)
                continue
            start = local_ordinal(max(e.ts, frm), tz)
            if nxt is not None:
                end = local_ordinal(nxt.ts, tz) + 1
            else:
                end = local_ordinal(to, tz) + 1
            total += quotient_days(end - start, dur, ch)
    return total, unprorated


def quotient_days(days, dur, ch):
    if ch:
        return quant(Decimal(days) / Decimal(dur), 10, ROUND_HALF_UP)
    return sig_quot(days, dur, 20)


def compute_bucket(evs, ctx, win, opts, cached, gdict, grouped, boundary_ev=None, carried_pool=None):
    """Aggregate one group of selected events. Returns the result dict (unrounded where relevant)."""
    atype = ctx.atype
    res = {}
    prorated = bool(opts.get("prorated"))
    cur = bool(opts.get("is_current_usage"))
    adv = bool(opts.get("is_pay_in_advance"))
    cache = None
    if cached is not None and cache_matches(cached, gdict):
        cache = cached_state(cached, win)
        lo_s = floor_ms(win["from"]) // SEC_US
        if not (lo_s <= cache["ts"] // SEC_US <= win["to"] // SEC_US) and atype != "weighted_sum_agg":
            cache = None
    frm = floor_ms(win["from"])
    in_win = [e for e in evs if e.ts >= frm]
    tz = win["tz"]

    if atype == "count_agg":
        n = Decimal(len(evs))
        res.update(aggregation=n, count=n, current_usage_units=n)
        res["_vals"] = [D1] * len(evs)
        res["_units_list"] = None
    elif atype == "sum_agg":
        vals = []
        for e in sorted(evs, key=order_key):
            v = ev_value(e, ctx)
            if v is not None:
                vals.append((e, v))
        total = sum((v for _, v in vals), D0)
        n = Decimal(len(vals))
        res.update(aggregation=total, count=n)
        res["_vals"] = [v for e, v in vals if e.ts >= frm]
        res["_vals_all"] = [v for _, v in vals]
        res["_pairs"] = vals
        if opts.get("charge_model_dynamic"):
            res["precise_total_amount_cents"] = sum((e.amount for e, _ in vals), D0)
    elif atype == "max_agg":
        vals = []
        for e in sorted(evs, key=order_key):
            v = ev_value(e, ctx)
            if v is not None:
                vals.append(v)
        mx = max(vals) if vals else D0
        res.update(aggregation=mx, count=Decimal(len(vals)))
        pe = []
        seen = False
        for v in vals:
            if not seen and v == mx:
                pe.append(v)
                seen = True
            else:
                pe.append(D0)
        res["_vals"] = pe
    elif atype == "latest_agg":
        vals = []
        for e in evs:
            v = ev_value(e, ctx)
            if v is not None:
                vals.append((e, v))
        if vals:
            last = max(vals, key=lambda p: order_key(p[0]))[1]
            last = max(last, D0)
        else:
            last = D0
        res.update(aggregation=last, count=Decimal(len(vals)))
    elif atype == "unique_count_agg":
        total = D0
        for _, pe in partition_unique(evs, ctx).items():
            total += sum(unique_adjustments(pe, ctx))
        total = ceil5(total)
        res.update(aggregation=total, count=total, current_usage_units=total)
        res["_vals"] = [D1] * len(in_win)
        res["_nwin"] = len(in_win)
    elif atype == "weighted_sum_agg":
        init = D0
        if ctx.recurring:
            cands = None
            if cached is not None and cache_matches(cached, gdict):
                cs = cached_state(cached, win)
                if cs["ts"] < win["from"]:
                    init = cs["c"]
                    cands = True
            if cands is None and ctx.sub.get("previous"):
                lim = win["from"] - SEC_US
                pool = carried_pool if carried_pool is not None else []
                init = level_sum([e for e in pool if e.ts <= lim and group_match(e, gdict, ctx)], ctx)
        wevs = [e for e in evs if e.ts >= frm]
        agg, var = weighted(wevs, ctx, win, init)
        agg_c = quant(agg, 20, ROUND_CEILING)
        res.update(aggregation=agg if grouped else agg_c, count=Decimal(len(wevs)), variation=var,
                   total_aggregated_units=init + var)
        res["_wevs"] = len(wevs)
        res["recurring_updated_at"] = fmt_instant(max(e.ts for e in wevs)) if wevs else fmt_instant(win["from"])
    return res


def group_match(e, gdict, ctx):
    for k, v in (gdict or {}).items():
        t = group_key(e, [k], ctx)[0]
        t = None if t in (None, "") else t
        if t != v:
            return False
    return True


def running_total(res, ctx, opts):
    K = int(opts.get("free_units_per_events") or 0)
    A = Decimal(opts.get("free_units_per_total_aggregation") or 0)
    if K == 0 and A == 0:
        return []
    atype = ctx.atype
    if atype == "sum_agg":
        vals = res.get("_vals_all", [])
        out = []
        if K > 0:
            t = D0
            for v in vals[:K]:
                t += v
                out.append(t)
            return out
        t = D0
        for v in vals:
            if t > A:
                break
            t += v
            out.append(t)
        return out
    if atype in ("count_agg", "unique_count_agg"):
        n = int(res["aggregation"]) if res["aggregation"] > 0 else 0
        return [Decimal(i) for i in range(1, n + 1)]
    return []


def finish_group(res, ctx, opts, win, grouped_flag, boundary):
    out = {}
    for k, v in res.items():
        if not k.startswith("_"):
            out[k] = v
    atype = ctx.atype
    if not boundary:
        for k in ("aggregation", "full_units_number", "current_usage_units"):
            if k in out:
                out[k] = apply_rounding(out[k], ctx.metric)
    return out


def encode(res):
    out = {}
    for k, v in res.items():
        if isinstance(v, Decimal):
            out[k] = fmt(v)
        elif isinstance(v, list):
            out[k] = [fmt(x) if isinstance(x, Decimal) else x for x in v]
        else:
            out[k] = v
    return out


def op_aggregate(inp, profile):
    store = inp.get("store", "pg")
    metric = inp.get("metric") or {}
    sub = inp.get("subscription") or {}
    win = get_window(inp.get("window"))
    ctx = Ctx(store, profile, metric, sub, win, bool(inp.get("deduplicate")))
    ctx.sub = sub
    opts = dict(inp.get("options") or {})
    if inp.get("charge_model") == "dynamic":
        opts["charge_model_dynamic"] = True
    sub_ext = sub.get("external_id", "sub_1")
    events = make_events(inp.get("events"), ctx, sub_ext, metric.get("code"))
    mcode = metric.get("code", "kit_metric")
    events = [e for e in events if (e.code is None or e.code == mcode) and e.ext == sub_ext]
    events = [e for e in events if not e.deleted]
    ch = ctx.ch and not ctx.rel
    if ctx.ch and ctx.deduplicate:
        seen = set()
        ded = []
        for e in events:
            k = (e.tx, e.ts)
            if k in seen:
                continue
            seen.add(k)
            ded.append(e)
        events = ded
    atype = ctx.atype
    grouped_by = inp.get("grouped_by") or []
    presentation_by = inp.get("presentation_by") or []
    prorated = bool(opts.get("prorated"))
    cur = bool(opts.get("is_current_usage"))
    adv = bool(opts.get("is_pay_in_advance"))
    recurring = ctx.recurring

    # boundary (pricing one event in advance)
    bev = None
    upper = None
    if inp.get("boundary_transaction_id") is not None:
        for e in events:
            if e.tx == inp["boundary_transaction_id"]:
                bev = e
                break
    if bev is not None:
        if ch and not ctx.rel:
            upper = lambda e: e.ts < bev.ts or (e.ts == bev.ts and e.tx <= bev.tx)  # noqa: E731
        else:
            upper = lambda e: e.ts < bev.ts or (e.ts == bev.ts and e.seq <= bev.seq)  # noqa: E731

    if ctx.exact and sub.get("upgraded") and sub.get("terminated_at"):
        term_us = parse_instant(sub["terminated_at"])
        if term_us == win["to"]:
            events = [e for e in events if e.ts != term_us]
    lower_free = (recurring and atype in ("sum_agg", "unique_count_agg")) or (prorated and atype in ("sum_agg", "unique_count_agg"))
    base = window_select(events, ctx, win, lower_free, upper)
    matching = inp.get("matching") or {}
    ignored = inp.get("ignored") or []
    sel = [e for e in base if ev_matches(e, matching, ignored, ctx)]
    gvals = inp.get("grouped_by_values") or {}
    if gvals:
        sel = [e for e in sel if group_match(e, gvals, ctx)]
    if atype in ("sum_agg", "max_agg", "latest_agg", "weighted_sum_agg"):
        sel = [e for e in sel if ev_value(e, ctx) is not None]
    carried_pool = None
    if atype == "weighted_sum_agg":
        carried_pool = [e for e in events if ev_matches(e, matching, ignored, ctx) and ev_value(e, ctx) is not None]
        # weighted sums take no history lower bound; keep only window events in `sel`
    cached = inp.get("cached")
    cached_obj = cached if cached else None

    bypass = bool(opts.get("bypass")) and not recurring
    grouped = bool(grouped_by)

    if grouped:
        gmap = {}
        for e in sel:
            gmap.setdefault(group_key(e, grouped_by, ctx), []).append(e)
        if not gmap or bypass:
            gmap = {tuple([None] * len(grouped_by)): []}
            if bypass:
                gmap = {tuple([None] * len(grouped_by)): []}
        items = sorted(gmap.items(), key=cmp_to_key(group_cmp))
    else:
        items = [((), sel)]
    if bypass:
        evs_override = True
    else:
        evs_override = False

    results = []
    for gk, gevs in items:
        gdict = group_report(gk, grouped_by) if grouped else {}
        if bypass:
            r = {"aggregation": D0, "count": D0, "current_usage_units": D0, "_vals": []}
            r2 = finish_group(r, ctx, opts, win, grouped, bev)
            r2["running_total"] = []
            results.append((gk, gdict, r2, r, gevs))
            continue
        r = compute_bucket(gevs, ctx, win, opts, cached_obj, gdict, grouped, bev, carried_pool)
        results.append((gk, gdict, r, r, gevs))

    final = []
    for gk, gdict, r, raw, gevs in results:
        if bypass:
            final.append((gdict, r))
            continue
        r = prorated_and_usage(r, gevs, ctx, win, opts, cached_obj, gdict, grouped, bev, events, matching, ignored)
        out = finish_group(r, ctx, opts, win, grouped, bev)
        out["running_total"] = running_total(r, ctx, opts)
        if opts.get("per_event"):
            out["per_event"] = r.get("_per_event", r.get("_vals", []))
            if "_per_event_prorated" in r:
                out["per_event_prorated"] = r["_per_event_prorated"]
        if bev is not None:
            pa, pamt = pay_in_advance_units(bev, gevs, ctx, win, opts, cached_obj, gdict, events, matching, ignored)
            out["pay_in_advance_aggregation"] = pa
            if opts.get("charge_model_dynamic"):
                out["pay_in_advance_precise_total_amount_cents"] = pamt
        final.append((gdict, out))

    out = {}
    if grouped:
        groups = []
        for gdict, r in final:
            g = {"grouped_by": gdict}
            g.update(encode(r))
            groups.append(g)
        out["groups"] = groups
    else:
        out.update(encode(final[0][1]))
    if presentation_by:
        keys = list(dict.fromkeys(list(grouped_by) + list(presentation_by)))
        bmap = {}
        for e in sel:
            bmap.setdefault(group_key(e, keys, ctx), []).append(e)
        bl = []
        for gk, gevs in sorted(bmap.items(), key=cmp_to_key(group_cmp)):
            r = compute_bucket(gevs, ctx, win, opts, None, group_report(gk, keys), True, None, carried_pool)
            bl.append({"groups": group_report(gk, keys), "value": fmt(r["aggregation"])})
        out["breakdowns"] = bl
    return out


def group_cmp(a, b):
    ka, kb = a[0], b[0]
    for x, y in zip(ka, kb):
        if x == y:
            continue
        if x is None:
            return 1
        if y is None:
            return -1
        return -1 if x < y else 1
    return 0


def pay_in_advance_units(bev, gevs, ctx, win, opts, cached, gdict, events, matching, ignored):
    """Units the priced event adds (BE-AG-40/41/43) and its own amount."""
    atype = ctx.atype
    amt = bev.amount
    if atype == "count_agg":
        return D1, amt
    in_grp = group_match(bev, gdict, ctx) if gdict else True
    cache = None
    if cached is not None and cache_matches(cached, group_report(group_key(bev, list((cached.get("grouped_by") or {}).keys()), ctx),
                                                                 list((cached.get("grouped_by") or {}).keys()))):
        cache = cached_state(cached, win)
    if atype == "sum_agg":
        v = ev_value(bev, ctx)
        x = v if v is not None else D0
        units, _ = sum_in_advance(x, cache)
        return units, amt
    if atype == "unique_count_agg":
        prior = [e for e in gevs if e is not bev]
        act = event_active_before(bev, prior, ctx)
        is_add = unique_op(bev, ctx) == "add"
        newly = 1 if (is_add and not act) else 0
        units, _ = unique_in_advance(newly, act, is_add, cache)
        return units, amt
    return D0, amt


def prorated_and_usage(r, gevs, ctx, win, opts, cached, gdict, grouped, bev, events, matching, ignored):
    """Apply proration (section 8) and the in-advance current-usage formulas (BE-AG-44, 53, 55)."""
    atype = ctx.atype
    prorated = bool(opts.get("prorated")) and atype in ("sum_agg", "unique_count_agg")
    cur = bool(opts.get("is_current_usage"))
    adv = bool(opts.get("is_pay_in_advance"))
    tz = win["tz"]
    frm, to, dur = win["from"], win["to"], win["dur"]
    lo = floor_ms(frm)
    cache = None
    if cached is not None and cache_matches(cached, gdict):
        cache = cached_state(cached, win)
        lo_s = lo // SEC_US
        if not (lo_s <= cache["ts"] // SEC_US <= to // SEC_US):
            cache = None

    if prorated:
        upgraded = bool(ctx.sub.get("upgraded"))
        P = proration_ratio(days_between(frm, to, tz, upgraded), dur, ctx)
        if atype == "sum_agg":
            pairs = r["_pairs"]
            carried = [(e, v) for e, v in pairs if e.ts < lo]
            wins = [(e, v) for e, v in pairs if e.ts >= lo]
            csum = sum((v for _, v in carried), D0)
            tot = quant(csum * P, 40, ROUND_HALF_UP) if (ctx.exact and not grouped) else csum * P
            ratios = []
            lt = local_ordinal(to, tz)
            colstore = ctx.ch and not ctx.rel and not ctx.exact
            if colstore:
                pf = float(P)
                cpart = [store_convert(v) * pf for _, v in carried]
                wpart = []
                tot = Decimal(0)
            for e, v in wins:
                dd = lt - local_ordinal(e.ts, tz) + 1
                if colstore:
                    f = store_convert(v) * (dd / dur)
                    wpart.append(f)
                    ratios.append(Decimal(repr(f)))
                    continue
                if ctx.exact and not grouped:
                    term = quant(v * dd / dur, 40, ROUND_HALF_UP)
                    ratios.append(sig_quot(term, 1, 20))
                else:
                    term = v * sig_quot(dd, dur, 20)
                    ratios.append(term)
                tot += term
            if colstore:
                tot = Decimal(repr(sum(cpart, 0.0))) + Decimal(repr(sum(wpart, 0.0)))
            unpro = csum + sum((v for _, v in wins), D0)
            prorated_val = ceil5(tot)
            r["count"] = Decimal(len(pairs))
            has_c = bool(carried) and csum != 0
            pe = [csum] if has_c else []
            pe += [v for _, v in wins]
            pep = [csum * p16(P, ctx)] if has_c else []
            pep += ratios
            r["_per_event"] = pe
            r["_per_event_prorated"] = pep
        else:
            grouped = bool(grouped)
            tot, unpro = prorated_unique(gevs, ctx, win, grouped)
            prorated_val = ceil5(tot)
            r["count"] = prorated_val
        r["full_units_number"] = unpro
        if adv and not cur:
            r["aggregation"] = unpro
        elif adv and cur:
            U = unpro
            if cache is not None:
                mp = cache["mp"] if cache["mp"] is not None else D0
                if P < 1:
                    v = ceil5((U - max(cache["c"], D0)) * p16(P, ctx)) + mp
                else:
                    v = U - max(cache["c"], D0) + mp
            else:
                v = prorated_val if P < 1 else U
            r["aggregation"] = max(v, D0)
            r["current_usage_units"] = max(U, D0)
        elif cur:
            r["aggregation"] = max(prorated_val, D0)
            r["current_usage_units"] = max(unpro, D0)
        else:
            r["aggregation"] = prorated_val
        return r

    if adv and cur and atype in ("sum_agg", "unique_count_agg"):
        T = r["aggregation"]
        if cache is not None:
            m = cache["m"] if cache["m"] is not None else cache["c"]
            r["aggregation"] = max(T - cache["c"] + m, D0)
        else:
            r["aggregation"] = max(T, D0)
        r["current_usage_units"] = max(T, D0)
        if atype == "unique_count_agg":
            r["count"] = T if grouped else r["aggregation"]
    return r


# --------------------------------------------------------------------------- other ops


def op_current_usage_in_advance(inp, profile):
    T = Decimal(inp["total"])
    c = inp.get("cached")
    if c:
        cc = Decimal(c["current_aggregation"])
        mm = Decimal(c["max_aggregation"])
        agg = max(T - cc + mm, D0)
    else:
        agg = max(T, D0)
    return {"aggregation": fmt(agg), "current_usage_units": fmt(max(T, D0))}


def op_in_advance_units(inp, profile):
    store = inp.get("store", "pg")
    atype = inp["aggregation_type"]
    metric = {"aggregation_type": atype, "field_name": inp.get("field_name", "value"),
              "recurring": bool(inp.get("prorated"))}
    sub = inp.get("subscription") or {}
    win = get_window(inp.get("window"))
    ctx = Ctx(store, profile, metric, sub, win)
    sub_ext = sub.get("external_id", "sub_1")
    ev = make_events([inp["event"]], ctx, sub_ext)[0]
    if "transaction_id" not in inp["event"]:
        ev.tx = "kit_event"
    prior = make_events(inp.get("prior_events") or [], ctx, sub_ext)
    prior = [e for e in prior if not e.deleted and e.ext == sub_ext]
    if ctx.ch and inp.get("deduplicate"):
        pass
    grouped_by = inp.get("grouped_by") or []
    if grouped_by:
        gk = group_key(ev, grouped_by, ctx)
        prior = [e for e in prior if group_key(e, grouped_by, ctx) == gk]
    gdict = group_report(group_key(ev, grouped_by, ctx), grouped_by) if grouped_by else {}
    cached = inp.get("cached")
    cache = None
    lo = floor_ms(win["from"])
    if cached and cache_matches(cached, gdict):
        cache = cached_state(cached, win)
        if not (lo // SEC_US <= cache["ts"] // SEC_US <= win["to"] // SEC_US):
            cache = None
    prorated = bool(inp.get("prorated"))
    out = {}
    if atype == "count_agg":
        return {"units": "1", "new_cached": {}}
    if atype == "sum_agg":
        v = ev_value(ev, ctx)
        x = v if v is not None else D0
        units, ns = sum_in_advance(x, cache)
    else:
        lower_free = prorated or bool(inp.get("recurring"))
        pr = [e for e in prior if (lower_free or e.ts >= lo) and e.ts <= ev.ts]
        pr = [e for e in pr if ev_matches(e, {}, [], ctx)]
        act = event_active_before(ev, pr, ctx)
        is_add = unique_op(ev, ctx) == "add"
        newly = 1 if (is_add and not act) else 0
        units, ns = unique_in_advance(newly, act, is_add, cache)
    if prorated:
        days = days_between(ev.ts, win["to"], win["tz"], False)
        pu = ceil5(units * p16(proration_ratio(days, win["dur"], ctx), ctx)) if units != 0 else D0
        out["full_units_number"] = fmt(units)
        mp0 = cache["mp"] if cache is not None and cache["mp"] is not None else D0
        if cache is None:
            ns["max_aggregation_with_proration"] = pu
        else:
            grew = ns["max_aggregation"] > (cache["m"] if cache["m"] is not None else cache["c"])
            ns["max_aggregation_with_proration"] = mp0 + pu if grew else mp0
        units = pu
    out["units"] = fmt(units)
    out["new_cached"] = {k: fmt(v) for k, v in ns.items()}
    return out


def op_select_events(inp, profile):
    store = inp.get("store", "pg")
    ctx = Ctx(store, profile)
    out = []
    for i, e in enumerate(inp.get("events") or [], 1):
        ev = Ev()
        ev.tx = e["transaction_id"]
        ev.props = parse_props(e)
        if ev_matches(ev, inp.get("matching") or {}, inp.get("ignored") or [], ctx):
            out.append(ev.tx)
    return {"transaction_ids": sorted(out)}


def expand(values, metric_filters):
    out = {}
    for k, v in values.items():
        if v == "ALL":
            out[k] = list(metric_filters.get(k, []))
        else:
            out[k] = list(v)
    return out


def op_matching_and_ignored(inp, profile):
    mf = inp.get("metric_filters") or {}
    filters = inp.get("charge_filters") or []
    sel = inp.get("selected")
    exp = {f["id"]: expand(f["values"], mf) for f in filters}
    if sel is None:
        return {"matching": {}, "ignored": [dict(exp[f["id"]]) for f in filters]}
    F = next(f for f in filters if f["id"] == sel)
    fv = exp[sel]
    fall = {k for k, v in F["values"].items() if v == "ALL"}
    ignored = []
    for G in filters:
        if G["id"] == sel:
            continue
        gv = exp[G["id"]]
        if not all(k in gv and set(gv[k]) & set(fv[k]) for k in fv):
            continue
        if set(gv) == set(fv):
            if all(set(gv[k]) == set(fv[k]) for k in fv):
                gk = (G.get("created_seq", 0), G["id"])
                fk = (F.get("created_seq", 0), F["id"])
                if gk < fk:
                    ignored.append(dict(gv))
                continue
            if all(set(gv[k]) <= set(fv[k]) for k in gv):
                ignored.append(dict(gv))
                continue
            combo = {}
            for k in fv:
                if k in fall:
                    continue
                combo[k] = [x for x in gv[k] if x not in fv[k]]
            ignored.append(combo)
        else:
            ignored.append(dict(gv))
    return {"matching": fv, "ignored": ignored}


def op_event_filter(inp, profile):
    mf = inp.get("metric_filters") or {}
    props = json.loads(inp["properties_json"]) if inp.get("properties_json") else {}
    filters = list(inp.get("charge_filters") or [])
    filters.sort(key=lambda f: f.get("updated_seq", f.get("created_seq", 0)))
    texts = {k: ptext(props, k) for k in mf}
    matching = []
    for f in filters:
        ev = expand(f["values"], mf)
        if ev and all(texts.get(k) is not None and texts[k] in vals for k, vals in ev.items()):
            matching.append((f, len(ev)))
    if not matching:
        return {"filter_id": None, "matching_filter_ids": []}
    best = max(n for _, n in matching)
    pick = next(f for f, n in matching if n == best)
    return {"filter_id": pick["id"], "matching_filter_ids": [f["id"] for f, _ in matching]}


def op_group_keys(inp, profile):
    store = inp.get("store", "pg")
    ctx = Ctx(store, profile)
    props = json.loads(inp["properties_json"]) if inp.get("properties_json") else {}
    out = {}
    for k in inp["grouped_by"]:
        t = maptext(props, k) if (ctx.ch and not ctx.rel) else ptext(props, k)
        out[k] = None if t in (None, "") else t
    return {"grouped_by": out}


OPS = {
    "aggregate": op_aggregate,
    "in_advance_units": op_in_advance_units,
    "current_usage_in_advance": op_current_usage_in_advance,
    "matching_and_ignored": op_matching_and_ignored,
    "select_events": op_select_events,
    "event_filter": op_event_filter,
    "group_keys": op_group_keys,
}


def main():
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        t = msg.get("type")
        if t == "hello":
            resp = {"type": "hello", "proto": 1, "impl": "crc-4a-aggregation", "impl_version": "1.0.0",
                    "profiles": ["compat", "corrected"], "ops": ["aggregation.*"]}
        elif t == "bye":
            break
        elif t == "call":
            resp = {"type": "result", "id": msg["id"]}
            try:
                if msg.get("area") != "aggregation" or msg.get("op") not in OPS:
                    resp["error"] = {"code": "unsupported_op", "message": "%s.%s" % (msg.get("area"), msg.get("op"))}
                else:
                    resp["output"] = OPS[msg["op"]](msg.get("input") or {}, msg.get("profile", "compat"))
            except Exception as ex:  # noqa: BLE001
                import traceback
                traceback.print_exc(file=sys.stderr)
                resp["error"] = {"code": "internal", "message": repr(ex)}
        else:
            continue
        out.write(json.dumps(resp, separators=(",", ":")) + "\n")
        out.flush()


if __name__ == "__main__":
    main()
