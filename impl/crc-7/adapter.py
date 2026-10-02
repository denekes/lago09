#!/usr/bin/env python3.12
"""CRC-7 adapter: wallets, progressive billing and alerts (kit adapter protocol v1)."""
from __future__ import annotations

import json
import os
import sys
from decimal import ROUND_CEILING, ROUND_DOWN, ROUND_FLOOR, ROUND_HALF_UP, Decimal
from datetime import datetime, timedelta, timezone as _tz
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                ".claude", "skills", "reimplementation-kit", "scripts"))
import adapter_ref as ar  # noqa: E402
from adapter_ref import KitError, dec, out_dec  # noqa: E402

ZERO = Decimal(0)
EXP = {"BHD": 3, "JOD": 3, "KWD": 3, "CLF": 4, "MRO": 1}
for _c in "BIF CLP DJF GNF HUF ISK JPY KMF KRW MGA PYG RWF UGX VND VUV XAF XOF XPF".split():
    EXP[_c] = 0


def exp(cur):
    return EXP.get(cur or "EUR", 2)


def rhu(d, places=0):
    return dec(d).quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)


def floor_places(d, places):
    return dec(d).quantize(Decimal(1).scaleb(-places), rounding=ROUND_DOWN)


def fdiv(a, b):
    """Binary floating point division (a float island of the reference), exact shortest text."""
    return Decimal(repr(float(a) / float(b)))


def fmul(a, b):
    return Decimal(repr(float(a) * float(b)))


def cents_to_credits(cents, rate, e):
    """BE-WL-4: round to whole minor units, to major, divide by rate (binary float)."""
    amount = rhu(cents, 0) / (Decimal(10) ** e)
    return fdiv(amount, rate)


def instant(s):
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s)


# ---------------------------------------------------------------- wallets.credits
def wallets_credits(inp, ctx):
    e = exp(inp.get("currency"))
    rate = dec(inp["rate_amount"])
    if inp.get("credits") is not None:
        credits = dec(inp["credits"])
        amount = rhu(credits * rate, e)
        cents = int(amount * (Decimal(10) ** e))
        invoiceable = inp.get("invoiceable", True)
        out_credits = fdiv(amount, rate) if invoiceable else credits
        floored = floor_places(credits, 5)
        return {"credits": out_credits, "amount": amount, "amount_cents": cents,
                "rounds_to_zero": bool(floored > 0 and cents == 0)}
    cents_in = rhu(inp["cents"], 0)
    amount = cents_in / (Decimal(10) ** e)
    return {"credits": fdiv(amount, rate), "amount": amount, "amount_cents": int(cents_in)}


# ---------------------------------------------------------------- wallets.top_up
def parse_amount(text):
    try:
        d = Decimal(text)
    except Exception:
        return None
    if not d.is_finite() or d < 0 or d > Decimal(10) ** 25 - 1:
        return None
    return d


def wallet_state(w):
    e = exp(w.get("currency"))
    rate = dec(w.get("rate_amount", "1"))
    bal = int(w.get("balance_cents", 0))
    if w.get("credits_balance") is not None:
        cb = dec(w["credits_balance"])
    else:
        cb = fdiv(Decimal(bal) / (Decimal(10) ** e), rate)
    return e, rate, bal, cb


