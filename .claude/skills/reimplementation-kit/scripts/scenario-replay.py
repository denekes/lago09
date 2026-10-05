#!/usr/bin/env python3
"""scenario-replay.py — replay the kit's end-to-end scenarios (scn.*.json) against an implementation.

Usage:
  scenario-replay.py (--impl-cmd CMD | --http BASE_URL) [--kit-root DIR] [--scenarios FILE ...] [--only REGEX]
                     [--profile compat|corrected] [--include-holdout DIR] [--timeout S] [--hello-timeout S]
                     [--report out.json] [--show-diff N] [--quiet] [--require-all] [--thresholds FILE]
                     [--kit-prefix PATH] [--mutate] [--mutate-steps] [--dump DIR]

  --impl-cmd   CMD speaks the adapter protocol v1 (reference/adapter-protocol.md) and answers the stateful ops
               system.reset / set_clock / api / tick / snapshot. One process serves all scenarios in sequence
               (each scenario starts with system.reset); it is restarted after a crash or timeout.
  --http       BASE_URL of a running test build exposing the REST API v1 plus the kit's test-only endpoints
               (default prefix /__kit, --kit-prefix to change): POST reset -> {"api_key"}, POST clock {"now"},
               POST tick {"jobs"}, GET snapshot. REST calls carry "Authorization: Bearer <api_key>".
  Default scenario set: every <kit-root>/<skill>/scenarios/scn.*.json (kit-root = the directory holding
  reimplementation-kit/). --scenarios replaces discovery with explicit files.
  --require-all  exit 3 unless every graded scenario passes (maintainers; the default verdict uses the "scn"
                 threshold of acceptance/thresholds.json).
  --mutate       self-check for maintainers: add 1 to the first integer of each scenario's final expectation
                 (or, when it has none, of the first step expectation that has one) before replaying; every
                 scenario must then FAIL.
  --mutate-steps self-check for maintainers: change every intermediate snapshot step's expectation instead (its
               first integer +1, or one extra element in its first list when it has no integer); scenarios without a
               snapshot step are not selected; every selected scenario must then FAIL.
  --dump DIR     write <id>.replay.json per scenario (every call with its step index and purpose
               setup/bind/step/final, every response, the final snapshot); maintainers fill authored scenarios
               from it (convert-scenarios.py --fill).

Replay semantics (normative text: reference/scenario-tier.md):
  reset(setup.organization, setup.billing_entity, premium, store) -> set_clock(setup.at) -> create setup objects
  over REST in the order taxes, billable_metrics, add_ons, coupons, plans, customers (each must answer 200) ->
  steps in order (set_clock when a step's "at" differs; resolve "bind" against a snapshot; substitute {{var}};
  api / tick / snapshot; check the step "expect"; apply "capture") -> final snapshot compared with "expect".

Output: one line per scenario (PASS|FAIL|ERROR|SKIP|UNRULED <id>), up to --show-diff diff lines under each
non-pass, an area table, then
  SUMMARY scenario-replay: scenarios=N passed=N failed=N errors=N skipped=N unruled=N exit=N

Exit codes: 0 the scn threshold is met and every core scenario passed (with --require-all: every graded scenario
passed); 3 below threshold / a core scenario did not pass; 2 setup or protocol error (adapter did not start, too
many restarts, HTTP endpoint unreachable); 4 scenario files invalid (unparsable, bad id); 1 usage error.

Standard library only; Python >= 3.10.
"""
from __future__ import annotations

import argparse
import copy
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import kitlib  # noqa: E402
import kitrun  # noqa: E402  (Adapter process handling is shared with the unit-vector runner)

VERSION = "1.1.0"
SETUP_ORDER = [("taxes", "tax", "/api/v1/taxes", "code"),
               ("billable_metrics", "billable_metric", "/api/v1/billable_metrics", "code"),
               ("add_ons", "add_on", "/api/v1/add_ons", "code"),
               ("coupons", "coupon", "/api/v1/coupons", "code"),
               ("plans", "plan", "/api/v1/plans", "code"),
               ("customers", "customer", "/api/v1/customers", "external_id")]
VAR_PREFIX = {"taxes": "tax", "billable_metrics": "bm", "add_ons": "add_on", "coupons": "coupon", "plans": "plan",
              "customers": "customer"}
