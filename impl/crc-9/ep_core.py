"""Pure parts of the events-processor pipeline (decoding, time, value text, subscription matching).

Everything here is deterministic and free of I/O so that the processor and the kitrun adapter share it.
`profile` is "corrected" (the processor's profile) or "compat" (reference behaviour, used by the adapter
when the grader asks for it).
"""
import json
import math
import re
from datetime import date
from decimal import Decimal

NS = 1_000_000_000
MS_NS = 1_000_000
EPOCH_ORD = 719163  # date(1970, 1, 1).toordinal()


class Undecodable(Exception):
    pass


class InvalidTimestamp(Exception):
    pass


class NonFiniteTimestamp(InvalidTimestamp):
    pass


class Num:
    """A JSON number kept as its literal text."""
    __slots__ = ("text",)

    def __init__(self, text):
        self.text = text

    def __repr__(self):
        return "Num(%s)" % self.text


class Raw:
    """Pre-rendered JSON text (used for output numbers)."""
    __slots__ = ("text",)

    def __init__(self, text):
        self.text = text


# ---------------------------------------------------------------- JSON with literal numbers

def _bad_constant(name):
    raise ValueError("invalid JSON constant " + name)


def _pairs(pairs):
    d = {}
    for k, v in pairs:
        d[k] = v  # the last duplicate wins
    return d


def loads_literal(text):
    return json.loads(text, parse_float=Num, parse_int=Num, parse_constant=_bad_constant,
                      object_pairs_hook=_pairs)


def _esc_str(s):
    out = json.dumps(s, ensure_ascii=False)
    return out.replace("\u2028", "\\u2028").replace("\u2029", "\\u2029")


def canon(v, profile="corrected"):
    """Canonical JSON text: sorted keys, no whitespace, no HTML escaping, number literals as given
    (compat: numbers re-encoded through binary64)."""
    if v is None:
        return "null"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, Raw):
        return v.text
    if isinstance(v, Num):
        if profile == "compat":
            return go_json_float(float(v.text))
        return v.text
    if isinstance(v, str):
        return _esc_str(v)
    if isinstance(v, int):
        return str(v)
    if isinstance(v, dict):
        return "{" + ",".join(_esc_str(k) + ":" + canon(v[k], profile) for k in sorted(v)) + "}"
    if isinstance(v, (list, tuple)):
        return "[" + ",".join(canon(x, profile) for x in v) + "]"
    raise TypeError(type(v))


# ---------------------------------------------------------------- float text (binary64)

def _shortest(f):
    """(sign, digits, dp): |f| = 0.digits * 10**dp, digits without trailing zeros ('0' for zero)."""
    neg = math.copysign(1.0, f) < 0
    _, digs, exp = Decimal(repr(abs(f))).as_tuple()
    full = "".join(map(str, digs)).lstrip("0")
    if not full:
        return (1 if neg else 0), "0", 1
    return (1 if neg else 0), full.rstrip("0"), len(full) + exp


def _fmt_f(sign, digs, dp):
    if digs == "0":
        out = "0"
    elif dp <= 0:
        out = "0." + "0" * (-dp) + digs
    elif dp >= len(digs):
        out = digs + "0" * (dp - len(digs))
    else:
        out = digs[:dp] + "." + digs[dp:]
    return ("-" if sign else "") + out


def _fmt_e(sign, digs, dp, min_exp_digits=2):
    e = dp - 1
    m = digs[0] + ("." + digs[1:] if len(digs) > 1 else "")
    es = "%s%0*d" % ("-" if e < 0 else "+", min_exp_digits, abs(e))
    return ("-" if sign else "") + m + "e" + es


def go_json_float(f):
    """Text of a float64 as the reference JSON encoder writes it."""
    if math.isinf(f) or math.isnan(f):
        raise Undecodable("non-finite number")
    sign, digs, dp = _shortest(f)
    if digs == "0":
        return "-0" if sign else "0"
    a = abs(f)
    if a < 1e-6 or a >= 1e21:
        t = _fmt_e(sign, digs, dp)
        # clean up e-09 to e-9 (negative exponents only)
        m = re.match(r"^(.*e-)0(\d)$", t)
        return m.group(1) + m.group(2) if m else t
    return _fmt_f(sign, digs, dp)