def wallets_top_up(inp, ctx):
    w = inp["wallet"]
    e, rate, bal, cb = wallet_state(w)
    scale = Decimal(10) ** e
    errors = []
    if w.get("status", "active") == "terminated":
        errors.append(("wallet_is_terminated", "wallet_id"))
    amounts = {}
    for key in ("paid_credits", "granted_credits", "voided_credits"):
        raw = inp.get(key)
        if raw is None:
            continue
        d = parse_amount(raw)
        if d is None:
            errors.append((f"invalid_{key}", key))
            errors.append(("invalid_amount", key))
            continue
        amounts[key] = floor_places(d, 5)

    def money(credits):
        amount = rhu(credits * rate, e)
        return amount, int(amount * scale)

    for key in ("paid_credits", "granted_credits"):
        if key in amounts and amounts[key] > 0:
            _, c = money(amounts[key])
            if c == 0:
                errors.append(("amount_rounds_to_zero", key))
    if "paid_credits" in amounts and amounts["paid_credits"] > 0 and not inp.get("ignore_paid_top_up_limits"):
        _, c = money(amounts["paid_credits"])
        mn, mx = w.get("paid_top_up_min_amount_cents"), w.get("paid_top_up_max_amount_cents")
        if mn is not None and c < mn:
            errors.append(("amount_below_minimum", "paid_credits"))
        if mx is not None and c > mx:
            errors.append(("amount_above_maximum", "paid_credits"))
    if "voided_credits" in amounts and amounts["voided_credits"] > cb:
        errors.append(("insufficient_credits", "voided_credits"))
    if errors:
        raise KitError(errors[0][0], errors[0][1])

    txs = []
    consumed = dec(w.get("consumed_credits", "0"))
    consumed_cents = int(w.get("consumed_amount_cents", 0))
    p = amounts.get("paid_credits", ZERO)
    if p > 0:
        amount, c = money(p)
        txs.append({"transaction_status": "purchased", "status": "pending", "transaction_type": "inbound",
                    "credit_amount": fdiv(amount, rate), "amount": amount, "amount_cents": c})
    g = amounts.get("granted_credits", ZERO)
    if g > 0:
        amount, c = money(g)
        credits = fdiv(amount, rate)
        txs.append({"transaction_status": "granted", "status": "settled", "transaction_type": "inbound",
                    "credit_amount": credits, "amount": amount, "amount_cents": c})
        bal += c
        cb += credits
        if inp.get("reset_consumed_credits"):
            before = consumed
            consumed = max(ZERO, consumed - credits)
            consumed_cents = max(0, int(((before - credits) * rate * scale).to_integral_value(rounding=ROUND_FLOOR)))
    v = amounts.get("voided_credits", ZERO)
    if v > 0:
        amount, c = money(v)
        txs.append({"transaction_status": "voided", "status": "settled", "transaction_type": "outbound",
                    "credit_amount": v, "amount": amount, "amount_cents": c})
        bal -= c
        cb -= v
        consumed += v
        consumed_cents += c
    return {"transactions": txs,
            "wallet": {"balance_cents": bal, "credits_balance": cb, "consumed_credits": consumed,
                       "consumed_amount_cents": consumed_cents}}


# ---------------------------------------------------------------- consumption
def consume(inbound, outbound, inbound_id=None):
    """BE-WL-13..15: returns list of (id, amount)."""
    outbound = int(outbound)
    if inbound_id is not None:
        for t in inbound:
            if t.get("id") == inbound_id:
                if outbound > t["remaining_cents"]:
                    raise KitError("exceeds_remaining_transaction_amount", "amount_cents")
                return [(inbound_id, outbound)] if outbound > 0 else []
        raise KitError("wallet_transaction_not_found", "inbound_id")
    items = []
    for i, t in enumerate(inbound):
        items.append((t.get("priority", 50), 0 if t.get("status", "granted") == "granted" else 1, i,
                      t.get("id") or f"in{i + 1}", int(t["remaining_cents"]), t.get("status", "granted")))
    items = [x for x in items if x[4] > 0]
    items.sort(key=lambda x: x[:3])
    if outbound > sum(x[4] for x in items):
        raise KitError("exceeds_available_amount", "amount_cents")
    res, left = [], outbound
    for x in items:
        if left <= 0:
            break
        take = min(x[4], left)
        res.append((x[3], take, x[5]))
        left -= take
    return res


def wallets_consumption_order(inp, ctx):
    res = consume(inp["inbound"], inp["outbound_cents"], inp.get("inbound_id"))
    return {"consumptions": [{"inbound": r[0], "amount_cents": r[1]} for r in res]}