RE_VAR = re.compile(r"\{\{([A-Za-z0-9_:.\-]+)\}\}")
REQUIRED = ["kit_schema", "id", "area", "title", "profile", "evidence", "setup", "steps", "expect"]


class ScenarioError(Exception):
    """The implementation misbehaved at protocol level (ERROR), not a value mismatch."""


class SetupFailed(Exception):
    """A setup create call or a precondition (bind) failed: the scenario FAILS before its steps are graded."""


# ---------------------------------------------------------------------------------------------------------------
# Transports
# ---------------------------------------------------------------------------------------------------------------
class AdapterTransport:
    def __init__(self, cmd, profile, timeout, hello_timeout, max_restarts=5):
        self.cmd, self.profile, self.timeout = cmd, profile, timeout
        self.hello_timeout, self.max_restarts = hello_timeout, max_restarts
        self.adapter = None
        self.restarts = 0
        self.seq = 0
        self.hello = None

    def _hello_msg(self):
        return {"type": "hello", "role": "runner", "proto": kitlib.PROTO, "kit_version": "scenario-replay",
                "kit_schema": kitlib.KIT_SCHEMA, "profiles": [self.profile], "areas": ["system"]}

    def ensure(self):
        if self.adapter is not None:
            return
        a = kitrun.Adapter(self.cmd, self._hello_msg(), self.hello_timeout)
        try:
            msg = a.start()
        except kitrun.SetupError:
            a.kill()
            raise
        profiles = msg.get("profiles") or []
        if self.profile not in profiles:
            a.kill()
            raise kitrun.SetupError(f"adapter does not declare profile {self.profile} (hello.profiles={profiles})")
        ops = msg.get("ops") or []
        missing = [o for o in ("system.reset", "system.set_clock", "system.api", "system.tick", "system.snapshot")
                   if not kitlib.op_supported(o, ops)]
        if missing:
            a.kill()
            raise kitrun.SetupError(f"adapter does not declare {', '.join(missing)}")
        self.adapter, self.hello = a, msg

    def restart(self):
        if self.adapter is not None:
            self.adapter.kill()
            self.adapter = None
        self.restarts += 1
        if self.restarts > self.max_restarts:
            raise kitrun.SetupError(f"more than {self.max_restarts} adapter restarts")

    def stderr_tail(self):
        return self.adapter.stderr_text()[-1500:] if self.adapter else ""

    def call(self, op, inp):
        self.ensure()
        self.seq += 1
        cid = f"scn-{self.seq}#1"
        text = kitlib.dumps_lit({"type": "call", "id": cid, "area": "system", "op": op, "profile": self.profile,
                                 "input": inp})
        kind, payload = self.adapter.call(text, cid, self.timeout)
        if kind != "result":
            tail = self.stderr_tail()
            self.restart()
            raise ScenarioError(f"system.{op}: adapter {kind}" + (f" ({payload})" if payload else "") +
                                (f"\n      stderr: {tail.strip()[-600:]}" if tail.strip() else ""))
        err = payload.get("error")
        if err is not None:
            raise ScenarioError(f"system.{op}: adapter error {err.get('code')}: {err.get('message', '')}".rstrip(": "))
        out = payload.get("output")
        if not isinstance(out, dict):
            raise ScenarioError(f"system.{op}: result without an output object")
        return out

    def close(self):
        if self.adapter is not None:
            self.adapter.close()
            self.adapter = None


