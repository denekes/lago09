#!/usr/bin/env python3
"""test_runner.py — unit tests of the kit runner (kitlib compare engine, kitrun process handling, exit codes).

Needs no lago source and no kit vectors: every vector and adapter used here is synthetic and generated in a
temporary directory. Run: python3 test_runner.py [-v]   (exit 0 = all tests passed). Called by kit-selftest.sh.
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.dirname(HERE)
sys.path.insert(0, SCRIPTS)
import kitlib  # noqa: E402

KITRUN = os.path.join(SCRIPTS, "kitrun.py")
ADAPTER_REF = os.path.join(SCRIPTS, "adapter_ref.py")

FAKE_ADAPTER = textwrap.dedent(r'''
    import json, os, sys, time
    mode = sys.argv[1]
    answers = json.load(open(sys.argv[2])) if len(sys.argv) > 2 else {}
    state = os.environ.get("FAKE_STATE")
    if mode == "noise":
        print("booting...", flush=True)
    calls = 0
    for line in sys.stdin:
        msg = json.loads(line)
        if msg["type"] == "hello":
            proto = 2 if mode == "proto2" else 1
            profiles = ["corrected"] if mode == "corrected-only" else ["compat", "corrected"]
            ops = ["domain.round"] if mode == "round-only" else ["*"]
            if mode == "crash-hello":
                sys.exit(3)
            print(json.dumps({"type": "hello", "proto": proto, "impl": "fake-" + mode, "impl_version": "0",
                              "profiles": profiles, "ops": ops}), flush=True)
            continue
        if msg["type"] == "bye":
            break
        calls += 1
        vid = msg["id"].split("#")[0]
        if mode == "echo-input":
            raw = line[line.index('"input":') + len('"input":'):].rstrip()[:-1]
            sys.stdout.write('{"type":"result","id":' + json.dumps(msg["id"]) + ',"output":{"raw":' + json.dumps(raw) + '}}\n')
            sys.stdout.flush()
            continue
        if mode == "crash" and vid.endswith("2"):
            sys.exit(1)
        if mode == "always-crash":
            sys.exit(1)
        if mode == "slow" and vid.endswith("2"):
            time.sleep(30)
        if mode == "garbage" and vid.endswith("2"):
            print("this is not json", flush=True)
            continue
        if mode == "wrong-id" and vid.endswith("2"):
            print(json.dumps({"type": "result", "id": "other#1", "output": {}}), flush=True)
            continue
        ans = answers.get(vid)
        if ans is None:
            print(json.dumps({"type": "result", "id": msg["id"], "error": {"code": "unsupported_op"}}), flush=True)
        elif "error" in ans:
            print(json.dumps({"type": "result", "id": msg["id"], "error": ans["error"]}), flush=True)
        else:
            sys.stdout.write('{"type":"result","id":' + json.dumps(msg["id"]) + ',"output":' + ans["raw"] + '}\n')
            sys.stdout.flush()
''')


def vec(i, op="round", expected=None, inp=None, profile="both", tags=("core",), compare=None, ruling="decided", pair=None):
    o = {"kit_schema": 1, "id": f"domain.synthetic.{op}.{i:03d}" + ("x" if profile == "corrected" else ""),
         "area": "domain", "op": op, "title": "synthetic runner fixture", "profile": profile, "ruling": ruling,
         "pair": pair, "rules": [], "rbd": [], "tags": list(tags), "input": inp or {"value": "1.5", "mode": "round"},
         "expected": expected if expected is not None else {"value": "2"},
         "evidence": {"kind": "RECOMPUTED", "by": "stdlib", "ref": "derived", "pin": "591ae9005110",
                      "runtime": "python3 selftest", "executed_at": "2026-10-02"}}
    if compare:
        o["compare"] = compare
    return o


class Env:
    def __init__(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="kit-selftest-")
        self.dir = self.tmp.name
        with open(os.path.join(self.dir, "fake.py"), "w") as f:
            f.write(FAKE_ADAPTER)

    def write_vectors(self, vectors, name="domain.synthetic.jsonl", raw_lines=None):
        p = os.path.join(self.dir, name)
        vectors = sorted(vectors, key=lambda o: o["id"])
        with open(p, "w") as f:
            for o in vectors:
                f.write(json.dumps(o, separators=(",", ":")) + "\n")
            for line in raw_lines or []:
                f.write(line + "\n")
        return p

    def write_answers(self, answers):
        p = os.path.join(self.dir, "answers.json")
        with open(p, "w") as f:
            json.dump({k: ({"raw": v} if isinstance(v, str) else v) for k, v in answers.items()}, f)
        return p

    def run(self, impl_cmd, files, *extra, timeout=120):
        cmd = [sys.executable, KITRUN, "--impl-cmd", impl_cmd, "--vectors", *files, "--report",
               os.path.join(self.dir, "report.json"), *extra]
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        rep = None
        if os.path.exists(os.path.join(self.dir, "report.json")):
            with open(os.path.join(self.dir, "report.json")) as f:
                rep = json.load(f)
            os.remove(os.path.join(self.dir, "report.json"))
        return p.returncode, p.stdout, rep

    def fake(self, mode, answers_path=""):
        return f"{sys.executable} {os.path.join(self.dir, 'fake.py')} {mode} {answers_path}".strip()


class CompareTests(unittest.TestCase):
    def check(self, expected, actual_text, compare=None, strict=False):
        actual = kitlib.loads_lit(actual_text)
        return kitlib.Comparator(compare or {}, strict).run(kitlib.loads_lit(json.dumps(expected)) if not isinstance(expected, str) else expected, actual)

    def test_defaults(self):
        self.assertEqual(self.check({"a": 1}, '{"a":1}'), [])
        self.assertTrue(self.check({"a": 1}, '{"a":"1"}'))           # integer vs string
        self.assertEqual(self.check({"a": "1.50"}, '{"a":"1.5"}'), [])  # decimal numeric
        self.assertEqual(self.check({"a": "1.50"}, '{"a":1.5}'), [])    # JSON number accepted (NUM-OUT warning)
        self.assertTrue(self.check({"a": "1.50"}, '{"a":"1.51"}'))
        self.assertEqual(self.check({"t": "2024-01-01T00:00:00Z"}, '{"t":"2024-01-01T01:00:00+01:00"}'), [])
        self.assertTrue(self.check({"t": "2024-01-01T00:00:00Z"}, '{"t":"2024-01-01T00:00:00.001Z"}'))
        self.assertEqual(self.check({"s": "abc"}, '{"s":"abc","extra":1}'), [])
        self.assertTrue(self.check({"s": "abc"}, '{"s":"abc","extra":1}', strict=True))
        self.assertEqual(self.check({"n": None}, '{}'), [])               # null = absent
        self.assertTrue(self.check({"n": 1}, '{}'))
        self.assertTrue(self.check({"b": True}, '{"b":1}'))
        self.assertTrue(self.check({"l": ["1", "2"]}, '{"l":["2","1"]}'))
        self.assertEqual(self.check({"d": "2024-02-29"}, '{"d":"2024-02-29"}'), [])

    def test_modes(self):
        self.assertEqual(self.check({"x": "0.3333333333333333"}, '{"x":"0.33333333333333333333"}', {"x": {"mode": "numeric", "scale": 15}}), [])
        self.assertTrue(self.check({"x": "0.3333333333333333"}, '{"x":"0.33333333333333333333"}'))
        self.assertTrue(self.check({"x": "1.0"}, '{"x":"1"}', {"x": {"mode": "text"}}))
        self.assertEqual(self.check({"x": "0.30000000000000004"}, '{"x":"0.3000000000000000444"}', {"x": {"mode": "float64"}}), [])
        self.assertTrue(self.check({"x": "0.3"}, '{"x":"0.30000000000000004"}', {"x": {"mode": "float64"}}))
        self.assertEqual(self.check({"x": "10"}, '{"x":"10.4"}', {"x": {"mode": "abs_tol", "tol": "0.5"}}), [])
        self.assertTrue(self.check({"x": "10"}, '{"x":"10.6"}', {"x": {"mode": "abs_tol", "tol": "0.5"}}))
        self.assertEqual(self.check({"w": {"min": "16", "max": "18.4"}}, '{"w":"17"}', {"w": {"mode": "range"}}), [])
        self.assertTrue(self.check({"w": {"min": "16", "max": "18.4"}}, '{"w":"19"}', {"w": {"mode": "range"}}))
        self.assertEqual(self.check({"l": [{"k": "a"}, {"k": "b"}]}, '{"l":[{"k":"b"},{"k":"a"}]}', {"l": {"mode": "set"}}), [])
        self.assertTrue(self.check({"l": ["a", "a"]}, '{"l":["a","b"]}', {"l": {"mode": "set"}}))
        self.assertEqual(self.check({"x": "anything"}, '{"x":"other"}', {"x": {"mode": "ignore"}}), [])
        self.assertEqual(self.check({"r": [{"u": "1.0"}, {"u": "2.0"}]}, '{"r":[{"u":"9"},{"u":"2"}]}', {"r[*].u": {"mode": "ignore"}}), [])
        self.assertTrue(self.check({"x": 2}, '{"x":2.0}', {"x": {"mode": "exact"}}))
        self.assertEqual(self.check({"o": {"a": 1}}, '{"o":{"a":1,"b":2}}', {"o": {"mode": "subset"}}, strict=True), [])
        self.assertTrue(self.check({"o": {"a": 1}}, '{"o":{"a":1,"b":2}}', {"o": {"mode": "strict"}}))

    def test_literal_spans(self):
        line = '{"id":"a","input":{"x":1e3,"y":2.0,"z":[9007199254740993]},"expected":{}}'
        s, e = kitlib.member_spans(line)["input"]
        self.assertEqual(line[s:e], '{"x":1e3,"y":2.0,"z":[9007199254740993]}')
        self.assertEqual(kitlib.dumps_lit(kitlib.loads_lit(line[s:e])), line[s:e])

    def test_results(self):
        st, d, _ = kitlib.compare_result({"error": {"code": "invalid_amount", "field": "amount"}},
                                         {"error": {"code": "invalid_amount", "field": "amount"}})
        self.assertEqual(st, "PASS")
        self.assertEqual(kitlib.compare_result({"error": {"code": "x"}}, {"output": {}})[0], "FAIL")
        self.assertEqual(kitlib.compare_result({"a": 1}, {"error": {"code": "x"}})[0], "FAIL")
        self.assertEqual(kitlib.compare_result({"a": 1}, {"error": {"code": "unsupported_op"}})[0], "SKIP")
        self.assertEqual(kitlib.compare_result({"a": 1}, {"error": {"code": "internal"}})[0], "ERROR")

    def test_instants(self):
        self.assertEqual(kitlib.parse_instant("1970-01-01T00:00:01.5Z"), (1, 500000000))
        self.assertIsNone(kitlib.parse_instant("2024-01-01 00:00:00"))
        self.assertEqual(kitlib.format_instant(1, 500000000), "1970-01-01T00:00:01.5Z")


class RunnerTests(unittest.TestCase):
    def setUp(self):
        self.env = Env()
        self.vs = [vec(1), vec(2), vec(3)]
        self.file = self.env.write_vectors(self.vs)
        self.answers = self.env.write_answers({v["id"]: json.dumps(v["expected"]) for v in self.vs})

    def tearDown(self):
        self.env.tmp.cleanup()

    def test_all_pass_and_report(self):
        rc, out, rep = self.env.run(self.env.fake("echo", self.answers), [self.file])
        self.assertEqual(rc, 0, out)
        self.assertIn("SUMMARY kitrun: areas=1 pass=1 fail=0 vectors=3 passed=3", out)
        sv = kitlib.SchemaValidator(os.path.join(os.path.dirname(SCRIPTS), "schemas"))
        schema, path = sv.load("report.schema.json")
        self.assertEqual(sv.validate(kitlib.loads_lit(json.dumps(rep)), schema, path), [])

    def test_parallel(self):
        rc, out, _ = self.env.run(self.env.fake("echo", self.answers), [self.file], "--parallel", "3")
        self.assertEqual(rc, 0, out)

    def test_fail_reports_diff(self):
        ans = self.env.write_answers({self.vs[0]["id"]: '{"value":"3"}', self.vs[1]["id"]: '{"value":"2"}',
                                      self.vs[2]["id"]: '{"value":"2"}'})
        rc, out, rep = self.env.run(self.env.fake("echo", ans), [self.file])
        self.assertEqual(rc, 3)
        self.assertIn('value: expected "2" (numeric) got "3"', out)

    def test_crash_restart(self):
        rc, out, rep = self.env.run(self.env.fake("crash", self.answers), [self.file])
        self.assertEqual(rc, 3, out)
        st = {v["id"]: v["status"] for v in rep["vectors"]}
        self.assertEqual(st["domain.synthetic.round.002"], "ERROR")
        self.assertEqual(st["domain.synthetic.round.003"], "PASS")
        self.assertEqual(rep["impl"]["restarts"], 1)

    def test_timeout(self):
        rc, out, rep = self.env.run(self.env.fake("slow", self.answers), [self.file], "--timeout", "1")
        self.assertEqual(rc, 3, out)
        st = {v["id"]: v["status"] for v in rep["vectors"]}
        self.assertEqual(st["domain.synthetic.round.002"], "TIMEOUT")
        self.assertEqual(st["domain.synthetic.round.003"], "PASS")

    def test_garbage_and_wrong_id(self):
        for mode in ("garbage", "wrong-id"):
            rc, out, rep = self.env.run(self.env.fake(mode, self.answers), [self.file])
            st = {v["id"]: v["status"] for v in rep["vectors"]}
            self.assertEqual(st["domain.synthetic.round.002"], "ERROR", mode)
            self.assertEqual(st["domain.synthetic.round.003"], "PASS", mode)

    def test_setup_errors(self):
        for mode in ("noise", "proto2", "corrected-only", "crash-hello"):
            rc, out, _ = self.env.run(self.env.fake(mode, self.answers), [self.file], "--hello-timeout", "5")
            self.assertEqual(rc, 2, f"{mode}: {out}")

    def test_restart_limit(self):
        rc, out, _ = self.env.run(self.env.fake("always-crash", self.answers), [self.file], "--max-restarts", "1")
        self.assertEqual(rc, 2, out)
        self.assertIn("ABORT", out)

    def test_invalid_files(self):
        bad = self.env.write_vectors(self.vs, name="domain.bad.jsonl", raw_lines=["{not json"])
        rc, out, _ = self.env.run(self.env.fake("echo", self.answers), [bad])
        self.assertEqual(rc, 4, out)
        dup = self.env.write_vectors(self.vs + [vec(1)], name="domain.dup.jsonl")
        rc, out, _ = self.env.run(self.env.fake("echo", self.answers), [dup])
        self.assertEqual(rc, 4, out)

    def test_skip_unsupported(self):
        vs = self.vs + [vec(4, op="days_between", inp={"from": "2024-01-01T00:00:00Z", "to": "2024-01-02T00:00:00Z", "timezone": "UTC"}, expected={"days": 1}, tags=())]
        f = self.env.write_vectors(vs, name="domain.skip.jsonl")
        rc, out, rep = self.env.run(self.env.fake("round-only", self.answers), [f])
        self.assertIn("SKIP domain.synthetic.days_between.004", out)
        self.assertIn("skipped_ops=1", out)
        self.assertEqual(rc, 3)  # SKIP counts as not passed; domain threshold is 100 %

    def test_literal_forwarding(self):
        v = vec(1, inp={"x": "placeholder"}, expected={"raw": '{"x":1e3,"y":2.0,"z":9007199254740993}'},
                compare={"raw": {"mode": "text"}})
        line = json.dumps(v, separators=(",", ":")).replace('{"x":"placeholder"}', '{"x":1e3,"y":2.0,"z":9007199254740993}')
        p = os.path.join(self.env.dir, "domain.lit.jsonl")
        with open(p, "w") as f:
            f.write(line + "\n")
        rc, out, _ = self.env.run(self.env.fake("echo-input"), [p])
        self.assertEqual(rc, 0, out)

    def test_unruled_and_fail_fast(self):
        vs = [vec(1), vec(2, profile="compat", pair="domain.synthetic.round.002x"),
              vec(2, profile="corrected", ruling="proposed", pair="domain.synthetic.round.002", expected={"value": "9"})]
        f = self.env.write_vectors(vs, name="domain.prof.jsonl")
        ans = self.env.write_answers({"domain.synthetic.round.001": '{"value":"2"}', "domain.synthetic.round.002": '{"value":"2"}',
                                      "domain.synthetic.round.002x": '{"value":"2"}'})
        rc, out, rep = self.env.run(self.env.fake("echo", ans), [f], "--profile", "corrected")
        self.assertEqual(rc, 0, out)
        self.assertIn("UNRULED domain.synthetic.round.002x (FAIL)", out)
        rc, out, _ = self.env.run(self.env.fake("echo", self.env.write_answers({})), [self.file], "--fail-fast")
        self.assertEqual(rc, 3)

    def test_reference_adapter(self):
        vs = [vec(1, inp={"value": "0.125", "mode": "round", "precision": 2}, expected={"value": "0.13"}),
              vec(2, inp={"value": "-0.125", "mode": "round", "precision": 2}, expected={"value": "-0.13"}),
              vec(3, inp={"value": "123.456", "mode": "ceil", "precision": -2}, expected={"value": "200"}),
              vec(4, inp={"value": "-1.231", "mode": "floor", "precision": 2}, expected={"value": "-1.24"})]
        f = self.env.write_vectors(vs, name="domain.ref.jsonl")
        rc, out, _ = self.env.run(f"{sys.executable} {ADAPTER_REF}", [f])
        self.assertEqual(rc, 0, out)


if __name__ == "__main__":
    unittest.main(verbosity=2 if "-v" in sys.argv else 1, argv=[sys.argv[0]])