# ---------------------------------------------------------------- top-up amounts
def topup_amounts(rule, w, pending):
    e = exp(w.get("currency"))
    rate = dec(w.get("rate_amount", "1"))
    ongoing = dec(w.get("credits_ongoing_balance", "0"))
    mn, mx = w.get("paid_top_up_min_amount_cents"), w.get("paid_top_up_max_amount_cents")
    min_c = cents_to_credits(mn, rate, e) if mn is not None else None
    max_c = cents_to_credits(mx, rate, e) if mx is not None else None
    ignore = bool(rule.get("ignore_paid_top_up_limits"))
    paid_r = dec(rule.get("paid_credits", "0"))
    granted_r = dec(rule.get("granted_credits", "0"))
    if rule.get("method", "fixed") == "target":
        target = dec(rule.get("target_ongoing_balance", "0"))
        if rule.get("grants_target_top_up"):
            return ZERO, max(ZERO, target - ongoing)
        if ongoing >= target:
            return ZERO, ZERO
        paid = target - ongoing
        if min_c is not None and not ignore and paid < min_c:
            paid = min_c
        return paid, ZERO
    if rule.get("trigger", "threshold") == "interval":
        return paid_r, granted_r
    thr = rule.get("threshold_credits")
    if paid_r == 0 or thr is None:
        return paid_r, granted_r
    gap = dec(thr) - ongoing - granted_r - pending
    if gap < paid_r:
        paid = paid_r
    else:
        paid = paid_r * ((gap / paid_r).to_integral_value(rounding=ROUND_FLOOR) + 1)
    if max_c is not None and not ignore and paid > max_c:
        paid = max_c
    return paid, granted_r


def wallets_topup_amount(inp, ctx):
    paid, granted = topup_amounts(inp["rule"], inp.get("wallet") or {}, dec(inp.get("pending_credits", "0")))
    return {"paid_credits": paid, "granted_credits": granted}


def wallets_threshold_top_up(inp, ctx):
    rule, w = inp["rule"], inp.get("wallet") or {}
    now = instant(inp.get("now", "2024-03-15T12:00:00Z"))
    no = {"top_up": False}
    if inp.get("rule_status", "active") != "active" or not inp.get("state_changed", True):
        return no
    thr = rule.get("threshold_credits")
    ongoing = dec(w.get("credits_ongoing_balance", "0"))
    txs = inp.get("transactions") or []
    pending = sum((dec(t["credit_amount"]) for t in txs
                   if t.get("status", "pending") == "pending" and t.get("transaction_status", "purchased") == "purchased"),
                  ZERO)
    if thr is not None:
        if ongoing > dec(thr) or pending + ongoing > dec(thr):
            return no
    paid, granted = topup_amounts(rule, w, pending)
    if paid > 0:
        fails = [t for t in txs if t.get("status", "pending") == "failed" and t.get("source", "threshold") == "threshold"
                 and t.get("transaction_status", "purchased") == "purchased" and t.get("failed_at")]
        for f in fails:
            fa = instant(f["failed_at"])
            if now - fa < timedelta(hours=1):
                settled_after = any(t.get("settled_at") and t.get("transaction_status", "purchased") == "purchased"
                                    and instant(t["settled_at"]) > fa for t in txs)
                if not settled_after:
                    return no
    return {"top_up": True, "paid_credits": paid, "granted_credits": granted}


# ---------------------------------------------------------------- interval
def _last_dom(y, m):
    nxt = datetime(y + (m == 12), m % 12 + 1, 1)
    return (nxt - timedelta(days=1)).day


