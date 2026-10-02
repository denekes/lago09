"""Plan minimum-commitment true-up (BE-IV-54..57) over a tiny billing-run simulator."""
import calendar
from datetime import date, datetime, timedelta, timezone
from fractions import Fraction
from types import SimpleNamespace

from periods import (parse_instant, fmt_instant, local_date, start_of_local_day_utc, end_of_local_day_utc,
                     period_of, days_between, clamp, _add_months, tzinfo)

STEP = {"weekly": None, "monthly": 1, "quarterly": 3, "semiannual": 6, "yearly": 12}


def minus_interval(D, interval, billing_time, anchor):
    """Base date B (BE-SP-12)."""
    if interval == "weekly":
        return D - timedelta(days=7)
    k = STEP[interval]
    y, m = _add_months(D.year, D.month, -k)
    B = clamp(y, m, D.day)
    if billing_time == "anniversary":
        last = D.day == calendar.monthrange(D.year, D.month)[1]
        if last and D.day < anchor.day:
            B = clamp(y, m, anchor.day)
    return B


def cut16(x):
    """Shortest round-trip digits of a float cut (not rounded) to 16 significant digits."""
    from decimal import Decimal, ROUND_DOWN
    d = Decimal(repr(float(x)))
    if d == 0:
        return Fraction(0)
    exp = d.adjusted()
    q = Decimal(1).scaleb(exp - 15)
    return Fraction(d.quantize(q, rounding=ROUND_DOWN))


