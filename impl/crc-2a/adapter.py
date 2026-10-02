#!/usr/bin/env python3.12
"""JSON-lines adapter (proto 1) for the pricing area."""
import json
import sys
from decimal import Decimal

from pricing_core import OpError, fmt
from ops import OPS


def enc(o):
    if isinstance(o, Decimal):
        return fmt(o)
    if isinstance(o, dict):
        return {k: enc(v) for k, v in o.items()}
    if isinstance(o, (list, tuple)):
        return [enc(v) for v in o]
    return o


def send(obj):
    sys.stdout.write(json.dumps(obj, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line, parse_float=Decimal)
        t = msg.get("type")
        if t == "hello":
            send({"type": "hello", "proto": 1, "impl": "crc-2a-pricing", "impl_version": "1.0.0",
                  "profiles": ["compat", "corrected"], "ops": ["pricing.*"]})
        elif t == "bye":
            return
        elif t == "call":
            cid = msg["id"]
            op = f"{msg['area']}.{msg['op']}"
            fn = OPS.get(op)
            if fn is None:
                send({"type": "result", "id": cid, "error": {"code": "unsupported_op", "message": op}})
                continue
            try:
                out = fn(msg.get("input", {}), msg.get("profile", "compat"))
                send({"type": "result", "id": cid, "output": enc(out)})
            except OpError as e:
                err = {"code": e.code, "message": e.message}
                if e.field:
                    err["field"] = e.field
                send({"type": "result", "id": cid, "error": err})
            except (KeyError, TypeError, ValueError) as e:
                send({"type": "result", "id": cid, "error": {"code": "bad_input", "message": repr(e)}})
            except Exception as e:  # noqa: BLE001
                import traceback
                traceback.print_exc(file=sys.stderr)
                send({"type": "result", "id": cid, "error": {"code": "internal", "message": repr(e)}})


if __name__ == "__main__":
    main()
