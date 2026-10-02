#!/usr/bin/env python3
"""gen-scenarios.py - regenerate the events-processor conformance scenarios and the
corrected-profile assertion files from one table (this file).

Usage:
  gen-scenarios.py [--check]                regenerate into a temp dir and compare with the shipped
                                            files (byte equality); the default action
  gen-scenarios.py --out DIR                write scenarios/EPC-*.json and golden/corrected/*.assert.json
                                            under DIR
  gen-scenarios.py --write                  MAINTAINER: overwrite the shipped files in the skill's
                                            conformance/ directory (then re-mint goldens, see
                                            maintainer/regen-goldens.sh)
  gen-scenarios.py --check-corpus FILE      compare the data rows of conformance/value-corpus.tsv
                                            with another copy of the corpus (comment lines ignored)

Number literals that must reach the wire verbatim (1e21, 0.123456789012345678, 2.0) are
injected as text through LIT(): a JSON library would re-format them.

Exit: 0 ok; 1 drift found (--check, --check-corpus); 2 usage error.
Writes only under --out, a temp dir (--check), or the skill's conformance/ directory with --write.
"""
import argparse
import difflib
import filecmp
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
CONF = os.path.join(ROOT, "conformance")
CORPUS = os.path.join(CONF, "value-corpus.tsv")

O1 = "11111111-1111-1111-1111-111111111111"
O2 = "99999999-9999-9999-9999-999999999999"
PLAN1 = "22222222-2222-2222-2222-222222222222"


def SUB(n):
    return "bbbbbbbb-0000-0000-0000-%012d" % n


CAT = ["../fixtures/catalog-base.sql"]
DEF = {"organization_id": O1, "external_subscription_id": "sub_ext_1", "ingested_at": "$INGESTED_NOW", "properties": {}}
Q = {"wait": "quiescent"}

lits = {}


def LIT(text):
    k = "__LIT_%d__" % len(lits)
    lits[k] = text
    return k


def ev(tx, code, **kw):
    d = {"transaction_id": tx, "code": code}
    if "timestamp" not in kw:
        d["timestamp"] = "1759320000"
    d.update(kw)
    return {"json": d}


def A(kind, why, rbd, ruling="decided", **kw):
    a = {"kind": kind}
    a.update(kw)
    a["why"] = why
    a["rbd"] = rbd
    a["ruling"] = ruling
    return a


DB_ONLY = {"EPC-10", "EPC-11", "EPC-12", "EPC-13", "EPC-14", "EPC-15", "EPC-16", "EPC-30"}
CACHE_ONLY = {"EPC-31", "EPC-32", "EPC-33", "EPC-34"}

SCEN = []      # (name, dict)
ASSERTS = []   # (name, list)


def scenario(name, desc, rules, rbd, steps, asserts=None, **extra):
    sc = {"name": name, "id": name[:6], "description": desc, "rules": rules, "rbd": rbd,
          "catalog": CAT, "defaults": DEF}
    if name[:6] in DB_ONLY:
        sc["modes"] = ["db"]
    if name[:6] in CACHE_ONLY:
        sc["modes"] = ["cache"]
    sc.update(extra)
    sc["steps"] = steps
    SCEN.append((name, sc))
    if asserts:
        ASSERTS.append((name, asserts))


def render(obj):
    """Readable but compact: top-level keys one per line, one step per line, one produced
    record per line. Literal placeholders are substituted afterwards."""
    def c(v):
        return json.dumps(v, ensure_ascii=False, separators=(", ", ": "))
    out = ["{"]
    keys = list(obj.keys())
    for i, k in enumerate(keys):
        comma = "," if i < len(keys) - 1 else ""
        v = obj[k]
        if k == "steps":
            out.append('  "steps": [')
            for j, st in enumerate(v):
                sc = "," if j < len(v) - 1 else ""
                if "produce" in st:
                    out.append('    {"produce": [')
                    pr = st["produce"]
                    for n, r in enumerate(pr):
                        out.append("      " + c(r) + ("," if n < len(pr) - 1 else ""))
                    out.append("    ]}" + sc)
                else:
                    out.append("    " + c(st) + sc)
            out.append("  ]" + comma)
        else:
            out.append("  " + json.dumps(k) + ": " + c(v) + comma)
    out.append("}")
    text = "\n".join(out) + "\n"
    for k, v in lits.items():
        text = text.replace('"%s"' % k, v)
    return text


def read_corpus(path):
    rows = []
    with open(path) as f:
        for line in f:
            if line.startswith("#") or not line.strip():
                continue
            rows.append(line.rstrip("\n").split("\t"))
    return rows


