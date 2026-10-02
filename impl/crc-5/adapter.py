#!/usr/bin/env python3
"""JSON-lines adapter (kit proto 1) for the `periods` area."""
import json
import sys
import traceback

from periods import OPS, KitError


def main():
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        t = msg.get("type")
        if t == "hello":
            resp = {"type": "hello", "proto": 1, "impl": "crc-5-periods", "impl_version": "0.1.0",
                    "profiles": ["compat", "corrected"], "ops": ["periods.*"]}
        elif t == "bye":
            break
        elif t == "call":
            name = f"{msg['area']}.{msg['op']}"
            fn = OPS.get(name)
            if fn is None:
                resp = {"type": "result", "id": msg["id"], "error": {"code": "unsupported_op"}}
            else:
                try:
                    resp = {"type": "result", "id": msg["id"], "output": fn(msg["input"], msg.get("profile", "compat"))}
                except KitError as e:
                    err = {"code": e.code}
                    if e.field:
                        err["field"] = e.field
                    if e.message:
                        err["message"] = e.message
                    resp = {"type": "result", "id": msg["id"], "error": err}
                except Exception as e:  # noqa: BLE001
                    traceback.print_exc(file=sys.stderr)
                    resp = {"type": "result", "id": msg["id"], "error": {"code": "internal", "message": repr(e)}}
        else:
            continue
        out.write(json.dumps(resp, separators=(",", ":")) + "\n")
        out.flush()


if __name__ == "__main__":
    main()
