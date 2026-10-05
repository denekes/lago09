"""Automatic credit note at termination of a pay-in-advance subscription (BE-CN-15..18)."""
import math
from datetime import timedelta
from fractions import Fraction
from types import SimpleNamespace

from periods import (parse_instant, local_date, end_of_local_day_utc, start_of_local_day_utc,
                     period_of)


def termination_note(inp, G):
    A = SimpleNamespace(**G)
    COMPAT = A.COMPAT
    tz = inp.get("timezone", "UTC")
    currency = inp.get("currency", "EUR")
    term = parse_instant(inp["terminated_at"])
    plan = inp["plan"]
    sub = inp["subscription"]
    invd = inp["invoice"]
    on_term = inp.get("on_termination", "credit")
    upgrade = inp.get("upgrade", False)
    started = parse_instant(sub["started_at"])
    sub_at = parse_instant(sub.get("subscription_at", sub["started_at"]))
    anchor = local_date(sub_at, tz)
    billing_time = sub.get("billing_time", "calendar")
    interval = plan["interval"]

    fee_amount = A.F(invd["subscription_fee_amount_cents"])
    if fee_amount == 0 or invd.get("status") == "voided":
        return {"credit_note": None}
    if upgrade and on_term in ("refund", "offset"):
        raise A.DomainError("server_error")

    tdate = local_date(term, tz)
    pstart, pend = period_of(tdate, interval, billing_time, anchor)
    period_days = (pend - pstart).days + 1
    E = end_of_local_day_utc(pend, tz).date()
    Fd = end_of_local_day_utc(tdate, tz).date()
    L = Fd
    if upgrade:
        Fd = Fd - timedelta(days=1)
    trial = A.F(plan.get("trial_period_days", 0))
    TE = None
    if trial > 0:
        init = started.date()
        TE_days = trial  # fractional days
        TE_ord = Fraction(init.toordinal()) + TE_days
        TE = TE_ord
        F_ord = Fraction(Fd.toordinal())
        E_ord = Fraction(E.toordinal())
        if TE >= F_ord:
            Fd_ord = E_ord if TE > E_ord else TE - 1
        else:
            Fd_ord = F_ord
        remaining = max(trunc_div(E_ord - Fd_ord), 0)
    else:
        remaining = max((E - Fd).days, 0)

    plan_amount = A.F(plan["amount_cents"]) if plan.get("amount_cents") else fee_amount
    if COMPAT:
        sdp = float(plan_amount) / period_days
        unused = sdp * remaining
    else:
        sdp = plan_amount / period_days
        unused = sdp * remaining
    if unused <= 0:
        return {"credit_note": None}
    unused_f = A.F(unused) if isinstance(unused, float) else unused
    if unused_f > fee_amount:
        unused_f = fee_amount

    # earlier notes' items on the subscription fee
    prev_cents = Fraction(0)
    for pn in inp.get("previous_credit_notes", []):
        for it in pn["items"]:
            if it["fee_id"] == "sub_fee":
                prev_cents += A.rnd(A.F(it["amount_cents"]))
    unused_f -= prev_cents
    if unused_f <= 0:
        return {"credit_note": None}
    item_amount = A.trunc_places(unused_f, 5)

    # invoice pipeline
    taxes = invd.get("taxes", [])
    fees = [{"id": "sub_fee", "amount_cents": int(fee_amount), "fee_type": "subscription", "taxes": taxes}]
    fees += list(invd.get("other_fees", []))
    invraw = {"currency": currency, "fees": fees, "applied_coupons": invd.get("applied_coupons", []),
              "payment_status": invd.get("payment_status", "pending"),
              "total_paid_amount_cents": invd.get("total_paid_amount_cents", 0)}
    ci = A.CNInvoice(invraw)
    for pn in inp.get("previous_credit_notes", []):
        n, e = A.compute_note(ci, pn, automatic=True)
        if n is not None:
            A.register_note(ci, n)

    fee = ci.by_id["sub_fee"]
    item = [{"fee": fee, "precise": item_amount, "cents": A.rnd(item_amount)}]
    am = A.note_amounts(ci, item, None)
    T = A.rnd(item_amount - am["adj"] + am["ptax"])

    paid = A.F(invd.get("total_paid_amount_cents", 0))
    sub_incl = A.F(ci.inv_out["sub_total_including_taxes_amount_cents"])
    if sub_incl != 0 and paid != 0:
        num = (fee.precise - fee.pc) + fee.taxes_precise
        paid_share = A.N(num) / A.N(sub_incl) * A.N(paid)
    else:
        paid_share = A.N(0)
    # used days (BE-SP-59)
    from_dt_date = max(pstart, started.date()) if False else None
    S = start_of_local_day_utc(pstart, tz)
    start_day = start_of_local_day_utc(local_date(started, tz), tz)
    if S < start_day:
        S = start_day
    S_date = S.date()
    if TE is not None and TE > Fraction(S_date.toordinal()):
        S_ord = TE
    else:
        S_ord = Fraction(S_date.toordinal())
    used_days = max(trunc_div(Fraction(min(L, E).toordinal()) - S_ord) + 1, 0)
    used_amount = (float(plan_amount) / period_days) * used_days if COMPAT else (plan_amount / period_days) * used_days
    uitem = [{"fee": fee, "precise": A.F(used_amount) if isinstance(used_amount, float) else used_amount,
              "cents": 0}]
    uam = A.note_amounts(ci, uitem, None)
    used = A.rnd(uitem[0]["precise"] - uam["adj"] + uam["ptax"])
    refund_f = min(paid_share - used, A.N(T))
    refund = A.rnd(refund_f) if refund_f > 0 else 0

    if on_term == "credit":
        credit, refund_amt, offset = T, 0, 0
    elif on_term == "refund":
        credit, refund_amt, offset = T - refund, refund, 0
    else:
        credit, refund_amt, offset = 0, refund, T - refund
    if credit == 0 and refund_amt == 0 and offset == 0:
        return {"credit_note": None}

    req = {"items": [{"fee_id": "sub_fee", "amount_cents": item_amount}],
           "credit_amount_cents": credit, "refund_amount_cents": refund_amt, "offset_amount_cents": offset}
    n, errors = A.compute_note(ci, req, automatic=True, skip_validation=True)
    if n is None:
        return {"credit_note": None}
    out = A.note_out(ci, n)
    A.register_note(ci, n)
    return {"credit_note": out}


def trunc_div(x):
    x = Fraction(x)
    return int(x.numerator // x.denominator) if x >= 0 else -int((-x).numerator // (-x).denominator)
