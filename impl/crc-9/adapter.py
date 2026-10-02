"""kitrun adapter for the ep.* unit ops (adapter protocol v1, JSON lines on stdin/stdout)."""
import base64
import json
import sys

import ep_core as core

PROTO = 1
DEFAULT_ORG = "11111111-1111-1111-1111-111111111111"


class OpError(Exception):
    def __init__(self, code, field=None, message=None):
        super().__init__(code)
        self.code, self.field, self.message = code, field, message


def op_decode(inp, profile):
    try:
        raw = base64.b64decode(inp["raw_b64"])
        return {"event_json": core.decode_event_json(raw, profile)}
    except core.Undecodable as e:
        raise OpError("undecodable", message=str(e))


def _read_ts(ts_json):
    if ts_json is None:
        return None
    try:
        return core.loads_literal(ts_json)
    except ValueError:
        return None


def op_parse_timestamp(inp, profile):
    ts = _read_ts(inp.get("timestamp_json"))
    try:
        t = core.parse_timestamp(ts, profile)
    except core.InvalidTimestamp:
        raise OpError("invalid_timestamp", "timestamp")
    out = {"emitted_text": t["emitted_text"]}
    mi = core.fmt_instant(t["match_ns"])
    if mi is not None:
        out["match_instant"] = mi
    if profile == "compat":
        mt = core.fmt_instant(t["match_ns"], t["offset_min"])
        if mt is not None:
            out["match_time"] = mt
    return out


def op_value_string(inp, profile):
    try:
        props = core.loads_literal(inp.get("properties_json") or "null")
    except ValueError:
        raise OpError("undecodable", message="properties_json is not JSON")
    if props is not None and not isinstance(props, dict):
        raise OpError("undecodable", message="properties_json is not an object")
    code = inp.get("aggregation_type")
    return {"value": core.value_text(code, inp.get("field_name"), props, profile),
            "aggregation_label": core.label_of(code)}


def op_match_subscription(inp, profile):
    ts = _read_ts(inp.get("timestamp_json"))
    try:
        t = core.parse_timestamp(ts, profile)
    except core.InvalidTimestamp:
        raise OpError("build_enriched_event")
    org = inp.get("organization_id") or DEFAULT_ORG
    subs = []
    for s in inp.get("subscriptions") or []:
        subs.append({
            "id": s["id"], "external_id": s["external_id"], "plan_id": s.get("plan_id"),
            "organization_id": s.get("organization_id") or org,
            "started_at": core.parse_loose_instant(s["started_at"]),
            "terminated_at": core.parse_loose_instant(s["terminated_at"]) if s.get("terminated_at") else None,
        })
    now_ns = core.parse_loose_instant(inp["now"]) if inp.get("recurring") and inp.get("now") else None
    found = core.match_subscription(subs, org, inp["external_subscription_id"], t, inp.get("mode", "db"),
                                    profile, bool(inp.get("recurring")), now_ns)
    return {"subscription_id": found["id"] if found else ""}


def op_commit_offset(inp, profile):
    return {"commit": core.commit_offset(inp.get("records") or [], inp.get("pending_before"), profile)}


def op_refresh_member(inp, profile):
    member, score = core.refresh_member(inp["organization_id"], inp["subscription_id"], inp["now_unix"])
    return {"member": member, "score": score}


HANDLERS = {
    "ep.decode": op_decode,
    "ep.parse_timestamp": op_parse_timestamp,
    "ep.value_string": op_value_string,
    "ep.match_subscription": op_match_subscription,
    "ep.commit_offset": op_commit_offset,
    "ep.refresh_member": op_refresh_member,
}


def send(obj):
    sys.stdout.write(json.dumps(obj, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except ValueError as e:
            print("unparsable request: %s" % e, file=sys.stderr)
            continue
        kind = msg.get("type")
        if kind == "hello":
            send({"type": "hello", "proto": PROTO, "impl": "crc-9-events-processor", "impl_version": "1.0",
                  "profiles": ["compat", "corrected"], "ops": sorted(HANDLERS)})
        elif kind == "bye":
            break
        elif kind == "call":
            cid = msg.get("id")
            name = "%s.%s" % (msg.get("area"), msg.get("op"))
            fn = HANDLERS.get(name)
            if fn is None:
                send({"type": "result", "id": cid, "error": {"code": "unsupported_op", "message": name}})
                continue
            try:
                send({"type": "result", "id": cid, "output": fn(msg.get("input") or {}, msg.get("profile") or "compat")})
            except OpError as e:
                err = {"code": e.code}
                if e.field:
                    err["field"] = e.field
                if e.message:
                    err["message"] = e.message
                send({"type": "result", "id": cid, "error": err})
            except (KeyError, TypeError, ValueError) as e:
                send({"type": "result", "id": cid, "error": {"code": "bad_input", "message": repr(e)}})
            except Exception as e:  # noqa: BLE001
                send({"type": "result", "id": cid, "error": {"code": "internal", "message": repr(e)}})


if __name__ == "__main__":
    main()
