#!/usr/bin/env python3
"""Lago kit adapter (domain area): money, time and numbering primitives. Standard library only."""
from __future__ import annotations

import hashlib
import os
import re
import sys
import unicodedata
from datetime import datetime, timedelta, timezone
from decimal import ROUND_CEILING, ROUND_FLOOR, ROUND_HALF_UP, Decimal
from zoneinfo import ZoneInfo

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                                ".claude", "skills", "reimplementation-kit", "scripts"))
import adapter_ref as ar  # noqa: E402
from adapter_ref import KitError, dec, out_dec, round_half_away  # noqa: E402
from currencies import CURRENCIES  # noqa: E402


# ---------- helpers ----------
def parse_instant(s: str) -> datetime:
    m = re.fullmatch(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d{1,9}))?(Z|[+-]\d\d:\d\d)", s)
    if not m:
        raise ar.BadInput(f"bad instant {s}")
    base, frac, z = m.groups()
    micro = int((frac or "0").ljust(9, "0")[:6])
    tz = timezone.utc if z == "Z" else timezone(
        (1 if z[0] == "+" else -1) * timedelta(hours=int(z[1:3]), minutes=int(z[4:6])))
    return datetime.fromisoformat(base).replace(microsecond=micro, tzinfo=tz)


def zone(name: str) -> ZoneInfo:
    return ZoneInfo(name)


def pad3(n: int) -> str:
    return f"{int(n):03d}"


# ---------- time ----------
def effective_timezone(inp, ctx):
    return {"timezone": inp.get("customer_timezone") or inp.get("billing_entity_timezone") or "UTC"}


def applicable_settings(inp, ctx):
    c, b = inp.get("customer") or {}, inp.get("billing_entity") or {}
    defaults = {"timezone": "UTC", "invoice_grace_period": 0, "net_payment_term": 0,
                "subscription_invoice_issuing_date_anchor": "next_period_start",
                "subscription_invoice_issuing_date_adjustment": "align_with_finalization_date",
                "document_locale": "en"}
    out = {}
    for k, dflt in defaults.items():
        cv, bv = c.get(k), b.get(k)
        if cv is not None and cv != "":
            out[k] = cv
        elif bv is not None and bv != "":
            out[k] = bv
        else:
            out[k] = dflt
    return out


def to_local(inp, ctx):
    t = parse_instant(inp["instant"]).astimezone(zone(inp["timezone"]))
    off = int(t.utcoffset().total_seconds())
    sign = "+" if off >= 0 else "-"
    a = abs(off)
    return {"local": f"{t:%Y-%m-%dT%H:%M:%S}{sign}{a // 3600:02d}:{a % 3600 // 60:02d}",
            "local_date": f"{t:%Y-%m-%d}", "utc_offset_seconds": off}


