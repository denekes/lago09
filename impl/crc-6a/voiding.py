"""Voiding a finalized invoice, optionally with credit notes (BE-IV-29, BE-IV-41, BE-IV-42)."""
from __future__ import annotations

from decimal import Decimal

import credit_notes as cn
import invoice as iv
from common import KitError, ZERO, dec, exact, float_round, rint, store5


def void(inp, ctx):
    ex = exact(ctx)
    invd = dict(inp["invoice"])
    premium = inp.get("premium", True)
    inv = cn.Inv(invd, ctx, inp.get("previous_credit_notes"))
    res = inv.res
    voidable = (inv.status == "finalized" and inv.payment_status in ("pending", "failed") and inv.paid == 0
                and not any(n["credit_status"] != "voided" for n in inv.notes))
    out = {"status": "voided", "voidable_before": voidable, "credit_notes": []}
    if inp.get("generate_credit_note"):
        credit = int(inp.get("credit_amount_cents", 0))
        refund = int(inp.get("refund_amount_cents", 0))
        creditable = inv.avail()
        refundable = inv.refundable()
        if credit > creditable or refund > refundable or credit + refund > creditable:
            raise KitError("total_amount_exceeds_invoice_amount", "credit_refund_amount")
        if credit + refund > 0:
            remaining = [(f.id, f.amount - inv.credited[f.id]) for f in inv.fee_list]
            remaining = [(fid, a) for fid, a in remaining if a > 0]
            est = cn.estimate_core(inv, remaining)
            T = est["max_creditable_amount_cents"]
            ratio = (credit + refund) / T if not ex else Decimal(credit + refund) / T
            items = []
            for fid, a in remaining:
                v = a * ratio
                items.append((fid, Decimal(repr(float_round(v, 5))) if isinstance(v, float) else store5(v)))
            n = cn.make_note(inv, items, credit, refund, 0, validate=False)
            inv.add(n)
            out["credit_notes"].append(_pub(n))
        creditable2 = inv.avail()
        if rint(creditable2) > 0:
            remaining = [(f.id, f.amount - inv.credited[f.id]) for f in inv.fee_list]
            remaining = [(fid, a) for fid, a in remaining if a > 0]
            est = cn.estimate_core(inv, remaining)
            n = cn.make_note(inv, [(it["fee_id"], it["amount_cents"]) for it in est["items"]],
                             est["max_creditable_amount_cents"], 0, 0, validate=False)
            n["credit_status"] = "voided"
            n["balance_amount_cents"] = 0
            out["credit_notes"].append(_pub(n))
    # coupons re-credit
    after = []
    credited = {id_: None for id_ in ()}
    for c in res.coupons:
        key = id(c)
        status, rem = res.coupon_after.get(key, (c.status, c.remaining if c.frequency == "recurring" else None))
        had_credit = any(cr["kind"] == "coupon" and cr["id"] == c.id for cr in res.credits)
        if had_credit:
            if status == "terminated" and c.frequency != "forever" and c.coupon_status == "active":
                status = "active"
            if c.frequency == "recurring":
                rem = (rem or 0) + 1
        after.append({"status": status, "frequency_duration_remaining": rem})
    out["applied_coupons_after"] = after
    return out


def _pub(n):
    o = cn.public(n)
    return {"credit_amount_cents": o["credit_amount_cents"], "refund_amount_cents": o["refund_amount_cents"],
            "total_amount_cents": o["total_amount_cents"], "credit_status": o["credit_status"], "items": o["items"]}


HANDLERS = {"invoice.void": void}
