#!/usr/bin/env python3
# MAINTAINER-ONLY: needs the lago repository (events-processor tree 83e012866f29) and the Go/CGO toolchain; excluded from clean-room packs.
"""mint-ep-units.py - mint vectors/ep.units.jsonl.

Every compat/both expectation is produced by the ep-oracle (the reference events-processor
packages behind the adapter protocol, built by build-go-reference.sh). Corrected twins are
recomputed here from the rebuild decision they implement (RBD-13 value text, RBD-14 literal
numbers, RBD-15/16/17 matching instant and bounds, RBD-18 emitted timestamp, RBD-1 commit
rule, RBD-4 numeric amount, RBD-99 exact external id); a vector is `both` when the recomputed
corrected output equals the reference output on every compared field. ep.refresh_member is
RECOMPUTED with a note: the reference reads its own wall clock, so the oracle checks the bucket
rule on a live flag write and maps it onto now_unix.

Usage: mint-ep-units.py [--oracle CMD] [--check | --write | --out FILE] [--date YYYY-MM-DD]
  --oracle  adapter command (default: from build-go-reference.sh --print-env)
  --check   (default) mint into memory and compare with the shipped file, evidence dates ignored
  --write   overwrite the shipped <skill>/vectors/ep.units.jsonl
  --out     write to FILE instead
Exit: 0 ok; 1 drift (--check) or oracle failure; 2 usage.
"""
import argparse
import base64
import json
import os
import subprocess
import sys
from datetime import datetime, timezone, timedelta
from decimal import Decimal, ROUND_FLOOR

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(os.path.dirname(HERE))
CORPUS = os.path.join(SKILL, "conformance", "value-corpus.tsv")
PIN = "ep:83e012866f29"
RUNTIME = "go1.25.0"
RECOMPUTE_RUNTIME = "python3"

O1 = "11111111-1111-1111-1111-111111111111"
O2 = "99999999-9999-9999-9999-999999999999"
P1 = "22222222-2222-2222-2222-222222222222"
P0 = "22222222-2222-2222-2222-000000000000"


def SUB(n):
    return "bbbbbbbb-0000-0000-0000-%012d" % n


REFS = {
    "decode": "$EP/models/event.go:12",
    "parse_timestamp": "$EP/utils/time.go:14",
    "value_string": "$EP/processors/events_processor/enrichment_service.go:111",
    "match_subscription_db": "$EP/models/subscriptions.go:26",
    "match_subscription_cache": "$EP/cache/subscriptions.go:45",
    "commit_offset": "$EP/config/kafka/consumer.go:278",
    "refresh_member": "$EP/models/stores.go:54",
}

# ---------------------------------------------------------------------------------- specs
# Ids retired to keep the file inside the kit size budget (numbers stay reserved so that chapter
# references remain stable; the behaviours stay covered by neighbouring vectors and the EPC scenarios).
DROP = {"ep.decode.012", "ep.decode.013", "ep.decode.020", "ep.parse_timestamp.014", "ep.parse_timestamp.016",
        "ep.parse_timestamp.017", "ep.parse_timestamp.019", "ep.parse_timestamp.022", "ep.value_string.029",
        "ep.value_string.034", "ep.value_string.039", "ep.value_string.042", "ep.match_subscription.008",
        "ep.match_subscription.027", "ep.commit_offset.006", "ep.commit_offset.007", "ep.commit_offset.008",
        "ep.refresh_member.002", "ep.refresh_member.005"}
SPECS = []  # dicts: id, op, title, rules, tags, input, fields, compare, twin (callable|None|"none"), rbd, twin_ruling


def spec(vid, op, title, rules, inp, fields, rbd=(), tags=(), twin=None, twin_ruling="decided", ref=None, notes=None,
         compare=None, twin_fields=None, twin_drop=()):
    if vid in DROP:
        return
    SPECS.append(dict(id=vid, op=op, title=title, rules=list(rules), input=inp, fields=list(fields), rbd=list(rbd),
                      tags=list(tags), twin=twin, twin_ruling=twin_ruling, ref=ref or REFS.get(op), notes=notes,
                      compare=compare, twin_fields=list(twin_fields or fields), twin_drop=list(twin_drop)))


def b64(s):
    return base64.b64encode(s.encode() if isinstance(s, str) else s).decode()


# ---------------------------------------------------------------------------------- recompute helpers (corrected)
def ms_trunc_seconds(d):
    """Decimal seconds -> Decimal seconds truncated to the millisecond (toward minus infinity)."""
    return (d * 1000).to_integral_value(rounding=ROUND_FLOOR) / Decimal(1000)


def dec_text(d):
    t = format(d.normalize(), "f") if d != 0 else "0"
    if "." in t:
        t = t.rstrip("0").rstrip(".")
    return t


def inst_text(d):
    """Decimal epoch seconds (ms precision) -> ISO instant in UTC."""
    ms = int((d * 1000).to_integral_value(rounding=ROUND_FLOOR))
    t = datetime(1970, 1, 1, tzinfo=timezone.utc) + timedelta(milliseconds=ms)
    frac = ms % 1000
    base = t.strftime("%Y-%m-%dT%H:%M:%S")
    return base + ("." + ("%03d" % frac).rstrip("0") if frac else "") + "Z"