class HttpTransport:
    def __init__(self, base, prefix, timeout):
        self.base = base.rstrip("/")
        self.prefix = "/" + prefix.strip("/")
        self.timeout = timeout
        self.api_key = None
        self.hello = {"impl": f"http {self.base}", "impl_version": "-"}

    def _req(self, method, path, body=None, query=None, auth=True):
        url = self.base + path
        if query:
            url += "?" + urllib.parse.urlencode({k: kitlib.dumps_lit(v) if isinstance(v, kitlib.Lit) else
                                                 (str(v).lower() if isinstance(v, bool) else v)
                                                 for k, v in query.items()})
        data = None if body is None else kitlib.dumps_lit(body).encode("utf-8")
        headers = {"Accept": "application/json"}
        if data is not None:
            headers["Content-Type"] = "application/json"
        if auth and self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        req = urllib.request.Request(url, data=data, method=method, headers=headers)
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                status, text = r.status, r.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            status, text = e.code, e.read().decode("utf-8", "replace")
        except (urllib.error.URLError, OSError) as e:
            raise kitrun.SetupError(f"HTTP {method} {url}: {e}")
        if not text.strip():
            return status, None
        try:
            return status, kitlib.loads_lit(text)
        except ValueError:
            return status, text

    def call(self, op, inp):
        if op == "api":
            st, body = self._req(inp["method"], inp["path"], inp.get("body"), inp.get("query"))
            return {"status": kitlib.Lit(str(st), True), "body": body}
        path = {"reset": "/reset", "set_clock": "/clock", "tick": "/tick", "snapshot": "/snapshot"}[op]
        method = "GET" if op == "snapshot" else "POST"
        st, body = self._req(method, self.prefix + path, None if op == "snapshot" else inp, auth=op != "reset")
        if st >= 300:
            raise ScenarioError(f"{method} {self.prefix}{path} answered {st}: {str(body)[:300]}")
        if op == "reset":
            if not isinstance(body, dict) or not isinstance(body.get("api_key"), str):
                raise ScenarioError("reset must answer {\"api_key\": \"...\"}")
            self.api_key = body["api_key"]
            return {}
        return body if isinstance(body, dict) else {}

    def stderr_tail(self):
        return ""

    def close(self):
        pass


# ---------------------------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------------------------
def lit_to_int(v):
    if isinstance(v, kitlib.Lit) and v.is_int:
        return int(v.text)
    if isinstance(v, int) and not isinstance(v, bool):
        return v
    return None


def subst(obj, env, where):
    """Replace {{var}} placeholders; a string that is exactly one placeholder takes the variable's JSON value."""
    if isinstance(obj, str):
        m = RE_VAR.fullmatch(obj)
        if m:
            if m.group(1) not in env:
                raise SetupFailed(f"{where}: unknown variable {{{{{m.group(1)}}}}}")
            return env[m.group(1)]

        def rep(mm):
            if mm.group(1) not in env:
                raise SetupFailed(f"{where}: unknown variable {{{{{mm.group(1)}}}}}")
            v = env[mm.group(1)]
            return kitlib.dumps_lit(v) if not isinstance(v, str) else v
        return RE_VAR.sub(rep, obj)
    if isinstance(obj, dict):
        return {k: subst(v, env, where) for k, v in obj.items()}
    if isinstance(obj, list):
        return [subst(v, env, where) for v in obj]
    return obj


def get_path(obj, path):
    """Dotted keys and [n] indices; returns (found, value)."""
    node = obj
    for tok in re.findall(r"[^.\[\]]+|\[[0-9]+\]", path):
        if tok.startswith("["):
            i = int(tok[1:-1])
            if not isinstance(node, list) or i >= len(node):
                return False, None
            node = node[i]
        else:
            if not isinstance(node, dict) or tok not in node:
                return False, None
            node = node[tok]
    return True, node


def select_from(snapshot, src):
    if src.endswith("[*].fees") or src.endswith("[*].items"):
        outer, _, inner = src.partition("[*].")
        out = []
        for o in snapshot.get(outer) or []:
            out.extend((o or {}).get(inner) or [])
        return out
    return list(snapshot.get(src) or [])


def set_hints(expected, actual, compare, path=""):
    """For lists compared as sets: name the closest actual element of every unmatched expected element and its
    first differences (the plain set diff only says that nothing matched)."""
    hints = []
    if isinstance(expected, dict) and isinstance(actual, dict):
        for k, v in expected.items():
            hints += set_hints(v, actual.get(k), compare, f"{path}.{k}" if path else k)
        return hints
    if not (isinstance(expected, list) and isinstance(actual, list)):
        return hints
    pat = re.sub(r"\[[0-9]+\]", "[*]", path)
    if (compare.get(pat) or {}).get("mode") != "set":
        for i, (e, a) in enumerate(zip(expected, actual)):
            hints += set_hints(e, a, compare, f"{path}[{i}]")
        return hints
    base = pat + "[*]"
    sub = {k[len(base) + 1:]: v for k, v in compare.items() if k.startswith(base + ".")}
    for i, e in enumerate(expected):
        scored = sorted((len(kitlib.Comparator(sub, False).run(e, a)), j) for j, a in enumerate(actual))
        if not scored or scored[0][0] == 0:
            continue
        n, j = scored[0]
        ds = kitlib.Comparator(sub, False).run(e, actual[j])
        hints.append(f"{path}[{i}] (expected) closest actual {path}[{j}], {n} difference(s): " + "; ".join(ds[:3]))
        hints += [f"{path}[{i}].{h}" for h in set_hints(e, actual[j], sub, "")]
    return hints


