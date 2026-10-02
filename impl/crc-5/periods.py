"""Billing-period calculator (kit area `periods`): boundaries, billing days, chains, subscription fee, lifecycle."""
from __future__ import annotations

import calendar
import math
import re
from dataclasses import dataclass
from datetime import date, datetime, time, timedelta, timezone
from decimal import ROUND_HALF_UP, Decimal
from fractions import Fraction
from zoneinfo import ZoneInfo

UTC = timezone.utc
ONE_US = timedelta(microseconds=1)
END_OF_DAY = time(23, 59, 59, 999999)
MIDNIGHT = time(0, 0, 0)
STEP = {"weekly": 0, "monthly": 1, "quarterly": 3, "semiannual": 6, "yearly": 12}
YEARLY_FACTOR = {"weekly": 52, "monthly": 12, "quarterly": 4, "semiannual": 2, "yearly": 1}


class KitError(Exception):
    def __init__(self, code, field=None, message=None):
        super().__init__(message or code)
        self.code, self.field, self.message = code, field, message


# ---------------------------------------------------------------- time helpers
_INSTANT = re.compile(r"^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})$")


def parse_instant(s):
    if s is None:
        return None
    m = _INSTANT.match(s)
    if not m:
        raise KitError("bad_input", message=f"bad instant {s!r}")
    y, mo, d, h, mi, se, frac, z = m.groups()
    us = int((frac or "0").ljust(9, "0")[:6])
    dt = datetime(int(y), int(mo), int(d), int(h), int(mi), int(se), us, tzinfo=UTC)
    if z != "Z":
        sign = 1 if z[0] == "+" else -1
        dt -= sign * timedelta(hours=int(z[1:3]), minutes=int(z[4:6]))
    return dt


def fmt_instant(dt):
    if dt is None:
        return None
    dt = dt.astimezone(UTC)
    base = dt.strftime("%Y-%m-%dT%H:%M:%S")
    return base + (f".{dt.microsecond:06d}" if dt.microsecond else "") + "Z"


def parse_date(s):
    return date.fromisoformat(s)


def round_second(dt):
    """Nearest whole second, half rounds up."""
    us = dt.microsecond
    base = dt.replace(microsecond=0)
    return base + timedelta(seconds=1) if us >= 500000 else base


def days_in_month(y, m):
    return calendar.monthrange(y, m)[1]


def clamp(y, m, d):
    return date(y, m, min(d, days_in_month(y, m)))


