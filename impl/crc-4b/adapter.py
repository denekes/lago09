#!/usr/bin/env python3.12
"""Usage aggregation engine adapter (kit JSON-lines protocol v1), area `aggregation`.

Standard library only.  One request per line on stdin, one response per line on stdout.
"""
import json
import re
import sys
from datetime import datetime, timedelta, timezone, date
from decimal import Decimal, ROUND_CEILING, ROUND_FLOOR, ROUND_HALF_UP, ROUND_DOWN, localcontext, getcontext
from fractions import Fraction
from zoneinfo import ZoneInfo

getcontext().prec = 80

EPOCH = datetime(1970, 1, 1, tzinfo=timezone.utc)
NUM_RE = re.compile(r'^-?[0-9]+(\.[0-9]+)?$')
CH_NUM_RE = re.compile(r'^[+-]?([0-9]+\.?[0-9]*|\.[0-9]+)([eE][+-]?[0-9]+)?$')
ISO_RE = re.compile(r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$')
SEC = 1_000_000
DAY_US = 86400 * SEC


class AdapterError(Exception):
    def __init__(self, code, message=""):
        super().__init__(message)
        self.code = code


# ---------------------------------------------------------------- time helpers
def parse_instant(s):
    m = ISO_RE.match(s)
    if not m:
        raise AdapterError("bad_input", "bad instant " + s)
    y, mo, d, h, mi, se, frac, z = m.groups()
    us = int((frac or "0").ljust(9, "0")[:6])
    dt = datetime(int(y), int(mo), int(d), int(h), int(mi), int(se), tzinfo=timezone.utc)
    off = 0
    if z != "Z":
        sign = 1 if z[0] == "+" else -1
        off = sign * (int(z[1:3]) * 3600 + int(z[4:6]) * 60)
    secs = int((dt - EPOCH).total_seconds()) - off
    return secs * SEC + us


def fmt_instant(us):
    secs, frac = divmod(us, SEC)
    dt = EPOCH + timedelta(seconds=secs)
    s = dt.strftime("%Y-%m-%dT%H:%M:%S")
    if frac:
        s += "." + ("%06d" % frac).rstrip("0")
    return s + "Z"


def tzinfo(name):
    return timezone.utc if name in (None, "UTC") else ZoneInfo(name)


def local_dt(us, tz):
    return (EPOCH + timedelta(microseconds=us)).astimezone(tz)


def local_date(us, tz):
    return local_dt(us, tz).date()


def days_between(from_us, to_us, tz, upgraded=False):
    a = local_dt(from_us, tz).replace(tzinfo=None)
    b = local_dt(to_us, tz).replace(tzinfo=None)
    if b.hour == 0 and b.minute == 0 and b.second == 0 and b.microsecond == 0:
        b += timedelta(seconds=1)
    delta = b - a
    n = -((-delta) // timedelta(days=1))
    if upgraded:
        n = max(n - 1, 0)
    return n


# ---------------------------------------------------------------- number helpers
def D(x):
    return x if isinstance(x, Decimal) else Decimal(str(x))


def fmt(d):
    if isinstance(d, Fraction):
        d = frac_to_dec(d)
    if d == 0:
        return "0"
    s = format(d, "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s


def frac_to_dec(f, digits=40):
    with localcontext() as c:
        c.prec = digits
        return Decimal(f.numerator) / Decimal(f.denominator)


def ceil_n(x, n):
    """Round towards +inf at n decimal places; x Decimal or Fraction."""
    if isinstance(x, Fraction):
        k = -((-x * 10 ** n) // 1)
        return Decimal(k).scaleb(-n)
    return x.quantize(Decimal(1).scaleb(-n), rounding=ROUND_CEILING)


def q20(num, den):
    with localcontext() as c:
        c.prec = 20
        return Decimal(num) / Decimal(den)


def apply_rounding(d, metric):
    fn = metric.get("rounding_function")
    if not fn:
        return d
    p = metric.get("rounding_precision") or 0
    mode = {"round": ROUND_HALF_UP, "ceil": ROUND_CEILING, "floor": ROUND_FLOOR}[fn]
    return d.quantize(Decimal(1).scaleb(-p), rounding=mode)


def float_text(f):
    r = repr(f)
    if "e" in r or "E" in r:
        r = format(Decimal(r), "f")
    if "." not in r:
        r += ".0"
    return r


# ---------------------------------------------------------------- property text
def pg_text(props, key):
    """Relational property text; None when absent or null."""
    if not isinstance(props, dict) or key not in props:
        return None
    v = props[key]
    if v is None:
        return None
    return json_text(v)


def json_text(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return v
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return float_text(v)
    return json.dumps(v, separators=(",", ":"))


def ch_map_text(props, key):
    """Columnar property map text: missing/null reads as ''; numbers normalised."""
    if not isinstance(props, dict) or key not in props or props[key] is None:
        return ""
    v = props[key]
    if isinstance(v, float):
        if v == int(v) and abs(v) < 1e21:
            return str(int(v))
        return float_text(v)
    return json_text(v)


def ep_value_text(v):
    """events-processor value text (compat)."""
    if v is None:
        return "<nil>"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, str):
        return v
    if isinstance(v, (int, float)):
        f = float(v)
        if f == 0:
            return "0"
        dec = Decimal(repr(f))
        sign, digits, exp = dec.as_tuple()
        ds = "".join(map(str, digits)).rstrip("0") or "0"
        e10 = len(digits) + exp - 1
        neg = "-" if sign else ""
        if e10 < -4 or e10 >= 6:
            mant = ds[0] + ("." + ds[1:] if len(ds) > 1 else "")
            return "%s%se%s%02d" % (neg, mant, "-" if e10 < 0 else "+", abs(e10))
        s = format(Decimal(repr(f)), "f")
        if "." in s:
            s = s.rstrip("0").rstrip(".")
        return s
    return str(v)


def ch_decimal(text):
    if text is None or not CH_NUM_RE.match(text):
        return Decimal(0)
    d = Decimal(text)
    if abs(d) >= Decimal(10) ** 12:
        return Decimal(0)
    return d


# ---------------------------------------------------------------- events
class Ev:
    __slots__ = ("id", "ts", "seq", "props", "code", "ext", "deleted", "amount", "ev", "_ch")

    def __init__(self, raw, idx, ctx):
        self.id = raw.get("transaction_id", "e%d" % (idx + 1))
        ts = parse_instant(raw["timestamp"])
        if ctx.store == "ch":
            ts = ts // 1000 * 1000
        self.ts = ts
        self.seq = raw.get("ingest_seq", idx + 1)
        if "properties_json" in raw and raw["properties_json"] is not None:
            self.props = json.loads(raw["properties_json"])
        else:
            self.props = raw.get("properties") or {}
        self.code = raw.get("code")
        self.ext = raw.get("external_subscription_id")
        self.deleted = bool(raw.get("deleted"))
        a = raw.get("precise_total_amount_cents")
        self.amount = Decimal(a) if a is not None else Decimal(0)
        self.ev = raw.get("enriched_value")
        self._ch = None

    def key(self):
        return (self.ts, self.seq)


class Ctx:
    def __init__(self, store, profile, metric=None):
        self.store = store or "pg"
        self.profile = profile
        self.compat = profile == "compat"
        self.chc = self.store == "ch" and self.compat  # columnar compat quirks
        self.metric = metric or {}
        self.grouped = False  # grouped prorated sums keep the binary64 islands in both profiles
        self.atype = self.metric.get("aggregation_type")
        self.field = self.metric.get("field_name") or "value"

    # property text for filters/groups
    def mtext(self, e, key):
        if self.chc:
            return ch_map_text(e.props, key)
        return pg_text(e.props, key)

    def enriched(self, e):
        if e.ev is not None:
            return e.ev
        if self.atype == "count_agg":
            return "1"
        return ep_value_text(e.props.get(self.field) if isinstance(e.props, dict) else None)

    def value(self, e):
        """Decimal value or None when the event is rejected by the numeric gate."""
        if self.chc:
            return ch_decimal(self.enriched(e))
        t = pg_text(e.props, self.field)
        if t is None or not NUM_RE.match(t):
            return None
        return Decimal(t)

    def identity(self, e):
        if self.chc:
            return ("v", self.enriched(e))
        t = pg_text(e.props, self.field)
        return ("m",) if t is None else ("v", t)

    def op(self, e):
        """(is_add, text) of the event's operation type."""
        t = pg_text(e.props, "operation_type")
        if self.chc:
            t = t or ""
            return (t in ("", "add"), t)
        if t is None:
            t = "add"
        return (t == "add", t)


def unique_adjust(ctx, evs):
    """Per-event adjusted values of one unique value's time-ordered events."""
    out = []
    if ctx.chc:
        prev_add = False
        prev_text = "remove"
        for i, e in enumerate(evs):
            is_add, text = ctx.op(e)
            if i == 0:
                prev_add, prev_text = False, "remove"
            if is_add:
                adj = 0 if prev_add else 1
            else:
                adj = 0 if prev_text == "remove" else -1
            prev_add, prev_text = is_add, text
            out.append(adj)
        return out
    prev = "remove"
    for e in evs:
        _, text = ctx.op(e)
        if text == prev:
            adj = 0
        elif text == "add":
            adj = 1
        else:
            adj = -1
        prev = text
        out.append(adj)
    return out


def unique_total(ctx, evs):
    by = {}
    for e in sorted(evs, key=Ev.key):
        by.setdefault(ctx.identity(e), []).append(e)
    total = 0
    for lst in by.values():
        total += sum(unique_adjust(ctx, lst))
    return Decimal(total)


# ---------------------------------------------------------------- selection
def matches_filters(ctx, e, matching, ignored):
    for k, vals in (matching or {}).items():
        t = ctx.mtext(e, k)
        if t is None or t not in vals:
            return False
    for combo in ignored or []:
        c = {k: v for k, v in combo.items() if v}
        if not c:
            continue
        ok = True
        for k, vals in c.items():
            t = ctx.mtext(e, k)
            if t is None:
                t = ""
            if t not in vals:
                ok = False
                break
        if ok:
            return False
    return True


def group_text(ctx, e, key):
    t = ctx.mtext(e, key)
    return t


def group_label(t):
    return None if t is None or t == "" else t


# ---------------------------------------------------------------- aggregate
def window_of(inp):
    w = inp.get("window") or {"from": "2024-03-01T00:00:00Z", "to": "2024-03-31T23:59:59.999999Z"}
    frm = parse_instant(w["from"])
    to = parse_instant(w["to"])
    tz = tzinfo(w.get("timezone"))
    dd = w.get("charges_duration_days")
    if dd is None:
        a = (EPOCH + timedelta(microseconds=frm)).date()
        b = (EPOCH + timedelta(microseconds=to)).date()
        dd = (b - a).days + 1
    return frm, to, dd, tz


def prorate_P(ctx, days, dd):
    if ctx.compat or ctx.grouped:
        return Fraction(Decimal(repr(days / dd)))
    return Fraction(days, dd)


def p16(days, dd):
    """BE-AG-56 (3): the binary64 ratio's shortest text cut (not rounded) to 16 significant digits."""
    d = Decimal(repr(days / dd))
    if d == 0:
        return Fraction(0)
    e = d.adjusted()
    return Fraction(d.quantize(Decimal(1).scaleb(e - 15), rounding=ROUND_DOWN))


def r64(i):
    """round a non-negative integer to 64 significant bits, ties to even"""
    k = i.bit_length() - 64
    if k <= 0:
        return i
    q, rem = divmod(i, 1 << k)
    half = 1 << (k - 1)
    if rem > half or (rem == half and q & 1):
        q += 1
    return q << k


def ch_conv(v):
    """BE-AG-74: the columnar store's decimal to binary64 conversion."""
    x = int(abs(v) * 10 ** 26)
    h, l = x >> 64, x & ((1 << 64) - 1)
    y = r64(r64(r64(h * ((1 << 64) - 1)) + h) + l)
    c = float(y) / float(10 ** 26)
    return -c if v < 0 else c


def ratio(ctx, n, dd):
    if ctx.compat or ctx.grouped:
        return Fraction(q20(n, dd))
    return Fraction(n, dd)


def frac_dec(f):
    return f if isinstance(f, Decimal) else frac_to_dec(f, 20)


def weighted_value(ctx, vals, frm, to, dd, init):
    """vals: list of (ts, Decimal) in time order."""
    T = to if to % SEC == 0 else (to // SEC + 1) * SEC
    rows = [(frm, init)] + list(vals) + [(T, Decimal(0))]
    level = Fraction(0)
    acc = Fraction(0)
    for i in range(len(rows) - 1):
        level += Fraction(rows[i][1])
        t0, t1 = rows[i][0], rows[i + 1][0]
        if ctx.chc:
            dur = (t1 // SEC - t0 // SEC) * SEC
        else:
            dur = t1 - t0
        if dur:
            acc += level * dur
    return ceil_n(acc / (dd * DAY_US), 20)


def aggregate(inp, profile):
    store = inp.get("store", "pg")
    metric = inp["metric"]
    ctx = Ctx(store, profile, metric)
    ctx.grouped = bool(inp.get("grouped_by"))
    atype = ctx.atype
    opts = inp.get("options") or {}
    sub = inp.get("subscription") or {}
    frm, to, dd, tz = window_of(inp)
    ext_id = sub.get("external_id", "sub_1")
    events = [Ev(r, i, ctx) for i, r in enumerate(inp.get("events", []))]
    recurring = bool(metric.get("recurring"))
    prorated = bool(opts.get("prorated"))
    upgraded = bool(sub.get("upgraded"))
    terminated = sub.get("terminated_at")
    matching = inp.get("matching") or {}
    ignored = inp.get("ignored") or []
    grouped_by = inp.get("grouped_by") or []
    pres_by = inp.get("presentation_by") or []
    cached = inp.get("cached")
    pay_adv = bool(opts.get("is_pay_in_advance"))
    cur_usage = bool(opts.get("is_current_usage"))

    # base scope
    base = [e for e in events
            if not e.deleted
            and (e.code is None or e.code == metric.get("code"))
            and (e.ext is None or e.ext == ext_id)]
    if inp.get("deduplicate") and store == "ch":
        seen = set()
        nb = []
        for e in base:
            k = (e.id, e.ts)
            if k in seen:
                continue
            seen.add(k)
            nb.append(e)
        base = nb

    boundary = None
    if inp.get("boundary_transaction_id") is not None:
        for e in base:
            if e.id == inp["boundary_transaction_id"]:
                boundary = e
                break

    # upper bound
    def within_upper(e):
        if boundary is not None:
            if e.ts < boundary.ts:
                return True
            if e.ts > boundary.ts:
                return False
            if ctx.chc:
                return e.id <= boundary.id
            return e.seq <= boundary.seq
        if e.ts > to:
            return False
        if (not ctx.compat) and upgraded and terminated and e.ts == to:
            return False
        return True

    base = [e for e in base if within_upper(e)]
    base = [e for e in base if matches_filters(ctx, e, matching, ignored)]
    gbv = inp.get("grouped_by_values")
    if gbv:
        base = [e for e in base if all(group_label(ctx.mtext(e, k)) == v for k, v in gbv.items())]

    gated = atype in ("sum_agg", "max_agg", "latest_agg", "weighted_sum_agg")
    vals = {}
    valid = []
    for e in base:
        if gated:
            v = ctx.value(e)
            if v is None:
                continue
            vals[id(e)] = v
        valid.append(e)
    lb = frm // 1000 * 1000
    lb_free = recurring and atype in ("sum_agg", "unique_count_agg")
    S_all = [e for e in valid if lb_free or e.ts >= lb]
    valid.sort(key=Ev.key)
    S_all.sort(key=Ev.key)

    # grouping
    def gkey(e):
        return tuple(ctx.mtext(e, k) for k in grouped_by)

    def glabels(key):
        return {k: group_label(t) for k, t in zip(grouped_by, key)}

    bypass = bool(opts.get("bypass")) and not recurring
    if bypass:
        S_all, valid = [], []

    groups = {}
    for e in S_all:
        groups.setdefault(gkey(e), [])
    for e in valid:
        groups.setdefault(gkey(e), [])
    order = list(groups.keys())
    Sg = {k: [] for k in order}
    Vg = {k: [] for k in order}
    for e in S_all:
        Sg[gkey(e)].append(e)
    for e in valid:
        Vg[gkey(e)].append(e)

    def cache_for(key):
        if not cached:
            return None
        cg = cached.get("grouped_by") or {}
        if grouped_by:
            lab = glabels(key)
            if {k: cg.get(k) for k in grouped_by} != lab:
                return None
        return cached

    def cvals(c):
        cur = D(c["current_aggregation"])
        mx = D(c["max_aggregation"]) if c.get("max_aggregation") is not None else None
        mp = D(c["max_aggregation_with_proration"]) if c.get("max_aggregation_with_proration") is not None else None
        return cur, mx, mp

    def compute(key, S, V, final=True):
        r = {}
        S = list(S)
        N = len(S)
        K = int(opts.get("free_units_per_events") or 0)
        A = D(opts.get("free_units_per_total_aggregation") or 0)
        per_event_wanted = bool(opts.get("per_event"))
        c = cache_for(key)
        if atype == "count_agg":
            r["aggregation"] = Decimal(N)
            r["count"] = Decimal(N)
            r["current_usage_units"] = Decimal(N)
            r["running_total"] = [Decimal(i) for i in range(1, N + 1)] if (K or A) else []
            pe = [Decimal(1)] * N
        elif atype == "sum_agg":
            vs = [vals[id(e)] for e in S]
            T = sum(vs, Decimal(0))
            r["aggregation"] = T
            r["count"] = Decimal(N)
            r["current_usage_units"] = T
            rt = []
            if K > 0:
                tot = Decimal(0)
                for v in vs[:K]:
                    tot += v
                    rt.append(tot)
            elif A > 0:
                tot = Decimal(0)
                for v in vs:
                    if tot > A:
                        break
                    tot += v
                    rt.append(tot)
            r["running_total"] = rt
            pe = list(vs)
            if inp.get("charge_model") == "dynamic":
                r["precise_total_amount_cents"] = sum((e.amount for e in S), Decimal(0))
        elif atype == "max_agg":
            vs = [vals[id(e)] for e in S]
            mx = max(vs) if vs else Decimal(0)
            r["aggregation"] = mx
            r["count"] = Decimal(N)
            r["running_total"] = []
            pe = []
            seen = False
            for v in vs:
                if not seen and v == mx:
                    pe.append(v)
                    seen = True
                else:
                    pe.append(Decimal(0))
        elif atype == "latest_agg":
            val = Decimal(0)
            if S:
                last = max(S, key=Ev.key)
                val = vals[id(last)]
                if val < 0:
                    val = Decimal(0)
            r["aggregation"] = val
            r["count"] = Decimal(N)
            r["running_total"] = []
            pe = []
        elif atype == "unique_count_agg":
            T = ceil_n(unique_total(ctx, S), 5)
            r["aggregation"] = T
            r["count"] = T
            r["current_usage_units"] = T
            r["running_total"] = [Decimal(i) for i in range(1, int(T) + 1)] if (K or A) and T > 0 else []
            pe = [Decimal(1)] * N
        elif atype == "weighted_sum_agg":
            wv = [(e.ts, vals[id(e)]) for e in S]
            init = Decimal(0)
            if recurring:
                ok = None
                if c is not None:
                    cts = parse_instant(c["timestamp"]) if c.get("timestamp") else frm
                    if cts < frm:
                        ok = D(c["current_aggregation"])
                if ok is not None:
                    init = ok
                elif sub.get("previous"):
                    init = sum((vals[id(e)] for e in V if e.ts <= frm - SEC), Decimal(0))
            variation = sum((v for _, v in wv), Decimal(0))
            agg = weighted_value(ctx, wv, frm, to, dd, init)
            r["aggregation"] = agg
            r["count"] = Decimal(N)
            r["variation"] = variation
            r["total_aggregated_units"] = init + variation
            r["recurring_updated_at"] = fmt_instant(S[-1].ts if S else frm)
            r["running_total"] = []
            pe = []
        else:
            raise AdapterError("bad_input", "unsupported aggregation_type " + str(atype))

        # ---- proration
        if prorated and atype in ("sum_agg", "unique_count_agg") and boundary is None:
            if pay_adv and not cur_usage:
                # BE-AG-55: the billing run bills the full unprorated units
                if atype == "sum_agg":
                    r["full_units_number"] = r["aggregation"]
                else:
                    r["full_units_number"] = r["aggregation"]
            else:
                days = days_between(frm, to, tz, upgraded)
                P = prorate_P(ctx, days, dd)
                if atype == "sum_agg":
                    carried = [e for e in V if e.ts < lb]
                    win = [e for e in V if e.ts >= lb]
                    csum = sum((vals[id(e)] for e in carried), Decimal(0))
                    tl = local_date(to, tz)
                    contrib_list = []
                    chp = ctx.chc and ctx.compat and not ctx.grouped
                    if chp:
                        Pf = days / dd
                        cpart = Decimal(0)
                        if carried:
                            cpart = Decimal(repr(sum((ch_conv(vals[id(e)]) * Pf for e in carried), 0.0)))
                        wcont = [Decimal(repr(ch_conv(vals[id(e)]) * (((tl - local_date(e.ts, tz)).days + 1) / dd))) for e in win]
                        wpart = Decimal(repr(sum((float(x) for x in wcont), 0.0))) if win else Decimal(0)
                        total = Fraction(cpart + wpart)
                    else:
                        total = Fraction(csum) * P
                    pe_prorated = [frac_dec(Fraction(csum) * (p16(days, dd) if ctx.compat or ctx.grouped else P))]
                    for e in win:
                        n = (tl - local_date(e.ts, tz)).days + 1
                        t = Fraction(vals[id(e)]) * ratio(ctx, n, dd)
                        if chp:
                            t = Fraction(wcont[len(pe_prorated) - 1])
                        else:
                            total += t
                        pe_prorated.append(frac_dec(t))
                    U = sum((vals[id(e)] for e in V), Decimal(0))
                    pv = ceil_n(total, 5)
                    r["aggregation"] = pv
                    r["count"] = Decimal(len(V))
                    r["full_units_number"] = U
                    r["current_usage_units"] = U
                    if carried and csum != 0:
                        pe = [csum] + [vals[id(e)] for e in win]
                    else:
                        pe = [vals[id(e)] for e in win]
                    pep = pe_prorated if carried and csum != 0 else pe_prorated[1:]
                    r["per_event_prorated"] = pep
                else:
                    pv, U = prorated_unique(ctx, V, frm, to, dd, tz, bool(grouped_by))
                    r["aggregation"] = pv
                    r["count"] = pv
                    r["full_units_number"] = U
                    r["current_usage_units"] = U
                    pe = [Decimal(1)] * len(S)
                if pay_adv and cur_usage:
                    U = r["full_units_number"]
                    if c is not None:
                        cur, mx, mp = cvals(c)
                        mp = mp or Decimal(0)
                        if P < 1:
                            agg = ceil_n(Fraction(U - max(cur, 0)) * (p16(days, dd) if ctx.compat or ctx.grouped else P), 5) + mp
                        else:
                            agg = U - max(cur, 0) + mp
                    else:
                        agg = r["aggregation"] if P < 1 else U
                    r["aggregation"] = max(agg, Decimal(0))
                    r["current_usage_units"] = max(U, Decimal(0))
                else:
                    r["aggregation"] = max(r["aggregation"], Decimal(0))
                    r["current_usage_units"] = max(r["current_usage_units"], Decimal(0))
        elif pay_adv and cur_usage and atype in ("sum_agg", "unique_count_agg") and boundary is None:
            T = r["aggregation"]
            if c is not None:
                cur, mx, mp = cvals(c)
                agg = max(T - cur + (mx if mx is not None else cur), Decimal(0))
                r["aggregation"] = agg
                if atype == "unique_count_agg":
                    r["count"] = T if grouped_by else agg
            r["current_usage_units"] = max(T, Decimal(0))

        if per_event_wanted:
            w = [e for e in S if e.ts >= lb] if not prorated else None
            if prorated and atype in ("sum_agg", "unique_count_agg") and boundary is None:
                r["per_event"] = pe
            else:
                lst = pe
                if lb_free:
                    # per-event values are taken over the window's events only
                    ws = [e for e in S if e.ts >= lb]
                    if atype == "sum_agg":
                        lst = [vals[id(e)] for e in ws]
                    else:
                        lst = [Decimal(1)] * len(ws)
                    S2 = ws
                else:
                    S2 = S
                if opts.get("exclude_event") and boundary is not None:
                    keep = [i for i, e in enumerate(S2) if e is not boundary]
                    lst = [lst[i] for i in keep]
                r["per_event"] = lst
        # pay-in-advance single event
        if boundary is not None:
            r.update(boundary_units(ctx, boundary, V, c, vals, lb, lb_free, atype, inp))
        if final and boundary is None:
            for f in ("aggregation", "full_units_number", "current_usage_units"):
                if f in r:
                    r[f] = apply_rounding(r[f], metric)
        return r

    def render(r):
        o = {}
        for k, v in r.items():
            if isinstance(v, list):
                o[k] = [fmt(x) for x in v]
            elif isinstance(v, Decimal):
                o[k] = fmt(v)
            else:
                o[k] = v
        return o

    out = {}
    if not grouped_by:
        key = ()
        res = compute(key, Sg.get(key, []), Vg.get(key, []))
        out.update(render(res))
    else:
        gl = []
        if not order:
            empty = {k: None for k in grouped_by}
            gl.append(dict(grouped_by=empty, **render(compute((), [], []))))
        for key in order:
            gl.append(dict(grouped_by=glabels(key), **render(compute(key, Sg[key], Vg[key]))))
        out["groups"] = gl
        if boundary is not None and gl:
            for f in ("pay_in_advance_aggregation", "pay_in_advance_precise_total_amount_cents"):
                if f in gl[0]:
                    out[f] = gl[0][f]

    if pres_by:
        keys = list(grouped_by) + [k for k in pres_by if k not in grouped_by]
        tuples = {}
        for e in S_all:
            tuples.setdefault(tuple(ctx.mtext(e, k) for k in keys), []).append(e)
        bd = []
        for tk, es in tuples.items():
            res = compute(tk, es, [x for x in valid if x in es], final=False)
            bd.append({"groups": {k: group_label(t) for k, t in zip(keys, tk)},
                       "value": fmt(res["aggregation"])})
        out["breakdowns"] = bd
        if grouped_by:
            top = compute((), S_all, valid)
            out.update({k: v for k, v in render(top).items() if k not in out})
    return out


def boundary_units(ctx, b, V, c, vals, lb, lb_free, atype, inp):
    """Pay-in-advance units for the boundary event (BE-AG-40/41/43)."""
    out = {}
    amt = b.amount
    if inp.get("charge_model") == "dynamic":
        out["pay_in_advance_precise_total_amount_cents"] = amt
    if atype == "count_agg":
        out["pay_in_advance_aggregation"] = Decimal(1)
        return out
    cached = c
    if atype == "sum_agg":
        x = vals.get(id(b), Decimal(0))
        units, st = sum_units(x, cached)
        out["pay_in_advance_aggregation"] = units
        out["current_aggregation"] = st[0]
        out["max_aggregation"] = st[1]
        out["units_applied"] = st[2]
    elif atype == "unique_count_agg":
        earlier = [e for e in V if e is not b and e.key() < b.key()]
        units, st = unique_units(ctx, b, earlier, cached)
        out["pay_in_advance_aggregation"] = units
        out["current_aggregation"] = st[0]
        out["max_aggregation"] = st[1]
        out["units_applied"] = st[2]
    return out


def sum_units(x, cached):
    if not cached:
        return max(x, Decimal(0)), (x, x, x)
    cur = D(cached["current_aggregation"])
    mx = D(cached["max_aggregation"]) if cached.get("max_aggregation") is not None else cur
    c2 = cur + x
    if c2 > mx:
        units = c2 - mx
        return units, (c2, max(c2, c2 - mx), x)
    return Decimal(0), (c2, mx, x)


def json_value_key(v):
    if v is None:
        return ("n",)
    if isinstance(v, bool):
        return ("b", v)
    if isinstance(v, (int, float)):
        return ("d", Decimal(repr(v)) if isinstance(v, float) else Decimal(v))
    if isinstance(v, str):
        return ("s", v)
    return ("j", json.dumps(v, sort_keys=True))


def unique_units(ctx, e, earlier, cached):
    """Units of one in-advance unique-count event given earlier events of the selection."""
    if ctx.chc:
        same = lambda a, b: ctx.enriched(a) == ctx.enriched(b)
    elif ctx.compat:
        f = ctx.field
        same = lambda a, b: json_value_key(a.props.get(f)) == json_value_key(b.props.get(f))
    else:
        same = lambda a, b: ctx.identity(a) == ctx.identity(b)
    prev = [p for p in earlier if same(p, e)]
    active_before = False
    if prev:
        last = max(prev, key=Ev.key)
        active_before = ctx.op(last)[0]
    is_add = ctx.op(e)[0]
    newly = 1 if (is_add and not active_before) else 0
    if not cached:
        n = Decimal(newly)
        return n, (n, n, n)
    cur = D(cached["current_aggregation"])
    mx = D(cached["max_aggregation"]) if cached.get("max_aggregation") is not None else cur
    c2 = cur + newly if is_add else cur - (1 if active_before else 0)
    if c2 > mx:
        return Decimal(1), (c2, c2, Decimal(newly))
    return Decimal(0), (c2, mx, Decimal(newly))


def prorated_unique(ctx, V, frm, to, dd, tz, grouped):
    by = {}
    for e in sorted(V, key=Ev.key):
        by.setdefault(ctx.identity(e), []).append(e)
    total = Fraction(0)
    unpro = 0
    to_date = local_date(to, tz)
    from_date = local_date(frm, tz)
    for lst in by.values():
        unpro += sum(unique_adjust(ctx, lst))
        # step 1: drop removals
        keep = []
        for i, e in enumerate(lst):
            if not ctx.op(e)[0]:
                d = local_date(e.ts, tz)
                later = [x for x in lst[i + 1:] if local_date(x.ts, tz) == d]
                if ctx.chc:
                    if later:
                        continue
                else:
                    if any(ctx.op(x)[0] for x in later):
                        continue
            keep.append(e)
        adj = unique_adjust(ctx, keep)
        rem = [(e, a) for e, a in zip(keep, adj) if a != 0]
        for i, (e, a) in enumerate(rem):
            if a <= 0:
                continue
            nxt = rem[i + 1][0] if i + 1 < len(rem) else None
            start = max(local_date(e.ts, tz), from_date) if e.ts >= frm else from_date
            if nxt is not None and nxt.ts < frm:
                days = 1 if (grouped and ctx.compat and ctx.store == "pg") else 0
            elif nxt is not None:
                days = (local_date(nxt.ts, tz) + timedelta(days=1) - start).days
            else:
                days = (to_date + timedelta(days=1) - start).days
            days = max(days, 0)
            if ctx.chc:
                total += Fraction(Decimal(days).__truediv__(Decimal(dd)).quantize(Decimal("1e-10")))
            else:
                total += ratio(ctx, days, dd)
    return ceil_n(total, 5), ceil_n(Decimal(unpro), 5)


# ---------------------------------------------------------------- in_advance_units
def in_advance_units(inp, profile):
    store = inp.get("store", "pg")
    atype = inp["aggregation_type"]
    metric = {"aggregation_type": atype, "field_name": inp.get("field_name", "value"),
              "recurring": bool(inp.get("prorated"))}
    ctx = Ctx(store, profile, metric)
    prorated = bool(inp.get("prorated"))
    frm, to, dd, tz = window_of(inp)
    cached = inp.get("cached")
    ev = Ev(inp["event"], 0, ctx)
    sub = inp.get("subscription") or {}
    ext_id = sub.get("external_id", "sub_1")
    grouped_by = inp.get("grouped_by") or []
    prior = [Ev(r, i + 1, ctx) for i, r in enumerate(inp.get("prior_events") or [])]
    if atype == "count_agg":
        return {"units": "1", "new_cached": {}}
    lb = frm // 1000 * 1000
    if atype == "sum_agg":
        x = ctx.value(ev)
        if x is None:
            x = Decimal(0)
        units, st = sum_units(x, cached)
    else:
        earlier = [p for p in prior if not p.deleted and (p.ext is None or p.ext == ext_id)
                   and p.ts < ev.ts or (p.ts == ev.ts and False)]
        earlier = [p for p in earlier if p.ts <= to and (prorated or p.ts >= lb)]
        if grouped_by:
            earlier = [p for p in earlier if all(group_label(ctx.mtext(p, k)) == group_label(ctx.mtext(ev, k))
                                                 for k in grouped_by)]
        units, st = unique_units(ctx, ev, earlier, cached)
    out = {}
    new = {"current_aggregation": fmt(st[0]), "max_aggregation": fmt(st[1]), "units_applied": fmt(st[2])}
    if prorated:
        days = days_between(ev.ts, to, tz, False)
        pu = ceil_n(Fraction(units) * (p16(days, dd) if ctx.compat or grouped_by else Fraction(days, dd)), 5) if units else Decimal(0)
        mp_old = D(cached["max_aggregation_with_proration"]) if cached and cached.get("max_aggregation_with_proration") is not None else None
        if not cached:
            mp = pu
        else:
            mp = (mp_old or Decimal(0)) + pu if units > 0 else (mp_old or Decimal(0))
        new["max_aggregation_with_proration"] = fmt(mp)
        out["full_units_number"] = fmt(units)
        units = pu
    out["units"] = fmt(units)
    out["new_cached"] = new
    return out


def current_usage_in_advance(inp, profile):
    T = D(inp["total"])
    c = inp.get("cached")
    if c:
        cur = D(c["current_aggregation"])
        mx = D(c["max_aggregation"])
        agg = T - cur + mx
    else:
        agg = T
    return {"aggregation": fmt(max(agg, Decimal(0))), "current_usage_units": fmt(max(T, Decimal(0)))}


# ---------------------------------------------------------------- filters
def expand(F, metric_filters):
    out = {}
    for k, v in F["values"].items():
        out[k] = list(metric_filters.get(k, [])) if v == "ALL" else list(v)
    return out


def matching_and_ignored(inp, profile):
    mf = inp["metric_filters"]
    filters = inp["charge_filters"]
    sel = inp.get("selected")
    exp = {f["id"]: expand(f, mf) for f in filters}
    if sel is None:
        return {"matching": {}, "ignored": [exp[f["id"]] for f in filters]}
    F = next(f for f in filters if f["id"] == sel)
    EF = exp[sel]
    ignored = []
    for G in filters:
        if G["id"] == sel:
            continue
        EG = exp[G["id"]]
        if not all(k in EG and set(EG[k]) & set(EF[k]) for k in EF):
            continue
        same_keys = set(EG) == set(EF)
        if same_keys and all(set(EG[k]) == set(EF[k]) for k in EF):
            gk = (G.get("created_seq", 0), G["id"])
            fk = (F.get("created_seq", 0), F["id"])
            if gk < fk:
                ignored.append(EG)
            continue
        if all(set(EG[k]) <= set(EF[k]) for k in EF):
            ignored.append(EG)
        elif same_keys:
            ignored.append({k: [v for v in EG[k] if v not in EF[k]] for k in EF})
        else:
            ignored.append(EG)
    return {"matching": EF, "ignored": ignored}


def event_filter(inp, profile):
    mf = inp["metric_filters"]
    filters = sorted(inp["charge_filters"],
                     key=lambda f: (f.get("updated_seq", f.get("created_seq", 0)), f.get("created_seq", 0)))
    props = json.loads(inp["properties_json"])
    texts = {k: pg_text(props, k) for k in mf}
    matched = []
    for f in filters:
        ef = expand(f, mf)
        if all(texts.get(k) is not None and texts[k] in v for k, v in ef.items()):
            matched.append((f, ef))
    best = None
    for f, ef in matched:
        if best is None or len(ef) > len(best[1]):
            best = (f, ef)
    return {"filter_id": best[0]["id"] if best else None,
            "matching_filter_ids": [f["id"] for f, _ in matched]}


def select_events(inp, profile):
    ctx = Ctx(inp.get("store", "pg"), profile)
    evs = []
    for i, r in enumerate(inp["events"]):
        raw = dict(r)
        raw["timestamp"] = "2024-03-10T00:00:00Z"
        evs.append(Ev(raw, i, ctx))
    ids = [e.id for e in evs if matches_filters(ctx, e, inp.get("matching"), inp.get("ignored"))]
    return {"transaction_ids": sorted(ids)}


def group_keys(inp, profile):
    ctx = Ctx(inp.get("store", "pg"), profile)
    props = json.loads(inp["properties_json"])
    return {"grouped_by": {k: group_label(ctx.mtext(Ev({"timestamp": "2024-03-10T00:00:00Z", "properties": props}, 0, ctx), k))
                           for k in inp["grouped_by"]}}


OPS = {
    "aggregate": aggregate,
    "in_advance_units": in_advance_units,
    "current_usage_in_advance": current_usage_in_advance,
    "matching_and_ignored": matching_and_ignored,
    "select_events": select_events,
    "event_filter": event_filter,
    "group_keys": group_keys,
}


def handle(req):
    rid = req.get("id")
    if req.get("area") != "aggregation" or req.get("op") not in OPS:
        return {"type": "result", "id": rid, "error": {"code": "unsupported_op"}}
    try:
        out = OPS[req["op"]](req["input"], req.get("profile", "compat"))
        return {"type": "result", "id": rid, "output": out}
    except AdapterError as e:
        return {"type": "result", "id": rid, "error": {"code": e.code, "message": str(e)}}
    except Exception as e:  # noqa
        import traceback
        traceback.print_exc(file=sys.stderr)
        return {"type": "result", "id": rid, "error": {"code": "internal", "message": repr(e)}}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = json.loads(line)
        t = req.get("type")
        if t == "hello":
            resp = {"type": "hello", "proto": 1, "impl": "crc-4b-aggregation", "impl_version": "0.1.0",
                    "profiles": ["compat", "corrected"], "ops": ["aggregation.*"]}
        elif t == "call":
            resp = handle(req)
        elif t == "bye":
            break
        else:
            continue
        sys.stdout.write(json.dumps(resp) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
