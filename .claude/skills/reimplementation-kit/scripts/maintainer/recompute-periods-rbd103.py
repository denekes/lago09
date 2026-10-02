#!/usr/bin/env python3
# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
"""recompute-periods-rbd103.py — independent model of the monthly-split charge and fixed-charge windows of a
terminated split plan (billing-engine-spec chapter 06, BE-SP-12..22 and BE-SP-17; rebuild decision RBD-103).

A yearly or semiannual plan that bills its charges (or fixed charges) monthly computes, on the termination invoice,
the monthly window that ends at the termination. The model has two profiles:

  compat     the reference rule: the termination is tested against 00:00 UTC of the billing date in the customer's
             zone, so a termination later that day still selects the PREVIOUS monthly window (the case the
             oracle-executed compat vectors pin);
  corrected  the RBD-103 proposal: the termination is tested against `billing_at` itself, so the window runs from
             the start of the current monthly period to the termination.

Scope: arrears plans, no successor subscription, status terminated, calendar or anniversary billing, any IANA zone.
The model is written from the chapter rules, not from the reference code. It produced the expected values of the
RBD-103 corrected twins (evidence kind RECOMPUTED, ref RBD-103) and reproduces the oracle-executed compat vectors.

Usage:
    recompute-periods-rbd103.py [check] [--kit-root DIR] [-v]
        Recompute every periods.* vector whose `rbd` lists RBD-103 (compat, corrected and both) and compare the
        keys of its `expected` object; prints one line per failure (all lines with -v) and a SUMMARY line.
        Default kit root: the skills directory that contains this script's reimplementation-kit.
    recompute-periods-rbd103.py adapter
        Serve the ops periods.boundaries and periods.invoice_boundaries over the kit adapter protocol v1, e.g.
        python3 reimplementation-kit/scripts/kitrun.py --areas periods \\
            --only 'periods\\.(boundaries\\.split\\.01[0-6]|invoice_boundaries\\.011)' \\
            --profile corrected --impl-cmd "python3 reimplementation-kit/scripts/maintainer/recompute-periods-rbd103.py adapter"
        (only the RBD-103 inputs are in scope; any other input is answered `unsupported_op`).
Exit codes: 0 all compared vectors agree (check) or end of input (adapter); 1 a disagreement; 2 usage.
"""
import calendar
import glob
import json
import os
import sys
from datetime import date, datetime, time, timedelta, timezone
from zoneinfo import ZoneInfo