def corrected_seconds(ts_json):
    """Exact event instant (Decimal seconds, ms-truncated, UTC) or None when the timestamp is invalid."""
    v = json.loads(ts_json, parse_float=lambda s: ("num", s), parse_int=lambda s: ("num", s))
    if isinstance(v, tuple):
        return ms_trunc_seconds(Decimal(v[1]))
    if isinstance(v, str):
        try:
            d = Decimal(v)
            if d.is_finite():
                return ms_trunc_seconds(d)
        except Exception:
            pass
        try:
            t = datetime.fromisoformat(v.replace("Z", "+00:00"))
            if t.tzinfo is None:
                return None
            t = t.astimezone(timezone.utc)
            whole = Decimal(int(t.replace(microsecond=0).timestamp()))
            return ms_trunc_seconds(whole + Decimal(t.microsecond) / Decimal(1000000))
        except Exception:
            return None
    return None


def twin_parse_timestamp(inp, ref_out, emitted_rule):
    s = corrected_seconds(inp["timestamp_json"])
    if s is None:
        return {"error": {"code": "invalid_timestamp", "field": "timestamp"}}
    out = {}
    if s < Decimal(253402300800):  # instants are written with a 4-digit year
        out["match_instant"] = inst_text(s)
    if emitted_rule:
        out["emitted_text"] = dec_text(s)
    elif "emitted_text" in ref_out:
        out["emitted_text"] = ref_out["emitted_text"]
    return out


def corpus_rows():
    rows = []
    with open(CORPUS) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            rows.append(line.rstrip("\n").split("\t"))
    return rows


def plain_value(lit_json):
    """Corrected value text of a JSON literal (corpus want_value semantics)."""
    if lit_json is None:
        return "0"
    v = json.loads(lit_json, parse_float=lambda s: ("float", s), parse_int=lambda s: ("int", s))
    if v is None:
        return "0"
    if isinstance(v, tuple):
        kind, text = v
        if kind == "int":
            return str(int(text))
        return dec_text(Decimal(repr(float(text))))
    if isinstance(v, str):
        return v
    return None  # bool / object / array: no string contract


def sub(n, ext, started, terminated=None, plan=None, org=None, status=None):
    d = {"id": SUB(n), "external_id": ext, "started_at": started}
    if terminated:
        d["terminated_at"] = terminated
    if plan:
        d["plan_id"] = plan
    if status is not None:
        d["status"] = status
    if org:
        d["organization_id"] = org
    return d


def corrected_match(inp):
    t = corrected_seconds(inp["timestamp_json"])
    if t is None:
        return {"error": {"code": "build_enriched_event"}}
    org = inp.get("organization_id", O1)

    def secs(s):
        x = datetime.fromisoformat(s.replace("Z", "+00:00")).astimezone(timezone.utc)
        return ms_trunc_seconds(Decimal(int(x.replace(microsecond=0).timestamp())) + Decimal(x.microsecond) / Decimal(1000000))

    def pick(at):
        cands = []
        for s in inp["subscriptions"]:
            if s.get("organization_id", org) != org or s["external_id"] != inp["external_subscription_id"]:
                continue
            st = secs(s["started_at"])
            te = secs(s["terminated_at"]) if s.get("terminated_at") else None
            if st <= at and (te is None or te >= at):
                cands.append((0 if te is None else 1, -(te or 0), -st, s["id"]))
        cands.sort()
        return cands[0] if cands else None

    best = pick(t)
    if best is None and inp.get("recurring"):
        now = datetime.fromisoformat(inp["now"].replace("Z", "+00:00")).timestamp()
        best = pick(Decimal(int(now)))  # recurring fallback at "now"
    return {"subscription_id": best[3] if best else ""}


def corrected_commit(inp):
    recs = inp["records"]
    pending = inp.get("pending_before") or []
    first_open = min([r["offset"] for r in recs if not r["processed"]] + list(pending), default=None)
    done = [r["offset"] for r in recs if r["processed"] and (first_open is None or r["offset"] < first_open)]
    if not done:
        return {"commit": None}
    return {"commit": max(done) + 1}


