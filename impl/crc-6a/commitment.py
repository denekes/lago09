"""Minimum-commitment true-up over simulated billing runs (billing spec chapter 07 section 9, chapter 06)."""
from __future__ import annotations

import datetime as dt
import math
from decimal import Decimal
from zoneinfo import ZoneInfo

import periods as pr
from common import ZERO, dec, exact, frnd, rint

UTC = dt.timezone.utc
ONE_DAY = dt.timedelta(days=1)


def add_months(d: dt.date, n: int) -> dt.date:
    k = d.year * 12 + d.month - 1 + n
    y, m = divmod(k, 12)
    return pr.clamp(y, m + 1, d.day)


def round_s(t: dt.datetime) -> dt.datetime:
    base = t.replace(microsecond=0)
    return base + dt.timedelta(seconds=1) if t.microsecond >= 500000 else base


def cut16(f: float) -> Decimal:
    """Shortest round-trip digits cut (not rounded) to 16 significant digits."""
    d = Decimal(repr(f))
    if d == 0:
        return d
    exp = d.adjusted()
    q = Decimal(1).scaleb(exp - 15)
    from decimal import ROUND_DOWN
    return d.quantize(q, rounding=ROUND_DOWN)


def day_count(a, b, tz):
    z = ZoneInfo(tz)
    la = a.astimezone(z).replace(tzinfo=None)
    lb = b.astimezone(z).replace(tzinfo=None)
    if lb.hour == 0 and lb.minute == 0 and lb.second == 0 and lb.microsecond == 0:
        lb = lb + dt.timedelta(seconds=1)
    return math.ceil((lb - la).total_seconds() / 86400)


