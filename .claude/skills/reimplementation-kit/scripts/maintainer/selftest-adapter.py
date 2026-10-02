#!/usr/bin/env python3
# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
"""selftest-adapter.py — an adapter that answers every call from the vector files themselves (it reads `expected`).

It exists to test the runner, never an implementation: with it, kitrun must report 100 % PASS; with --mutate every
answer is perturbed at its first gradable leaf and kitrun must report FAIL for (nearly) every vector. It must never
ship in a clean-room pack (kit-pack.sh strips scripts/maintainer/).

Usage (as kitrun --impl-cmd):
  selftest-adapter.py [--kit-root DIR] [--vectors FILE ...] [--include-holdout DIR] [--mutate]

Answers are built from the raw text of `expected` (literal number spelling preserved); an expected error
{"error": {...}} is answered as an error result. Exit 0 on bye/EOF.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
from decimal import Decimal

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import kitlib  # noqa: E402
from kitlib import Lit  # noqa: E402


def leaves(obj, path=""):
    """(path, value, parent, key) in document order; objects/arrays are yielded too (after their children)."""
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from leaves(v, kitlib.join_path(path, k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from leaves(v, kitlib.join_path(path, i))
    yield path, obj


def set_at(tree, path, value):
    if path == "":
        return value
    toks = re.findall(r"[^.\[\]]+|\[[0-9]+\]", path)
    node = tree
    for t in toks[:-1]:
        node = node[int(t[1:-1])] if t.startswith("[") else node[t]
    last = toks[-1]
    if last.startswith("["):
        node[int(last[1:-1])] = value
    else:
        node[last] = value
    return tree


def mutated_value(val, spec):
    mode = (spec or {}).get("mode")
    if mode == "range" and isinstance(val, dict):
        hi = kitlib.as_decimal(val.get("max"))
        lo = kitlib.as_decimal(val.get("min"))
        if hi is not None:
            return Lit(kitlib.canonical_decimal(hi + 1), False)
        return None if lo is None else Lit(kitlib.canonical_decimal(lo - 1), False)
    if mode == "abs_tol":
        tol = kitlib.as_decimal(spec.get("tol", "0")) or Decimal(0)
        d = kitlib.as_decimal(val)
        return None if d is None else kitlib.canonical_decimal(d + 10 * tol + 1)
    if isinstance(val, bool):
        return not val
    if val is None:
        return "mutated"
    if isinstance(val, Lit):
        return Lit(kitlib.canonical_decimal(val.dec() + 1), val.is_int)
    if isinstance(val, str):
        if kitlib.RE_DECIMAL.match(val):
            return kitlib.canonical_decimal(Decimal(val) + 1)
        inst = kitlib.parse_instant(val)
        if inst is not None:
            return kitlib.format_instant(inst[0] + 1, inst[1])
        return val + "~"
    if isinstance(val, list):
        return val + ["mutated"]
    return None


def mutate(expected, compare, strict):
    if kitlib.is_error_expectation(expected):
        e = dict(expected["error"])
        e["code"] = str(e.get("code")) + "_mutated"
        return {"error": e}
    cmp = kitlib.Comparator(compare or {}, strict)
    for path, val in leaves(expected):
        if path == "":
            break
        spec = cmp.spec_for(path)
        mode = (spec or {}).get("mode")
        if mode == "ignore":
            continue
        if isinstance(val, dict) and mode != "range":
            continue
        if isinstance(val, list) and val and mode != "set":
            continue
        new = mutated_value(val, spec)
        if new is None:
            continue
        return set_at(kitlib.loads_lit(kitlib.dumps_lit(expected)), path, new)
    if isinstance(expected, dict) and not expected:
        return {"error": {"code": "mutated_error"}}
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kit-root", default=kitlib.skill_root_default(os.path.dirname(os.path.abspath(__file__))))
    ap.add_argument("--vectors", nargs="+", default=None)
    ap.add_argument("--include-holdout", default=None)
    ap.add_argument("--mutate", action="store_true")
    args = ap.parse_args()
    files = args.vectors or kitlib.discover(args.kit_root)
    if args.include_holdout:
        files += sorted(os.path.join(args.include_holdout, f) for f in os.listdir(args.include_holdout) if f.endswith(".jsonl"))
    table = {}
    for f in files:
        vs, _ = kitlib.load_vector_file(f)
        for v in vs:
            if isinstance(v.obj.get("id"), str):
                table[v.obj["id"]] = v
    out = sys.stdout
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = kitlib.loads_lit(line)
        t = msg.get("type")
        if t == "hello":
            out.write('{"type":"hello","proto":1,"impl":"selftest-adapter","impl_version":"1.0.0' +
                      ('-mutate' if args.mutate else '') + '","profiles":["compat","corrected"],"ops":["*"]}\n')
        elif t == "bye":
            break
        elif t == "call":
            cid = msg.get("id")
            vid = str(cid).split("#", 1)[0]
            v = table.get(vid)
            if v is None:
                out.write('{"type":"result","id":' + kitlib.dumps_lit(cid) + ',"error":{"code":"unsupported_op","message":"unknown vector"}}\n')
            else:
                exp = v.obj["expected"]
                if args.mutate:
                    m = mutate(exp, v.obj.get("compare") or {}, bool(v.obj.get("strict")))
                    body = kitlib.dumps_lit(m if m is not None else exp)
                    exp_obj = m if m is not None else exp
                else:
                    body = v.raw_member("expected")
                    exp_obj = exp
                if kitlib.is_error_expectation(exp_obj):
                    err = kitlib.dumps_lit(exp_obj["error"])
                    out.write('{"type":"result","id":' + kitlib.dumps_lit(cid) + ',"error":' + err + '}\n')
                else:
                    out.write('{"type":"result","id":' + kitlib.dumps_lit(cid) + ',"output":' + body + '}\n')
        out.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