# ---------------------------------------------------------------------------------- the vectors
def build_specs():
    # ---------------- ep.decode
    ev = lambda **kw: json.dumps(kw, separators=(",", ":"))
    base = {"organization_id": O1, "external_subscription_id": "sub_ext_1", "transaction_id": "tx_1", "code": "api_calls",
            "timestamp": "1741007009.123", "properties": {"amount": "12", "region": "eu"}, "precise_total_amount_cents": "100.5",
            "source": "http_ruby", "source_metadata": {"api_post_processed": True}, "ingested_at": "2025-03-03T13:03:30.456"}
    spec("ep.decode.001", "decode", "complete raw event: every field kept, ingested_at re-emitted without milliseconds",
         ["EP-C1", "EP-D5", "EP-W1", "EP-W4"], {"raw_b64": b64(ev(**base))}, ["event_json"], tags=["core"], twin="same")
    spec("ep.decode.002", "decode", "unknown top-level fields are dropped",
         ["EP-C4"], {"raw_b64": b64(ev(transaction_id="tx_2", code="count_calls", timestamp="1759320000", external_customer_id="cust_1", foo={"bar": 1}))},
         ["event_json"], twin="same")
    spec("ep.decode.003", "decode", "duplicate key: the last value wins",
         ["EP-C4"], {"raw_b64": b64('{"transaction_id":"first","transaction_id":"last","code":"count_calls","timestamp":"1759320000"}')},
         ["event_json"], tags=["boundary"], twin="same")
    spec("ep.decode.004", "decode", "the JSON literal null decodes to an all-empty event",
         ["EP-C3"], {"raw_b64": b64("null")}, ["event_json"], tags=["boundary"], twin="same")
    for i, (raw, title) in enumerate([
            ("{not json", "invalid JSON is undecodable"),
            ("", "an empty record value is undecodable"),
            ("[1,2]", "a JSON array is undecodable"),
            ('{"transaction_id":"t","properties":[1,2]}', "properties as an array is undecodable"),
            ('{"transaction_id":123,"code":"count_calls"}', "a numeric transaction_id is undecodable"),
            ('{"transaction_id":"t","source_metadata":"x"}', "source_metadata as a string is undecodable"),
            ('{"transaction_id":"t","ingested_at":"yesterday"}', "an unparsable ingested_at is undecodable"),
            ('{"transaction_id":"t","source_metadata":{"api_post_processed":"yes"}}', "api_post_processed as a string is undecodable"),
            ('{"organization_id":42,"transaction_id":"t"}', "a numeric organization_id is undecodable"),
    ], start=5):
        spec("ep.decode.%03d" % i, "decode", title, ["EP-C1", "EP-C2"], {"raw_b64": b64(raw)}, ["error"], twin="same")
    spec("ep.decode.014", "decode", "numeric precise_total_amount_cents is undecodable (reference)",
         ["EP-C1", "EP-C2", "EP-F5"], {"raw_b64": b64('{"transaction_id":"t","code":"api_calls","precise_total_amount_cents":100}')},
         ["error"], rbd=["RBD-4"], twin=lambda inp, ref: {"event_json": ref_decode_like(inp, ptac="100")}, twin_ruling="proposed",
         twin_fields=["event_json"])
    spec("ep.decode.015", "decode", "ingested_at as an epoch-seconds string is accepted and re-emitted as a UTC date-time",
         ["EP-D5"], {"raw_b64": b64('{"transaction_id":"t","ingested_at":"1744335427"}')}, ["event_json"], twin="same")
    spec("ep.decode.016", "decode", "ingested_at null and absent both re-emit as null",
         ["EP-D5"], {"raw_b64": b64('{"transaction_id":"t","ingested_at":null}')}, ["event_json"], twin="same")
    spec("ep.decode.017", "decode", "number literals inside properties are re-encoded through binary64 (reference)",
         ["EP-C5"], {"raw_b64": b64('{"transaction_id":"t","properties":{"a":9007199254740993,"b":2.0,"c":1e21,"d":0.0000001,"e":12345678901234567890,"f":0.00001}}')},
         ["event_json"], rbd=["RBD-14"], tags=["literal"], twin=lambda inp, ref: {"event_json": literal_properties(ref["event_json"], inp)},
         twin_ruling="proposed")
    spec("ep.decode.018", "decode", "a numeric timestamp is re-encoded through binary64 in the dead-letter copy",
         ["EP-C5", "EP-W4"], {"raw_b64": b64('{"transaction_id":"t","timestamp":1.741007009e9}')}, ["event_json"], tags=["literal"], twin="same",
         notes="The dead-letter copy of the event is diagnostic; only the enriched timestamp is a billing contract (ep.parse_timestamp).")
    spec("ep.decode.019", "decode", "null properties kept; empty source omitted; null string field reads as empty",
         ["EP-C1", "EP-W4"], {"raw_b64": b64('{"transaction_id":"t","properties":null,"source":"","code":null}')}, ["event_json"], twin="same")

    spec("ep.decode.021", "decode", "ingested_at with a UTC offset is re-emitted as the wall clock of that offset",
         ["EP-D5"], {"raw_b64": b64('{"transaction_id":"t","ingested_at":"2025-03-03T15:03:30+02:00"}')}, ["event_json"], tags=["boundary"], twin="same",
         notes="The age rule uses the instant; only the dead-letter copy shows the local wall clock.")
    spec("ep.decode.022", "decode", "ingested_at as a JSON integer (epoch seconds) is accepted",
         ["EP-D5"], {"raw_b64": b64('{"transaction_id":"t","ingested_at":1744335427}')}, ["event_json"], twin="same")
    spec("ep.decode.023", "decode", "field names match ignoring case; the last spelling of a field wins",
         ["EP-C1", "EP-C4"], {"raw_b64": b64('{"Transaction_Id":"first","TRANSACTION_ID":"tx_ci","CODE":"api_calls",'
                                             '"Organization_ID":"%s","External_Subscription_Id":"sub_ext_1","Timestamp":"1759320000",'
                                             '"Properties":{"Amount":"1"},"Source":"http_ruby","Source_Metadata":{"API_POST_PROCESSED":true},'
                                             '"Ingested_At":"2025-03-03T13:03:30","Precise_Total_Amount_Cents":"1"}' % O1)},
         ["event_json"], tags=["boundary"], twin="same",
         notes="Property keys inside properties keep their case; only the recognised field names (and api_post_processed) fold.")

    # ---------------- ep.parse_timestamp
    T = [
        ("001", '"1741007009.123"', "decimal-seconds string with milliseconds", ["core"]),
        ("002", '"1741007009.123456"', "decimal-seconds string with microseconds: emitted truncated to ms", []),
        ("003", '"1741007009"', "integer-seconds string", ["core"]),
        ("004", "1741007009", "JSON integer seconds", ["core"]),
        ("005", "1741007009.123456", "JSON number with microseconds: emitted untruncated (reference)", ["literal"]),
        ("006", "1.741007009e9", "JSON number in exponent form", ["literal"]),
        ("007", '"2025-03-03T13:03:29Z"', "RFC 3339 UTC", []),
        ("008", '"2025-03-03T13:03:29.344Z"', "RFC 3339 UTC with milliseconds", []),
        ("009", '"2025-03-03T15:03:29.123456+02:00"', "RFC 3339 with an offset and microseconds: zone kept for matching (reference)", ["boundary"]),
        ("010", '"2025-03-03 13:03:29"', "space-separated date-time is rejected", []),
        ("011", '"1741007009123"', "millisecond epoch sent as seconds is accepted as seconds (far future)", ["boundary"]),
        ("012", '"-1"', "negative seconds", ["boundary"]),
        ("013", '"1.741007009e9"', "decimal string in exponent form", []),
        ("014", "true", "boolean is rejected", []),
        ("015", "null", "null (same as absent) is rejected", []),
        ("016", '{"a":1}', "object is rejected", []),
        ("017", '""', "empty string is rejected", []),
        ("018", '"1748736000.001"', "1 ms after a whole second: the matching instant lands 1 ms early (reference)", ["boundary"]),
        ("019", '"1741007009.999"', "999 ms: matching instant (reference float path)", ["boundary"]),
        ("020", "1741007009.123", "JSON number with milliseconds: matching instant 1 ms early (reference)", ["boundary"]),
        ("021", '"2025-03-03T13:03:29.123456789Z"', "RFC 3339 with nanoseconds", ["boundary"]),
        ("022", '"1735689600.000"', "explicit .000 milliseconds", []),
        ("023", '"2025-03-01T00:30:00+01:00"', "RFC 3339 offset crossing a UTC day boundary", ["boundary"]),
        ("024", '"-1.0005"', "negative fraction: emitted toward zero, matching instant floored", ["boundary"]),
        ("025", '"-0.0005"', "negative value above -1 ms: emitted as negative zero (reference)", ["boundary"]),
        ("026", '"1e19"', "no range check: a value far beyond year 9999 is accepted", ["boundary"]),
    ]
    PT_NOTES = {
        "009": "match_time keeps the zone and sub-millisecond digits the reference compares in DB mode (wall clock).",
        "023": "match_time keeps the zone and sub-millisecond digits the reference compares in DB mode (wall clock).",
        "024": "The emitted number truncates toward zero (-1.000); the matching instant is floored (-1.001 s), in both profiles.",
        "025": "No corrected contract for the sign of a zero emitted timestamp.",
        "026": "The matching instant of such a value is not part of the contract (op output omitted beyond year 9999).",
    }
    for n, tj, title, tags in T:
        emitted_rbd = n in ("005",)
        rbd = ["RBD-15"]
        if emitted_rbd:
            rbd = ["RBD-15", "RBD-18"]
        if n in ("009", "021", "023"):
            rbd = ["RBD-15", "RBD-16"]
        rules = ["EP-D1", "EP-D2", "EP-D3"] + (["EP-D4"] if n in ("009", "023") else [])
        fields = ["emitted_text", "match_instant"] + (["match_time"] if n in ("009", "023") else [])
        if n in ("011", "026"):
            fields = ["emitted_text"]
        twin = (lambda e: (lambda inp, ref: twin_parse_timestamp(inp, ref, e)))(emitted_rbd)
        if n == "025":
            twin = "none"
        spec("ep.parse_timestamp.%s" % n, "parse_timestamp", title, rules, {"timestamp_json": tj}, fields, rbd=rbd, tags=tags,
             twin=twin,
             twin_ruling="proposed" if emitted_rbd else "decided", twin_drop=["match_time"],
             notes=PT_NOTES.get(n))

    # ---------------- ep.value_string
    rows = corpus_rows()
    for i, r in enumerate(rows, start=1):
        rid, lit, want = r[0], r[1], r[2]
        props = "{}" if lit == "MISSING" else '{"amount":%s}' % lit
        tw = "none" if want == "n/a" else (lambda w: (lambda inp, ref: {"value": w}))(want)
        spec("ep.value_string.%03d" % i, "value_string", "sum of amount, corpus literal %s" % ("(missing)" if lit == "MISSING" else lit),
             ["EP-F2"], {"aggregation_type": "1", "field_name": "amount", "properties_json": props}, ["value"], rbd=["RBD-13"],
             tags=["literal"] + (["core"] if rid in ("int_42", "dec_0.1", "missing") else []), twin=tw,
             notes="No corrected contract for this type." if want == "n/a" else None)
    k = len(rows)
    extra = [
        ("0", "amount", '{"amount":3}', "count ignores the field: value 1", ["EP-F1"], ["core"], "same"),
        ("0", None, "{}", "count without field_name and without properties: value 1", ["EP-F1"], [], "same"),
        ("0", "amount", None, "count with properties null: value 1", ["EP-F1"], [], "same"),
        ("4", "amount", '{"amount":5}', "retired type code 4: empty label, value from the field", ["EP-F2", "EP-F4"], ["boundary"], "same"),
        ("99", "amount", '{"amount":5}', "unknown type code: empty label, value from the field", ["EP-F2", "EP-F4"], ["boundary"], "same"),
        ("7", None, '{"x":1}', "custom aggregation without field_name: value of a missing field", ["EP-F2", "EP-F4"], [], lambda inp, ref: {"value": "0"}),
        ("3", "user_id", '{"user_id":"u-1"}', "unique_count with a string identity: verbatim", ["EP-F2", "EP-F4"], ["core"], "same"),
        ("3", "user_id", '{"user_id":1000000}', "unique_count with a numeric identity", ["EP-F2", "EP-F4"], [], lambda inp, ref: {"value": "1000000"}),
        ("2", "amount", '{"amount":99}', "max with an integer", ["EP-F2", "EP-F4"], [], "same"),
        ("5", "gb", '{"gb":2.5}', "weighted_sum with a decimal", ["EP-F2", "EP-F4"], [], "same"),
        ("6", "level", '{"level":"gold"}', "latest with a string", ["EP-F2", "EP-F4"], [], "same"),
        ("1", "amount", '{"amount":"h\\u00e9llo w\\u00f6rld"}', "non-ASCII string passes verbatim", ["EP-F2"], [], "same"),
        ("1", "a.b", '{"a":{"b":7}}', "a dotted field_name is a plain key, not a path", ["EP-F2"], ["boundary"], lambda inp, ref: {"value": "0"}),
        ("1", "amount", "null", "properties null: value of a missing field", ["EP-F2"], [], lambda inp, ref: {"value": "0"}),
        ("1", "amount", '{"amount":[1,2]}', "an array value prints in the reference's list syntax", ["EP-F2"], ["boundary"], "none"),
    ]
    for j, (agg, field, props, title, rules, tags, tw) in enumerate(extra, start=k + 1):
        inp = {"aggregation_type": agg, "field_name": field}
        if props is not None:
            inp["properties_json"] = props
        else:
            inp["properties_json"] = "null"
        fields = ["value"] + (["aggregation_label"] if "EP-F4" in rules else [])
        spec("ep.value_string.%03d" % j, "value_string", title, rules, inp, fields, rbd=["RBD-13"] if tw not in ("same",) else [],
             tags=tags, twin=tw, notes=None)

    # ---------------- ep.match_subscription
    NOW = "2026-10-02T00:00:00Z"
    term = sub(2, "sub_ext_term", "2025-01-01T00:00:00Z", "2025-06-01T00:00:00.0007Z")
    s03 = sub(3, "sub_ext_multi", "2025-01-01T00:00:00Z", "2025-03-01T00:00:00Z", plan=P0)
    s04 = sub(4, "sub_ext_multi", "2025-03-01T00:00:00Z")
    s01 = sub(1, "sub_ext_1", "2025-01-01T00:00:00.0005Z")
    s10 = sub(10, "sub_ext_ms", "2025-03-03T13:03:29.123Z")
    late = sub(6, "sub_ext_late", "2025-09-01T00:00:00Z")
    M = []

    def m(n, title, ext, tj, subs, rules, modes=("db", "cache"), recurring=False, rbd=("RBD-15",), tags=(), org=None, notes=None):
        for mode in modes:
            M.append((n, mode, title, ext, tj, subs, rules, recurring, rbd, tags, org, notes))

    m(1, "terminated subscription, event 1 s before terminated_at", "sub_ext_term", '"1748735999"', [term], ["EP-H1"], tags=("core",), modes=("db",))
    m(2, "event in the terminated_at millisecond still matches", "sub_ext_term", '"1748736000.000"', [term], ["EP-H1", "EP-H6"], modes=("cache",))
    m(3, "event 1 ms after the terminated_at millisecond (reference matches)", "sub_ext_term", '"1748736000.001"', [term], ["EP-H6", "EP-D3"], tags=("boundary",))
    m(4, "before a hand-over: the terminated subscription matches", "sub_ext_multi", '"1739577600"', [s03, s04], ["EP-H1"], modes=("db",))
    m(5, "at the hand-over instant: the open subscription wins (terminated_at NULLS FIRST)", "sub_ext_multi", '"1740787200"', [s03, s04], ["EP-H1"], tags=("core",))
    m(6, "subscription starting in the future: no match", "sub_ext_future", '"1759320000"', [sub(5, "sub_ext_future", "2030-01-01T00:00:00Z")], ["EP-H1", "EP-H4"], modes=("cache",))
    m(7, "event in the started_at millisecond, started_at has +500 microseconds", "sub_ext_1", '"1735689600.000"', [s01], ["EP-H5"], rbd=("RBD-17",), tags=("boundary",))
    m(8, "event 1 ms before started_at: no match", "sub_ext_1", '"1735689599.999"', [s01], ["EP-H1"], modes=("db",))
    m(9, "recurring metric, no subscription at the event time: falls back to the one active now", "sub_ext_late", '"1736899200"', [late], ["EP-H3"], recurring=True, tags=("core",),
      notes="Use input.now for the fallback; the answer is the same for any now after 2025-09-01.")
    m(10, "non-recurring metric, no subscription at the event time: no fallback", "sub_ext_late", '"1736899200"', [late], ["EP-H3", "EP-H4"], modes=("cache",))
    m(11, "external id is matched exactly ('acme' does not match 'acme:eu')", "acme", '"1759320000"',
      [sub(8, "acme", "2025-01-01T00:00:00Z"), sub(9, "acme:eu", "2025-01-01T00:00:00Z", plan=P0)], ["EP-H1"], modes=("db",))
    m(12, "RFC 3339 offset: DB mode compares the wall clock, cache mode the instant", "sub_ext_multi", '"2025-03-01T00:30:00+01:00"', [s03, s04],
      ["EP-H1", "EP-D4"], rbd=("RBD-16",), tags=("boundary",))
    m(13, "decimal-seconds string in the started_at millisecond (reference misses it)", "sub_ext_ms", '"1741007009.123"', [s10], ["EP-D3", "EP-H5"], tags=("boundary",))
    m(14, "JSON number in the started_at millisecond (reference misses it)", "sub_ext_ms", "1741007009.123", [s10], ["EP-D3", "EP-H5"], tags=("boundary",))
    m(15, "RFC 3339 in the started_at millisecond matches", "sub_ext_ms", '"2025-03-03T13:03:29.123Z"', [s10], ["EP-H1", "EP-H5"], modes=("cache",))
    m(16, "same external id in another organization never matches", "sub_ext_1", '"1759320000"',
      [sub(11, "sub_ext_1", "2025-01-01T00:00:00Z", org=O2)], ["EP-H1", "EP-I5"], modes=("db",))
    m(17, "two open subscriptions: the latest started_at wins", "sub_ext_two", '"1740787200"',
      [sub(12, "sub_ext_two", "2025-01-01T00:00:00Z"), sub(13, "sub_ext_two", "2025-02-01T00:00:00Z")], ["EP-H1"], modes=("cache",))
    m(18, "two terminated subscriptions: the latest terminated_at wins", "sub_ext_two", '"1738368000"',
      [sub(14, "sub_ext_two", "2025-01-01T00:00:00Z", "2025-03-01T00:00:00Z"), sub(15, "sub_ext_two", "2025-01-15T00:00:00Z", "2025-02-15T00:00:00Z")], ["EP-H1"], modes=("db",))
    m(19, "invalid timestamp fails before matching", "sub_ext_1", '"2025-03-03 13:03:29"', [s01], ["EP-D1"], rbd=(), modes=("cache",))
    m(20, "no subscription rows at all: no match, no error", "sub_ext_1", '"1759320000"', [], ["EP-H4"], rbd=(), modes=("db",))
    m(21, "RFC 3339 with sub-millisecond digits after the terminated_at millisecond", "sub_ext_term", '"2025-06-01T00:00:00.0008Z"', [term],
      ["EP-H6", "EP-D3"], rbd=("RBD-15", "RBD-17"), tags=("boundary",))
    m(22, "terminated_at exactly equal to the event instant matches", "sub_ext_eq", '"1740787200"',
      [sub(16, "sub_ext_eq", "2025-01-01T00:00:00Z", "2025-03-01T00:00:00Z")], ["EP-H1"], modes=("cache",))
    m(23, "subscription status is not read (incomplete subscription matches)", "sub_ext_incomplete", '"1759320000"',
      [sub(7, "sub_ext_incomplete", "2025-01-01T00:00:00Z", status=4)], ["EP-H2"], rbd=("RBD-19",), modes=("db",))
    m(24, "external id that is a prefix of another one containing ':' (reference cache mode sees both)", "acme", '"1759320000"',
      [sub(8, "acme", "2025-01-01T00:00:00Z"), sub(9, "acme:eu", "2025-02-01T00:00:00Z", plan=P0)], ["EP-H1", "EP-H8"], rbd=("RBD-99",),
      tags=("boundary",), notes="Reference cache lookup scans the key prefix sub:<org>:<external_id>: (RBD-99).")
    seq = 0
    for (n, mode, title, ext, tj, subs, rules, recurring, rbd, tags, org, notes) in M:
        seq += 1
        inp = {"mode": mode, "external_subscription_id": ext, "timestamp_json": tj, "subscriptions": subs}
        if recurring:
            inp["recurring"] = True
            inp["now"] = NOW
        if org:
            inp["organization_id"] = org
        if n == 23 or (mode == "cache" and n in (3, 13, 14, 21)):
            tw = "none"  # status: owner question; cache twins of these cases duplicate the db-mode twins
            if n != 23:
                notes = "Corrected: same as the db-mode twin ep.match_subscription.%03dx." % (seq - 1)
        elif n in (19, 20):
            tw = "same"
        else:
            tw = lambda inp, ref: corrected_match(inp)
        spec("ep.match_subscription.%03d" % seq, "match_subscription", "%s (%s mode)" % (title, mode), rules, inp, ["subscription_id"],
             rbd=list(rbd), tags=list(tags), twin=tw, ref=REFS["match_subscription_" + mode],
             twin_ruling="proposed" if n == 24 else "decided",
             notes=(None if (n == 24 and mode == "db") else notes) if n != 23 else "Corrected: open owner question (RBD-19).")

    # ---------------- ep.commit_offset
    C = [
        ("all processed: commit after the last record", [(10, True), (11, True), (12, True)], None, ["core"]),
        ("first record unprocessed: nothing committed for this batch", [(10, False), (11, True), (12, True)], None, ["core"]),
        ("middle record unprocessed: commit the prefix before it", [(10, True), (11, False), (12, True)], None, ["core"]),
        ("last record unprocessed", [(10, True), (11, True), (12, False)], None, []),
        ("two gaps: the lowest unprocessed offset bounds the commit", [(0, True), (1, False), (2, True), (3, False), (4, True)], None, []),
        ("single processed record", [(7, True)], None, []),
        ("single unprocessed record", [(7, False)], None, []),
        ("non-contiguous offsets (compacted topic), all processed", [(3, True), (5, True), (9, True)], None, []),
        ("a later batch after an unprocessed record of an earlier batch: the reference commits past it", [(20, True), (21, True)], [19], ["boundary"]),
        ("a later batch with its own gap after an earlier unprocessed record", [(20, True), (21, False), (22, True)], [18], ["boundary"]),
    ]
    for i, (title, recs, pending, tags) in enumerate(C, start=1):
        inp = {"records": [{"offset": o, "processed": p} for o, p in recs]}
        if pending:
            inp["pending_before"] = pending
        spec("ep.commit_offset.%03d" % i, "commit_offset", title, ["EP-B2", "EP-B3", "EP-B4"], inp, ["commit"], rbd=["RBD-1"], tags=tags,
             twin=lambda inp, ref: corrected_commit(inp),
             notes="pending_before: offsets of earlier batches still without a disposition (the reference ignores them)." if pending else None)

    # ---------------- ep.refresh_member
    R = [
        (O1, SUB(1), 1759320007, "member is <organization>:<subscription>|<10 s bucket>, score = now", ["core"]),
        (O1, SUB(1), 1759320000, "now on a bucket boundary", ["boundary"]),
        (O1, SUB(1), 1759320009, "last second of a bucket", ["boundary"]),
        (O1, SUB(1), 1759320010, "first second of the next bucket gives a new member", ["boundary"]),
        (O2, "bbbbbbbb-0000-0000-0000-0000000000f1", 1759320123, "another organization", []),
    ]
    for i, (org, sid, now, title, tags) in enumerate(R, start=1):
        spec("ep.refresh_member.%03d" % i, "refresh_member", title, ["EP-K1", "EP-K2", "EP-W5"],
             {"organization_id": org, "subscription_id": sid, "now_unix": now}, ["member", "score"], tags=tags, twin="same",
             notes=None)