def build():
    # ---------------------------------------------------------------- EPC-00
    scenario("EPC-00-smoke-parity",
             "Nine mixed records (metric found / unknown, bad timestamp, undecodable bytes, expression failure, "
             "unknown subscription, API-post-processed, started_at millisecond, expression success) in one batch.",
             ["EP-C2", "EP-D1", "EP-E1", "EP-G1", "EP-G3", "EP-H4", "EP-H5", "EP-J1", "EP-P1", "EP-P5"], ["RBD-4"], [
                 {"produce": [
                     {"json": {"transaction_id": "tx_A", "code": "api_calls", "properties": {"amount": LIT("0.0000001")}, "timestamp": "1759320000.123", "source": "probe"}},
                     {"json": {"transaction_id": "tx_B", "code": "nope", "timestamp": "1759320000"}},
                     {"json": {"transaction_id": "tx_C", "code": "api_calls", "timestamp": "2025-03-06 12:00:00"}},
                     {"raw": "{not json", "label": "tx_D"},
                     {"json": {"transaction_id": "tx_E", "code": "expr_metric", "properties": {"a": 2, "flag": True}, "timestamp": LIT("1759320000")}},
                     {"json": {"transaction_id": "tx_F", "code": "count_calls", "external_subscription_id": "unknown_sub", "timestamp": LIT("1759320000")}},
                     {"json": {"transaction_id": "tx_G", "code": "api_calls", "properties": {"amount": 5}, "timestamp": "1759320000.5", "source": "http_ruby", "source_metadata": {"api_post_processed": True}}},
                     {"json": {"transaction_id": "tx_H", "code": "count_calls", "timestamp": "1735689600.000"}},
                     {"json": {"transaction_id": "tx_I", "code": "expr_metric", "properties": {"a": 2}, "timestamp": LIT("1759320000")}},
                 ]}, Q])

    # ---------------------------------------------------------------- EPC-01
    scenario("EPC-01-aggregation-types", "One event per aggregation type; value string and aggregation_type label.",
             ["EP-F1", "EP-F2", "EP-F4", "EP-J2", "EP-W2"], ["RBD-13", "RBD-22"], [
                 {"produce": [
                     ev("agg_count", "count_calls", properties={"amount": 3}),
                     ev("agg_count_field", "count_field", properties={"amount": 7}),
                     ev("agg_sum_int", "api_calls", properties={"amount": 12}),
                     ev("agg_sum_float", "api_calls", properties={"amount": LIT("12.5")}),
                     ev("agg_sum_string", "api_calls", properties={"amount": "12"}),
                     ev("agg_sum_missing", "api_calls", properties={"other": 1}),
                     ev("agg_max", "max_amount", properties={"amount": 99}),
                     ev("agg_unique", "unique_users", properties={"user_id": "u-1"}),
                     ev("agg_unique_num", "unique_users", properties={"user_id": 1000000}),
                     ev("agg_wsum", "storage_gb", properties={"gb": LIT("2.5")}),
                     ev("agg_latest", "latest_level", properties={"level": "gold"}),
                     ev("agg_custom", "custom_metric", properties={"x": 1}),
                     ev("agg_type4", "legacy_type4", properties={"amount": 5}),
                 ]}, Q])

    scenario("EPC-02-filters-pass-through",
             "Metric and charge filters exist for filtered_calls; the processor neither reads nor applies them: "
             "properties pass through unchanged.",
             ["EP-E3"], [], [
                 {"produce": [
                     ev("flt_eu", "filtered_calls", properties={"amount": 1, "region": "eu"}),
                     ev("flt_fr", "filtered_calls", properties={"amount": 1, "region": "fr"}),
                     ev("flt_none", "filtered_calls", properties={"amount": 1}),
                     ev("flt_nested", "filtered_calls", properties={"amount": 1, "region": "eu", "meta": {"a": [1, "b", None, True]}}),
                 ]}, Q])

    scenario("EPC-03-billable-metric-resolution", "Unknown, soft-deleted, wrong-organization, empty and case-mismatched codes.",
             ["EP-E1", "EP-N1", "EP-I3", "EP-W4"], [], [
                 {"produce": [
                     ev("bm_unknown", "nope"),
                     ev("bm_deleted", "deleted_metric", properties={"amount": 1}),
                     ev("bm_other_org", "count_calls", organization_id=O2),
                     ev("bm_unknown_org", "api_calls", organization_id="00000000-0000-0000-0000-000000000000"),
                     ev("bm_empty_code", ""),
                     ev("bm_case", "API_CALLS"),
                     ev("bm_ok_control", "count_calls"),
                 ]}, Q])

    scenario("EPC-04-subscription-matching",
             "Subscription window, ordering, boundaries, recurring fallback, status, external-id exactness, timestamp precision.",
             ["EP-D3", "EP-D4", "EP-H1", "EP-H2", "EP-H3", "EP-H4", "EP-H5", "EP-H6", "EP-H7"],
             ["RBD-15", "RBD-16", "RBD-17", "RBD-19", "RBD-20"], [
                 {"produce": [
                     ev("sm_unknown", "count_calls", external_subscription_id="no_such_sub"),
                     ev("sm_term_before", "count_calls", external_subscription_id="sub_ext_term", timestamp="1748735999"),
                     ev("sm_term_at_ms", "count_calls", external_subscription_id="sub_ext_term", timestamp="1748736000.000"),
                     ev("sm_term_after", "count_calls", external_subscription_id="sub_ext_term", timestamp="1748736000.001"),
                     ev("sm_multi_before", "api_calls", external_subscription_id="sub_ext_multi", timestamp="1739577600", properties={"amount": 1}),
                     ev("sm_multi_at", "api_calls", external_subscription_id="sub_ext_multi", timestamp="1740787200", properties={"amount": 1}),
                     ev("sm_future", "count_calls", external_subscription_id="sub_ext_future"),
                     ev("sm_started_ms", "count_calls", timestamp="1735689600.000"),
                     ev("sm_before_start", "count_calls", timestamp="1735689599.999"),
                     ev("sm_recurring_fallback", "seats", external_subscription_id="sub_ext_late", timestamp="1736899200", properties={"seats": 4}),
                     ev("sm_nonrecurring_nofallback", "api_calls", external_subscription_id="sub_ext_late", timestamp="1736899200", properties={"amount": 1}),
                     ev("sm_incomplete", "count_calls", external_subscription_id="sub_ext_incomplete"),
                     ev("sm_acme", "count_calls", external_subscription_id="acme"),
                     ev("sm_acme_eu", "count_calls", external_subscription_id="acme:eu"),
                     ev("sm_ts_offset", "count_calls", external_subscription_id="sub_ext_multi", timestamp="2025-02-28T23:30:00-01:00"),
                     ev("sm_ms_exact_str", "count_calls", external_subscription_id="sub_ext_ms", timestamp="1741007009.123"),
                     ev("sm_ms_exact_rfc", "count_calls", external_subscription_id="sub_ext_ms", timestamp="2025-03-03T13:03:29.123Z"),
                     ev("sm_ms_exact_num", "count_calls", external_subscription_id="sub_ext_ms", timestamp=LIT("1741007009.123")),
                 ]}, Q],
             asserts=[
                 A("subscription", "an event in the started_at millisecond matches (no binary-float rounding of the event time)", ["RBD-15"], tx="sm_ms_exact_str", want=SUB(10)),
                 A("subscription", "the same instant sent as a JSON number matches too", ["RBD-15"], tx="sm_ms_exact_num", want=SUB(10)),
                 A("subscription", "an RFC3339 offset is compared as a UTC instant (00:30Z lies in the open subscription 004, inside the cache window)", ["RBD-16"], tx="sm_ts_offset", want=SUB(4)),
                 A("subscription", "started_at is truncated to the millisecond before comparing, in both modes", ["RBD-17"], tx="sm_started_ms", want=SUB(1)),
                 A("subscription", "an event 1 ms after the terminated_at millisecond does not match", ["RBD-15"], tx="sm_term_after", want=""),
             ])

    scenario("EPC-05-expressions", "Custom expression evaluation: success, skipped for API-sourced events, failures.",
             ["EP-G1", "EP-G2", "EP-G3", "EP-F3"], ["RBD-22", "RBD-38"], [
                 {"produce": [
                     ev("ex_ok", "expr_metric", properties={"a": 2}),
                     ev("ex_overrides_field", "expr_metric", properties={"a": 2, "total": 100}),
                     ev("ex_http_ruby_skip", "expr_metric", properties={"a": 2, "total": 9}, source="http_ruby", source_metadata={"api_post_processed": True}),
                     ev("ex_bool_prop", "expr_metric", properties={"a": 2, "flag": True}),
                     ev("ex_missing_var", "expr_metric", properties={}),
                     ev("ex_props_null", "expr_metric", properties=None),
                     ev("ex_round", "expr_round", properties={"value": "12.0", "units": 3}),
                     ev("ex_ts_str", "expr_ts", timestamp="1741007009.123"),
                     ev("ex_ts_int", "expr_ts", timestamp=1741007009),
                     ev("ex_float_a", "expr_metric", properties={"a": LIT("0.1")}),
                     ev("ex_string_a", "expr_metric", properties={"a": "3"}),
                 ]}, Q])

    scenario("EPC-06-pay-in-advance", "In-advance emission and the API-post-processed split.",
             ["EP-J1", "EP-J2", "EP-K1", "EP-H7", "EP-I2", "EP-W3"], ["RBD-19", "RBD-20"], [
                 {"produce": [
                     ev("pia_yes", "api_calls", properties={"amount": 1}),
                     ev("pia_http_ruby_pp_true", "api_calls", properties={"amount": 1}, source="http_ruby", source_metadata={"api_post_processed": True}),
                     ev("pia_http_ruby_pp_false", "api_calls", properties={"amount": 1}, source="http_ruby", source_metadata={"api_post_processed": False}),
                     ev("pia_http_ruby_no_meta", "api_calls", properties={"amount": 1}, source="http_ruby"),
                     ev("pia_other_source_pp_true", "api_calls", properties={"amount": 1}, source="connector", source_metadata={"api_post_processed": True}),
                     ev("pia_no_sub", "api_calls", properties={"amount": 1}, external_subscription_id="no_such_sub"),
                     ev("pia_deleted_charge", "max_amount", properties={"amount": 1}),
                     ev("pia_not_in_advance", "count_calls"),
                     ev("pia_other_plan", "api_calls", external_subscription_id="sub_ext_multi", timestamp="1739577600", properties={"amount": 1}),
                     ev("pia_missing_property", "api_calls", properties={}),
                     ev("pia_o2", "api_calls", organization_id=O2),
                     ev("pia_recurring", "seats", properties={"seats": 2}),
                 ]}, Q])

    # ---------------------------------------------------------------- EPC-07 value corpus
    evs, cas = [], []
    for r in read_corpus(CORPUS):
        rid, lit, want_value = r[0], r[1], r[2]
        tx = "v_" + rid
        props = {} if lit == "MISSING" else {"amount": LIT(lit)}
        evs.append(ev(tx, "api_calls", properties=props, external_subscription_id="no_such_sub"))
        if want_value != "n/a":
            cas.append(A("value", "corpus want_value: exact plain decimal of the literal ('0' when missing or null)", ["RBD-13"], tx=tx, want=want_value))
    scenario("EPC-07-value-corpus",
             "The value corpus (properties.amount literal -> value string) through a sum metric, no subscription.",
             ["EP-C5", "EP-F2"], ["RBD-13", "RBD-14"], [{"produce": evs}, Q], asserts=cas)

    T = [
        ("t_str_ms", "1741007009.123"), ("t_str_us", "1741007009.123456"), ("t_str_int", "1741007009"),
        ("t_num_int", LIT("1741007009")), ("t_num_float", LIT("1741007009.123456")), ("t_num_exp", LIT("1.741007009e9")),
        ("t_rfc_z", "2025-03-03T13:03:29Z"), ("t_rfc_ms", "2025-03-03T13:03:29.344Z"), ("t_rfc_off", "2025-03-03T15:03:29.123456+02:00"),
        ("t_space", "2025-03-03 13:03:29"), ("t_ms_epoch", "1741007009123"), ("t_neg", "-1"), ("t_str_exp", "1.741007009e9"),
        ("t_bool", True), ("t_null", None), ("t_obj", {"a": 1}), ("t_empty", ""), ("t_absent", "$ABSENT"),
        ("t_nan", "NaN"), ("t_inf", "Inf"), ("t_hex", "0x1.9f0e3a8p+30"),
    ]
    scenario("EPC-08-time-formats",
             "Accepted and rejected timestamp shapes; emitted timestamp value. Non-finite spellings (NaN, Inf) parse as numbers "
             "but cannot be written to the output topic.",
             ["EP-D1", "EP-D2", "EP-D6"], ["RBD-18", "RBD-4"], [
                 {"produce": [ev(tx, "count_calls", timestamp=ts, external_subscription_id="no_such_sub") for tx, ts in T]}, Q],
             asserts=[
                 A("on_dlq", "a non-finite timestamp is a PERMANENT failure: dead-letter with a cause, never a silent commit", ["RBD-4"], tx="t_nan"),
                 A("on_dlq", "a non-finite timestamp is a PERMANENT failure: dead-letter with a cause, never a silent commit", ["RBD-4"], tx="t_inf"),
                 A("all_done", "every timestamp shape ends enriched or dead-lettered", ["RBD-4"]),
             ])

    scenario("EPC-09-undecodable-records",
             "Records that do not decode into the event shape, plus shape edge cases that do decode.",
             ["EP-C1", "EP-C2", "EP-C3", "EP-C4", "EP-D5", "EP-I3", "EP-P6", "EP-R5"], ["RBD-4"], [
                 {"produce": [
                     {"raw": "{not json", "label": "u_bad_json"},
                     {"raw": "", "label": "u_empty_value"},
                     {"raw": "[1,2]", "label": "u_array"},
                     {"raw": "null", "label": "u_null_literal"},
                     ev("u_ptac_number", "api_calls", precise_total_amount_cents=LIT("100"), external_subscription_id="no_such_sub"),
                     ev("u_ptac_string", "api_calls", precise_total_amount_cents="100.5", external_subscription_id="no_such_sub"),
                     ev("u_props_array", "api_calls", properties=[1, 2], external_subscription_id="no_such_sub"),
                     ev("u_ingested_bad", "count_calls", ingested_at="yesterday", external_subscription_id="no_such_sub"),
                     ev("u_ingested_epoch", "count_calls", ingested_at="1744335427", external_subscription_id="no_such_sub"),
                     ev("u_ingested_ms", "count_calls", ingested_at="2025-03-03T13:03:30.456", external_subscription_id="no_such_sub"),
                     {"json": {"transaction_id": 123, "code": "count_calls", "timestamp": "1759320000"}, "label": "u_tx_number"},
                     ev("u_source_metadata_string", "count_calls", source_metadata="x", external_subscription_id="no_such_sub"),
                     ev("u_extra_fields", "count_calls", external_subscription_id="no_such_sub", external_customer_id="cust_1", foo={"bar": 1}),
                     {"raw": '{"transaction_id":"u_dup_first","transaction_id":"u_dup_last","code":"count_calls","organization_id":"%s",'
                             '"external_subscription_id":"no_such_sub","timestamp":"1759320000","properties":{},"ingested_at":"2025-03-03T13:03:30"}' % O1,
                      "label": "u_dup_last"},
                     ev("u_after", "count_calls", external_subscription_id="no_such_sub"),
                 ]}, Q],
             asserts=[
                 A("all_done", "every raw record ends enriched or on the dead-letter topic with a cause; undecodable bytes are never committed silently", ["RBD-4"]),
                 A("done_with_cause", "a numeric precise_total_amount_cents is either accepted or dead-lettered with a cause", ["RBD-4"], tx="u_ptac_number"),
             ])

    def fault_prefix(table, tx, code="api_calls", **kw):
        return [{"produce": [ev("warm", "count_calls")]}, Q,
                {"db_fault": {"table": table, "times": 1}},
                {"produce": [ev(tx, code, properties={"amount": 1}, **kw)]},
                {"wait_db_fault_fired": table}]

    scenario("EPC-10-retry-lost-db-fault",
             "Transient database error on the subscription lookup of one record; two good records follow in a later batch.",
             ["EP-B2", "EP-B3", "EP-B4", "EP-L1", "EP-P3", "EP-P4", "EP-R2", "EP-R4"], ["RBD-1"],
             fault_prefix("subscriptions", "f_retry") + [Q, {"produce": [ev("n1", "count_calls"), ev("n2", "count_calls")]}, Q],
             asserts=[
                 A("all_done", "a transient failure is retried (in place or through a retry topic) or dead-lettered with a cause, never committed past", ["RBD-1"]),
                 A("enriched", "a one-shot transient fault must not lose the event", ["RBD-1"], tx="f_retry"),
             ], db_fault_tables=["subscriptions"])

    scenario("EPC-11-retry-only-batch-restart",
             "Control: same database fault, nothing follows; a graceful restart re-reads from the last commit.",
             ["EP-B4", "EP-M1"], ["RBD-2", "RBD-1"],
             fault_prefix("subscriptions", "f_retry") + [Q, {"restart": "TERM"}, Q],
             asserts=[
                 A("all_done", "the record ends with an output after the restart", ["RBD-1", "RBD-2"]),
                 A("no_dup", "no duplicate output for a record that was never produced before the restart", ["RBD-1", "RBD-2"]),
             ], db_fault_tables=["subscriptions"])

    scenario("EPC-12-retry-stale-13h", "Same database fault, ingested_at 13 h ago: past the retry horizon.",
             ["EP-L1", "EP-D5"], ["RBD-3"],
             fault_prefix("subscriptions", "f_stale", ingested_at="$INGESTED_13H_AGO") + [Q],
             asserts=[
                 A("all_done", "a record past the retry horizon is dispositioned", ["RBD-3"]),
                 A("done_with_cause", "enriched after an in-place retry, or dead-lettered with a cause", ["RBD-3"], tx="f_stale"),
             ], db_fault_tables=["subscriptions"])

    scenario("EPC-13-retry-no-ingested-at", "Same database fault, no ingested_at: counts as older than the horizon.",
             ["EP-L1", "EP-D5"], ["RBD-3"],
             fault_prefix("subscriptions", "f_noing", ingested_at="$ABSENT") + [Q],
             asserts=[
                 A("all_done", "a record without ingested_at is dispositioned", ["RBD-3"]),
                 A("done_with_cause", "enriched after an in-place retry, or dead-lettered with a cause (age rule for a missing ingested_at: KQ-4)", ["RBD-3"], tx="f_noing"),
             ], db_fault_tables=["subscriptions"])

    scenario("EPC-14-retry-11h-pending",
             "Same database fault, ingested 11 h ago, nothing follows, no restart: the record stays uncommitted.",
             ["EP-B4", "EP-L1"], ["RBD-1", "RBD-3"],
             fault_prefix("subscriptions", "f_pending", ingested_at="$INGESTED_11H_AGO") + [Q],
             asserts=[
                 A("all_done", "a transient failure inside the horizon is retried while the process runs, not parked until a restart", ["RBD-1"]),
                 A("enriched", "a one-shot transient fault must not keep the event pending", ["RBD-1"], tx="f_pending"),
             ], db_fault_tables=["subscriptions"])

    scenario("EPC-15-bm-db-fault",
             "Transient database error on the billable-metric lookup (not a not-found): retryable; a later batch commits past it.",
             ["EP-E2", "EP-B3", "EP-B4"], ["RBD-1"],
             [{"produce": [ev("warm", "count_calls")]}, Q,
              {"db_fault": {"table": "billable_metrics", "times": 1}},
              {"produce": [ev("f_bm", "api_calls", properties={"amount": 1})]},
              {"wait_db_fault_fired": "billable_metrics"}, Q,
              {"produce": [ev("n1", "count_calls")]}, Q],
             asserts=[A("all_done", "a transient metric-lookup failure must not be lost", ["RBD-1"])],
             db_fault_tables=["billable_metrics"])

    scenario("EPC-16-charges-db-fault",
             "Transient database error on the pay-in-advance charge lookup after the enriched record was produced; a later batch commits.",
             ["EP-J3", "EP-B4"], ["RBD-8"],
             [{"produce": [ev("warm", "count_calls", external_subscription_id="sub_ext_multi")]}, Q,
              {"db_fault": {"table": "charges", "times": 1}},
              {"produce": [ev("f_charge", "api_calls", properties={"amount": 1})]},
              {"wait_db_fault_fired": "charges"}, Q,
              {"produce": [ev("n1", "count_calls", external_subscription_id="sub_ext_multi")]}, Q],
             asserts=[
                 A("in_advance", "the charge is pay-in-advance; a transient fault must not drop the in-advance record", ["RBD-8"], tx="f_charge"),
                 A("zset_has", "the refresh flag of f_charge must not be dropped", ["RBD-8"], want=O1 + ":" + SUB(1)),
             ], db_fault_tables=["charges"])

    scenario("EPC-17-redis-fault", "Redis error while the refresh flag is written; a later batch commits.",
             ["EP-L5", "EP-J3"], ["RBD-9"],
             [{"produce": [ev("warm", "count_calls", external_subscription_id="sub_ext_multi")]}, Q,
              {"redis_error": "ERR epconf injected redis failure"},
              {"produce": [ev("f_redis", "api_calls", properties={"amount": 1})]}, Q,
              {"redis_error": ""},
              {"produce": [ev("n1", "count_calls", external_subscription_id="sub_ext_multi")]}, Q],
             asserts=[
                 A("zset_has", "the refresh flag of f_redis is retried, not skipped", ["RBD-9"], want=O1 + ":" + SUB(1)),
                 A("no_dup", "only the failed side effect is retried (no duplicate enriched or in-advance record)", ["RBD-9"]),
             ])

    scenario("EPC-18-produce-reject-enriched", "The broker rejects produce to the enriched topic for one record.",
             ["EP-L2", "EP-A7", "EP-R5", "EP-R6"], ["RBD-6"],
             [{"kafka_reject_produce": ["events_enriched"]},
              {"produce": [ev("f_enr", "api_calls", properties={"amount": 1})]}, Q,
              {"kafka_reject_produce": []},
              {"produce": [ev("n1", "count_calls")]}, Q],
             asserts=[
                 A("on_dlq", "a record-specific broker rejection is PERMANENT: dead-letter with a non-empty cause", ["RBD-6"], tx="f_enr"),
                 A("not_in_advance", "the in-advance record is produced only after the enriched produce succeeded", ["RBD-6"], tx="f_enr"),
             ])

    scenario("EPC-19-produce-reject-dlq", "Unknown code (dead-letter bound) while the broker rejects produce to the dead-letter topic.",
             ["EP-L4", "EP-A7", "EP-R1", "EP-R3"], ["RBD-5"],
             [{"kafka_reject_produce": ["events_dead_letter"]},
              {"produce": [ev("f_dlq", "nope")]}, Q,
              {"kafka_reject_produce": []},
              {"produce": [ev("n1", "count_calls")]}, Q],
             asserts=[A("all_done", "a failed dead-letter produce is SYSTEMIC: never commit a record that reached no topic", ["RBD-5"])])

    scenario("EPC-20-produce-reject-in-advance", "The broker rejects produce to the charged-in-advance topic for one record.",
             ["EP-L3", "EP-A7", "EP-P7"], ["RBD-7"],
             [{"kafka_reject_produce": ["events_charged_in_advance"]},
              {"produce": [ev("f_adv", "api_calls", properties={"amount": 1})]}, Q,
              {"kafka_reject_produce": []},
              {"produce": [ev("n1", "count_calls")]}, Q],
             asserts=[
                 A("not_on_dlq", "never dead-letter a record whose enriched output exists (proposal)", ["RBD-7"], ruling="proposed", tx="f_adv"),
                 A("in_advance", "the in-advance record is eventually produced (retry in place, then pause; proposal)", ["RBD-7"], ruling="proposed", tx="f_adv"),
             ])

    scenario("EPC-21-restart-graceful",
             "200 records, SIGTERM while they are consumed, restart: the in-flight batch finishes and commits; nothing lost. "
             "Database pool capped at 20 so the server connection limit is not the variable under test (see EPC-30).",
             ["EP-M1", "EP-A6", "EP-B1", "EP-N5"], ["RBD-12"],
             [{"produce": [ev("g%03d" % i, "count_calls", external_subscription_id="no_such_sub") for i in range(200)]},
              {"restart": "TERM"}, Q],
             asserts=[
                 A("all_done", "a graceful restart loses nothing", ["RBD-12"]),
                 A("no_dup", "a graceful restart duplicates nothing", ["RBD-12"]),
             ], env={"LAGO_EVENTS_PROCESSOR_DATABASE_MAX_CONNECTIONS": "20"})

    scenario("EPC-22-multi-partition",
             "Three raw partitions; per-partition commit; a dead-letter-bound record in partition 1 does not block it.",
             ["EP-B5", "EP-B6"], [],
             [{"produce": [dict(ev("mp%d_%d" % (p, i), "count_calls" if not (p == 1 and i == 1) else "nope"), partition=p) for p in range(3) for i in range(3)]}, Q],
             partitions=3)

    scenario("EPC-23-org-scoping", "Same code and external_subscription_id in two organizations.",
             ["EP-I1", "EP-I5", "EP-A7"], [],
             [{"produce": [
                 ev("org1_tx", "api_calls", properties={"amount": 1}),
                 ev("org2_tx", "api_calls", organization_id=O2, properties={"amount": 1}),
                 ev("same_tx", "api_calls", properties={"amount": 2}),
                 ev("same_tx", "api_calls", organization_id=O2, properties={"amount": 2}),
             ]}, Q])

    scenario("EPC-24-refresh-zset",
             "Refresh-flag members: one per (organization, subscription) per 10 s bucket; none without subscription, "
             "when post-processed by the API, or for a dead-lettered event.",
             ["EP-K1", "EP-K2", "EP-J1", "EP-W5"], [],
             [{"produce": [
                 ev("z1", "count_calls"), ev("z2", "count_calls"), ev("z3", "api_calls", properties={"amount": 1}),
                 ev("z_multi", "count_calls", external_subscription_id="sub_ext_multi"),
                 ev("z_nosub", "count_calls", external_subscription_id="no_such_sub"),
                 ev("z_pp", "count_calls", external_subscription_id="sub_ext_late", source="http_ruby", source_metadata={"api_post_processed": True}),
                 ev("z_o2", "api_calls", organization_id=O2),
                 ev("z_dlq", "nope", external_subscription_id="sub_ext_incomplete"),
             ]}, Q])

    scenario("EPC-25-duplicate-transaction",
             "The same raw record produced twice: the processor does not deduplicate (downstream does).",
             ["EP-I4", "EP-R7"], ["RBD-11"],
             [{"produce": [ev("dup", "api_calls", properties={"amount": 1}), ev("dup", "api_calls", properties={"amount": 1})]}, Q])

    st = [A("startup_exit", "a broken configuration or an unreachable dependency stops the process with a non-zero status before it joins the group", ["RBD-23"])]
    scenario("EPC-26-startup-missing-topic-env",
             "Startup contract: empty enriched-topic variable -> the process exits non-zero before joining the group.",
             ["EP-A1", "EP-A2", "EP-A3", "EP-A4", "EP-P2"], ["RBD-23"], [], asserts=st, env={"LAGO_KAFKA_ENRICHED_EVENTS_TOPIC": ""}, expect_no_ready=True)
    scenario("EPC-27-startup-redis-unreachable", "Startup contract: Redis unreachable -> exit before joining.",
             ["EP-A1", "EP-A2", "EP-A3", "EP-A4", "EP-P2"], ["RBD-23"], [], asserts=st, env={"LAGO_REDIS_STORE_URL": "127.0.0.1:1"}, expect_no_ready=True)
    scenario("EPC-28-startup-db-unreachable", "Startup contract: Postgres unreachable -> exit before joining.",
             ["EP-A1", "EP-A2", "EP-A3", "EP-A4", "EP-P2"], ["RBD-23"], [], asserts=st,
             env={"DATABASE_URL": "postgres://lago:lago@127.0.0.1:1/none?connect_timeout=2"}, expect_no_ready=True)
    scenario("EPC-29-startup-no-brokers", "Startup contract: empty bootstrap servers -> exit before joining.",
             ["EP-A1", "EP-A2", "EP-A3", "EP-A4", "EP-P2"], ["RBD-23"], [], asserts=st, env={"LAGO_KAFKA_BOOTSTRAP_SERVERS": ""}, expect_no_ready=True)

    scenario("EPC-30-db-connection-burst",
             "200 records in one poll while the database admits at most 30 connections for the implementation's role and its pool "
             "allows 200 (reference default): connection errors become retryable failures. Timing-dependent: assertions only.",
             ["EP-L6", "EP-R3"], ["RBD-10"],
             [{"produce": [ev("b%03d" % i, "count_calls", external_subscription_id="no_such_sub") for i in range(200)]}, Q,
              {"produce": [ev("b_tail", "count_calls", external_subscription_id="no_such_sub")]}, Q],
             asserts=[
                 A("all_done", "pool exhaustion is back-pressure (SYSTEMIC pause), never silent loss", ["RBD-10"]),
                 A("no_dup", "no redelivery is needed without a restart", ["RBD-10"]),
             ], db_connection_limit=30, no_golden=True)

    CH1 = "cccccccc-0000-0000-0000-000000000001"
    BM1 = "aaaaaaaa-0000-0000-0000-000000000001"
    scenario("EPC-31-cdc-charge-update-column-gap",
             "Memory-cache mode: a charge update arrives through CDC shaped by the reference deployment's CDC column list "
             "(no pay_in_advance column). The cached charge is replaced whole, so pay_in_advance reads false.",
             ["EP-N3", "EP-N4", "EP-A8", "EP-W6"], ["RBD-21"],
             [{"produce": [ev("before_cdc", "api_calls", properties={"amount": 1})]}, Q,
              {"cdc": {"table": "charges", "row": {"id": CH1, "organization_id": O1, "plan_id": PLAN1, "billable_metric_id": BM1,
                                                   "created_at": "$NOW_US", "updated_at": "$NOW_US", "deleted_at": None, "properties": "{}",
                                                   "__deleted": "false", "__table": "charges", "__lsn": 1}}},
              {"wait_cdc_applied": "charges"},
              {"produce": [ev("after_cdc", "api_calls", properties={"amount": 1})]}, Q],
             asserts=[A("in_advance", "a charge edit must not switch pay-in-advance off (a missing CDC column never resets a value; proposal pending the production column list)", ["RBD-21"], ruling="proposed", tx="after_cdc")])
    scenario("EPC-32-cdc-new-metric", "Memory-cache mode: a billable metric created after start becomes visible through CDC.",
             ["EP-N3", "EP-N1", "EP-A8"], [],
             [{"produce": [ev("before_create", "fresh_metric")]}, Q,
              {"cdc": {"table": "billable_metrics", "row": {"id": "aaaaaaaa-0000-0000-0000-0000000000a1", "organization_id": O1, "code": "fresh_metric",
                                                            "aggregation_type": 0, "field_name": None, "expression": None, "created_at": "$NOW_US",
                                                            "updated_at": "$NOW_US", "deleted_at": None, "__deleted": "false",
                                                            "__table": "billable_metrics", "__lsn": 2}}},
              {"wait_cdc_applied": "billable_metrics"},
              {"produce": [ev("after_create", "fresh_metric")]}, Q])
    scenario("EPC-33-cdc-delete-metric",
             "Memory-cache mode: soft-deleting a billable metric through CDC (deleted_at set, same id) removes it from the cache.",
             ["EP-N6"], [],
             [{"produce": [ev("before_delete", "count_calls")]}, Q,
              {"cdc": {"table": "billable_metrics", "row": {"id": "aaaaaaaa-0000-0000-0000-000000000002", "organization_id": O1, "code": "count_calls",
                                                            "aggregation_type": 0, "field_name": None, "expression": None, "created_at": "$NOW_US",
                                                            "updated_at": "$NOW_US", "deleted_at": "$NOW_US", "__deleted": "false",
                                                            "__table": "billable_metrics", "__lsn": 3}}},
              {"wait_cdc_applied": "billable_metrics"},
              {"produce": [ev("after_delete", "count_calls")]}, Q])
    scenario("EPC-34-cdc-terminate-subscription", "Memory-cache mode: terminating a subscription through CDC.",
             ["EP-N6", "EP-H1"], [],
             [{"produce": [ev("before_term", "count_calls", timestamp="1751328000")]}, Q,
              {"cdc": {"table": "subscriptions", "row": {"id": SUB(1), "organization_id": O1, "external_id": "sub_ext_1",
                                                         "plan_id": PLAN1, "created_at": "$NOW_US", "updated_at": "$NOW_US",
                                                         "started_at": 1735689600000500, "terminated_at": 1748736000000000,
                                                         "__deleted": "false", "__table": "subscriptions", "__lsn": 4}}},
              {"wait_cdc_applied": "subscriptions"},
              {"produce": [ev("after_term", "count_calls", timestamp="1751328000"), ev("inside_window", "count_calls", timestamp="1740000000")]}, Q])