def first_int_path(obj, path=""):
    """Path of the first JSON integer (not a boolean) in document order, or None."""
    if isinstance(obj, kitlib.Lit) and obj.is_int:
        return path
    if isinstance(obj, dict):
        for k, v in obj.items():
            p = first_int_path(v, f"{path}.{k}" if path else k)
            if p is not None:
                return p
    if isinstance(obj, list):
        for i, v in enumerate(obj):
            p = first_int_path(v, f"{path}[{i}]")
            if p is not None:
                return p
    return None


def bump(obj, path):
    """Add 1 to the integer at path (in place)."""
    toks = re.findall(r"[^.\[\]]+|\[[0-9]+\]", path)
    node = obj
    for t in toks[:-1]:
        node = node[int(t[1:-1])] if t.startswith("[") else node[t]
    last = toks[-1]
    key = int(last[1:-1]) if last.startswith("[") else last
    node[key] = kitlib.Lit(str(int(node[key].text) + 1), True)


def load_scenarios(files):
    out, bad = [], []
    for f in files:
        try:
            with open(f, encoding="utf-8") as fh:
                doc = kitlib.loads_lit(fh.read())
        except (OSError, ValueError) as e:
            bad.append(f"{f}: {e}")
            continue
        missing = [k for k in REQUIRED if k not in doc] if isinstance(doc, dict) else REQUIRED
        sid = doc.get("id") if isinstance(doc, dict) else None
        if missing or not isinstance(sid, str) or not kitlib.RE_SCENARIO_ID.match(sid):
            bad.append(f"{f}: missing {missing} or bad id {sid!r}")
            continue
        out.append((f, doc))
    return out, bad