def wallets_interval_due(inp, ctx):
    tz = ZoneInfo(inp.get("timezone") or inp.get("billing_entity_timezone") or "UTC")
    now = instant(inp["now"])
    created = instant(inp["wallet_created_at"])
    anchor = instant(inp["rule_started_at"]) if inp.get("rule_started_at") else created
    a_local = anchor.astimezone(tz)
    today = now.astimezone(tz)
    nd = {"due": False}
    if inp.get("rule_expiration_at") and instant(inp["rule_expiration_at"]) <= now:
        return nd
    if ctx["profile"] == "corrected":
        if anchor > now:
            return nd
    else:
        if a_local.replace(tzinfo=None) > now.astimezone(_tz.utc).replace(tzinfo=None):
            return nd
    if created.astimezone(tz).date() == today.date():
        return nd
    for t in inp.get("interval_top_ups_at") or []:
        if instant(t).astimezone(tz).date() == today.date():
            return nd
    iv = inp["interval"]
    ad, am = a_local.day, a_local.month

    def day_rule():
        if today.day == ad:
            return True
        return today.day == _last_dom(today.year, today.month) and ad >= today.day

    if iv == "weekly":
        ok = a_local.isoweekday() == today.isoweekday()
    elif iv == "monthly":
        ok = day_rule()
    elif iv == "quarterly":
        ok = (today.month - am) % 3 == 0 and day_rule()
    elif iv == "semiannual":
        ok = (today.month - am) % 6 == 0 and day_rule()
    else:
        ok = today.month == am and (today.day == ad or
                                    (am == 2 and ad == 29 and today.day == 28 and _last_dom(today.year, 2) == 28))
    if not ok:
        return nd
    rule = {"trigger": "interval", "method": inp.get("method", "fixed"),
            "paid_credits": inp.get("paid_credits", "10"), "granted_credits": inp.get("granted_credits", "0"),
            "target_ongoing_balance": inp.get("target_ongoing_balance"), "ignore_paid_top_up_limits": True}
    paid, granted = topup_amounts(rule, {}, ZERO)
    if rule["method"] == "target" and paid == 0 and granted == 0:
        return nd
    return {"due": True, "paid_credits": paid, "granted_credits": granted}


# ---------------------------------------------------------------- allocation helpers
def norm_wallets(wallets, currency):
    res = []
    for i, w in enumerate(wallets):
        x = dict(w)
        x["id"] = w.get("id") or f"w{i + 1}"
        x["_i"] = i
        x["currency"] = w.get("currency") or currency
        x["e"] = exp(x["currency"])
        x["rate"] = dec(w.get("rate_amount", "1"))
        x["balance"] = Decimal(int(w.get("balance_cents", 0)))
        res.append(x)
    return res


def applicable(w, fee_type, metric, target):
    if target is not None:
        return w["id"] == target
    types = w.get("allowed_fee_types") or []
    metrics = w.get("billable_metric_codes") or []
    if fee_type == "charge" and metric in metrics:
        return True
    if fee_type in types:
        return True
    return not types and not metrics


def sort_wallets(ws):
    return sorted(ws, key=lambda w: (w.get("priority", 50), w["_i"]))


def wallets_allocate(inp, ctx):
    cur = inp.get("currency") or "EUR"
    ws = [w for w in sort_wallets(norm_wallets(inp["wallets"], cur))
          if w.get("status", "active") == "active" and w["balance"] > 0 and w["currency"] == cur]
    buckets = {}
    order = []
    premium = inp.get("premium", False)
    for f in inp["fees"]:
        ft = f.get("fee_type", "charge")
        sub = dec(f["amount_cents"]) - dec(f.get("precise_coupons_cents", "0"))
        if sub == 0:
            continue
        cap = sub + dec(f.get("taxes_precise_cents", "0")) - dec(f.get("precise_credit_notes_cents", "0"))
        if cap <= 0:
            continue
        metric = f.get("billable_metric_code", "m1") if ft == "charge" else None
        target = f.get("target_wallet_code") if (premium and ft == "charge") else None
        key = (ft, metric, target)
        if key not in buckets:
            buckets[key] = ZERO
            order.append(key)
        buckets[key] += cap
    total = Decimal(int(inp["invoice_total_cents"]))
    keys = sorted(order, key=lambda k: -buckets[k])
    d = total - sum(buckets.values(), ZERO)
    if keys and 0 < d <= len(keys):
        buckets[keys[0]] += d
    remainder = dict(buckets)
    inv_rem = total
    per = []
    for w in ws:
        taken = ZERO
        for k in keys:
            if remainder[k] <= 0 or inv_rem <= 0:
                continue
            if not applicable(w, k[0], k[1], k[2]):
                continue
            t = min(remainder[k], w["balance"] - taken, inv_rem)
            if t <= 0:
                continue
            taken += t
            remainder[k] -= t
            inv_rem -= t
        if taken > 0:
            per.append((w, taken))
    out, tot = [], 0
    all_trace = bool(inp["wallets"]) and all(w.get("traceable") for w in inp["wallets"])
    granted = purchased = 0
    for w, taken in per:
        cents = int(rhu(taken, 0))
        credits = cents_to_credits(taken, w["rate"], w["e"])
        out.append({"wallet": w["id"], "amount_cents": cents, "credit_amount": credits})
        tot += cents
        if all_trace:
            for r in consume(w.get("inbound") or [], cents):
                if r[2] == "granted":
                    granted += r[1]
                else:
                    purchased += r[1]
    res = {"per_wallet": out, "prepaid_credit_amount_cents": tot}
    if all_trace:
        res["prepaid_granted_credit_amount_cents"] = granted
        res["prepaid_purchased_credit_amount_cents"] = purchased
    return res