def write_all(conf):
    sdir = os.path.join(conf, "scenarios")
    adir = os.path.join(conf, "golden", "corrected")
    os.makedirs(sdir, exist_ok=True)
    os.makedirs(adir, exist_ok=True)
    for name, sc in SCEN:
        with open(os.path.join(sdir, name + ".json"), "w") as f:
            f.write(render(sc))
    for name, items in ASSERTS:
        with open(os.path.join(adir, name + ".assert.json"), "w") as f:
            f.write("[\n" + ",\n".join(" " + json.dumps(a, ensure_ascii=False) for a in items) + "\n]\n")


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--out")
    ap.add_argument("--write", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--check-corpus")
    a = ap.parse_args()
    if a.check_corpus:
        mine = read_corpus(CORPUS)
        other = read_corpus(a.check_corpus)
        if mine != other:
            d = difflib.unified_diff(["\t".join(r) for r in other], ["\t".join(r) for r in mine], "other", "kit", lineterm="")
            print("\n".join(d))
            print("corpus-sync: DRIFT rows_kit=%d rows_other=%d" % (len(mine), len(other)))
            return 1
        print("corpus-sync: OK rows=%d" % len(mine))
        return 0
    build()
    if a.out and a.write:
        print("gen-scenarios: --out and --write are exclusive", file=sys.stderr)
        return 2
    if not a.out and not a.write:
        tmp = tempfile.mkdtemp(prefix="epconf-gen-")
        write_all(tmp)
        bad = 0
        for sub in ("scenarios", os.path.join("golden", "corrected")):
            dc = filecmp.dircmp(os.path.join(tmp, sub), os.path.join(CONF, sub))
            for f in dc.diff_files + dc.left_only:
                print("drift: %s/%s" % (sub, f))
                bad += 1
            for f in dc.right_only:
                if f.endswith(".json"):
                    print("extra shipped file: %s/%s" % (sub, f))
                    bad += 1
        print("gen-scenarios --check: scenarios=%d assert_files=%d drift=%d" % (len(SCEN), len(ASSERTS), bad))
        return 1 if bad else 0
    out = a.out if a.out else CONF
    write_all(out)
    print("gen-scenarios: scenarios=%d assert_files=%d out=%s" % (len(SCEN), len(ASSERTS), out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