# ---------------------------------------------------------------------------------------------------------------
# One scenario
# ---------------------------------------------------------------------------------------------------------------
class Replay:
    def __init__(self, transport, doc, show_diff, dump):
        self.t = transport
        self.doc = doc
        self.env = {}
        self.diffs = []
        self.warnings = []
        self.clock = None
        self.log = [] if dump else None
        self.show_diff = show_diff
        self.where = ("setup", None)   # (why, step index) recorded with each dumped call

    def call(self, op, inp):
        out = self.t.call(op, inp)
        if self.log is not None:
            why, step = self.where
            self.log.append({"op": op, "why": why, "step": step, "input": inp, "output": out})
        return out

    def set_clock(self, at):
        if at is not None and at != self.clock:
            self.call("set_clock", {"now": at})
            self.clock = at

    def check(self, label, expected, actual, compare):
        cmp = kitlib.Comparator(compare or {}, False)
        diffs = cmp.run(expected, actual)
        for d in diffs:
            self.diffs.append(f"{label}.{d}" if not d.startswith("$") else f"{label}{d[1:]}")
        self.warnings.extend(f"{label}: {w}" for w in cmp.warnings)
        if any("(set)" in d for d in diffs):
            self.diffs.extend(f"{label}.{h}" for h in set_hints(expected, actual, compare or {}))

    def api(self, method, path, body=None, query=None):
        inp = {"method": method, "path": path}
        if query:
            inp["query"] = query
        if body is not None:
            inp["body"] = body
        out = self.call("api", inp)
        st = lit_to_int(out.get("status"))
        if st is None:
            raise ScenarioError(f"system.api {method} {path}: output has no integer status")
        return st, out.get("body")

    def run(self):
        s = self.doc["setup"]
        reset_in = {"organization": s.get("organization") or {}, "premium": bool(s.get("premium")),
                    "store": s.get("store", "pg")}
        if s.get("billing_entity"):
            reset_in["billing_entity"] = s["billing_entity"]
        self.call("reset", reset_in)
        self.set_clock(s["at"])
        for key, root, path, ident in SETUP_ORDER:
            for i, obj in enumerate(s.get(key) or []):
                body = subst(obj, self.env, f"setup.{key}[{i}]")
                st, resp = self.api("POST", path, {root: body})
                if st != 200:
                    raise SetupFailed(f"setup.{key}[{i}]: POST {path} answered {st}: "
                                      f"{kitlib.dumps_lit(resp)[:300] if resp is not None else ''}")
                self.capture_setup(key, root, ident, body, resp)
        for i, step in enumerate(self.doc["steps"]):
            self.step(i, step)
        self.where = ("final", None)
        snap = self.call("snapshot", {})
        if self.log is not None:
            self.final = snap
        self.check("expect", self.doc["expect"], snap, self.doc.get("compare"))

    def capture_setup(self, key, root, ident, body, resp):
        obj = (resp or {}).get(root) if isinstance(resp, dict) else None
        if not isinstance(obj, dict):
            return
        k = obj.get(ident, body.get(ident))
        if isinstance(k, str) and "lago_id" in obj:
            self.env[f"{VAR_PREFIX[key]}:{k}"] = obj["lago_id"]
        if key == "plans" and isinstance(k, str):
            for c in obj.get("charges") or []:
                if isinstance(c, dict) and isinstance(c.get("code"), str):
                    self.env[f"charge:{k}:{c['code']}"] = c.get("lago_id")
            for c in obj.get("fixed_charges") or []:
                if isinstance(c, dict) and isinstance(c.get("code"), str):
                    self.env[f"fixed_charge:{k}:{c['code']}"] = c.get("lago_id")

    def resolve_binds(self, i, binds):
        snap = self.call("snapshot", {})
        for var, b in binds.items():
            cands = select_from(snap, b["from"])
            where = subst(b["where"], self.env, f"steps[{i}].bind.{var}")
            hits = [c for c in cands if not kitlib.Comparator({}, False).run(where, c)]
            idx = lit_to_int(b.get("index"))
            if idx is None and len(hits) != 1:
                raise SetupFailed(f"steps[{i}].bind.{var}: {len(hits)} {b['from']} match {kitlib.dumps_lit(where)}"
                                  " (need exactly 1)")
            if idx is not None and idx >= len(hits):
                raise SetupFailed(f"steps[{i}].bind.{var}: index {idx} but only {len(hits)} match")
            found, val = get_path(hits[idx or 0], b.get("pick", "lago_id"))
            if not found:
                raise SetupFailed(f"steps[{i}].bind.{var}: matched object has no {b.get('pick', 'lago_id')}")
            self.env[var] = val

    def step(self, i, step):
        self.where = ("step", i)
        self.set_clock(step.get("at"))
        if step.get("bind"):
            self.where = ("bind", i)
            self.resolve_binds(i, step["bind"])
            self.where = ("step", i)
        op = step["op"]
        label = f"steps[{i}]"
        if op == "api":
            path = subst(step["path"], self.env, label + ".path")
            query = subst(step.get("query"), self.env, label + ".query") if step.get("query") else None
            body = subst(step["body"], self.env, label + ".body") if "body" in step else None
            st, resp = self.api(step["method"], path, body, query)
            actual = {"status": kitlib.Lit(str(st), True), "body": resp}
            exp = step.get("expect")
            if exp is None:
                if st >= 400:
                    self.diffs.append(f"{label}: {step['method']} {path} answered {st} (no expectation given, 2xx required)")
            else:
                self.check(label, exp, actual, step.get("compare"))
            for var, p in (step.get("capture") or {}).items():
                found, val = get_path(resp, p)
                if not found:
                    raise SetupFailed(f"{label}.capture.{var}: response has no {p}")
                self.env[var] = val
        elif op == "tick":
            self.call("tick", {"jobs": step["jobs"]})
        elif op == "snapshot":
            snap = self.call("snapshot", {})
            self.check(label, step.get("expect") or {}, snap, step.get("compare"))
        else:
            raise SetupFailed(f"{label}: unknown op {op!r}")


