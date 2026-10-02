#!/usr/bin/env python3
"""JSON-lines adapter (kit protocol v1) for the invoice and credit_notes areas."""
from __future__ import annotations

import json
import sys
import traceback
from decimal import Decimal

sys.path.insert(0, __file__.rsplit("/", 1)[0] if "/" in __file__ else ".")

from common import KitError, Unsupported, dec  # noqa: E402
import invoice as inv  # noqa: E402

HANDLERS = {
    "invoice.totals": inv.totals,
    "invoice.apply_taxes": inv.apply_taxes,
    "invoice.fee_tax_selection": inv.fee_tax_selection,
    "invoice.coupon_amount": inv.coupon_amount,
    "invoice.coupon_distribution": inv.coupon_distribution,
    "invoice.coupon_order": inv.coupon_order,
    "invoice.final_status": inv.final_status,
    "invoice.issuing_date": inv.issuing_date,
    "invoice.payment_due_date": inv.payment_due_date,
    "invoice.available_to_credit": inv.available_to_credit,
}

try:
    import coupons  # noqa: E402
    HANDLERS.update(coupons.HANDLERS)
except ImportError:
    pass
try:
    import credit_notes  # noqa: E402
    HANDLERS.update(credit_notes.HANDLERS)
except ImportError:
    pass
try:
    import commitment  # noqa: E402
    HANDLERS.update(commitment.HANDLERS)
except ImportError:
    pass
try:
    import voiding  # noqa: E402
    HANDLERS.update(voiding.HANDLERS)
except ImportError:
    pass


def out_dec(d: Decimal) -> str:
    s = format(d, "f")
    if "." in s:
        s = s.rstrip("0").rstrip(".") if False else s
    if s.startswith("-") and Decimal(s) == 0:
        s = s[1:]
    return s


def encode(obj) -> str:
    def default(o):
        if isinstance(o, Decimal):
            return out_dec(o)
        raise TypeError(type(o).__name__)
    return json.dumps(obj, default=default, ensure_ascii=False, separators=(",", ":"))


def main() -> int:
    out = sys.stdout

    def send(o):
        out.write(encode(o) + "\n")
        out.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line, parse_float=Decimal, parse_int=int)
        except ValueError:
            continue
        kind = msg.get("type")
        if kind == "hello":
            send({"type": "hello", "proto": 1, "impl": "crc-6a-python", "impl_version": "1.0",
                  "profiles": ["compat", "corrected"], "ops": sorted(HANDLERS)})
        elif kind == "bye":
            break
        elif kind == "call":
            cid = msg.get("id")
            name = f"{msg.get('area')}.{msg.get('op')}"
            fn = HANDLERS.get(name)
            if fn is None:
                send({"type": "result", "id": cid, "error": {"code": "unsupported_op", "message": name}})
                continue
            try:
                res = fn(msg.get("input") or {}, {"profile": msg.get("profile"), "id": cid})
                send({"type": "result", "id": cid, "output": res})
            except KitError as e:
                err = {"code": e.code}
                if e.field:
                    err["field"] = e.field
                if e.message and e.message != e.code:
                    err["message"] = e.message
                send({"type": "result", "id": cid, "error": err})
            except Unsupported as e:
                send({"type": "result", "id": cid, "error": {"code": "unsupported_op", "message": str(e)}})
            except Exception as e:  # noqa: BLE001
                traceback.print_exc(file=sys.stderr)
                send({"type": "result", "id": cid, "error": {"code": "internal", "message": f"{type(e).__name__}: {e}"}})
    return 0


if __name__ == "__main__":
    sys.exit(main())