def add_months(d, k):
    idx = d.year * 12 + d.month - 1 + k
    return clamp(idx // 12, idx % 12 + 1, d.day)


class Zone:
    def __init__(self, name):
        self.name = name or "UTC"
        self.tz = ZoneInfo(self.name) if self.name != "UTC" else UTC

    def local_date(self, dt):
        return dt.astimezone(self.tz).date()

    def at(self, d, t):
        return datetime.combine(d, t, tzinfo=self.tz).astimezone(UTC)

    def start(self, d):
        return self.at(d, MIDNIGHT)

    def end(self, d):
        return self.at(d, END_OF_DAY)

    def offset(self, dt):
        return dt.astimezone(self.tz).utcoffset()

    def days_between(self, frm, to):
        """BE-DM-15/16: whole local days, any fraction rounded up."""
        lt = to.astimezone(self.tz)
        if lt.timetz().replace(tzinfo=None) == MIDNIGHT:
            to = to + timedelta(seconds=1)
        delta = (to - frm) + self.offset(frm) - self.offset(to)
        us = delta // ONE_US
        return -((-us) // 86_400_000_000)


# ---------------------------------------------------------------- period algebra
def month_index(d):
    return d.year * 12 + d.month - 1


def period_of(interval, billing_time, anchor, x):
    """(start, end) local dates of the period holding local date x."""
    if interval == "weekly":
        if billing_time == "anniversary":
            s = x - timedelta(days=(x.weekday() - anchor.weekday()) % 7)
        else:
            s = x - timedelta(days=x.weekday())
        return s, s + timedelta(days=6)
    n = STEP[interval]
    if billing_time == "anniversary":
        ai = month_index(anchor)
        k = month_index(x) - ((month_index(x) - ai) % n)
        s = clamp(k // 12, k % 12 + 1, anchor.day)
        if s > x:
            k -= n
            s = clamp(k // 12, k % 12 + 1, anchor.day)
        nxt = k + n
        e = clamp(nxt // 12, nxt % 12 + 1, anchor.day) - timedelta(days=1)
        return s, e
    k = month_index(x)
    k -= k % n if n else 0
    # calendar: monthly any month, quarterly Jan/Apr/.., semiannual Jan/Jul, yearly Jan
    if n == 1:
        k = month_index(x)
    elif n == 12:
        k = x.year * 12
    else:
        k = x.year * 12 + ((x.month - 1) // n) * n
    s = date(k // 12, k % 12 + 1, 1)
    nxt = k + n
    e = date(nxt // 12, nxt % 12 + 1, 1) - timedelta(days=1)
    return s, e


def length(per):
    return (per[1] - per[0]).days + 1


def base_date(interval, billing_time, anchor, d):
    """BE-SP-12: the date one interval before d (with the anniversary month-end correction)."""
    if interval == "weekly":
        return d - timedelta(days=7)
    n = STEP[interval]
    b = add_months(d, -n)
    if billing_time == "anniversary" and d.day == days_in_month(d.year, d.month) and d.day < anchor.day:
        idx = month_index(d) - n
        b = clamp(idx // 12, idx % 12 + 1, anchor.day)
    return b


def is_billing_day(plan, sub, anchor, t):
    interval = plan["interval"]
    bt = sub["billing_time"]
    split = interval in ("yearly", "semiannual") and (plan["bill_charges_monthly"] or plan["bill_fixed_charges_monthly"])
    last = t.day == days_in_month(t.year, t.month)

    def day_match():
        return anchor.day == t.day or (last and anchor.day > t.day)

    if bt == "calendar":
        if interval == "weekly":
            return t.weekday() == 0
        if split or interval == "monthly":
            return t.day == 1
        if interval == "quarterly":
            return t.day == 1 and t.month in (1, 4, 7, 10)
        if interval == "semiannual":
            return t.day == 1 and t.month in (1, 7)
        return t.day == 1 and t.month == 1
    if interval == "weekly":
        return t.weekday() == anchor.weekday()
    if split or interval == "monthly":
        return day_match()
    if interval == "quarterly":
        return day_match() and (t.month - anchor.month) % 3 == 0
    if interval == "semiannual":
        return day_match() and (t.month - anchor.month) % 6 == 0
    return t.month == anchor.month and (
        t.day == anchor.day or (t.month == 2 and t.day == 28 and not calendar.isleap(t.year) and anchor.day in (28, 29))
    )


# ---------------------------------------------------------------- input normalisation
def norm_plan(p):
    p = dict(p or {})
    p.setdefault("pay_in_advance", False)
    p.setdefault("amount_cents", 100)
    p["bill_charges_monthly"] = bool(p.get("bill_charges_monthly"))
    p["bill_fixed_charges_monthly"] = bool(p.get("bill_fixed_charges_monthly"))
    tp = p.get("trial_period")
    p["trial"] = Fraction(str(tp)) if tp not in (None, "") else Fraction(0)
    return p


def norm_sub(s):
    s = dict(s or {})
    s.setdefault("billing_time", "calendar")
    sa = parse_instant(s["subscription_at"])
    s["subscription_at"] = sa
    s["started_at"] = parse_instant(s["started_at"]) if "started_at" in s and s["started_at"] is not None else (
        None if "started_at" in s else sa)
    s["terminated_at"] = parse_instant(s.get("terminated_at"))
    s.setdefault("next_subscription", "none")
    if "status" not in s:
        s["status"] = "terminated" if s["terminated_at"] else "active"
    ca = s.get("created_at")
    s["created_at"] = parse_instant(ca) if ca else (s["started_at"] or sa)
    s["ending_at"] = parse_instant(s.get("ending_at"))
    s["trial_ended_at"] = parse_instant(s.get("trial_ended_at"))
    return s


def norm_prev_sub(p):
    if not p:
        return None
    p = dict(p)
    p["started_at"] = parse_instant(p.get("started_at"))
    return p


def terminated_reached(sub, at):
    if sub["status"] != "terminated" or sub["terminated_at"] is None:
        return False
    return round_second(sub["terminated_at"]) <= round_second(at)


# ---------------------------------------------------------------- boundaries
def first_month(plan, sub, anchor, d):
    """BE-SP-18: d falls in the first month of the plan period."""
    interval = plan["interval"]
    if sub["billing_time"] == "calendar":
        return d.month == 1 if interval == "yearly" else d.month in (1, 7)
    s, _ = period_of("monthly", "anniversary", anchor, d)
    if interval == "yearly":
        return s.month == anchor.month
    return (s.month - anchor.month) % 6 == 0


def compute(plan, sub, zone, at, current=False, prev=None, profile="compat"):
    anchor = zone.local_date(sub["subscription_at"])
    bt = sub["billing_time"]
    D = zone.local_date(at)
    started = sub["started_at"]
    advance = plan["pay_in_advance"]
    interval = plan["interval"]
    succ = sub["next_subscription"] != "none"
    downg = sub["next_subscription"] == "downgrade"
    T = terminated_reached(sub, at)
    splittable = interval in ("yearly", "semiannual")
    split_c = splittable and plan["bill_charges_monthly"]
    split_f = splittable and plan["bill_fixed_charges_monthly"]

    def dates(iv, Tq):
        B = D if current else base_date(iv, bt, anchor, D)
        fee = D if (advance or (Tq and not downg)) else B
        cdate = D if (Tq and not succ) else (B if advance else fee)
        return B, fee, cdate

    B, fee_date, charges_date = dates(interval, T)
    # monthly family reads termination against 00:00 UTC of D (RBD-103 compat)
    if profile == "compat":
        mid = datetime.combine(D, MIDNIGHT, tzinfo=UTC)
        Tm = sub["status"] == "terminated" and sub["terminated_at"] is not None and \
            round_second(sub["terminated_at"]) <= round_second(mid)
    else:
        Tm = T
    cdates = dates("monthly", Tm) if split_c else (B, fee_date, charges_date)
    fdates = dates("monthly", Tm) if split_f else (B, fee_date, charges_date)

    fee_per = period_of(interval, bt, anchor, fee_date)
    c_iv = "monthly" if split_c else interval
    f_iv = "monthly" if split_f else interval
    c_per = period_of(c_iv, bt, anchor, cdates[2])
    f_per = period_of(f_iv, bt, anchor, fdates[2])

    out = {}
    frm = zone.start(fee_per[0])
    if started is not None and frm < started:
        frm = zone.start(zone.local_date(started))
    to = zone.end(fee_per[1])
    if T and to > round_second(sub["terminated_at"]):
        to = round_second(sub["terminated_at"])
    if started is not None and to < started:
        to = started
    out["from_datetime"], out["to_datetime"] = frm, to

    def window(per, key):
        cf = zone.start(per[0])
        if prev and prev["timezone"] != zone.name:
            end_s = prev.get(key) or prev.get("charges_to_datetime")
            if end_s:
                c = parse_instant(end_s) + timedelta(seconds=1)
                if abs(cf - c) <= timedelta(hours=26):
                    cf = c
        if started is not None and cf < started:
            cf = started
        ct = zone.end(per[1])
        if sub["status"] == "terminated" and sub["terminated_at"] is not None and sub["terminated_at"] <= ct:
            ct = sub["terminated_at"]
        if started is not None and ct < started:
            ct = started
        return cf, ct

    cf, ct = window(c_per, "charges_to_datetime")
    ff, ft = window(f_per, "fixed_charges_to_datetime")
    first = first_month(plan, sub, anchor, D) if splittable else True
    usage_present = not (splittable and plan["bill_fixed_charges_monthly"] and not plan["bill_charges_monthly"]
                         and not first and not current)
    fixed_present = not (splittable and plan["bill_charges_monthly"] and not plan["bill_fixed_charges_monthly"]
                         and not first)
    out["charges_from_datetime"], out["charges_to_datetime"] = (cf, ct) if usage_present else (None, None)
    out["fixed_charges_from_datetime"], out["fixed_charges_to_datetime"] = (ff, ft) if fixed_present else (None, None)
    out["fixed_charges_period_to_datetime"] = ft
    out["period_days"] = length(fee_per)
    out["charges_duration_days"] = length(c_per)
    out["fixed_charges_duration_days"] = length(f_per)
    cur = period_of(interval, bt, anchor, D)
    out["next_end_of_period"] = zone.end(cur[1])
    out["current_beginning_of_period"] = zone.start(cur[0])
    out["previous_beginning_of_period"] = zone.start(period_of(interval, bt, anchor, B)[0])
    out["_fee_per"] = fee_per
    out["_terminated"] = T
    return out


BOUND_KEYS = ["from_datetime", "to_datetime", "charges_from_datetime", "charges_to_datetime",
              "fixed_charges_from_datetime", "fixed_charges_to_datetime", "fixed_charges_period_to_datetime",
              "next_end_of_period", "current_beginning_of_period", "previous_beginning_of_period"]


def render(b, keys=BOUND_KEYS, extra=("period_days", "charges_duration_days", "fixed_charges_duration_days")):
    o = {k: fmt_instant(b[k]) for k in keys if k in b}
    for k in extra:
        if k in b:
            o[k] = b[k]
    return o


def prep(inp):
    plan = norm_plan(inp.get("plan"))
    sub = norm_sub(inp.get("subscription"))
    zone = Zone(inp.get("timezone") or "UTC")
    return plan, sub, zone


def op_boundaries(inp, profile):
    plan, sub, zone = prep(inp)
    b = compute(plan, sub, zone, parse_instant(inp["billing_at"]), bool(inp.get("current_usage")),
                inp.get("previous_invoice"), profile)
    return render(b)


# ---------------------------------------------------------------- invoice boundaries
def op_invoice_boundaries(inp, profile):
    plan, sub, zone = prep(inp)
    at = parse_instant(inp["billing_at"])
    reason = inp["invoicing_reason"]
    prev = inp.get("previous_invoice")
    T = terminated_reached(sub, at)
    current = reason == "progressive_billing" or (T and sub["next_subscription"] == "upgrade")
    if reason == "subscription_periodic" and inp.get("previous_period_invoiced"):
        raise KitError("duplicated_invoices")
    b = None
    if sub["status"] == "terminated" and sub["next_subscription"] == "none" and sub["started_at"] is not None \
            and at - timedelta(days=1) >= sub["started_at"]:
        active = dict(sub, status="active", terminated_at=None)
        x = compute(plan, active, zone, at - timedelta(days=1), True, prev, profile)["charges_to_datetime"]
        if x is not None and at >= x and at - x < timedelta(days=1):
            if not inp.get("previous_period_invoiced"):
                b = compute(plan, active, zone, at, False, prev, profile)
    if b is None:
        b = compute(plan, sub, zone, at, current, prev, profile)
    out = render(b, BOUND_KEYS[:6], ())
    out["recurring"] = reason == "subscription_periodic"
    if reason == "upgrading":
        reason = "subscription_terminating" if sub["status"] == "terminated" else "subscription_starting"
    out["invoicing_reason"] = reason
    return out


# ---------------------------------------------------------------- billing days / periodic / chain
def op_billing_days(inp, profile):
    plan, sub, zone = prep(inp)
    anchor = zone.local_date(sub["subscription_at"])
    d0, d1 = parse_date(inp["from_date"]), parse_date(inp["to_date"])
    hour = inp.get("utc_hour")
    res = []
    d = d0
    while d <= d1:
        if hour is None:
            t = d
        else:
            t = zone.local_date(datetime.combine(d, time(hour, 10), tzinfo=UTC))
        if is_billing_day(plan, sub, anchor, t):
            res.append(d.isoformat())
        d += timedelta(days=1)
    return {"dates": res}


def op_periodic_billing(inp, profile):
    plan, sub, zone = prep(inp)
    anchor = zone.local_date(sub["subscription_at"])
    r = parse_instant(inp["billing_at"])
    t = zone.local_date(r)
    none = {"action": "none"}
    if sub["status"] != "active" or not is_billing_day(plan, sub, anchor, t):
        return none
    if sub["started_at"] is None or not zone.local_date(sub["started_at"]) < t:
        return none
    created_d = zone.local_date(sub["created_at"]) if profile == "corrected" else sub["created_at"].astimezone(UTC).date()
    run_d = t if profile == "corrected" else r.date()
    if not created_d <= run_d:
        return none
    if sub["ending_at"] is not None and zone.local_date(sub["ending_at"]) == t:
        return none
    for s in inp.get("recurring_invoices_at") or []:
        if zone.local_date(parse_instant(s)) == t:
            return none
    return {"action": "rotate" if sub["next_subscription"] == "downgrade" else "bill"}


def op_chain(inp, profile):
    plan, sub, zone = prep(inp)
    anchor = zone.local_date(sub["subscription_at"])
    d = parse_date(inp["from_date"])
    out = []
    guard = 0
    while len(out) < inp["count"] and guard < 4000:
        guard += 1
        if is_billing_day(plan, sub, anchor, d):
            b = compute(plan, sub, zone, zone.at(d, time(12, 0)), False, None, profile)
            out.append({"billing_date": d.isoformat(), "from_datetime": fmt_instant(b["from_datetime"]),
                        "to_datetime": fmt_instant(b["to_datetime"]),
                        "charges_from_datetime": fmt_instant(b["charges_from_datetime"]),
                        "charges_to_datetime": fmt_instant(b["charges_to_datetime"]),
                        "period_days": b["period_days"]})
        d += timedelta(days=1)
    return {"periods": out}


# ---------------------------------------------------------------- trial
def initial_start(sub, prev):
    cands = [x for x in (sub["started_at"], prev["started_at"] if prev else None) if x is not None]
    return min(cands) if cands else sub["subscription_at"]


def frac_days(f):
    return timedelta(microseconds=int(round(f * 86_400_000_000)))


def trial_points(plan, sub, prev):
    """(initial start, trial end instant, trial end day) or (initial, None, None) without trial."""
    ini = initial_start(sub, prev)
    if plan["trial"] <= 0:
        return ini, None, None
    midnight = datetime.combine(ini.astimezone(UTC).date(), MIDNIGHT, tzinfo=UTC)
    return ini, ini + frac_days(plan["trial"]), midnight + frac_days(plan["trial"])


def in_trial(plan, sub, prev, at):
    ini, end, _ = trial_points(plan, sub, prev)
    return end is not None and sub["trial_ended_at"] is None and ini <= at and end > at


def op_trial_end(inp, profile):
    plan, sub, zone = prep(inp)
    prev = norm_prev_sub(inp.get("previous_subscription"))
    at = parse_instant(inp["at"])
    ini, end, day = trial_points(plan, sub, prev)
    return {"trial_end_datetime": fmt_instant(end), "trial_end_date": day.date().isoformat() if day else None,
            "initial_started_at": fmt_instant(ini), "in_trial": in_trial(plan, sub, prev, at)}


# ---------------------------------------------------------------- single-day price and subscription fee
def f_str(x):
    """Plain decimal text of a float (shortest round-trip digits)."""
    return format(Decimal(repr(float(x))), "f")


def cut16(x):
    """Shortest round-trip digits of a binary64, cut (not rounded) to 16 significant digits."""
    d = Decimal(repr(float(x)))
    sign, digits, exp = d.as_tuple()
    if len(digits) > 16:
        cut = len(digits) - 16
        digits = digits[:16]
        exp += cut
    return format(Decimal((sign, digits, exp)), "f")


def half_up_int(x):
    if isinstance(x, float):
        x = Decimal(x)
    return int(Decimal(x).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def op_single_day_price(inp, profile):
    plan, sub, zone = prep(inp)
    amount = inp.get("plan_amount_cents", plan["amount_cents"])
    anchor = zone.local_date(sub["subscription_at"])
    if inp.get("from_date"):
        x = parse_date(inp["from_date"])
        n = length(period_of(plan["interval"], sub["billing_time"], anchor, x))
    else:
        b = compute(plan, sub, zone, parse_instant(inp["billing_at"]), bool(inp.get("current_usage")), None, profile)
        n = length(b["_fee_per"])
    return {"value": f_str(amount / n), "period_days": n}


def _frac_str(fr, places):
    q = Decimal(fr.numerator) / Decimal(fr.denominator)
    return format(q.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP), "f")


def yearly_amount(plan):
    return plan["amount_cents"] * YEARLY_FACTOR[plan["interval"]]


def op_subscription_fee(inp, profile):
    plan, sub, zone = prep(inp)
    prev = norm_prev_sub(inp.get("previous_subscription"))
    b = inp["boundaries"]
    frm, to, ts = parse_instant(b["from_datetime"]), parse_instant(b["to_datetime"]), parse_instant(b["timestamp"])
    inv_created = parse_instant(inp["invoice_created_at"]) if inp.get("invoice_created_at") else ts
    others = [parse_instant(x) for x in inp.get("other_subscription_fees_created_at") or []]
    count = inp.get("invoice_count") or 1 + len(others)
    advance = plan["pay_in_advance"]
    interval = plan["interval"]
    anchor = zone.local_date(sub["subscription_at"])
    D = zone.local_date(ts)
    status = sub["status"]

    # ---- gate (BE-SP-46..48)
    created = True
    if advance and others:
        if profile == "corrected":
            lo, hi = zone.start(D), zone.end(D)
        else:
            lo = datetime.combine(D, MIDNIGHT, tzinfo=UTC)
            hi = lo + timedelta(days=1) - ONE_US
        if any(lo <= o <= hi for o in others):
            created = False
    if created and interval in ("yearly", "semiannual"):
        fm = first_month(plan, sub, anchor, D)
        started_past = _started_in_past(sub, zone if profile == "corrected" else None)
        if advance and not started_past:
            ok = fm or not others
        elif advance:
            if sub["billing_time"] == "calendar":
                first_plan_period = D.year == anchor.year
            else:
                s, _ = period_of("monthly", "anniversary", anchor, D)
                first_plan_period = s.month == anchor.month and s.year == anchor.year
            ok = fm and not first_plan_period
        else:
            ok = status == "terminated" or fm
        created = ok
    if created and in_trial(plan, sub, prev, inv_created):
        _, tend, _ = trial_points(plan, sub, prev)
        if zone.local_date(tend) != D:
            created = False
    if created:
        created = status in ("active", "incomplete") or (
            status == "terminated" and (not advance or (sub["terminated_at"] and sub["terminated_at"] > inv_created)))

    # ---- basis (BE-SP-39)
    run = compute(plan, sub, zone, ts, False, None, profile)
    nxt = sub["next_subscription"]
    zc = zone if profile == "corrected" else None
    if status == "terminated" and not advance and nxt in ("upgrade", "none"):
        basis = "terminated"
    elif prev is not None and count <= 1 and prev["amount_cents"] * YEARLY_FACTOR[prev["interval"]] <= yearly_amount(plan):
        basis = "upgraded"
    elif (advance and sub["billing_time"] == "anniversary" and prev is None) or any(o < inv_created for o in others) \
            or (_started_in_past(sub, zc) and advance) \
            or (_started_in_past(sub, zc) and sub["started_at"] is not None and sub["started_at"] < run["previous_beginning_of_period"]):
        basis = "full_period"
    else:
        basis = "first_period"

    _, tend, tday = trial_points(plan, sub, prev)
    amount = plan["amount_cents"]

    def sdp(x_date):
        return amount / length(period_of(interval, sub["billing_time"], anchor, x_date))

    def day_count(f, t, minus_one=False):
        n = zone.days_between(f, t)
        return max(n - 1, 0) if minus_one else n

    exact = profile == "corrected"
    value = None  # float (compat) or Fraction (corrected)

    def prorate(days, price_date, default=False):
        if default:
            n = run["period_days"]
        else:
            n = length(period_of(interval, sub["billing_time"], anchor, price_date))
        if exact:
            return Fraction(days * amount, n)
        return days * (amount / n)

    if basis in ("terminated", "upgraded"):
        f2 = frm
        zero = False
        if tend is not None:
            if tend >= to:
                zero = True
            elif frm < tend < to:
                f2 = tend
        if zero:
            value = 0
        elif basis == "terminated":
            days = day_count(f2, to, minus_one=(nxt == "upgrade"))
            value = prorate(days, zone.local_date(f2))
        else:
            value = prorate(day_count(f2, to), None, default=True)
    elif basis == "full_period":
        if tend is not None and tend >= to:
            value = 0
        elif tend is not None and frm < tend < to:
            value = prorate(day_count(tend, to), zone.local_date(frm))
        else:
            value = amount
    else:
        f2 = frm
        zero = False
        if tday is not None:
            if tday >= to:
                zero = True
            elif frm < tday < to:
                f2 = tend
        value = 0 if zero else prorate(day_count(f2, to), None, default=True)

    if isinstance(value, int):
        return {"created": created, "basis": basis, "precise_amount_cents": str(value), "amount_cents": value}
    if exact:
        return {"created": created, "basis": basis, "precise_amount_cents": _frac_str(value, 15),
                "amount_cents": half_up_int(Decimal(value.numerator) / Decimal(value.denominator))}
    return {"created": created, "basis": basis, "precise_amount_cents": cut16(value), "amount_cents": half_up_int(value)}


def _started_in_past(sub, zone=None):
    if zone is not None:
        return sub["started_at"] is not None and zone.local_date(sub["started_at"]) < zone.local_date(sub["created_at"])
    return sub["started_at"] is not None and sub["started_at"].astimezone(UTC).date() < sub["created_at"].astimezone(UTC).date()


# ---------------------------------------------------------------- lifecycle
def op_classify_change(inp, profile):
    cur, nxt = inp["current"], inp["next"]
    cy = cur["amount_cents"] * YEARLY_FACTOR[cur["interval"]]
    ny = nxt["amount_cents"] * YEARLY_FACTOR[nxt["interval"]]
    if nxt.get("same_plan"):
        kind = "same"
    else:
        kind = "upgrade" if ny >= cy else "downgrade"
    return {"kind": kind, "current_yearly_amount_cents": cy, "next_yearly_amount_cents": ny}


def utc_date_of(dt):
    return dt.astimezone(UTC).date()


def op_termination_credit_days(inp, profile):
    plan, sub, zone = prep(inp)
    term = sub["terminated_at"]
    if term is None:
        raise KitError("bad_input", "subscription.terminated_at")
    upgrade = bool(inp.get("upgrade"))
    b = compute(plan, sub, zone, term, False, None, profile)
    E = utc_date_of(b["next_end_of_period"])
    L = utc_date_of(zone.end(zone.local_date(term)))
    F = L - timedelta(days=1) if upgrade else L
    ordn = lambda d: Fraction(d.toordinal())
    Ef, Ff = ordn(E), ordn(F)
    ini, tend, tday = trial_points(plan, sub, None)
    TE = None
    if tday is not None:
        TE = Fraction(tday.toordinal()) + Fraction(tday.hour * 3600 + tday.minute * 60 + tday.second, 86400) \
            + Fraction(tday.microsecond, 86_400_000_000)
        if TE >= Ff:
            Ff = Ef if TE > Ef else TE - 1
    diff = Ef - Ff
    remaining = max(int(diff) if diff >= 0 else -int(-diff), 0)
    S = Fraction(utc_date_of(b["from_datetime"]).toordinal())
    if TE is not None and TE > S:
        S = TE
    used = max(int(min(Fraction(L.toordinal()), Ef) - S + 1), 0)
    anchor = zone.local_date(sub["subscription_at"])
    n = length(period_of(plan["interval"], sub["billing_time"], anchor, zone.local_date(term)))
    amt = inp.get("fee_plan_amount_cents")
    amt = plan["amount_cents"] if amt is None else amt
    if profile == "compat":
        price = amt / n
        return {"remaining_days": remaining, "used_days": used, "period_days": n, "day_price": f_str(price),
                "unused_amount_cents": f_str(remaining * price), "next_end_of_period": fmt_instant(b["next_end_of_period"])}
    price = Fraction(amt, n)
    return {"remaining_days": remaining, "used_days": used, "period_days": n, "day_price": _frac_str(price, 15),
            "unused_amount_cents": _frac_str(price * remaining, 15), "next_end_of_period": fmt_instant(b["next_end_of_period"])}


def op_create_status(inp, profile):
    plan = norm_plan(inp["plan"])
    zone = Zone(inp.get("timezone") or "UTC")
    sa = parse_instant(inp["subscription_at"])
    now = parse_instant(inp["now"])
    started = sa
    pt = parse_instant(inp.get("previous_terminated_at"))
    if pt is not None and inp.get("previous_on_termination_invoice", "generate") == "generate" and started < pt:
        started = pt
    ld, ln = zone.local_date(sa), zone.local_date(now)
    if ld > ln:
        return {"status": "pending", "started_at": None, "billed_at_creation": False, "invoicing_reasons": [],
                "webhooks": []}
    billed = False
    if ld == ln and plan["pay_in_advance"]:
        sub = {"subscription_at": sa, "started_at": started, "trial_ended_at": None}
        billed = not in_trial(plan, sub, None, now)
    return {"status": "active", "started_at": fmt_instant(started), "billed_at_creation": billed,
            "invoicing_reasons": ["subscription_starting"] if billed else [], "webhooks": ["subscription.started"]}


def op_terminate(inp, profile):
    plan, sub, zone = prep(inp)
    now = parse_instant(inp["now"])
    status = sub["status"]
    prev = inp.get("previous_subscription")
    skip = inp.get("on_termination_invoice") == "skip"
    nxt = sub["next_subscription"]
    if status == "canceled":
        raise KitError("subscription_canceled")
    if status == "incomplete":
        return {"status": "canceled", "canceled": True, "webhooks": ["subscription.canceled"], "invoicing_reasons": []}
    ev = "subscription.canceled" if profile == "corrected" else "subscription.terminated"
    if status == "pending":
        out = {"status": "canceled", "canceled": True, "webhooks": [ev], "invoicing_reasons": []}
        if prev:
            out["webhooks"] = ["subscription.updated", ev]
            out["previous_subscription_status"] = "terminated"
        return out
    if status == "terminated":
        return {"status": "terminated", "terminated_at": fmt_instant(sub["terminated_at"]), "canceled": False,
                "webhooks": [] if profile == "corrected" else ["subscription.terminated"], "invoicing_reasons": []}
    out = {"status": "terminated", "terminated_at": fmt_instant(sub["terminated_at"] or now), "canceled": False,
           "webhooks": ["subscription.updated", "subscription.terminated"],
           "invoicing_reasons": [] if skip else ["subscription_terminating"]}
    if nxt == "downgrade":
        out["next_subscription_status"] = "canceled"
    return out


OPS = {
    "periods.boundaries": op_boundaries,
    "periods.invoice_boundaries": op_invoice_boundaries,
    "periods.billing_days": op_billing_days,
    "periods.periodic_billing": op_periodic_billing,
    "periods.chain": op_chain,
    "periods.single_day_price": op_single_day_price,
    "periods.subscription_fee": op_subscription_fee,
    "periods.classify_change": op_classify_change,
    "periods.trial_end": op_trial_end,
    "periods.termination_credit_days": op_termination_credit_days,
    "periods.create_status": op_create_status,
    "periods.terminate": op_terminate,
}