class Sim:
    def __init__(self, inp, ctx):
        self.ex = exact(ctx)
        self.compat = not self.ex
        self.tz = inp.get("timezone", "UTC")
        plan = inp["plan"]
        self.interval = plan["interval"]
        self.amount = int(plan.get("amount_cents", 0))
        self.advance = bool(plan.get("pay_in_advance", False))
        self.split = bool(plan.get("bill_charges_monthly", False)) and self.interval in ("yearly", "semiannual")
        self.commit = int(inp["commitment_amount_cents"])
        sub = inp["subscription"]
        self.started = pr.parse_instant(sub["started_at"])
        self.billing_time = sub.get("billing_time", "calendar")
        self.anchor = pr.to_local_date(self.started, self.tz)
        self.P = pr.Plan(self.interval, self.billing_time, self.anchor)
        self.Q = pr.Plan("monthly", self.billing_time, self.anchor) if self.split else self.P
        self.M = pr.Plan("monthly", self.billing_time, self.anchor)
        u = inp.get("usage")
        self.usage_amount = dec(u["amount"]) if u else None
        self.events = [pr.parse_instant(e) for e in (u or {}).get("events", [])]
        self.lines = []
        self.fees = []
        self.terminated_at = None

    # -- dates
    def ld(self, t):
        return pr.to_local_date(t, self.tz)

    def base_date(self, D, plan):
        n = pr.STEP[plan.interval]
        if n == 7:
            return D - dt.timedelta(days=7)
        B = add_months(D, -n)
        if plan.anniv:
            last = D.day == pr.calendar.monthrange(D.year, D.month)[1]
            if last and D.day < plan.anchor.day:
                k = D.year * 12 + D.month - 1 - n
                y, m = divmod(k, 12)
                B = pr.clamp(y, m + 1, plan.anchor.day)
        return B

    def first_month(self, D):
        if self.interval not in ("yearly", "semiannual"):
            return True
        if self.billing_time == "calendar":
            return D.month == 1 if self.interval == "yearly" else D.month in (1, 7)
        s, _ = self.M.period(D)
        am = self.anchor.month
        return s.month == am if self.interval == "yearly" else (s.month - am) % 6 == 0

    # -- boundaries of a billing run
    def boundaries(self, at, terminated, term_at):
        D = self.ld(at)
        fee_date = D if (self.advance or terminated) else self.base_date(D, self.P)
        ps, pe = self.P.period(fee_date)
        f_from = pr.local_start(ps, self.tz)
        if f_from < self.started:
            f_from = pr.local_start(self.ld(self.started), self.tz)
        f_to = pr.local_end(pe, self.tz)
        if terminated and f_to > round_s(term_at):
            f_to = round_s(term_at)
        if f_to < self.started:
            f_to = self.started
        # charges family
        tq = terminated
        if self.split and terminated and self.compat:
            midnight = dt.datetime(D.year, D.month, D.day, tzinfo=UTC)
            tq = term_at <= midnight
        cdate = D if tq else self.base_date(D, self.Q)
        cs, ce = self.Q.period(cdate)
        c_from = pr.local_start(cs, self.tz)
        if c_from < self.started:
            c_from = self.started
        c_to = pr.local_end(ce, self.tz)
        if terminated and term_at <= c_to:
            c_to = term_at
        if c_to < self.started:
            c_to = self.started
        return {"D": D, "f_from": f_from, "f_to": f_to, "f_ps": ps, "c_from": c_from, "c_to": c_to}

    def run_boundaries(self, at, terminating, term_at):
        if not terminating:
            return self.boundaries(at, False, None)
        # BE-SP-27: termination within 24 h after a period end bills the previous full period
        prev = at - ONE_DAY
        if prev >= self.started:
            Dp = self.ld(prev)
            _, ce = self.Q.period(Dp)
            X = pr.local_end(ce, self.tz)
            if at >= X and at - X < ONE_DAY:
                b = self.boundaries(at, False, None)
                dup = any(l["periodic"] and l["f_from"] == b["f_from"] and l["f_to"] == b["f_to"] for l in self.lines)
                if not dup:
                    return b
        return self.boundaries(at, True, term_at)

    # -- fees
    def sdp(self, x: dt.date):
        length = self.P.length(x)
        return self.amount / length if self.compat else Decimal(self.amount) / length

    def sub_fee(self, b, at, terminating, term_at, had_fee):
        D = b["D"]
        if self.interval in ("yearly", "semiannual"):
            fm = self.first_month(D)
            if self.advance:
                ok = fm or not had_fee
            else:
                ok = terminating or fm
            if not ok:
                return None
        f_from, f_to = b["f_from"], b["f_to"]
        if terminating and not self.advance:
            days = day_count(f_from, f_to, self.tz)
            s = self.sdp(self.ld(f_from))
            return self.make_fee_amount(days, s)
        if (self.advance and self.billing_time == "anniversary") or had_fee:
            return {"amount": self.amount, "precise": Decimal(self.amount)}
        days = day_count(f_from, f_to, self.tz)
        s = self.sdp(b["f_ps"])
        return self.make_fee_amount(days, s)

    def make_fee_amount(self, days, s):
        if self.compat:
            v = days * s
            return {"amount": frnd(v), "precise": cut16(v) if v != int(v) else Decimal(int(v))}
        v = days * s
        return {"amount": rint(v), "precise": v}

    def charge_fee(self, b):
        if self.usage_amount is None:
            return None
        if not b["c_from"] < b["c_to"]:
            return None
        units = sum(1 for e in self.events if b["c_from"] <= e <= b["c_to"])
        precise = Decimal(units) * self.usage_amount * 100
        return {"amount": rint(precise), "precise": precise, "from": b["c_from"], "to": b["c_to"]}

    # -- commitment
    def commitment(self, line):
        if self.advance:
            rec = None
            for l in reversed(self.lines[:-1]):
                if l["sub_fee"] is not None:
                    rec = l
                    break
            if rec is None:
                return None
        else:
            rec = line
        if self.interval in ("yearly", "semiannual") and line["sub_fee"] is None:
            return None
        ps, pe = self.P.period(self.ld(rec["f_from"]))
        P_start, P_end = pr.local_start(ps, self.tz), pr.local_end(pe, self.tz)
        inside = [l for l in self.lines if P_start <= l["f_from"] <= P_end]
        first = min(inside, key=lambda l: l["f_from"]) if inside else rec
        stop = min(self.terminated_at, P_end) if self.terminated_at is not None else rec["f_to"]
        covered = day_count(first["f_from"], stop, self.tz)
        length = day_count(P_start, P_end, self.tz)
        if self.compat:
            C = frnd(self.commit * (covered / length))
        else:
            C = rint(Decimal(self.commit) * covered / length)
        counted = [f for f in self.fees if P_start <= f["from"] <= P_end and f["kind"] != "commitment"]
        F = sum(f["amount"] for f in counted)
        if F >= C:
            return None
        precise = Decimal(C) - sum((f["precise"] for f in counted), ZERO)
        amt = C - F
        return {"amount": amt, "precise": precise, "from": rec["f_from"], "to": rec["f_to"]}

    def run(self, run):
        at = pr.parse_instant(run["at"])
        reason = run.get("reason", "subscription_periodic")
        terminating = reason == "subscription_terminating"
        if terminating:
            self.terminated_at = at
        b = self.run_boundaries(at, terminating, self.terminated_at)
        had_fee = any(l["sub_fee"] is not None for l in self.lines)
        fee = self.sub_fee(b, at, terminating, self.terminated_at, had_fee)
        line = {"periodic": reason == "subscription_periodic", "f_from": b["f_from"], "f_to": b["f_to"], "sub_fee": fee}
        self.lines.append(line)
        invoice_fees = []
        if fee is not None:
            f = {"kind": "subscription", "amount": fee["amount"], "precise": fee["precise"], "from": b["f_from"], "to": b["f_to"]}
            self.fees.append(f)
            invoice_fees.append(f)
        if reason != "subscription_starting":
            cf = self.charge_fee(b)
            if cf is not None:
                f = {"kind": "charge", "amount": cf["amount"], "precise": cf["precise"], "from": cf["from"], "to": cf["to"]}
                self.fees.append(f)
                invoice_fees.append(f)
            cm = self.commitment(line) if reason != "subscription_starting" else None
            if cm is not None:
                f = {"kind": "commitment", "amount": cm["amount"], "precise": cm["precise"], "from": cm["from"], "to": cm["to"]}
                self.fees.append(f)
                invoice_fees.append(f)
        else:
            cm = None
        total = sum(f["amount"] for f in invoice_fees)
        out = {"fees_amount_cents": total, "commitment": None}
        if cm is not None:
            amt = cm["amount"]
            pu = amt / 100 if self.compat else Decimal(amt) / 100
            out["commitment"] = {
                "amount_cents": amt,
                "precise_amount_cents": cm["precise"],
                "unit_amount_cents": amt,
                "precise_unit_amount": Decimal(repr(pu)) if self.compat else pu,
                "units": Decimal(1),
                "from_datetime": cm["from"].strftime("%Y-%m-%dT%H:%M:%SZ"),
                "to_datetime": cm["to"].strftime("%Y-%m-%dT%H:%M:%SZ"),
            }
        return out


def commitment_true_up(inp, ctx):
    sim = Sim(inp, ctx)
    return {"invoices": [sim.run(r) for r in inp["billing_runs"]]}


HANDLERS = {"invoice.commitment_true_up": commitment_true_up}