# ---------------------------------------------------------------------------------------------------------------
def main(argv=None):
    ap = argparse.ArgumentParser(description="Replay kit scenarios (scn.*.json) against an implementation.",
                                 formatter_class=argparse.RawDescriptionHelpFormatter, epilog=__doc__.split("Replay semantics")[0])
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--impl-cmd")
    g.add_argument("--http")
    ap.add_argument("--kit-root", default=kitlib.skill_root_default(__file__))
    ap.add_argument("--scenarios", nargs="+")
    ap.add_argument("--only")
    ap.add_argument("--profile", choices=["compat", "corrected"], default="compat")
    ap.add_argument("--include-holdout")
    ap.add_argument("--timeout", type=float, default=180.0)
    ap.add_argument("--hello-timeout", type=float, default=60.0)
    ap.add_argument("--max-restarts", type=int, default=5)
    ap.add_argument("--report")
    ap.add_argument("--show-diff", type=int, default=5)
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--require-all", action="store_true")
    ap.add_argument("--thresholds")
    ap.add_argument("--kit-prefix", default="/__kit")
    ap.add_argument("--mutate", action="store_true")
    ap.add_argument("--mutate-steps", action="store_true")
    ap.add_argument("--dump")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 1 if e.code else 0
    try:
        only = re.compile(args.only) if args.only else None
    except re.error as e:
        print(f"usage: invalid --only expression: {e}", file=sys.stderr)
        return 1
    files = args.scenarios or kitlib.discover_scenarios(args.kit_root)
    hold = []
    if args.include_holdout:
        hold = sorted(os.path.join(args.include_holdout, f) for f in os.listdir(args.include_holdout)
                      if f.startswith("scn.") and f.endswith(".json"))
    loaded, bad = load_scenarios(files)
    loaded_h, bad_h = load_scenarios(hold)
    for b in bad + bad_h:
        print(f"INVALID {b}")
    if bad or bad_h:
        print("SUMMARY scenario-replay: scenarios=0 passed=0 failed=0 errors=0 skipped=0 unruled=0 exit=4")
        return 4
    sel = [(f, d, "shipped") for f, d in loaded] + [(f, d, "holdout") for f, d in loaded_h]
    sel = [x for x in sel if not only or only.search(x[1]["id"])]
    sel = [x for x in sel if x[1].get("profile", "both") in ("both", args.profile)]
    if args.mutate_steps:
        sel = [x for x in sel if any(st.get("op") == "snapshot" for st in x[1]["steps"])]
    sel.sort(key=lambda x: x[1]["id"])
    if not sel:
        print("NOTE no scenario selected (check --only / --profile / --scenarios)")
        return 0
    th = kitlib.load_thresholds(args.thresholds or os.path.join(args.kit_root, "reimplementation-kit", "acceptance",
                                                                "thresholds.json"))
    if args.dump:
        os.makedirs(args.dump, exist_ok=True)
    transport = (AdapterTransport(args.impl_cmd, args.profile, args.timeout, args.hello_timeout, args.max_restarts)
                 if args.impl_cmd else HttpTransport(args.http, args.kit_prefix, args.timeout))
    started = kitrun.utc_now()
    try:
        if isinstance(transport, AdapterTransport):
            transport.ensure()
    except kitrun.SetupError as e:
        print(f"SETUP-ERROR {e}")
        print("SUMMARY scenario-replay: scenarios=0 passed=0 failed=0 errors=0 skipped=0 unruled=0 exit=2")
        return 2
    print(f"scenario-replay {VERSION} proto={kitlib.PROTO} profile={args.profile} scenarios={len(sel)}"
          f" impl={transport.hello.get('impl')} {transport.hello.get('impl_version')}")
    records = []
    exit_code = None
    for f, doc, set_name in sel:
        sid = doc["id"]
        unruled = doc.get("profile") == "corrected" and doc.get("ruling") == "proposed"
        if args.mutate:
            doc = copy.deepcopy(doc)
            p = first_int_path(doc["expect"])
            if p is not None:
                bump(doc["expect"], p)
            else:  # no integer in the final expectation: change one in a step expectation (body first, then status)
                for st in doc["steps"]:
                    e = st.get("expect")
                    if isinstance(e, dict):
                        q = first_int_path(e.get("body")) if e.get("body") is not None else None
                        if q is not None:
                            bump(e["body"], q)
                            break
                        if isinstance(e.get("status"), kitlib.Lit):
                            bump(e, "status")
                            break
        if args.mutate_steps:
            doc = copy.deepcopy(doc)
            for st in doc["steps"]:
                if st.get("op") != "snapshot" or not isinstance(st.get("expect"), dict):
                    continue
                q = first_int_path(st["expect"])
                if q is not None:
                    bump(st["expect"], q)
                else:
                    lst = next((v for v in st["expect"].values() if isinstance(v, list)), None)
                    if lst is not None:
                        lst.append({})
        rp = Replay(transport, doc, args.show_diff, args.dump)
        t0 = time.monotonic()
        status, diffs = "PASS", []
        try:
            rp.run()
            diffs = rp.diffs
            status = "FAIL" if diffs else "PASS"
        except SetupFailed as e:
            status, diffs = "FAIL", rp.diffs + [str(e)]
        except ScenarioError as e:
            status, diffs = "ERROR", rp.diffs + [str(e)]
        except kitrun.SetupError as e:
            status, diffs = "ERROR", [str(e)]
            exit_code = 2
        ms = int((time.monotonic() - t0) * 1000)
        shown = "UNRULED" if unruled else status
        rec = {"id": sid, "set": set_name, "status": shown, "ms": ms, "diffs": diffs[:200],
               "warnings": rp.warnings[:50], "tags": doc.get("tags") or []}
        if unruled:
            rec["unruled_outcome"] = status
        records.append(rec)
        if args.dump:
            with open(os.path.join(args.dump, sid + ".replay.json"), "w", encoding="utf-8") as fh:
                fh.write(kitlib.dumps_lit({"id": sid, "status": status, "diffs": diffs, "calls": rp.log,
                                           "final_snapshot": getattr(rp, "final", None)}))
        if not (args.quiet and shown == "PASS"):
            print(f"{shown} {sid}" + (f" [{status}]" if unruled else "") + f" ({ms / 1000:.1f}s)", flush=True)
            if shown != "PASS":
                for d in diffs[: args.show_diff]:
                    print(f"    {d}")
                if len(diffs) > args.show_diff:
                    print(f"    … {len(diffs) - args.show_diff} more")
        if exit_code == 2:
            break
    transport.close()

    def rate_row(set_name):
        rs = [r for r in records if r["set"] == set_name]
        if not rs:
            return None
        n = len(rs)
        c = {k: sum(1 for r in rs if r["status"] == k) for k in ("PASS", "FAIL", "ERROR", "SKIP", "UNRULED")}
        graded = n - c["UNRULED"]
        rate = c["PASS"] / graded if graded else 1.0
        core = [r for r in rs if "core" in r["tags"] and r["status"] != "UNRULED"]
        core_rate = sum(1 for r in core if r["status"] == "PASS") / len(core) if core else 1.0
        thr, _core_thr = kitlib.threshold_for(th, "scn", set_name)
        need = 1.0 if args.require_all else thr
        verdict = "PASS" if rate >= need - 1e-12 and core_rate == 1.0 else ("INFO" if graded == 0 else "FAIL")
        return {"area": "scn", "set": set_name, "total": n, "pass": c["PASS"], "fail": c["FAIL"],
                "error": c["ERROR"], "skip": c["SKIP"], "unruled": c["UNRULED"], "rate": rate,
                "core_rate": core_rate, "threshold": need, "verdict": verdict}
    rows = [r for r in (rate_row("shipped"), rate_row("holdout")) if r]
    print(f"{'AREA':<10}{'SET':<9}{'TOTAL':>6}{'PASS':>6}{'FAIL':>6}{'ERROR':>6}{'UNRULED':>8}{'RATE':>8}{'CORE':>8}"
          f"{'THRESH':>8}  VERDICT")
    for r in rows:
        print(f"{r['area']:<10}{r['set']:<9}{r['total']:>6}{r['pass']:>6}{r['fail']:>6}{r['error']:>6}"
              f"{r['unruled']:>8}{r['rate'] * 100:>7.1f}%{r['core_rate'] * 100:>7.1f}%{r['threshold'] * 100:>7.1f}%"
              f"  {r['verdict']}")
    if exit_code is None:
        exit_code = 0 if all(r["verdict"] in ("PASS", "INFO") for r in rows) else 3
    tot = {k: sum(1 for r in records if r["status"] == k) for k in ("PASS", "FAIL", "ERROR", "SKIP", "UNRULED")}
    print(f"SUMMARY scenario-replay: scenarios={len(records)} passed={tot['PASS']} failed={tot['FAIL']} "
          f"errors={tot['ERROR']} skipped={tot['SKIP']} unruled={tot['UNRULED']} exit={exit_code}")
    if args.report:
        rep = {"runner": "scenario-replay", "version": VERSION, "proto": kitlib.PROTO, "started_at": started,
               "finished_at": kitrun.utc_now(), "profile": args.profile,
               "impl": {"cmd": args.impl_cmd or args.http, "name": transport.hello.get("impl"),
                        "version": transport.hello.get("impl_version"),
                        "restarts": getattr(transport, "restarts", 0)},
               "exit_code": exit_code, "areas": rows, "scenarios": records}
        with open(args.report, "w", encoding="utf-8") as fh:
            json.dump(rep, fh, indent=1)
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