def go_g_float(f):
    """%g with shortest digits (reference value text for JSON numbers)."""
    sign, digs, dp = _shortest(f)
    if digs == "0":
        return "-0" if sign else "0"
    e = dp - 1
    if e < -4 or e >= 6:
        return _fmt_e(sign, digs, dp)
    return _fmt_f(sign, digs, dp)


def go_v_float(f):
    sign, digs, dp = _shortest(f)
    if digs == "0":
        return "-0" if sign else "0"
    e = dp - 1
    if e < -4 or e >= 21:
        return _fmt_e(sign, digs, dp)
    return _fmt_f(sign, digs, dp)


def plain_decimal(text_or_float):
    """Plain (non-exponent) text of the shortest round-trip digits of a float."""
    f = text_or_float
    sign, digs, dp = _shortest(f)
    if digs == "0":
        return "0"
    return _fmt_f(sign, digs, dp)


# ---------------------------------------------------------------- calendar helpers

def fmt_instant(ns, offset_min=0, z=True):
    days, rem = divmod(ns + offset_min * 60 * NS, 86400 * NS)
    try:
        d = date.fromordinal(EPOCH_ORD + days)
    except (ValueError, OverflowError):
        return None
    secs, frac = divmod(rem, NS)
    hh, r = divmod(secs, 3600)
    mm, ss = divmod(r, 60)
    out = "%04d-%02d-%02dT%02d:%02d:%02d" % (d.year, d.month, d.day, hh, mm, ss)
    if frac:
        out += "." + ("%09d" % frac).rstrip("0")
    if offset_min == 0 and z:
        return out + "Z"
    sgn = "+" if offset_min >= 0 else "-"
    om = abs(offset_min)
    return out + "%s%02d:%02d" % (sgn, om // 60, om % 60)


def fmt_wall_seconds(wall_ns):
    """YYYY-MM-DDTHH:MM:SS of a wall-clock value (fraction dropped)."""
    days, rem = divmod(wall_ns, 86400 * NS)
    try:
        d = date.fromordinal(EPOCH_ORD + days)
    except (ValueError, OverflowError):
        return None
    secs = rem // NS
    hh, r = divmod(secs, 3600)
    mm, ss = divmod(r, 60)
    return "%04d-%02d-%02dT%02d:%02d:%02d" % (d.year, d.month, d.day, hh, mm, ss)


_RFC = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$")
_NAIVE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(\.\d+)?$")


def _ns_from_fields(y, mo, d, hh, mi, ss, frac):
    if not (1 <= mo <= 12 and 0 <= hh <= 23 and 0 <= mi <= 59 and 0 <= ss <= 59):
        return None
    try:
        dt = date(y, mo, d)
    except ValueError:
        return None
    days = dt.toordinal() - EPOCH_ORD
    fr = int((frac or "")[1:10].ljust(9, "0")) if frac else 0
    return ((days * 86400 + hh * 3600 + mi * 60 + ss) * NS) + fr


def parse_rfc3339(s):
    """-> (utc_ns, offset_minutes) or None. Seconds required, fraction optional, Z or numeric offset."""
    m = _RFC.match(s)
    if not m:
        return None
    y, mo, d, hh, mi, ss = (int(m.group(i)) for i in range(1, 7))
    wall = _ns_from_fields(y, mo, d, hh, mi, ss, m.group(7))
    if wall is None:
        return None
    z = m.group(8)
    if z == "Z":
        off = 0
    else:
        oh, om = int(z[1:3]), int(z[4:6])
        if oh > 23 or om > 59:
            return None
        off = (oh * 60 + om) * (1 if z[0] == "+" else -1)
    return wall - off * 60 * NS, off


def parse_loose_instant(s):
    """Subscription bound / now: RFC 3339 or a zone-less UTC wall clock. -> utc ns."""
    r = parse_rfc3339(s)
    if r:
        return r[0]
    s2 = s.replace(" ", "T", 1)
    m = _NAIVE.match(s2)
    if m:
        y, mo, d, hh, mi, ss = (int(m.group(i)) for i in range(1, 7))
        return _ns_from_fields(y, mo, d, hh, mi, ss, m.group(7))
    raise ValueError("bad instant " + s)


# ---------------------------------------------------------------- timestamps (EP-D)

_DEC = re.compile(r"^[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?$")
_NONFINITE = re.compile(r"^[+-]?(nan|inf|infinity)$", re.I)
_HEXF = re.compile(r"^[+-]?0[xX]([0-9a-fA-F]+\.?[0-9a-fA-F]*|\.[0-9a-fA-F]+)[pP][+-]?\d+$")
_MAX_SECONDS = Decimal(10) ** 17


def _decimal_of(text, limit=_MAX_SECONDS):
    d = Decimal(text)
    if not d.is_finite() or (limit is not None and abs(d) >= limit):
        raise InvalidTimestamp("out of range")
    return d


def _trunc_ms_text(d):
    """Emitted text: d seconds truncated toward zero to ms, shortest float64 text."""
    ms = int((d * 1000).to_integral_value(rounding="ROUND_DOWN"))
    t = Decimal(ms) / 1000
    if ms == 0 and d.is_signed():
        return "-0"
    return go_json_float(float(t))


def parse_timestamp(ts, profile="corrected"):
    """ts: Num | str | other. -> dict(emitted_text, match_ns, wall_ns, offset_min). Raises InvalidTimestamp."""
    if isinstance(ts, Num):
        kind = "num"
        text = ts.text
    elif isinstance(ts, str):
        if _DEC.match(ts):
            kind = "str"
            text = ts
        elif _NONFINITE.match(ts):
            raise NonFiniteTimestamp("non-finite timestamp")
        elif profile == "compat" and _HEXF.match(ts):
            kind = "str"
            text = repr(float.fromhex(ts))
        else:
            r = parse_rfc3339(ts)
            if r is None:
                raise InvalidTimestamp("invalid timestamp")
            utc_ns, off = r
            ms_ns = utc_ns - utc_ns % MS_NS
            # truncate toward zero to ms
            if utc_ns >= 0:
                t_ms = utc_ns // MS_NS
            else:
                t_ms = -((-utc_ns) // MS_NS)
            emitted = go_json_float(float(Decimal(t_ms) / 1000))
            if profile == "compat":
                return {"emitted_text": emitted, "match_ns": utc_ns, "wall_ns": utc_ns + off * 60 * NS,
                        "offset_min": off}
            return {"emitted_text": emitted, "match_ns": ms_ns, "wall_ns": ms_ns, "offset_min": 0}
    else:
        raise InvalidTimestamp("invalid timestamp")
    d = _decimal_of(text, None)
    if abs(d) >= _MAX_SECONDS:
        # beyond the contract: accepted, emitted in plain notation, instant clamped
        emitted = go_json_float(float(d)) if kind == "num" else _trunc_ms_text(d)
        big = (1 if d > 0 else -1) * _MAX_SECONDS * NS
        big = int(big)
        return {"emitted_text": emitted, "match_ns": big, "wall_ns": big, "offset_min": 0}
    if kind == "num" and profile == "compat":
        f = float(text)
        if math.isinf(f):
            raise InvalidTimestamp("out of range")
        emitted = go_json_float(f)
    else:
        emitted = _trunc_ms_text(d)
    if profile == "compat":
        f = float(text)
        frac, sec = math.modf(f)
        total = int(sec) * NS + int(frac * 1e9)
        total -= total % MS_NS
        return {"emitted_text": emitted, "match_ns": total, "wall_ns": total, "offset_min": 0}
    ms = int((d * 1000).to_integral_value(rounding="ROUND_FLOOR"))
    total = ms * MS_NS
    return {"emitted_text": emitted, "match_ns": total, "wall_ns": total, "offset_min": 0}


# ---------------------------------------------------------------- decode (EP-C)

_STR_FIELDS = ("organization_id", "external_subscription_id", "transaction_id", "code", "source")


def _read_ingested_at(v, profile):
    """-> (utc_ns or None, output text or None). Raises Undecodable."""
    if v is None or v == "":
        return None, None
    if isinstance(v, str):
        m = _NAIVE.match(v)
        if m:
            y, mo, d, hh, mi, ss = (int(m.group(i)) for i in range(1, 7))
            ns = _ns_from_fields(y, mo, d, hh, mi, ss, m.group(7))
            if ns is None:
                raise Undecodable("bad ingested_at")
            return ns, fmt_wall_seconds(ns)
        if _DEC.match(v):
            return _epoch_seconds(v)
        r = parse_rfc3339(v)
        if r is None:
            raise Undecodable("bad ingested_at")
        utc, off = r
        return utc, fmt_wall_seconds(utc + off * 60 * NS)
    if isinstance(v, Num):
        return _epoch_seconds(v.text)
    raise Undecodable("bad ingested_at type")


def _epoch_seconds(text):
    try:
        d = _decimal_of(text)
    except InvalidTimestamp:
        raise Undecodable("bad ingested_at")
    ns = int((d * NS).to_integral_value(rounding="ROUND_FLOOR"))
    out = fmt_wall_seconds(ns)
    if out is None:
        raise Undecodable("bad ingested_at")
    return ns, out


def _fold_key(k):
    return k.lower().replace("\u017f", "s")


def _fold_keys(d):
    out = {}
    for k, v in d.items():
        out[_fold_key(k)] = v
    return out


def decode(raw, profile="corrected"):
    """raw: bytes. -> event dict. Raises Undecodable.

    event keys: the five string fields, precise_total_amount_cents (str), properties (dict|None),
    timestamp (raw JSON value or None), source_metadata (dict|None), ingested_at (text|None),
    ingested_ns (int|None), post_processed (bool).
    """
    try:
        text = raw.decode("utf-8", errors="replace") if isinstance(raw, (bytes, bytearray)) else raw
        obj = loads_literal(text)
    except (ValueError, RecursionError) as e:
        raise Undecodable("invalid JSON: %s" % e)
    if obj is None:
        obj = {}
    if not isinstance(obj, dict):
        raise Undecodable("record is not a JSON object")
    obj = _fold_keys(obj)
    ev = {}
    for k in _STR_FIELDS:
        v = obj.get(k)
        if v is None:
            v = ""
        elif not isinstance(v, str):
            raise Undecodable("field %s must be a string" % k)
        ev[k] = v
    v = obj.get("precise_total_amount_cents")
    if v is None:
        v = ""
    elif isinstance(v, str):
        pass
    elif isinstance(v, Num) and profile != "compat":
        v = v.text
    else:
        raise Undecodable("field precise_total_amount_cents must be a string")
    ev["precise_total_amount_cents"] = v
    props = obj.get("properties")
    if props is not None and not isinstance(props, dict):
        raise Undecodable("properties must be an object")
    ev["properties"] = props
    ev["timestamp"] = obj.get("timestamp")
    sm = obj.get("source_metadata")
    post = False
    if sm is not None:
        if not isinstance(sm, dict):
            raise Undecodable("source_metadata must be an object")
        apm = _fold_keys(sm).get("api_post_processed")
        if apm is None:
            apm = False
        elif not isinstance(apm, bool):
            raise Undecodable("api_post_processed must be a boolean")
        post = apm
        sm = {"api_post_processed": apm}
    ev["source_metadata"] = sm
    ev["post_processed"] = post
    ing_ns, ing_text = _read_ingested_at(obj.get("ingested_at"), profile)
    ev["ingested_ns"] = ing_ns
    ev["ingested_at"] = ing_text
    return ev


def event_copy(ev, profile="corrected"):
    """The dead-letter copy of a decoded event (wire-formats section 4, field `event`) as a dict."""
    out = {
        "organization_id": ev["organization_id"],
        "external_subscription_id": ev["external_subscription_id"],
        "transaction_id": ev["transaction_id"],
        "code": ev["code"],
        "precise_total_amount_cents": ev["precise_total_amount_cents"],
        "properties": ev["properties"],
        "timestamp": _ts_copy(ev["timestamp"]),
        "source_metadata": ev["source_metadata"],
        "ingested_at": ev["ingested_at"],
    }
    if ev["source"]:
        out["source"] = ev["source"]
    return out


def _ts_copy(ts):
    if isinstance(ts, Num):
        try:
            return Raw(go_json_float(float(ts.text)))
        except Undecodable:
            return ts
    return ts


def decode_event_json(raw, profile="corrected"):
    ev = decode(raw, profile)
    return canon(event_copy(ev, profile), profile)


# ---------------------------------------------------------------- value (EP-F)

LABELS = {0: "count", 1: "sum", 2: "max", 3: "unique_count", 5: "weighted_sum", 6: "latest", 7: "custom"}


def label_of(code):
    try:
        return LABELS.get(int(code), "")
    except (TypeError, ValueError):
        return ""


def go_render(v):
    """The reference's internal rendering of a decoded JSON value (compat value text)."""
    if v is None:
        return "<nil>"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, str):
        return v
    if isinstance(v, Num):
        return go_g_float(float(v.text))
    if isinstance(v, dict):
        return "map[" + " ".join("%s:%s" % (k, go_render_nested(v[k])) for k in sorted(v)) + "]"
    if isinstance(v, list):
        return "[" + " ".join(go_render_nested(x) for x in v) + "]"
    return str(v)


def go_render_nested(v):
    if isinstance(v, Num):
        return go_v_float(float(v.text))
    return go_render(v)


_INT_LIT = re.compile(r"^-?\d+$")


def num_value_text(n):
    """Corrected value text of a number literal (RBD-13)."""
    t = n.text
    if _INT_LIT.match(t):
        s = t.lstrip("-").lstrip("0") or "0"
        return ("-" + s) if t.startswith("-") and s != "0" else s
    f = float(t)
    if math.isinf(f):
        d = Decimal(t)
        return format(d, "f")
    return plain_decimal(f)


def value_text(aggregation_type, field_name, properties, profile="corrected"):
    """`value` of the enriched record. aggregation_type: stored code (int or str)."""
    try:
        code = int(aggregation_type)
    except (TypeError, ValueError):
        code = -1
    if code == 0:
        return "1"
    present = properties is not None and field_name is not None and field_name in properties
    v = properties[field_name] if present else None
    if v is None:
        return "<nil>" if profile == "compat" else "0"
    if isinstance(v, str):
        return v
    if isinstance(v, Num):
        if profile == "compat":
            return go_g_float(float(v.text))
        return num_value_text(v)
    return go_render(v)


# ---------------------------------------------------------------- subscription matching (EP-H)

def _floor_ms(ns):
    return ns - ns % MS_NS


def _pick(cands):
    """cands: list of (started_ns, terminated_ns|None, sub) -> best by EP-H1 order."""
    best = None
    best_key = None
    for st, te, sub in cands:
        key = (1 if te is None else 0, te if te is not None else 0, st)
        if best_key is None or key > best_key:
            best, best_key = sub, key
    return best


def match_subscription(subs, org, ext_id, t, mode, profile, recurring=False, now_ns=None):
    """subs: list of dicts with id, organization_id, external_id, started_at (ns), terminated_at (ns|None).
    t: parse_timestamp result. Returns the matching sub dict or None."""

    def attempt(t_utc, t_wall):
        cands = []
        for s in subs:
            if s.get("organization_id", org) != org:
                continue
            e = s["external_id"]
            if profile == "compat" and mode == "cache":
                if not (e == ext_id or e.startswith(ext_id + ":")):
                    continue
            elif e != ext_id:
                continue
            st, te = s["started_at"], s.get("terminated_at")
            if profile == "compat":
                if mode == "db":
                    tt = t_wall
                    st = _floor_ms(st)
                    te = _floor_ms(te) if te is not None else None
                else:
                    tt = t_utc
            else:
                tt = _floor_ms(t_utc)
                st = _floor_ms(st)
                te = _floor_ms(te) if te is not None else None
            if st is None or st > tt:
                continue
            if te is not None and te < tt:
                continue
            cands.append((st, te, s))
        return _pick(cands)

    found = attempt(t["match_ns"], t["wall_ns"])
    if found is None and recurring and now_ns is not None:
        found = attempt(now_ns, now_ns)
    return found


# ---------------------------------------------------------------- commit offset, refresh member

def commit_offset(records, pending_before=None, profile="corrected"):
    unprocessed = [r["offset"] for r in records if not r["processed"]]
    if profile == "corrected" and pending_before:
        unprocessed += list(pending_before)
    if not unprocessed:
        return records[-1]["offset"] + 1 if records else None
    low = min(unprocessed)
    below = [r["offset"] for r in records if r["processed"] and r["offset"] < low]
    return max(below) + 1 if below else None


def refresh_member(org, sub_id, now_unix):
    now = int(now_unix)
    return "%s:%s|%d" % (org, sub_id, now // 10 * 10), now