# ---------------------------------------------------------------- ongoing balance
def wallets_ongoing_balance(inp, ctx):
    cur = inp.get("currency") or "EUR"
    ws = sort_wallets(norm_wallets(inp["wallets"], cur))
    nets = {}

    def add(f, sign_fn):
        ft = f.get("fee_type", "charge")
        key = (ft, f.get("billable_metric_code", "m1") if ft == "charge" else None, None,
               f.get("currency") or cur)
        nets[key] = nets.get(key, ZERO) + sign_fn(f)

    for f in inp.get("current_usage_fees", []):
        add(f, lambda f: dec(f["amount_cents"]) + dec(f.get("taxes_cents", 0)))
        if f.get("pay_in_advance"):
            add(f, lambda f: -(dec(f["amount_cents"]) + dec(f.get("taxes_cents", 0))))
    for f in inp.get("draft_invoice_fees", []):
        add(f, lambda f: dec(f["amount_cents"]) + dec(f.get("taxes_cents", 0)) - dec(f.get("precise_coupons_cents", "0")))
    for f in inp.get("progressive_billing_fees", []):
        add(f, lambda f: -(dec(f["amount_cents"]) - dec(f.get("precise_coupons_cents", "0")) + dec(f.get("taxes_cents", 0))))
    budgets = {}
    for k, n in nets.items():
        budgets[k[3]] = budgets.get(k[3], ZERO) + n
    budgets = {c: max(ZERO, b) for c, b in budgets.items()}
    alloc = {w["id"]: ZERO for w in ws}
    pos = sorted((k for k, n in nets.items() if n > 0),
                 key=lambda k: (-nets[k], k[0], k[1] or "", k[2] or "", k[3]))
    for k in pos:
        net = nets[k]
        wl = [w for w in ws if w["currency"] == k[3] and applicable(w, k[0], k[1], k[2])]
        for i, w in enumerate(wl):
            if net <= 0 or budgets[k[3]] <= 0:
                break
            rem = min(net, budgets[k[3]])
            if w.get("threshold_rule") or i == len(wl) - 1:
                take = rem
            else:
                take = min(rem, max(ZERO, w["balance"] - alloc[w["id"]]))
            if take <= 0:
                continue
            alloc[w["id"]] += take
            net -= take
            budgets[k[3]] -= take
    out = []
    for w in norm_wallets(inp["wallets"], cur):
        a = alloc[w["id"]]
        ongoing = w["balance"] - a
        scale = Decimal(10) ** w["e"]
        out.append({"id": w["id"], "ongoing_usage_balance_cents": int(a), "ongoing_balance_cents": int(ongoing),
                    "credits_ongoing_usage_balance": fdiv(a / scale, w["rate"]),
                    "credits_ongoing_balance": fdiv(ongoing / scale, w["rate"]),
                    "depleted_ongoing_balance": ongoing <= 0})
    return {"wallets": out}


# ---------------------------------------------------------------- progressive
def progressive_lifetime_usage(inp, ctx):
    inv = 0
    for i in inp.get("invoices", []):
        if i.get("status", "finalized") not in ("finalized", "draft"):
            continue
        if i.get("invoice_type", "subscription") != "subscription":
            continue
        if i.get("subscription", "self") not in ("self", "predecessor"):
            continue
        inv += sum(int(f["amount_cents"]) for f in i.get("fees", []) if f.get("fee_type", "charge") == "charge")
    total = int(inp.get("historical_cents", 0)) + inv + int(inp.get("current_cents", 0))
    return {"invoiced_usage_cents": inv, "total_cents": total}


