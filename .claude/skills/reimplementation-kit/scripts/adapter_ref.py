#!/usr/bin/env python3
"""adapter_ref.py — reference adapter loop for the kit adapter protocol v1 (standard library only).

Use it two ways:

1. As a library for a Python implementation:

       import adapter_ref as ar

       def charge_model(inp, ctx):
           ...                                   # your engine
           return {"amount": ar.out_dec(amount), "unit_amount": ar.out_dec(unit)}

       ar.serve({"pricing.charge_model": charge_model}, impl="acme-billing", impl_version="0.1.0",
                profiles=["compat"])

   then `kitrun.py --impl-cmd "python3 my_adapter.py"`.

2. As a runnable skeleton: `python3 adapter_ref.py` serves the single worked example `domain.round`
   (round half away from zero / ceil / floor at a precision). `python3 adapter_ref.py --list-ops` prints the op
   catalogue (schemas/ops) with one line per op.

Contract (reference/adapter-protocol.md): read one JSON request per line on stdin, write exactly one JSON line per
request on stdout (nothing else on stdout; logs go to stderr), answer `hello` first, exit 0 on `bye` or EOF.
Inputs are parsed with every JSON number as Decimal (exact text kept; `*_json` fields are strings holding exact
JSON text). Raise KitError(code, field) for a DOMAIN error the reference reports; raise Unsupported for an input
shape you do not handle (graded SKIP); any other exception becomes protocol error `internal` (graded ERROR).
"""
from __future__ import annotations

import glob
import json
import os
import sys
import traceback
from decimal import ROUND_CEILING, ROUND_FLOOR, ROUND_HALF_UP, Decimal, InvalidOperation, getcontext

getcontext().prec = 80
PROTO = 1


class KitError(Exception):
    """A domain error: `code` is the reference's error code, `field` the offending input field (optional)."""

    def __init__(self, code: str, field: str | None = None, message: str | None = None):
        super().__init__(message or code)
        self.code, self.field, self.message = code, field, message


class Unsupported(Exception):
    """This implementation does not handle this op or input shape (graded SKIP, never FAIL)."""


class BadInput(Exception):
    """The input does not match the op schema (graded ERROR)."""


# -- value helpers ------------------------------------------------------------------------------------------------
def dec(x) -> Decimal:
    """Decimal from a canonical decimal string, an int or a Decimal (exact; floats are refused)."""
    if isinstance(x, bool) or x is None:
        raise BadInput(f"not a decimal: {x!r}")
    if isinstance(x, Decimal):
        return x
    if isinstance(x, int):
        return Decimal(x)
    if isinstance(x, str):
        try:
            return Decimal(x)
        except InvalidOperation:
            raise BadInput(f"not a decimal: {x!r}")
    raise BadInput(f"not a decimal: {x!r}")


def out_dec(d) -> str:
    """Canonical decimal text (no exponent, '-0' -> '0')."""
    d = dec(d)
    s = format(d, "f")
    if s.startswith("-") and Decimal(s) == 0:
        s = s[1:]
    return s


def round_half_away(d, places: int = 0) -> Decimal:
    """Round half away from zero (the kit's money and metric rounding rule)."""
    return dec(d).quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)


def raw_json(text: str):
    """Parse a `*_json` field (exact JSON text) keeping numbers as Decimal."""
    return json.loads(text, parse_float=Decimal, parse_int=int)


# -- protocol loop ------------------------------------------------------------------------------------------------
def _encode(obj) -> str:
    def default(o):
        if isinstance(o, Decimal):
            return out_dec(o)
        raise TypeError(f"cannot encode {type(o).__name__}")

    return json.dumps(obj, default=default, ensure_ascii=False, separators=(",", ":"))


def serve(handlers: dict, impl: str = "adapter-ref", impl_version: str = "0", profiles=("compat",), stdin=None, stdout=None):
    """Run the protocol loop. handlers: {"area.op": fn(input, ctx) -> dict}. ctx = {"profile", "id", "line"}."""
    stdin = stdin or sys.stdin
    out = stdout or sys.stdout

    def send(obj):
        out.write(_encode(obj) + "\n")
        out.flush()

    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line, parse_float=Decimal, parse_int=int)
        except ValueError as e:
            print(f"[adapter_ref] unparsable request: {e}", file=sys.stderr)
            continue
        kind = msg.get("type")
        if kind == "hello":
            send({"type": "hello", "proto": PROTO, "impl": impl, "impl_version": impl_version,
                  "profiles": list(profiles), "ops": sorted(handlers)})
        elif kind == "bye":
            break
        elif kind == "call":
            cid = msg.get("id")
            name = f"{msg.get('area')}.{msg.get('op')}"
            fn = handlers.get(name)
            if fn is None:
                send({"type": "result", "id": cid, "error": {"code": "unsupported_op", "message": name}})
                continue
            try:
                output = fn(msg.get("input") or {}, {"profile": msg.get("profile"), "id": cid, "line": line})
                if not isinstance(output, dict):
                    raise TypeError(f"handler for {name} returned {type(output).__name__}, expected dict")
                send({"type": "result", "id": cid, "output": output})
            except KitError as e:
                err = {"code": e.code}
                if e.field:
                    err["field"] = e.field
                if e.message:
                    err["message"] = e.message
                send({"type": "result", "id": cid, "error": err})
            except Unsupported as e:
                send({"type": "result", "id": cid, "error": {"code": "unsupported_op", "message": str(e) or name}})
            except (BadInput, KeyError) as e:
                send({"type": "result", "id": cid, "error": {"code": "bad_input", "message": str(e)}})
            except Exception as e:  # noqa: BLE001
                traceback.print_exc(file=sys.stderr)
                send({"type": "result", "id": cid, "error": {"code": "internal", "message": f"{type(e).__name__}: {e}"}})
        else:
            print(f"[adapter_ref] unknown message type {kind!r}", file=sys.stderr)
    return 0


# -- worked example ------------------------------------------------------------------------------------------------
def domain_round(inp, ctx):
    """domain.round: {value, mode: round|ceil|floor, precision (default 0)} -> {value}.

    round = half away from zero; ceil = towards +infinity; floor = towards -infinity, at `precision` decimal places."""
    value = dec(inp["value"])
    places = inp.get("precision")
    places = 0 if places is None else int(places)
    modes = {"round": ROUND_HALF_UP, "ceil": ROUND_CEILING, "floor": ROUND_FLOOR}
    mode = inp.get("mode")
    if mode not in modes:
        raise BadInput(f"mode must be one of {sorted(modes)}")
    return {"value": out_dec(value.quantize(Decimal(1).scaleb(-places), rounding=modes[mode]))}


def list_ops(kit_dir: str) -> int:
    for p in sorted(glob.glob(os.path.join(kit_dir, "schemas", "ops", "*.schema.json"))):
        with open(p, encoding="utf-8") as f:
            doc = json.load(f)
        meta = doc.get("x-kit", {})
        print(f"{doc.get('title', os.path.basename(p)):<40} {meta.get('status', '?'):<9} {doc.get('description', '')}")
    return 0


if __name__ == "__main__":
    if "--list-ops" in sys.argv[1:]:
        import signal
        signal.signal(signal.SIGPIPE, signal.SIG_DFL)
        sys.exit(list_ops(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))))
    if any(a in ("-h", "--help") for a in sys.argv[1:]):
        print(__doc__)
        sys.exit(0)
    sys.exit(serve({"domain.round": domain_round}, impl="adapter-ref-example", impl_version="1.0.0",
                   profiles=["compat", "corrected"]))