def commitment_true_up(inp, G):
    A = SimpleNamespace(**G)
    COMPAT = A.COMPAT
    tz = inp.get("timezone", "UTC")
    plan = inp["plan"]
    interval = plan["interval"]
    amount = plan.get("amount_cents", 0)
    advance = plan.get("pay_in_advance", False)
    split = plan.get("bill_charges_monthly", False) and interval in ("yearly", "semiannual")
    cm = A.F(inp["commitment_amount_cents"])
    sub = inp["subscription"]
    started = parse_instant(sub["started_at"])
    billing_time = sub.get("billing_time", "calendar")
    anchor = local_date(started, tz)
    usage = inp.get("usage")
    events = [parse_instant(e) for e in (usage or {}).get("events", [])]
    uamount = A.F(usage["amount"]) if usage else None
    terminated_at = None

    lines = []  # dicts
    outs = []

    def full_period_of(d, itv=interval):
        return period_of(d, itv, billing_time, anchor)

    def first_month(D):
        if interval == "yearly":
            if billing_time == "calendar":
                return D.month == 1
            ps, _ = period_of(D, "monthly", billing_time, anchor)
            return ps.month == anchor.month
        if interval == "semiannual":
            if billing_time == "calendar":
                return D.month in (1, 7)
            ps, _ = period_of(D, "monthly", billing_time, anchor)
            return (ps.month - anchor.month) % 6 == 0
        return True

    for run in inp["billing_runs"]:
        at = parse_instant(run["at"])
        reason = run.get("reason", "subscription_periodic")
        D = local_date(at, tz)
        terminating = reason == "subscription_terminating"
        if terminating:
            terminated_at = at
        B = minus_interval(D, interval, billing_time, anchor)
        charge_itv = "monthly" if split else interval
        Bc = minus_interval(D, charge_itv, billing_time, anchor)

        # --- fee period and charges period (local dates)
        fee_period = None
        ch_period = None
        if reason == "subscription_starting":
            if not advance:
                outs.append(None)
                continue
            fee_period = full_period_of(D)
            ch_period = None
        elif terminating:
            fee_period = full_period_of(D) if not advance else None
            ch_period = period_of(D, charge_itv, billing_time, anchor)
            if advance:
                fee_period = None
        else:
            if advance:
                fee_period = full_period_of(D)
                ch_period = period_of(Bc, charge_itv, billing_time, anchor)
            else:
                fee_period = full_period_of(B)
                ch_period = period_of(Bc if split else B, charge_itv, billing_time, anchor)

        line = {"fees": [], "sub": None, "terminated": terminating}
        fees_total = 0

        # --- subscription fee
        if fee_period is not None:
            ps, pe = fee_period
            plan_len = (pe - ps).days + 1
            from_dt = start_of_local_day_utc(ps, tz)
            sday = start_of_local_day_utc(local_date(started, tz), tz)
            if from_dt < sday:
                from_dt = sday
            to_dt = end_of_local_day_utc(pe, tz)
            if terminating and to_dt > at:
                to_dt = at.replace(microsecond=0) if at.microsecond < 500000 else (at.replace(microsecond=0) + timedelta(seconds=1))
            if to_dt < started:
                to_dt = started
            # gate for yearly / semiannual
            gate = True
            if interval in ("yearly", "semiannual"):
                if advance:
                    gate = first_month(D) or not any(l["sub"] for l in lines)
                else:
                    gate = terminating or first_month(D)
            if gate:
                full = False
                if advance and billing_time == "anniversary":
                    full = True
                elif started and local_date(started, tz) < ps:
                    full = True
                if full and not (terminating and not advance):
                    fa, fp = Fraction(amount), Fraction(amount)
                else:
                    sdp = float(amount) / plan_len if COMPAT else Fraction(amount) / plan_len
                    days = days_between(from_dt, to_dt, tz) if not (to_dt.microsecond == 0 and False) else 0
                    val = days * sdp
                    if COMPAT:
                        fa = Fraction(A.rnd(Fraction(val)))
                        fp = cut16(val)
                    else:
                        fa = Fraction(A.rnd(val))
                        fp = val
                line["sub"] = {"amount": fa, "precise": fp, "from": from_dt, "to": to_dt,
                               "pstart": ps, "pend": pe}
                fees_total += fa
            line["from"] = from_dt
            line["to"] = to_dt
            line["fee_period"] = fee_period
        # --- usage charge
        if ch_period is not None and usage is not None:
            cs, ce = ch_period
            cfrom = start_of_local_day_utc(cs, tz)
            if cfrom < started:
                cfrom = started
            cto = end_of_local_day_utc(ce, tz)
            if terminating and cto >= at:
                cto = at
            if cfrom < cto:
                cnt = sum(1 for e in events if cfrom <= e <= cto)
                prec = uamount * cnt * 100
                ca = A.rnd(prec)
                line["fees"].append({"from": cfrom, "to": cto, "amount": Fraction(ca), "precise": prec})
                fees_total += ca
            if "from" not in line:
                line["from"] = cfrom
                line["to"] = cto
        lines.append(line)
        prev_lines = lines[:-1]

        # --- commitment
        commit = None
        rec = None
        if advance:
            for l in reversed(prev_lines):
                if l["sub"] is not None:
                    rec = l
                    break
        else:
            rec = line if line["sub"] is not None or True else None
            if line.get("sub") is None and "from" not in line:
                rec = None
        ok = rec is not None
        if ok and interval in ("yearly", "semiannual") and line["sub"] is None:
            ok = False
        if ok and rec is not None:
            rfrom = rec["sub"]["from"] if rec["sub"] else rec["from"]
            rto = rec["sub"]["to"] if rec["sub"] else rec["to"]
            rdate = local_date(rfrom, tz)
            Ps, Pe = full_period_of(rdate)
            Pstart = start_of_local_day_utc(Ps, tz)
            Pend = end_of_local_day_utc(Pe, tz)
            first = None
            for l in lines:
                lf = (l["sub"]["from"] if l["sub"] else l.get("from"))
                if lf is not None and Pstart <= lf <= Pend:
                    first = lf if first is None or lf < first else first
            if first is None:
                first = rfrom
            stop = rto
            if terminated_at is not None:
                stop = min(terminated_at, Pend)
                if advance:
                    stop = min(terminated_at, Pend)
                else:
                    stop = min(rto, stop) if rto <= Pend else stop
            covered = days_between(first, stop, tz)
            length = (Pe - Ps).days + 1
            ratio = covered / length if COMPAT else Fraction(covered, length)
            C = A.rnd(Fraction(float(cm) * ratio) if COMPAT else cm * ratio)
            Fsum = Fraction(0)
            Psum = Fraction(0)
            for l in lines:
                if l["sub"] is not None:
                    s = l["sub"]
                    if Pstart <= s["from"] and s["to"] <= Pend:
                        Fsum += s["amount"]
                        Psum += s["precise"]
                for cf in l["fees"]:
                    if Pstart <= cf["from"] and cf["to"] <= Pend:
                        Fsum += cf["amount"]
                        Psum += cf["precise"]
            if Fsum < C:
                ca = C - Fsum
                commit = {
                    "amount_cents": int(ca),
                    "precise_amount_cents": A.dec_str(C - Psum, 15),
                    "unit_amount_cents": int(ca),
                    "precise_unit_amount": A.dec_str(Fraction(repr(float(ca) / 100)), 15) if COMPAT else A.dec_str(ca / 100, 15),
                    "units": "1",
                    "from_datetime": fmt_instant(rfrom),
                    "to_datetime": fmt_instant(rto),
                }
                fees_total += ca
        outs.append({"fees_amount_cents": int(fees_total), "commitment": commit})
    return {"invoices": outs}