def progressive_check_thresholds(inp, ctx):
    fixed = [int(x) for x in inp.get("fixed_cents", [])]
    rec = inp.get("recurring_cents")
    plan_fixed = [int(x) for x in inp.get("plan_fixed_cents", [])]
    attach = inp.get("attach", "subscription")
    if inp.get("progressive_billing_disabled"):
        return {"passed_fixed_cents": [], "recurring_passed": False}
    own = fixed or rec is not None
    if attach == "subscription":
        if own:
            fx, r = fixed, rec
        else:
            fx, r = plan_fixed, None
    elif attach == "plan":
        fx, r = sorted(set(fixed + plan_fixed)), rec
    else:  # parent_plan: the plan's own thresholds replace the parent's
        if plan_fixed:
            fx, r = plan_fixed, None
        else:
            fx, r = fixed, rec
    fx = sorted(set(fx))
    r = int(r) if r is not None else None
    H, I, C = (int(inp.get("historical_cents", 0)), int(inp.get("invoiced_cents", 0)), int(inp["current_cents"]))
    P = int(inp.get("progressively_billed_cents", 0))
    A = C - P
    none = {"passed_fixed_cents": [], "recurring_passed": False}
    if A < 0:
        return none
    B = H + I + P
    T = B + A
    L = fx[-1] if fx else 0
    passed, rp = [], False
    if B < L:
        passed = [t for t in fx if B < t <= T]
        rp = r is not None and r > 0 and T - L >= r
    elif r is not None and r > 0:
        rp = A + (B % r) >= r
    return {"passed_fixed_cents": passed, "recurring_passed": rp}


def progressive_passed_amount(inp, ctx):
    a, t = int(inp["amount_cents"]), int(inp["lifetime_usage_cents"])
    if inp.get("recurring"):
        return {"passed_amount_cents": t - (t % a)}
    return {"passed_amount_cents": a}


def progressive_to_credit(inp, ctx):
    pbs = [p for p in inp.get("pb_invoices", []) if p.get("status", "finalized") in ("finalized", "failed")]
    fees = inp["fees"]
    if not pbs:
        return {"progressive_billed_cents": 0, "to_credit_cents": 0, "credit_cents": 0, "credit_note_cents": 0,
                "fees": [{"charge": f["charge"], "precise_coupons_cents": ZERO} for f in fees]}
    pb = pbs[-1]
    billed = sum(int(f["amount_cents"]) for f in pb["fees"])
    to_credit = billed - int(pb.get("coupons_cents", 0))
    to_credit -= sum(int(c["amount_cents"]) for c in pb.get("credited_cents", [])
                     if c.get("status", "finalized") not in ("voided", "closed", "deleted"))
    to_credit -= sum(int(c["credit_amount_cents"]) for c in pb.get("credit_notes", [])
                     if c.get("credit_status", "available") in ("available", "consumed"))
    to_credit = max(0, to_credit)
    pb_charges = {f["charge"] for f in pb["fees"]}
    charges_total = sum(int(f["amount_cents"]) for f in fees if f["charge"] in pb_charges)
    cn = 0
    credit = to_credit
    if to_credit > charges_total:
        cn = to_credit - charges_total
        credit = charges_total
    out_fees = []
    pb_by = {}
    for f in pb["fees"]:
        pb_by[f["charge"]] = pb_by.get(f["charge"], 0) + int(f["amount_cents"])
    for f in fees:
        add = min(pb_by.get(f["charge"], 0), int(f["amount_cents"])) if credit > 0 else 0
        out_fees.append({"charge": f["charge"], "precise_coupons_cents": Decimal(add)})
    return {"progressive_billed_cents": billed, "to_credit_cents": to_credit, "credit_cents": credit,
            "credit_note_cents": cn, "fees": out_fees}