def inst(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def out(t):
    t = t.astimezone(timezone.utc)
    s = t.strftime("%Y-%m-%dT%H:%M:%S")
    if t.microsecond:
        s += "." + f"{t.microsecond:06d}".rstrip("0")
    return s + "Z"


def clamp(y, m, d):
    return date(y, m, min(d, calendar.monthrange(y, m)[1]))


def add_months(y, m, k):
    i = y * 12 + (m - 1) + k
    return i // 12, i % 12 + 1


def monthly_period(x, anchor_day, anniversary):
    """The monthly period containing local date x: (first, last) local dates."""
    if not anniversary:
        first = date(x.year, x.month, 1)
    else:
        first = clamp(x.year, x.month, anchor_day)
        if first > x:
            y, m = add_months(x.year, x.month, -1)
            first = clamp(y, m, anchor_day)
    y, m = add_months(first.year, first.month, 1)
    nxt = clamp(y, m, anchor_day) if anniversary else date(y, m, 1)
    return first, nxt - timedelta(days=1)


def base_date(d, anchor_day, anniversary):
    """The date one month before d (the previous monthly period's reference date)."""
    y, m = add_months(d.year, d.month, -1)
    b = clamp(y, m, d.day)
    if anniversary and d.day == calendar.monthrange(d.year, d.month)[1] and d.day < anchor_day:
        b = clamp(y, m, anchor_day)
    return b


def window(inp, profile):
    """(from, to) of the monthly charge window on the termination invoice, as UTC instants."""
    tz = ZoneInfo(inp.get("timezone", "UTC"))
    s = inp["subscription"]
    anniversary = s.get("billing_time", "calendar") == "anniversary"
    anchor = inst(s["subscription_at"]).astimezone(tz).date()
    started = inst(s.get("started_at", s["subscription_at"]))
    term = inst(s["terminated_at"])
    at = inst(inp["billing_at"])
    d = at.astimezone(tz).date()
    ref = datetime.combine(d, time(0), timezone.utc) if profile == "compat" else at
    terminated = term <= ref
    cdate = d if terminated else base_date(d, anchor.day, anniversary)
    first, last = monthly_period(cdate, anchor.day, anniversary)
    frm = datetime.combine(first, time(0), tz)
    to = datetime.combine(last, time(23, 59, 59, 999999), tz)
    if frm < started:
        frm = started
    if term <= to:
        to = term
    if to < started:
        to = started
    return out(frm), out(to)


def answer(op, inp, profile):
    plan = inp["plan"]
    ch, fx = bool(plan.get("bill_charges_monthly")), bool(plan.get("bill_fixed_charges_monthly"))
    w = window(inp, profile)
    o = {"charges_from_datetime": None, "charges_to_datetime": None,
         "fixed_charges_from_datetime": None, "fixed_charges_to_datetime": None}
    if ch:
        o["charges_from_datetime"], o["charges_to_datetime"] = w
    if fx:
        o["fixed_charges_from_datetime"], o["fixed_charges_to_datetime"] = w
    if plan["interval"] == "yearly" and inp["subscription"].get("billing_time", "calendar") == "calendar":
        # subscription-fee window of a calendar yearly plan on its termination invoice: 1 January (local) to the
        # termination, whole seconds
        tz = ZoneInfo(inp.get("timezone", "UTC"))
        d = inst(inp["billing_at"]).astimezone(tz).date()
        o["from_datetime"] = out(datetime(d.year, 1, 1, tzinfo=tz))
        o["to_datetime"] = out(inst(inp["subscription"]["terminated_at"]).replace(microsecond=0))
    if op.endswith("invoice_boundaries"):
        o["invoicing_reason"] = inp["invoicing_reason"]
        o["recurring"] = False
    return o


def adapter():
    for line in sys.stdin:
        m = json.loads(line)
        if m.get("type") == "hello":
            print(json.dumps({"type": "hello", "proto": 1, "impl": "recompute-periods-rbd103", "impl_version": "1",
                              "profiles": ["compat", "corrected"],
                              "ops": ["periods.boundaries", "periods.invoice_boundaries"]}), flush=True)
        elif m.get("type") == "call":
            try:
                r = {"type": "result", "id": m["id"], "output": answer(m["op"], m["input"], m["profile"])}
            except (KeyError, TypeError, ValueError) as e:  # an input outside the model's scope
                r = {"type": "result", "id": m["id"], "error": {"code": "unsupported_op", "message": f"out of scope: {e}"}}
            print(json.dumps(r), flush=True)
        else:
            break
    return 0


def check(kit_root, verbose):
    files = sorted(glob.glob(os.path.join(kit_root, "billing-engine-spec", "vectors", "periods.*.jsonl")))
    if not files:
        print(f"recompute-periods-rbd103: no periods vectors under {kit_root}", file=sys.stderr)
        return 2
    n = bad = 0
    for f in files:
        for line in open(f, encoding="utf-8"):
            if not line.strip():
                continue
            v = json.loads(line)
            if "RBD-103" not in (v.get("rbd") or []):
                continue
            profiles = ["compat", "corrected"] if v["profile"] == "both" else [v["profile"]]
            for p in profiles:
                n += 1
                got = answer(v["op"], v["input"], p)
                diff = {k: (got.get(k), want) for k, want in v["expected"].items() if got.get(k) != want}
                if diff:
                    bad += 1
                    print(f"FAIL {v['id']} [{p}] {json.dumps(diff)}")
                elif verbose:
                    print(f"PASS {v['id']} [{p}]")
    print(f"SUMMARY recompute-periods-rbd103: compared={n} agree={n - bad} disagree={bad}")
    return 0 if bad == 0 else 1


def main(argv):
    mode = "check"
    if argv and argv[0] in ("check", "adapter"):
        mode = argv.pop(0)
    if mode == "adapter":
        return adapter()
    here = os.path.dirname(os.path.abspath(__file__))
    kit_root = os.path.dirname(os.path.dirname(os.path.dirname(here)))
    verbose = False
    while argv:
        a = argv.pop(0)
        if a == "--kit-root" and argv:
            kit_root = argv.pop(0)
        elif a in ("-v", "--verbose"):
            verbose = True
        else:
            print(__doc__, file=sys.stderr)
            return 2
    return check(kit_root, verbose)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