def days_between(inp, ctx):
    z = zone(inp["timezone"])
    f = parse_instant(inp["from"])
    t = parse_instant(inp["to"])
    tl = t.astimezone(z)
    if tl.hour == 0 and tl.minute == 0 and tl.second == 0 and tl.microsecond == 0:
        t = t + timedelta(seconds=1)
    fo = f.astimezone(z).utcoffset()
    to = t.astimezone(z).utcoffset()
    delta = (t - f) + to - fo
    us = delta // timedelta(microseconds=1)
    day = 86400 * 10**6
    days = -((-us) // day)  # ceil
    if inp.get("terminated_upgraded"):
        days = max(days - 1, 0)
    return {"days": days}


def terminated_at_reached(inp, ctx):
    if inp.get("status", "terminated") != "terminated":
        return {"reached": False}

    def rnd(d):
        us = (d - datetime(1970, 1, 1, tzinfo=timezone.utc)) // timedelta(microseconds=1)
        return (us + 500000) // 10**6

    return {"reached": rnd(parse_instant(inp["terminated_at"])) <= rnd(parse_instant(inp["at"]))}


# ---------- money ----------
def currency_exponent(inp, ctx):
    c = inp["currency"]
    if c in CURRENCIES:
        e, s = CURRENCIES[c]
        return {"exponent": e, "subunit_to_unit": s, "accepted": True}
    return {"exponent": 2, "subunit_to_unit": 100, "accepted": False}


def round_(inp, ctx):
    v = dec(inp["value"])
    p = inp.get("precision") or 0
    mode = inp["mode"]
    rm = {"round": ROUND_HALF_UP, "ceil": ROUND_CEILING, "floor": ROUND_FLOOR}[mode]
    r = v.quantize(Decimal(1).scaleb(-int(p)), rounding=rm)
    return {"value": out_dec(r)}


def to_minor_units(inp, ctx):
    cur = inp["currency"]
    if cur not in CURRENCIES:
        raise KitError("value_is_invalid", "currency")
    e = CURRENCIES[cur][0]
    a = dec(inp["amount"])
    return {"amount_cents": int(round_half_away(a, e).scaleb(e)), "precise_amount_cents": out_dec(a.scaleb(e))}


def fee_taxes(inp, ctx):
    amount = dec(inp["amount_cents"])
    precise = dec(inp["precise_amount_cents"]) if inp.get("precise_amount_cents") is not None else amount
    coupons = dec(inp.get("precise_coupons_amount_cents") or 0)
    applied, total_unrounded, total_precise, total_rate = [], Decimal(0), Decimal(0), Decimal(0)
    for t in inp.get("taxes") or []:
        rate = dec(t["rate"])
        raw = (amount - coupons) * rate / 100
        prec = (precise - coupons) * rate / 100
        applied.append({"code": t["code"], "amount_cents": int(round_half_away(raw)), "precise_amount_cents": out_dec(prec)})
        total_unrounded += raw
        total_precise += prec
        total_rate += rate
    return {"applied": applied, "taxes_amount_cents": int(round_half_away(total_unrounded)),
            "taxes_precise_amount_cents": out_dec(total_precise), "taxes_rate": out_dec(total_rate)}


# ---------- numbering ----------
def document_prefix(inp, ctx):
    sp = inp.get("supplied_prefix")
    if sp is not None:
        if len(sp) > 10:
            raise KitError("value_is_too_long", "document_number_prefix")
        if len(sp) < 1:
            raise KitError("value_is_too_short", "document_number_prefix")
        return {"prefix": sp.upper()}
    return {"prefix": inp["name"][:3].upper() + "-" + inp["record_id"][-4:].upper()}


def customer_slug(inp, ctx):
    return {"slug": f"{inp['organization_prefix']}-{pad3(inp['sequential_id'])}"}


def next_sequential_id(inp, ctx):
    scope = inp["scope"]
    best = 0
    for r in inp.get("existing") or []:
        if r.get("other_scope") or r.get("seq") is None:
            continue
        status = r.get("status", "finalized")
        if scope == "billing_entity_invoice" and (r.get("self_billed") or status not in ("finalized", "voided")):
            continue
        best = max(best, r["seq"])
    return {"next": best + 1}


FINALIZING_FROM = {"draft", "generating", "open", "failed", "pending"}


def invoice_number(inp, ctx):
    status = inp["status"]
    prev = inp.get("previous_status", status)
    prefix = inp["prefix"]
    if not (status == "finalized" and prev in FINALIZING_FROM):
        return {"number": inp.get("number") or f"{prefix}-DRAFT"}
    if inp["numbering"] == "per_customer" or inp["self_billed"]:
        return {"number": f"{prefix}-{pad3(inp['customer_sequential_id'])}-{pad3(inp['invoice_sequential_id'])}"}
    now = parse_instant(inp["now"]).astimezone(zone(inp["billing_entity_timezone"]))
    return {"number": f"{prefix}-{now:%Y%m}-{pad3(inp['billing_entity_sequential_id'])}"}


def credit_note_number(inp, ctx):
    status = inp.get("status", "finalized")
    prev = inp.get("previous_status", status)
    cur = inp.get("number")
    if not cur or (prev == "draft" and status == "finalized"):
        return {"number": f"{inp['invoice_number']}-CN{pad3(inp['sequential_id'])}"}
    return {"number": cur}


# ---------- catalog ----------
def code_reusable(inp, ctx):
    kind, code = inp["kind"], inp["code"]
    for r in inp.get("existing") or []:
        if r["code"] != code:
            continue
        if r.get("deleted") and kind != "tax":
            continue
        if kind == "billing_entity" and r.get("archived"):
            continue
        if kind == "wallet" and r.get("status", "active") == "terminated":
            continue
        return {"valid": False, "error": "value_already_exist"}
    return {"valid": True, "error": None}


def subscription_external_id_valid(inp, ctx):
    c = inp["candidate"]
    if c["status"] in ("active", "incomplete"):
        for r in inp.get("existing") or []:
            if r["external_id"] == c["external_id"] and r["status"] == c["status"]:
                return {"valid": False, "error": "value_already_exist"}
    return {"valid": True, "error": None}


_TRANSLIT = {"Æ": "AE", "æ": "ae", "Ð": "D", "ð": "d", "×": "x", "Ø": "O", "ø": "o", "Þ": "Th", "þ": "th",
             "ß": "ss", "ẞ": "SS", "Đ": "D", "đ": "d", "Ħ": "H", "ħ": "h", "ı": "i", "Ĳ": "IJ", "ĳ": "ij",
             "ĸ": "k", "Ŀ": "L", "ŀ": "l", "Ł": "L", "ł": "l", "ŉ": "'n", "Ŋ": "NG", "ŋ": "ng", "Œ": "OE",
             "œ": "oe", "Ŧ": "T", "ŧ": "t"}


def _translit_char(ch: str) -> str:
    if ord(ch) < 128:
        return ch
    cp = ord(ch)
    in_table = (0xC0 <= cp <= 0x17E and cp != 0xF7) or 0x1EA <= cp <= 0x1ED or cp == 0x1E9E
    if not in_table:
        return "?"
    if ch in _TRANSLIT:
        return _TRANSLIT[ch]
    base = "".join(c for c in unicodedata.normalize("NFD", ch) if ord(c) < 128)
    return base or "?"


def slug(text: str) -> str:
    t = unicodedata.normalize("NFC", text)
    t = "".join(_translit_char(c) for c in t)
    t = re.sub(r"[^A-Za-z0-9_-]+", "_", t)
    t = re.sub(r"_+", "_", t)
    if t.startswith("_"):
        t = t[1:]
    if t.endswith("_"):
        t = t[:-1]
    return t.lower()


def charge_filter_code(inp, ctx):
    values = inp["values"]
    canonical = "|".join(f"{k}:" + "+".join(sorted(values[k])) for k in sorted(values))
    base = slug(canonical)[:200] + "_" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()[:8]
    taken = set(inp.get("taken") or [])
    code, n = base, 2
    while code in taken:
        code = f"{base}_{n}"
        n += 1
    return {"code": code, "base_code": base}


HANDLERS = {f"domain.{k}": v for k, v in {
    "effective_timezone": effective_timezone, "applicable_settings": applicable_settings, "to_local": to_local,
    "days_between": days_between, "terminated_at_reached": terminated_at_reached,
    "currency_exponent": currency_exponent, "round": round_, "to_minor_units": to_minor_units,
    "fee_taxes": fee_taxes, "document_prefix": document_prefix, "customer_slug": customer_slug,
    "next_sequential_id": next_sequential_id, "invoice_number": invoice_number,
    "credit_note_number": credit_note_number, "code_reusable": code_reusable,
    "subscription_external_id_valid": subscription_external_id_valid, "charge_filter_code": charge_filter_code,
}.items()}

if __name__ == "__main__":
    ar.serve(HANDLERS, impl="crc-1-domain", impl_version="0.1.0", profiles=["compat", "corrected"])
