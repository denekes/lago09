#!/usr/bin/env python3
"""kitrun.py — run the kit's unit vectors against an implementation over the adapter protocol v1.

Usage:
  kitrun.py --impl-cmd CMD [--kit-root DIR] [--vectors FILE ...] [--areas a,b] [--only REGEX]
            [--profile compat|corrected] [--include-holdout DIR] [--parallel N] [--timeout S]
            [--hello-timeout S] [--report out.json] [--show-diff N] [--quiet] [--fail-fast]
            [--thresholds FILE] [--max-restarts N]

  CMD is started as `sh -c "exec CMD"` in its own process group; requests go to its stdin, one JSON line each,
  and exactly one JSON line per request is read back from its stdout (reference/adapter-protocol.md).
  Default vector set: every <kit-root>/<skill>/vectors/*.jsonl (kit-root = the directory holding
  reimplementation-kit/). --vectors replaces discovery with explicit files.

Output: one line per vector (PASS|FAIL|ERROR|TIMEOUT|SKIP|UNRULED <id>; FAIL/ERROR lines are followed by up to
--show-diff diff lines), a per-area table, then
  SUMMARY kitrun: areas=N pass=N fail=N vectors=N passed=N skipped_ops=N exit=N

Exit codes: 0 every area meets its threshold (acceptance/thresholds.json) and every core vector passed;
            3 an area is below its threshold or a core vector did not pass (or --fail-fast stopped the run);
            2 protocol/setup error (adapter did not start or answer hello, proto/profile mismatch, too many restarts);
            4 vector files invalid (unparsable line, missing envelope field, duplicate id); 1 usage error
            (including an unknown --areas name or an invalid --only expression).
  An empty selection prints a NOTE line and exits 0.

Standard library only; Python >= 3.10.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import json
import os
import queue
import re
import select
import signal
import subprocess
import sys
import threading
import time

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kitlib  # noqa: E402

KITRUN_VERSION = "1.6.0"
ENVELOPE_REQUIRED = ["kit_schema", "id", "area", "op", "profile", "input", "expected"]
STDERR_TAIL_BYTES = 4096


class SetupError(Exception):
    pass


class Adapter:
    """One adapter process: start, hello, synchronous calls with a deadline, kill."""

    def __init__(self, cmd: str, hello_msg: dict, hello_timeout: float, env=None):
        self.cmd = cmd
        self.hello_msg = hello_msg
        self.hello_timeout = hello_timeout
        self.env = env
        self.proc = None
        self.buf = b""
        self.stderr_tail = collections.deque()
        self.stderr_size = 0
        self.hello = None

    def start(self):
        self.proc = subprocess.Popen(["sh", "-c", "exec " + self.cmd], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     stderr=subprocess.PIPE, start_new_session=True, bufsize=0, env=self.env)
        self.buf = b""
        threading.Thread(target=self._drain_stderr, args=(self.proc,), daemon=True).start()
        try:
            self._send(json.dumps(self.hello_msg))
        except OSError as e:
            raise SetupError(f"adapter did not accept hello: {e}")
        kind, line = self._read_line(self.hello_timeout)
        if kind != "line":
            raise SetupError(f"adapter hello: {kind} ({self.stderr_text()[-300:].strip()})")
        try:
            msg = json.loads(line)
        except ValueError:
            raise SetupError(f"adapter hello is not JSON: {line[:200]!r}")
        if not isinstance(msg, dict) or msg.get("type") != "hello":
            raise SetupError(f"adapter answered hello with {line[:200]!r}")
        if msg.get("proto") != kitlib.PROTO:
            raise SetupError(f"protocol mismatch: runner proto {kitlib.PROTO}, adapter proto {msg.get('proto')}")
        self.hello = msg
        return msg

    def _drain_stderr(self, proc):
        while True:
            try:
                chunk = proc.stderr.read(4096)
            except (OSError, ValueError):
                return
            if not chunk:
                return
            self.stderr_tail.append(chunk)
            self.stderr_size += len(chunk)
            while self.stderr_size > STDERR_TAIL_BYTES and len(self.stderr_tail) > 1:
                self.stderr_size -= len(self.stderr_tail.popleft())

    def stderr_text(self) -> str:
        return b"".join(self.stderr_tail).decode("utf-8", "replace")

    def _send(self, text: str):
        self.proc.stdin.write(text.encode("utf-8") + b"\n")
        self.proc.stdin.flush()

    def _read_line(self, timeout: float):
        deadline = time.monotonic() + timeout
        fd = self.proc.stdout.fileno()
        while b"\n" not in self.buf:
            left = deadline - time.monotonic()
            if left <= 0:
                return "timeout", None
            r, _, _ = select.select([fd], [], [], left)
            if not r:
                continue
            chunk = os.read(fd, 65536)
            if not chunk:
                return "eof", None
            self.buf += chunk
        line, _, self.buf = self.buf.partition(b"\n")
        return "line", line.decode("utf-8", "replace").rstrip("\r")

    def call(self, request_text: str, call_id: str, timeout: float):
        """Returns (kind, payload): ("result", dict) | ("timeout", None) | ("crash", reason) | ("garbage", line)."""
        try:
            self._send(request_text)
        except OSError as e:
            return "crash", f"write failed: {e}"
        kind, line = self._read_line(timeout)
        if kind == "timeout":
            return "timeout", None
        if kind == "eof":
            rc = self.proc.poll()
            return "crash", f"adapter exited (status {rc})" if rc is not None else "adapter closed stdout"
        try:
            msg = kitlib.loads_lit(line)
        except ValueError:
            return "garbage", line[:300]
        if not isinstance(msg, dict) or msg.get("type") != "result":
            return "garbage", line[:300]
        if msg.get("id") != call_id:
            return "garbage", f"result id {msg.get('id')!r} does not match call id {call_id!r}"
        return "result", msg

    def kill(self):
        if self.proc is None:
            return
        try:
            os.killpg(self.proc.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError):
            pass
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        self.proc = None

    def close(self):
        if self.proc is None:
            return
        try:
            self._send('{"type":"bye"}')
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            pass
        self.kill()


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_vectors(files, holdout_files):
    vectors, errors = [], []
    for f in files:
        v, e = kitlib.load_vector_file(f, "shipped")
        vectors += v
        errors += e
    for f in holdout_files:
        v, e = kitlib.load_vector_file(f, "holdout")
        vectors += v
        errors += e
    seen = {}
    for v in vectors:
        missing = [k for k in ENVELOPE_REQUIRED if k not in v.obj]
        if missing:
            errors.append(kitlib.LoadError(v.file, v.line_no, f"missing envelope field(s) {missing}"))
            continue
        if not isinstance(v.obj.get("id"), str) or not kitlib.RE_VECTOR_ID.match(v.obj["id"]):
            errors.append(kitlib.LoadError(v.file, v.line_no, f"bad id {v.obj.get('id')!r}"))
        elif v.obj["id"] in seen:
            errors.append(kitlib.LoadError(v.file, v.line_no, f"duplicate id {v.obj['id']} (also {seen[v.obj['id']]})"))
        else:
            seen[v.obj["id"]] = f"{os.path.basename(v.file)}:{v.line_no}"
        if not isinstance(v.obj.get("input"), dict) or not isinstance(v.obj.get("expected"), dict):
            errors.append(kitlib.LoadError(v.file, v.line_no, "input and expected must be objects"))
    return vectors, errors


def lit_int(v, default=None):
    if isinstance(v, kitlib.Lit) and v.is_int:
        return int(v.text)
    return default


def main(argv=None):
    ap = argparse.ArgumentParser(description="Run kit unit vectors against an implementation (adapter protocol v1).")
    ap.add_argument("--impl-cmd", required=True)
    ap.add_argument("--kit-root", default=kitlib.skill_root_default(__file__))
    ap.add_argument("--vectors", nargs="+", default=None)
    ap.add_argument("--areas", default=None)
    ap.add_argument("--only", default=None)
    ap.add_argument("--profile", choices=["compat", "corrected"], default="compat")
    ap.add_argument("--include-holdout", default=None, metavar="DIR")
    ap.add_argument("--parallel", type=int, default=1)
    ap.add_argument("--timeout", type=float, default=5.0)
    ap.add_argument("--slow-timeout", type=float, default=30.0)
    ap.add_argument("--hello-timeout", type=float, default=30.0)
    ap.add_argument("--max-restarts", type=int, default=20)
    ap.add_argument("--report", default=None)
    ap.add_argument("--show-diff", type=int, default=3)
    ap.add_argument("--quiet", action="store_true", help="print only non-PASS vector lines")
    ap.add_argument("--fail-fast", action="store_true")
    ap.add_argument("--thresholds", default=None)
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 1 if e.code else 0

    started = utc_now()
    root = os.path.abspath(args.kit_root)
    files = [os.path.abspath(f) for f in args.vectors] if args.vectors else kitlib.discover(root)
    holdout = []
    if args.include_holdout:
        if not os.path.isdir(args.include_holdout):
            print(f"usage: --include-holdout {args.include_holdout} is not a directory", file=sys.stderr)
            return 1
        holdout = sorted(os.path.join(args.include_holdout, f) for f in os.listdir(args.include_holdout) if f.endswith(".jsonl"))
    vectors, load_errors = load_vectors(files, holdout)
    if load_errors:
        for e in load_errors:
            print(f"INVALID {e.file}:{e.line_no} {e.message}")
        print(f"SUMMARY kitrun: areas=0 pass=0 fail=0 vectors={len(vectors)} passed=0 skipped_ops=0 exit=4")
        return 4

    areas = set(a.strip() for a in args.areas.split(",") if a.strip()) if args.areas else None
    unknown = sorted(areas - set(kitlib.AREAS)) if areas else []
    if unknown:  # a misspelt area would otherwise select nothing and "pass" vacuously (exit 0)
        print(f"usage: unknown area(s) {','.join(unknown)} (known: {','.join(kitlib.AREAS)})", file=sys.stderr)
        return 1
    try:
        only = re.compile(args.only) if args.only else None
    except re.error as e:
        print(f"usage: --only is not a valid regular expression: {e}", file=sys.stderr)
        return 1
    selected = []
    for v in vectors:
        o = v.obj
        if o["profile"] not in ("both", args.profile):
            continue
        if areas and o["area"] not in areas:
            continue
        if only and not only.search(o["id"]):
            continue
        selected.append(v)
    selected.sort(key=lambda v: (v.set, v.obj["id"]))
    kver = kitlib.kit_version(root)
    th = kitlib.load_thresholds(args.thresholds or os.path.join(root, "reimplementation-kit", "acceptance", "thresholds.json"))
    sel_areas = sorted({v.obj["area"] for v in selected})
    hello_msg = {"type": "hello", "role": "runner", "proto": kitlib.PROTO, "kit_version": kver,
                 "kit_schema": kitlib.KIT_SCHEMA, "profiles": [args.profile], "areas": sel_areas}

    print(f"kitrun {KITRUN_VERSION} proto={kitlib.PROTO} kit={kver} profile={args.profile} vectors={len(selected)} "
          f"files={len(files) + len(holdout)}", flush=True)
    if not selected:
        print("NOTE no vector selected (check --vectors/--areas/--only/--profile; discovery reads "
              "<kit-root>/<skill>/vectors/*.jsonl)")
        print("SUMMARY kitrun: areas=0 pass=0 fail=0 vectors=0 passed=0 skipped_ops=0 exit=0")
        return 0

    # --- adapters ----------------------------------------------------------------------------------------------
    nproc = max(1, min(args.parallel, len(selected)))
    lock = threading.Lock()
    state = {"restarts": 0, "abort": None, "stop": False}
    try:
        first = Adapter(args.impl_cmd, hello_msg, args.hello_timeout)
        hello = first.start()
    except SetupError as e:
        print(f"SETUP-ERROR {e}")
        print(f"SUMMARY kitrun: areas=0 pass=0 fail=0 vectors={len(selected)} passed=0 skipped_ops=0 exit=2")
        try:
            first.kill()
        except Exception:
            pass
        return 2
    impl_profiles = hello.get("profiles") or []
    impl_ops = hello.get("ops") or []
    if args.profile not in impl_profiles:
        first.close()
        print(f"SETUP-ERROR adapter {hello.get('impl')} supports profiles {impl_profiles}, run asked for {args.profile}")
        print(f"SUMMARY kitrun: areas=0 pass=0 fail=0 vectors={len(selected)} passed=0 skipped_ops=0 exit=2")
        return 2
    print(f"impl={hello.get('impl')} {hello.get('impl_version', '')} profiles={','.join(impl_profiles)} "
          f"ops={len(impl_ops)}", flush=True)

    work = queue.Queue()
    for i, v in enumerate(selected):
        work.put((i, v))
    results = [None] * len(selected)
    print_lock = threading.Lock()
    skipped_ops = set()

    def emit(v, rec):
        st = rec["status"]
        if args.quiet and st == "PASS":
            return
        extra = f" ({rec['unruled_outcome']})" if st == "UNRULED" else ""
        with print_lock:
            print(f"{st} {v.obj['id']}{extra}" + (" [holdout]" if v.set == "holdout" else ""))
            if st in ("FAIL", "ERROR", "TIMEOUT") or (st == "UNRULED" and rec.get("unruled_outcome") != "PASS"):
                for d in rec["diffs"][: args.show_diff]:
                    print(f"    {d}")
            sys.stdout.flush()

    def worker(adapter):
        while not state["stop"]:
            try:
                idx, v = work.get_nowait()
            except queue.Empty:
                break
            o = v.obj
            op_name = f"{o['area']}.{o['op']}"
            rec = {"id": o["id"], "area": o["area"], "op": o["op"], "set": v.set, "status": None, "ms": 0,
                   "diffs": [], "warnings": [], "adapter_error": None}
            if not kitlib.op_supported(op_name, impl_ops):
                rec["status"] = "SKIP"
                rec["diffs"] = [f"op {op_name} not declared in adapter hello"]
                with lock:
                    skipped_ops.add(op_name)
            else:
                if adapter is None or adapter.proc is None:
                    adapter = restart(adapter)
                    if adapter is None:
                        rec["status"] = "ERROR"
                        rec["diffs"] = ["adapter could not be restarted"]
                        results[idx] = rec
                        emit(v, rec)
                        continue
                call_id = f"{o['id']}#1"
                request = ('{"type":"call","id":' + json.dumps(call_id) + ',"area":' + json.dumps(o["area"]) +
                           ',"op":' + json.dumps(o["op"]) + ',"profile":' + json.dumps(args.profile) +
                           ',"input":' + v.raw_member("input") + "}")
                tags = o.get("tags") or []
                timeout = lit_int(o.get("timeout_s"), None) or (args.slow_timeout if "slow" in tags else args.timeout)
                t0 = time.monotonic()
                kind, payload = adapter.call(request, call_id, timeout)
                rec["ms"] = int((time.monotonic() - t0) * 1000)
                if kind == "result":
                    status, diffs, warns = kitlib.compare_result(o["expected"], payload, o.get("compare") or {},
                                                                  bool(o.get("strict")))
                    rec["status"], rec["diffs"], rec["warnings"] = status, diffs, warns
                    if payload.get("error") is not None:
                        rec["adapter_error"] = kitlib.to_plain(payload["error"])
                        if status == "SKIP":
                            with lock:
                                skipped_ops.add(op_name)
                else:
                    rec["status"] = "TIMEOUT" if kind == "timeout" else "ERROR"
                    rec["diffs"] = [f"adapter {kind}" + (f": {payload}" if payload else f" after {timeout:g} s")]
                    rec["stderr_tail"] = adapter.stderr_text()[-1500:]
                    adapter.kill()
                    adapter = restart(adapter)
            if o["profile"] == "corrected" and o.get("ruling") == "proposed":
                rec["unruled_outcome"] = rec["status"]
                rec["status"] = "UNRULED"
            results[idx] = rec
            emit(v, rec)
            if args.fail_fast and rec["status"] in ("FAIL", "ERROR", "TIMEOUT"):
                state["stop"] = True
        if adapter is not None:
            adapter.close()

    def restart(old):
        if old is not None:
            old.kill()
        with lock:
            state["restarts"] += 1
            if state["restarts"] > args.max_restarts:
                state["abort"] = f"more than {args.max_restarts} adapter restarts"
                state["stop"] = True
                return None
        a = Adapter(args.impl_cmd, hello_msg, args.hello_timeout)
        try:
            a.start()
            return a
        except SetupError as e:
            with print_lock:
                print(f"RESTART-FAILED {e}", flush=True)
            a.kill()
            return None

    threads = []
    for n in range(nproc):
        adapter = first if n == 0 else None
        if n > 0:
            a = Adapter(args.impl_cmd, hello_msg, args.hello_timeout)
            try:
                a.start()
                adapter = a
            except SetupError as e:
                print(f"SETUP-ERROR parallel adapter {n + 1}: {e}")
                a.kill()
                continue
        t = threading.Thread(target=worker, args=(adapter,), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()

    # --- grading -----------------------------------------------------------------------------------------------
    done = [(v, r) for v, r in zip(selected, results) if r is not None]
    rows = []
    groups = collections.OrderedDict()
    for v, r in done:
        groups.setdefault((r["area"], r["set"]), []).append((v, r))
    any_below = False
    for (area, set_name), items in sorted(groups.items()):
        cnt = collections.Counter(r["status"] for _, r in items)
        total = len(items)
        unruled = cnt["UNRULED"]
        graded = total - unruled
        rate = cnt["PASS"] / graded if graded else None
        core = [r for v, r in items if "core" in (v.obj.get("tags") or []) and r["status"] != "UNRULED"]
        core_rate = (sum(1 for r in core if r["status"] == "PASS") / len(core)) if core else None
        thresh, core_thresh = kitlib.threshold_for(th, area, set_name)
        if graded == 0:
            verdict = "INFO"
        else:
            ok = (thresh is None or rate + 1e-12 >= thresh) and (core_rate is None or core_rate + 1e-12 >= core_thresh)
            verdict = "PASS" if ok else "FAIL"
            any_below |= not ok
        rows.append({"area": area, "set": set_name, "total": total, "pass": cnt["PASS"], "fail": cnt["FAIL"],
                     "error": cnt["ERROR"], "timeout": cnt["TIMEOUT"], "skip": cnt["SKIP"], "unruled": unruled,
                     "rate": rate, "core_rate": core_rate, "threshold": thresh, "verdict": verdict})

    def pct(x):
        return "-" if x is None else f"{100 * x:.1f}%"

    print(f"{'AREA':<22} {'TOTAL':>5} {'PASS':>5} {'FAIL':>5} {'ERROR':>5} {'TIMEOUT':>7} {'SKIP':>5} {'UNRULED':>7} "
          f"{'RATE':>6} {'CORE':>6} {'THRESH':>6}  VERDICT")
    for r in rows:
        name = r["area"] + (" (holdout)" if r["set"] == "holdout" else "")
        print(f"{name:<22} {r['total']:>5} {r['pass']:>5} {r['fail']:>5} {r['error']:>5} {r['timeout']:>7} "
              f"{r['skip']:>5} {r['unruled']:>7} {pct(r['rate']):>6} {pct(r['core_rate']):>6} {pct(r['threshold']):>6}  {r['verdict']}")
    warn_count = sum(len(r["warnings"]) for _, r in done)
    if warn_count:
        print(f"WARNINGS {warn_count} (e.g. {next(w for _, r in done for w in r['warnings'])})")
    if state["abort"]:
        exit_code = 2
        print(f"ABORT {state['abort']}")
    elif any_below or (args.fail_fast and state["stop"]) or len(done) < len(selected):
        exit_code = 3
    else:
        exit_code = 0
    passed = sum(1 for _, r in done if r["status"] == "PASS")
    n_pass = sum(1 for r in rows if r["verdict"] == "PASS")
    n_fail = sum(1 for r in rows if r["verdict"] == "FAIL")
    print(f"SUMMARY kitrun: areas={len(rows)} pass={n_pass} fail={n_fail} vectors={len(selected)} passed={passed} "
          f"skipped_ops={len(skipped_ops)} exit={exit_code}")

    if args.report:
        report = {
            "kitrun_version": KITRUN_VERSION, "proto": kitlib.PROTO, "kit_version": kver, "kit_schema": kitlib.KIT_SCHEMA,
            "started_at": started, "finished_at": utc_now(),
            "impl": {"cmd": args.impl_cmd, "name": str(hello.get("impl", "")), "version": str(hello.get("impl_version", "")),
                     "profiles": impl_profiles, "ops": impl_ops, "restarts": state["restarts"]},
            "profile": args.profile,
            "selection": {"files": [os.path.relpath(f, root) for f in files + holdout], "areas": sorted(areas) if areas else None,
                          "only": args.only, "holdout": bool(holdout)},
            "exit_code": exit_code, "areas": rows,
            "vectors": [r for _, r in done],
            "warnings": [w for _, r in done for w in r["warnings"]],
        }
        with open(args.report, "w", encoding="utf-8") as f:
            json.dump(report, f, indent=1, default=str)
            f.write("\n")
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