def ref_decode_like(inp, ptac):
    raw = base64.b64decode(inp["raw_b64"]).decode()
    obj = json.loads(raw)
    full = {"code": "", "external_subscription_id": "", "ingested_at": None, "organization_id": "", "precise_total_amount_cents": "",
            "properties": None, "source_metadata": None, "timestamp": None, "transaction_id": ""}
    for k, v in obj.items():
        if k in full or k == "source":
            full[k] = v
    full["precise_total_amount_cents"] = ptac
    return json.dumps(full, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def literal_properties(ref_json, inp):
    """Corrected (RBD-14): the reference event text with the original literal spelling of properties."""
    raw = base64.b64decode(inp["raw_b64"]).decode()
    lit = json.loads(raw, parse_float=lambda s: ("§", s), parse_int=lambda s: ("§", s))
    obj = json.loads(ref_json, parse_float=lambda s: ("§", s), parse_int=lambda s: ("§", s))
    obj["properties"] = lit["properties"]

    def enc(v):
        if isinstance(v, tuple):
            return v[1]
        if isinstance(v, dict):
            return "{" + ",".join(json.dumps(k, ensure_ascii=False) + ":" + enc(v[k]) for k in sorted(v)) + "}"
        if isinstance(v, list):
            return "[" + ",".join(enc(x) for x in v) + "]"
        return json.dumps(v, ensure_ascii=False)
    return enc(obj)


# ---------------------------------------------------------------------------------- oracle client
class Oracle:
    def __init__(self, cmd):
        self.p = subprocess.Popen(["sh", "-c", "exec " + cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        h = self.rpc({"type": "hello", "proto": 1, "kit_version": "1.1.0", "kit_schema": 1, "profiles": ["compat"], "areas": ["ep"]})
        assert h.get("type") == "hello", h
        self.n = 0

    def rpc(self, m):
        self.p.stdin.write(json.dumps(m) + "\n")
        self.p.stdin.flush()
        line = self.p.stdout.readline()
        if not line:
            raise RuntimeError("oracle exited")
        return json.loads(line)

    def call(self, op, inp):
        self.n += 1
        r = self.rpc({"type": "call", "id": "m%d" % self.n, "area": "ep", "op": op, "profile": "compat", "input": inp})
        if "error" in r:
            return {"error": r["error"]}
        return r["output"]

    def close(self):
        try:
            self.p.stdin.write(json.dumps({"type": "bye"}) + "\n")
            self.p.stdin.flush()
        except BrokenPipeError:
            pass
        self.p.wait(timeout=30)


def pick(out, fields):
    if "error" in out:
        e = {"code": out["error"]["code"]}
        if out["error"].get("field"):
            e["field"] = out["error"]["field"]
        return {"error": e}
    return {f: out[f] for f in fields if f in out}


# Corrected twins whose compat title describes the reference quirk get a title of their own (a twin
# title must describe what the twin expects). Others reuse the compat title minus "(reference…)".
TWIN_TITLES = {
    "ep.match_subscription.033x": "external id matched exactly: 'acme' does not see 'acme:eu' (cache mode)",
    "ep.commit_offset.009x": "later batch after an earlier unprocessed record: nothing committed",
    "ep.commit_offset.010x": "later batch with its own gap after an earlier pending record: no commit",
    "ep.decode.014x": "numeric precise_total_amount_cents accepted as its literal text",
    "ep.decode.017x": "number literals inside properties keep their literal text",
    "ep.match_subscription.016x": "RFC 3339 offset compared as a UTC instant (db mode)",
    "ep.parse_timestamp.005x": "JSON number with microseconds: emitted truncated to ms",
    "ep.parse_timestamp.009x": "RFC 3339 with an offset and microseconds: UTC instant truncated to ms",
    "ep.parse_timestamp.018x": "1 ms after a whole second: exact matching instant",
    "ep.parse_timestamp.020x": "JSON number with milliseconds: exact matching instant",
    "ep.parse_timestamp.021x": "RFC 3339 with nanoseconds: matching instant truncated to ms",
}

REFRESH_NOTE = ("Reference reads its own wall clock: the ep-oracle performs a live flag write with the reference code, checks "
                "bucket = score floored to 10 s, then applies that rule to input now_unix.")
TEXT_FIELDS = {"value", "emitted_text"}  # other expected strings are not decimals: default compare is text


def compare_for(expected):
    c = {k: {"mode": "text"} for k in expected if k in TEXT_FIELDS}
    return c or None


def envelope(vid, s, profile, ruling, pair, expected, evidence, rbd, notes):
    title = s["title"] if len(s["title"]) <= 72 else s["title"][:69].rstrip(" ,;:") + "..."
    v = {"kit_schema": 1, "id": vid, "area": "ep", "op": s["op"], "title": title, "profile": profile, "ruling": ruling,
         "pair": pair, "rules": s["rules"], "rbd": rbd, "tags": s["tags"], "input": s["input"], "expected": expected}
    c = compare_for(expected)
    if c:
        v["compare"] = c
    v["evidence"] = evidence
    if notes:
        v["notes"] = notes
    return v


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--oracle")
    ap.add_argument("--out")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--date", default=datetime.now(timezone.utc).strftime("%Y-%m-%d"))
    a = ap.parse_args()
    cmd = a.oracle
    if not cmd:
        env = subprocess.run(["bash", os.path.join(HERE, "build-go-reference.sh"), "--print-env"], capture_output=True, text=True, check=True).stdout
        kv = dict(l.split("=", 1) for l in env.strip().splitlines() if "=" in l)
        cmd = "env LD_LIBRARY_PATH=%s %s" % (kv["EP_REF_LD_LIBRARY_PATH"], kv["EP_ORACLE_BIN"])
    build_specs()
    orc = Oracle(cmd)
    vectors = []
    try:
        for s in SPECS:
            ref = orc.call(s["op"], s["input"])
            if "error" in ref and ref["error"]["code"] in ("internal", "bad_input", "unsupported_op"):
                raise RuntimeError("%s: oracle error %s" % (s["id"], ref["error"]))
            exp = pick(ref, s["fields"])
            ev_exec = {"kind": "EXECUTED", "by": "ep-oracle", "ref": s["ref"], "pin": PIN, "runtime": RUNTIME, "executed_at": a.date}
            if s["op"] == "refresh_member":  # the reference reads its own wall clock: the oracle maps the observed rule onto now_unix
                ev_exec = dict(ev_exec, kind="RECOMPUTED", by="recompute", note=REFRESH_NOTE)
            tw = s["twin"]
            if tw == "same":
                vectors.append(envelope(s["id"], s, "both", "decided", None, exp, ev_exec, s["rbd"], s["notes"]))
                continue
            if tw == "none":
                note = s["notes"] or "No corrected contract for this case."
                vectors.append(envelope(s["id"], s, "compat", "decided", None, exp, ev_exec, s["rbd"], note))
                continue
            corr = tw(s["input"], ref if "error" not in ref else {})
            if "error" in corr:
                corr_cmp = {"error": corr["error"]}
            else:
                corr_cmp = {k: v for k, v in exp.items() if k != "error" and k not in s["twin_drop"]}
                corr_cmp.update({k: v for k, v in corr.items() if k in s["twin_fields"]})
            same = corr_cmp == exp
            if same:
                vectors.append(envelope(s["id"], s, "both", "decided", None, exp, ev_exec, s["rbd"], s["notes"]))
                continue
            twin_id = s["id"] + "x"
            rbd = s["rbd"]
            vectors.append(envelope(s["id"], s, "compat", "decided", twin_id, exp, ev_exec, rbd, s["notes"]))
            ev_rec = {"kind": "RECOMPUTED", "by": "recompute", "ref": ",".join(rbd) if rbd else "derived", "pin": PIN,
                      "runtime": RECOMPUTE_RUNTIME, "executed_at": a.date}
            t = dict(s)
            t["title"] = TWIN_TITLES.get(twin_id) or s["title"].replace(" (reference)", "").replace(" (reference matches)", "").replace(" (reference misses it)", "")
            vectors.append(envelope(twin_id, t, "corrected", s["twin_ruling"], s["id"], corr_cmp, ev_rec, rbd, None))
    finally:
        orc.close()
    vectors.sort(key=lambda v: v["id"])
    text = "".join(json.dumps(v, ensure_ascii=False, separators=(",", ":")) + "\n" for v in vectors)
    shipped = os.path.join(SKILL, "vectors", "ep.units.jsonl")
    if not a.out and not a.write:
        cur = open(shipped).read() if os.path.exists(shipped) else ""
        strip = lambda t: [json.dumps({k: v for k, v in json.loads(l).items() if k != "evidence"}, sort_keys=True) for l in t.splitlines()]
        if strip(cur) != strip(text):
            print("mint-ep-units --check: DRIFT (vectors differ from a fresh mint, evidence ignored)")
            return 1
        print("mint-ep-units --check: OK vectors=%d" % len(vectors))
        return 0
    out = a.out or shipped
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    with open(out, "w") as f:
        f.write(text)
    prof = {}
    for v in vectors:
        prof[v["profile"]] = prof.get(v["profile"], 0) + 1
    print("mint-ep-units: vectors=%d %s out=%s" % (len(vectors), " ".join("%s=%d" % kv for kv in sorted(prof.items())), out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
