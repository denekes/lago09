#!/usr/bin/env python3
# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
"""make-kit-json.py — build the kit manifest reimplementation-kit/kit.json (vector-format.md section 10).

Usage:
  make-kit-json.py [--kit-root DIR] [--kit-version X.Y.Z] (--check | --write)

The manifest lists every file of the three kit skills (reimplementation-kit, billing-engine-spec,
events-processor-spec) with its sha256: a plain file as `"<path>": "<sha256>"`, a vector file (`*/vectors/*.jsonl`,
`selftest/*.jsonl`, holdout files) as `{"sha256", "vectors": <count>}`, a maintainer-only file with
`"maintainer": true` added (kit-pack.sh accepts both forms). Maintainer-only means exactly what
kit-pack.sh --cleanroom strips: anything under a `scripts/maintainer/` or `maintainer-data/` directory,
`reimplementation-kit/reference/maintainer-oracle.md`, and any file whose first three lines carry the MAINTAINER-ONLY
header. Left out: kit.json itself, `__pycache__/`, `*.pyc`, `.DS_Store`, `*.tmp`. The output is deterministic (no
timestamp, sorted paths, one file per line), so --check after --write is clean until a file changes.

--kit-version   default: the kit_version of the current kit.json, else 1.6.0.
--check         compare with the current kit.json; prints ADDED/REMOVED/CHANGED lines; exit 0 when identical, 1 when
                absent or different.
--write         write kit.json.
Run it last at integration (after holdout-split.py --write and every other edit); kit-pack.sh verifies the hashes.
Output: `SUMMARY make-kit-json: files=N maintainer=N vectors=N bytes=N changed=N mode=check|write`.
Exit: 0 ok / in sync; 1 differs (--check); 2 usage error. Standard library only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import kitlib  # noqa: E402

SKILLS = ("reimplementation-kit", "billing-engine-spec", "events-processor-spec")
MANIFEST = os.path.join("reimplementation-kit", "kit.json")
HEADER = "MAINTAINER-ONLY: needs lago-api"


def maintainer_only(rel: str, path: str) -> bool:
    r = "/" + rel.replace(os.sep, "/")
    if "/scripts/maintainer/" in r or "/maintainer-data/" in r or r == "/reimplementation-kit/reference/maintainer-oracle.md":
        return True
    try:
        with open(path, "rb") as fh:
            head = b"".join(fh.readline() for _ in range(3))
    except OSError:
        return False
    return HEADER.encode() in head


def is_vector_file(rel: str) -> bool:
    r = "/" + rel.replace(os.sep, "/")
    return r.endswith(".jsonl") and ("/vectors/" in r or "/reimplementation-kit/selftest/" in r
                                     or "/maintainer-data/holdout/" in r)


def skipped(rel: str) -> bool:
    parts = rel.replace(os.sep, "/").split("/")
    name = parts[-1]
    return ("__pycache__" in parts or name.endswith(".pyc") or name == ".DS_Store" or name.endswith(".tmp")
            or rel.replace(os.sep, "/") == MANIFEST.replace(os.sep, "/"))


def build(root: str, kit_version: str) -> str:
    entries = []
    for skill in SKILLS:
        base = os.path.join(root, skill)
        for d, dirs, files in os.walk(base):
            dirs[:] = sorted(x for x in dirs if x != "__pycache__")
            for name in files:
                path = os.path.join(d, name)
                rel = os.path.relpath(path, root).replace(os.sep, "/")
                if skipped(rel) or not os.path.isfile(path) or os.path.islink(path):
                    continue
                with open(path, "rb") as fh:
                    data = fh.read()
                meta = {"sha256": hashlib.sha256(data).hexdigest()}
                if is_vector_file(rel):
                    meta["vectors"] = sum(1 for line in data.split(b"\n") if line.strip())
                if maintainer_only(rel, path):
                    meta["maintainer"] = True
                entries.append((rel, meta["sha256"] if len(meta) == 1 else meta))
    entries.sort()
    head = {"kit_version": kit_version, "kit_schema": kitlib.KIT_SCHEMA, "proto": kitlib.PROTO,
            "pins": {"lago_api": kitlib.BILLING_PIN, "events_processor_tree": kitlib.EP_PIN.split(":", 1)[-1]},
            "generated_by": "reimplementation-kit/scripts/maintainer/make-kit-json.py"}
    lines = ["{" + json.dumps(head, separators=(",", ":"))[1:-1] + ',"files":{']
    for k, (rel, meta) in enumerate(entries):
        lines.append(json.dumps(rel) + ":" + json.dumps(meta, separators=(",", ":")) + ("," if k < len(entries) - 1 else ""))
    lines.append("}}")
    return "\n".join(lines) + "\n"


def main(argv=None):
    ap = argparse.ArgumentParser(description="Build reimplementation-kit/kit.json (sha256 manifest of the kit).")
    ap.add_argument("--kit-root", default=kitlib.skill_root_default(__file__))
    ap.add_argument("--kit-version", default=None)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--write", action="store_true")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    root = os.path.abspath(args.kit_root)
    if not os.path.isdir(os.path.join(root, "reimplementation-kit")):
        print(f"usage: --kit-root {root} has no reimplementation-kit/", file=sys.stderr)
        return 2
    target = os.path.join(root, MANIFEST)
    old_text, old = None, {}
    if os.path.exists(target):
        with open(target, encoding="utf-8") as fh:
            old_text = fh.read()
        try:
            old = json.loads(old_text)
        except ValueError:
            old = {}
    version = args.kit_version or str(old.get("kit_version") or "1.6.0")
    if not re.match(r"^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$", version):
        print(f"usage: --kit-version {version!r} is not semver", file=sys.stderr)
        return 2
    text = build(root, version)
    new = json.loads(text)
    of, nf = old.get("files", {}) if isinstance(old.get("files"), dict) else {}, new["files"]
    changed = 0
    for rel in sorted(set(of) | set(nf)):
        if rel not in of:
            changed += 1
            if args.check:
                print(f"ADDED {rel}")
        elif rel not in nf:
            changed += 1
            if args.check:
                print(f"REMOVED {rel}")
        elif of[rel] != nf[rel]:
            changed += 1
            if args.check:
                print(f"CHANGED {rel}")
    if args.check and old_text is None:
        print(f"ABSENT {MANIFEST}")
    if args.write and text != old_text:
        tmp = target + ".tmp"
        with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(text)
        os.replace(tmp, target)
    dicts = [m for m in nf.values() if isinstance(m, dict)]
    nmaint = sum(1 for m in dicts if m.get("maintainer"))
    nvec = sum(m.get("vectors", 0) for m in dicts if not m.get("maintainer"))
    mode = "write" if args.write else "check"
    print(f"SUMMARY make-kit-json: files={len(nf)} maintainer={nmaint} vectors={nvec} bytes={len(text.encode())} "
          f"changed={changed} mode={mode}")
    if args.check and text != old_text:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
