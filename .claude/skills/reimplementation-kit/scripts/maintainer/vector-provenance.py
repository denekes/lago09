#!/usr/bin/env python3
# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
"""vector-provenance.py — check that every evidence.ref of the kit's vectors and scenarios resolves at its pin, and
report the evidence residue (vectors that are not EXECUTED).

Usage:
  vector-provenance.py [--kit-root DIR] [--api DIR] [--repo DIR] [--include-holdout DIR] [FILE ...]

  --api   pinned lago-api checkout (default $LAGO_SKILLS_CACHE/lago-api@591ae9005110, i.e. the path printed by
          research-methodology/scripts/pinned-checkout.sh api)
  --repo  umbrella repository holding the events-processor (default: git toplevel of this script, else the cwd);
          `events-processor/<path>:<line>` and `$EP/<path>:<line>` refs are read from tree 83e012866f29 with git.

Ref forms: `$API/<path>:<line>[-<line>]` (file must exist and have that many lines), `events-processor/<path>:<line>`,
`RBD-n[,RBD-m]`, `derived`, `EPC-nn`, `golden:/corpus:/fixture:<name>` (accepted, not resolved).
Output: `BROKEN <file>:<line> <id> <ref> <reason>` lines, `RESIDUE <kind> <id> <note>` lines for both/compat vectors
that are not EXECUTED, then
  SUMMARY vector-provenance: vectors=N refs_checked=N broken=N residue_recomputed=N residue_extracted=N
Exit: 0 no broken ref; 1 broken refs; 2 usage error (missing checkout).
"""
from __future__ import annotations

import argparse
import glob
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
import kitlib  # noqa: E402

EP_TREE = "83e012866f29"
RE_API = re.compile(r"^\$API/(\S+?):([0-9]+)(?:-([0-9]+))?$")
RE_EP = re.compile(r"^(?:\$EP|events-processor)/(\S+?):([0-9]+)(?:-([0-9]+))?$")
RE_OK = [re.compile(r"^RBD-[0-9]+(,\s*RBD-[0-9]+)*$"), re.compile(r"^derived$"), re.compile(r"^EPC-[0-9]{2}$"),
         re.compile(r"^(golden|corpus|fixture):\S+$")]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("files", nargs="*")
    ap.add_argument("--kit-root", default=kitlib.skill_root_default(os.path.dirname(os.path.abspath(__file__))))
    cache = os.environ.get("LAGO_SKILLS_CACHE", os.path.expanduser("~/.cache/lago-skills"))
    ap.add_argument("--api", default=os.environ.get("API", os.path.join(cache, "lago-api@591ae9005110")))
    ap.add_argument("--repo", default=None)
    ap.add_argument("--include-holdout", default=None)
    args = ap.parse_args()
    if not os.path.isdir(args.api):
        print(f"usage: pinned checkout not found at {args.api} (pinned-checkout.sh api)", file=sys.stderr)
        return 2
    repo = args.repo
    if repo is None:
        try:
            repo = subprocess.run(["git", "-C", os.path.dirname(os.path.abspath(__file__)), "rev-parse", "--show-toplevel"],
                                  capture_output=True, text=True, check=True).stdout.strip()
        except (subprocess.CalledProcessError, FileNotFoundError):
            repo = os.getcwd()
    root = os.path.abspath(args.kit_root)
    files = [os.path.abspath(f) for f in args.files] or (kitlib.discover(root) + kitlib.discover_holdout(root) +
                                                         sorted(glob.glob(os.path.join(root, "reimplementation-kit", "selftest", "*.jsonl"))))
    if args.include_holdout:
        files += sorted(glob.glob(os.path.join(args.include_holdout, "*.jsonl")))
    items = []
    for f in files:
        if f.endswith(".jsonl"):
            vs, _ = kitlib.load_vector_file(f)
            items += [(v.file, v.line_no, v.obj) for v in vs]
    for f in ([] if args.files else kitlib.discover_scenarios(root)) + [f for f in files if f.endswith(".json")]:
        try:
            with open(f, encoding="utf-8") as fh:
                items.append((f, 1, kitlib.loads_lit(fh.read())))
        except ValueError:
            print(f"BROKEN {f}:1 - - unparsable scenario")
    line_counts, ep_cache = {}, {}

    def nlines(data: bytes) -> int:
        """Number of lines; a final newline does not start an extra line."""
        return data.count(b"\n") + (0 if not data or data.endswith(b"\n") else 1)
    broken = checked = 0
    residue = {"RECOMPUTED": 0, "EXTRACTED": 0}

    def api_lines(path):
        if path not in line_counts:
            p = os.path.join(args.api, path)
            if not os.path.isfile(p):
                line_counts[path] = -1
            else:
                with open(p, "rb") as fh:
                    line_counts[path] = nlines(fh.read())
        return line_counts[path]

    def ep_lines(path):
        if path not in ep_cache:
            r = subprocess.run(["git", "-C", repo, "cat-file", "-p", f"{EP_TREE}:{path}"], capture_output=True)
            ep_cache[path] = nlines(r.stdout) if r.returncode == 0 else -1
        return ep_cache[path]

    for f, ln, o in items:
        vid = o.get("id")
        ev = o.get("evidence") or {}
        for ref in [r.strip() for r in str(ev.get("ref", "")).split(";") if r.strip()]:
            checked += 1
            m = RE_API.match(ref)
            m2 = RE_EP.match(ref)
            if m:
                n = api_lines(m.group(1))
                last = int(m.group(3) or m.group(2))
                if n < 0:
                    broken += 1
                    print(f"BROKEN {os.path.relpath(f, root)}:{ln} {vid} {ref} file not in the pinned checkout")
                elif last > n:
                    broken += 1
                    print(f"BROKEN {os.path.relpath(f, root)}:{ln} {vid} {ref} file has {n} lines")
            elif m2:
                n = ep_lines(m2.group(1))
                last = int(m2.group(3) or m2.group(2))
                if n < 0 or last > n:
                    broken += 1
                    print(f"BROKEN {os.path.relpath(f, root)}:{ln} {vid} {ref} not resolvable in events-processor tree {EP_TREE}")
            elif not any(rx.match(ref) for rx in RE_OK):
                broken += 1
                print(f"BROKEN {os.path.relpath(f, root)}:{ln} {vid} {ref} unknown ref form")
        kind = ev.get("kind")
        if o.get("profile") in ("both", "compat") and kind in residue:
            residue[kind] += 1
            note = (o.get("notes") or ev.get("note") or "").replace("\n", " ")[:120]
            print(f"RESIDUE {kind} {vid} {note}")
    print(f"SUMMARY vector-provenance: vectors={len(items)} refs_checked={checked} broken={broken} "
          f"residue_recomputed={residue['RECOMPUTED']} residue_extracted={residue['EXTRACTED']}")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