# ---------------------------------------------------------------- alerts
def alerts_measure(inp, ctx):
    t = inp["alert_type"]
    if t == "current_usage_amount":
        return {"value": Decimal(int(inp["current_usage"].get("amount_cents", 0)))}
    if t in ("billable_metric_current_usage_amount", "billable_metric_current_usage_units",
             "billable_metric_lifetime_usage_units"):
        fees = [f for f in (inp.get("current_usage") or {}).get("fees", [])
                if f["billable_metric_code"] == inp.get("billable_metric_code")]
        if not fees:
            return {"value": None}
        if t.endswith("amount"):
            return {"value": Decimal(max(int(f.get("amount_cents", 0)) for f in fees))}
        return {"value": max(dec(f.get("units", "0")) for f in fees)}
    if t == "lifetime_usage_amount":
        lu = inp["lifetime_usage"]
        return {"value": Decimal(int(lu.get("historical_cents", 0)) + int(lu.get("invoiced_cents", 0))
                                 + int(lu.get("current_cents", 0)))}
    w = inp["wallet"]
    key = {"wallet_balance_amount": "balance_cents", "wallet_credits_balance": "credits_balance",
           "wallet_ongoing_balance_amount": "ongoing_balance_cents",
           "wallet_credits_ongoing_balance": "credits_ongoing_balance"}[t]
    return {"value": dec(w.get(key, 0))}


def crossed_values(direction, thresholds, prev, cur):
    one = sorted({dec(t["value"]) for t in thresholds if not t.get("recurring")})
    rec = [dec(t["value"]) for t in thresholds if t.get("recurring")]
    r = rec[0] if rec else None
    res = set()
    if direction == "increasing":
        if cur <= prev or (one and cur < one[0]):
            return []
        if one and prev < one[-1]:
            res |= {v for v in one if prev < v <= cur}
        if r:
            b = one[-1] if one else ZERO
            first = b + max(1, int(((prev - b) / r).to_integral_value(rounding=ROUND_CEILING))) * r
            last = b + int(((cur - b) / r).to_integral_value(rounding=ROUND_FLOOR)) * r
            v = first
            while v <= last:
                res.add(v)
                v += r
    else:
        if cur >= prev or (one and cur > one[-1]):
            return []
        if one and prev > one[0]:
            res |= {v for v in one if cur <= v < prev}
        if r:
            b = one[0] if one else ZERO
            hi = b - max(1, int(((b - prev) / r).to_integral_value(rounding=ROUND_CEILING))) * r
            lo = b - int(((b - cur) / r).to_integral_value(rounding=ROUND_FLOOR)) * r
            v = lo
            while v <= hi:
                res.add(v)
                v += r
    return sorted(res)


def alerts_crossed(inp, ctx):
    ths = []
    for i, t in enumerate(inp["thresholds"]):
        ths.append({"value": t["value"], "recurring": bool(t.get("recurring")), "code": t.get("code") or f"t{i + 1}"})
    prev, cur = dec(inp["previous"]), dec(inp["current"])
    vals = crossed_values(inp.get("direction", "increasing"), ths, prev, cur)
    rows = []
    onetime = {dec(t["value"]) for t in ths if not t["recurring"]}
    for t in ths:
        if not t["recurring"] and dec(t["value"]) in vals:
            rows.append({"code": t["code"], "value": dec(t["value"]), "recurring": False})
    rec = next((t for t in ths if t["recurring"]), None)
    for v in vals:
        if v not in onetime and rec:
            rows.append({"code": rec["code"], "value": v, "recurring": True})
    return {"crossed": vals, "triggered": bool(vals), "previous_after": cur, "crossed_thresholds": rows}


HANDLERS = {
    "wallets.credits": wallets_credits,
    "wallets.top_up": wallets_top_up,
    "wallets.consumption_order": wallets_consumption_order,
    "wallets.topup_amount": wallets_topup_amount,
    "wallets.threshold_top_up": wallets_threshold_top_up,
    "wallets.interval_due": wallets_interval_due,
    "wallets.allocate": wallets_allocate,
    "wallets.ongoing_balance": wallets_ongoing_balance,
    "progressive.lifetime_usage": progressive_lifetime_usage,
    "progressive.check_thresholds": progressive_check_thresholds,
    "progressive.passed_amount": progressive_passed_amount,
    "progressive.to_credit": progressive_to_credit,
    "alerts.measure": alerts_measure,
    "alerts.crossed": alerts_crossed,
}

if __name__ == "__main__":
    sys.exit(ar.serve(HANDLERS, impl="crc-7", impl_version="0.1.0", profiles=["compat", "corrected"]))
