#!/usr/bin/env python3
# MAINTAINER-ONLY: needs lago-api at pin 591ae9005110 (pinned-checkout.sh api) and the oracle toolchain; excluded from clean-room packs.
"""holdout-split.py — move a seeded, stratified sample of the kit's unit vectors into the maintainer holdout.

Usage:
  holdout-split.py [--kit-root DIR] [--seed TEXT] [--fraction F] [--include-ep] [--prune-vec-tags] [--list]
                   (--check | --write)

The split is computed over the FULL set (shipped vector files plus whatever already sits in the holdout), so the
result depends only on the vector set, the seed and the fraction: re-running with the same seed is idempotent, and a
new seed (holdout rotation before an acceptance run) moves earlier holdout vectors back into their shipped files.

Selection, per stratum (file, op), in an order fixed by sha256(seed, unit id):
  * a unit is one vector, or a compat/corrected pair (twins always move together);
  * never selected: vectors tagged `core`; vectors whose id is written out in any kit text that ships (Markdown,
    scenarios, schemas, scripts, other vectors' titles or notes; wildcards such as `pricing.graduated.*` do not
    count; `a.b.002/003` protects both ids, `a.b.001-014` protects both ends); `ep.*` vectors unless --include-ep;
    the runner fixtures (reimplementation-kit/selftest/) are never considered;
  * coverage is kept: a unit is skipped when moving it would leave a rule id (vector `rules`), an RBD id (vector
    `rbd`) or a `[vec: ...]` wildcard of the kit Markdown without any shipped vector;
  * target per stratum = round-half-up(fraction x vectors in the stratum); a unit that would overshoot is skipped.

--prune-vec-tags  opt-in: a vector named only inside `[vec: ...]` tags of kit Markdown (as a whole token) becomes
          eligible; every tag keeps at least one shipped vector, scenario or wildcard, and --write removes the
          holdout ids from those tags (`PRUNE` lines in --check). Ids written anywhere else stay protected. Pruned
          citations are not restored when a later rotation moves a vector back.
--check   compute the split and compare it with the tree: prints per-file counts and the moves --write would make;
          exit 0 when the tree already is that split, 1 when it differs.
--write   rewrite the shipped vector files (selected lines removed) and reimplementation-kit/maintainer-data/holdout/
          <same file name> (selected lines, byte-identical, sorted by id). Lines are never re-serialised.
--list    also print one `SELECT <id>` line per holdout vector.

Output: `FILE <path> total=N core=N cited=N ep_excluded=N eligible=N target=N holdout=N` lines, `MOVE` lines (check),
then `SUMMARY holdout-split: seed=S fraction=F vectors=N eligible=N holdout=N (P %) moves=N mode=check|write`.
Exit: 0 ok / in sync; 1 tree differs (--check) or the kit cannot be loaded; 2 usage error.
Standard library only; run `validate-vectors.py` after --write (HOLDOUT, REF and COVER must stay clean).
"""
from __future__ import annotations

import argparse
import collections
import decimal
import glob
import hashlib
import json
import os
import re
import sys

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))
import kitlib  # noqa: E402

DEFAULT_SEED = "lago-kit-holdout-v1"
DEFAULT_FRACTION = "0.20"
ID_BODY = r"(?:" + "|".join(kitlib.AREAS) + r")(?:\.[a-z0-9_]+)+"
# a full id, optionally followed by shorthand siblings: a.b.002/003, a.b.002/.003x, a.b.001-014, a.b.009..012, a.b.1, .2
RE_CITE = re.compile(r"(?<![A-Za-z0-9_.])(" + ID_BODY + r")\.([0-9]{3}x?)((?:\s*(?:/|,|-|–|\.\.|\band\b|\bto\b)\s*\.?[0-9]{3}x?(?![0-9]))*)")
RE_SHORT = re.compile(r"(/|,|-|–|\.\.|\band\b|\bto\b)\s*\.?([0-9]{3}x?)")
TEXT_EXT = {".md", ".json", ".jsonl", ".py", ".sh", ".txt", ".tsv", ".sql", ".go", ".yaml", ".yml", ".csv"}


def is_maintainer(rel: str, path: str) -> bool:
    r = rel.replace(os.sep, "/")
    if "/scripts/maintainer/" in "/" + r or "/maintainer-data/" in "/" + r or r.endswith("reference/maintainer-oracle.md"):
        return True
    if "/__pycache__/" in "/" + r:
        return True
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            head = "".join(fh.readline() for _ in range(3))
        return "MAINTAINER-ONLY: needs lago-api" in head
    except OSError:
        return True


def cited_ids(text: str) -> set:
    """Vector ids written out in `text`, including shorthand siblings (wildcards never match)."""
    out = set()
    for m in RE_CITE.finditer(text):
        prefix, first, tail = m.group(1), m.group(2), m.group(3) or ""
        out.add(f"{prefix}.{first}")
        for sep, num in RE_SHORT.findall(tail):
            out.add(f"{prefix}.{num}")
    return out


def unit_key(seed: str, uid: str) -> str:
    return hashlib.sha256(f"{seed}\0{uid}".encode()).hexdigest()


def round_half_up(x: decimal.Decimal) -> int:
    return int(x.quantize(decimal.Decimal(1), rounding=decimal.ROUND_HALF_UP))


def main(argv=None):
    ap = argparse.ArgumentParser(description="Seeded, stratified holdout split of the kit's unit vectors.")
    ap.add_argument("--kit-root", default=kitlib.skill_root_default(__file__))
    ap.add_argument("--seed", default=DEFAULT_SEED)
    ap.add_argument("--fraction", default=DEFAULT_FRACTION)
    ap.add_argument("--include-ep", action="store_true", help="also split ep.* vectors (excluded by default)")
    ap.add_argument("--prune-vec-tags", action="store_true",
                    help="allow vectors cited only in [vec: ...] tags; --write removes them from the tags")
    ap.add_argument("--list", action="store_true")
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--check", action="store_true")
    g.add_argument("--write", action="store_true")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    try:
        frac = decimal.Decimal(args.fraction)
    except decimal.InvalidOperation:
        frac = decimal.Decimal(-1)
    if not (0 <= frac < 1):
        print("usage: --fraction must be a decimal in [0, 1)", file=sys.stderr)
        return 2
    root = os.path.abspath(args.kit_root)
    if not os.path.isdir(os.path.join(root, "reimplementation-kit")):
        print(f"usage: --kit-root {root} has no reimplementation-kit/", file=sys.stderr)
        return 2
    hold_dir = os.path.join(root, "reimplementation-kit", "maintainer-data", "holdout")

    # 1. the full set: shipped files + current holdout lines, keyed by the shipped file's base name ----------------
    shipped_files = kitlib.discover(root)
    by_base = {os.path.basename(p): p for p in shipped_files}
    if len(by_base) != len(shipped_files):
        print("ERROR two shipped vector files share a base name; the holdout naming needs unique names", file=sys.stderr)
        return 1
    lines = collections.defaultdict(list)          # base name -> [(id, raw line, Vector)]
    current_hold = set()
    for path, set_name in [(p, "shipped") for p in shipped_files] + \
                          [(p, "holdout") for p in sorted(glob.glob(os.path.join(hold_dir, "*.jsonl")))]:
        base = os.path.basename(path)
        if base not in by_base:
            print(f"ERROR holdout file {base} has no shipped file of the same name", file=sys.stderr)
            return 1
        vs, errs = kitlib.load_vector_file(path, set_name)
        if errs:
            for e in errs:
                print(f"ERROR {e.file}:{e.line_no} {e.message}", file=sys.stderr)
            return 1
        for v in vs:
            lines[base].append((v.id, v.raw, v))
            if set_name == "holdout":
                current_hold.add(v.id)
    vec = {}
    for base, items in lines.items():
        for vid, raw, v in items:
            if vid in vec:
                print(f"ERROR duplicate id {vid}", file=sys.stderr)
                return 1
            vec[vid] = (base, v)

    # 2. protected ids: cited in shipped text ---------------------------------------------------------------------
    cited = collections.Counter()
    tags = []          # --prune-vec-tags: [(md path, line index, set of whole-token vector ids, n other resolvable)]
    md_paths = []
    for skill in ("reimplementation-kit", "billing-engine-spec", "events-processor-spec"):
        for path in glob.glob(os.path.join(root, skill, "**", "*"), recursive=True):
            rel = os.path.relpath(path, root)
            if not os.path.isfile(path) or os.path.splitext(path)[1] not in TEXT_EXT or is_maintainer(rel, path):
                continue
            r = "/" + rel.replace(os.sep, "/")
            if r.endswith(".jsonl") and ("/vectors/" in r or "/selftest/" in r):
                continue   # vector files: handled per line below (a line may name itself and its twin)
            with open(path, encoding="utf-8", errors="replace") as fh:
                text = fh.read()
            if args.prune_vec_tags and path.endswith(".md"):
                md_paths.append(path)
                text = scan_tags(path, text, vec, tags)
            for i in cited_ids(text):
                cited[i] += 1
    for vid, (base, v) in vec.items():
        own = {vid, v.obj.get("pair")}
        for i in cited_ids(v.raw) - own:
            cited[i] += 1
    for f in sorted(glob.glob(os.path.join(root, "reimplementation-kit", "selftest", "*.jsonl"))):
        for v in kitlib.load_vector_file(f, "selftest")[0]:
            for i in cited_ids(v.raw) - {v.id, v.obj.get("pair")}:
                cited[i] += 1

    # wildcards of the kit Markdown ([vec: ...] tags and prose), to keep at least one shipped match each
    wild = set()
    for skill in ("reimplementation-kit", "billing-engine-spec", "events-processor-spec"):
        for path in glob.glob(os.path.join(root, skill, "**", "*.md"), recursive=True):
            with open(path, encoding="utf-8", errors="replace") as fh:
                for m in re.finditer(r"(?<![A-Za-z0-9_.])(" + ID_BODY + r"(?:\.[a-z0-9_]+)*\.\*)", fh.read()):
                    wild.add(m.group(1))
    wild_rx = {w: re.compile("^" + re.escape(w).replace(r"\*", ".*") + "$") for w in sorted(wild)}
    tag_left = [len(ids) + other for (_, _, ids, other) in tags]
    tags_of = collections.defaultdict(list)
    for k, (_, _, ids, _) in enumerate(tags):
        for i in ids:
            tags_of[i].append(k)

    # 3. units and eligibility -------------------------------------------------------------------------------------
    units, seen = [], set()
    for vid in sorted(vec):
        if vid in seen:
            continue
        base, v = vec[vid]
        pair = v.obj.get("pair")
        members = [vid] + ([pair] if pair and pair in vec and pair not in seen else [])
        seen.update(members)
        units.append(members)
    reason = {}
    for members in units:
        for m in members:
            base, v = vec[m]
            if "core" in (v.obj.get("tags") or []):
                reason[m] = "core"
            elif cited[m]:
                reason[m] = "cited"
            elif v.obj.get("area") == "ep" and not args.include_ep:
                reason[m] = "ep"
    # coverage counters over the full set (everything starts shipped in the desired state)
    rule_n, rbd_n, wild_n = collections.Counter(), collections.Counter(), collections.Counter()
    vec_wild = {}
    for vid, (base, v) in vec.items():
        for r in v.obj.get("rules") or []:
            rule_n[r] += 1
        for r in v.obj.get("rbd") or []:
            rbd_n[r] += 1
        ws = [w for w, rx in wild_rx.items() if rx.match(vid)]
        vec_wild[vid] = ws
        for w in ws:
            wild_n[w] += 1

    strata = collections.defaultdict(list)       # (base, op) -> units
    stratum_size = collections.Counter()
    for members in units:
        base, v = vec[members[0]]
        key = (base, v.obj.get("op"))
        strata[key].append(members)
        stratum_size[key] += len(members)

    selected = set()
    for key in sorted(strata):
        target = round_half_up(frac * stratum_size[key])
        taken = 0
        for members in sorted(strata[key], key=lambda ms: unit_key(args.seed, ms[0])):
            if taken + len(members) > target:
                continue
            if any(m in reason for m in members):
                continue
            # coverage: every rule / rbd / wildcard of the unit keeps a shipped vector
            dec_rule, dec_rbd, dec_wild = collections.Counter(), collections.Counter(), collections.Counter()
            for m in members:
                o = vec[m][1].obj
                dec_rule.update(o.get("rules") or [])
                dec_rbd.update(o.get("rbd") or [])
                dec_wild.update(vec_wild[m])
            dec_tag = collections.Counter(k for m in members for k in tags_of.get(m, []))
            if any(rule_n[r] - n < 1 for r, n in dec_rule.items()) or \
                    any(rbd_n[r] - n < 1 for r, n in dec_rbd.items()) or \
                    any(wild_n[w] - n < 1 for w, n in dec_wild.items()) or \
                    any(tag_left[k] - n < 1 for k, n in dec_tag.items()):
                continue
            rule_n.subtract(dec_rule)
            rbd_n.subtract(dec_rbd)
            wild_n.subtract(dec_wild)
            for k, n in dec_tag.items():
                tag_left[k] -= n
            selected.update(members)
            taken += len(members)

    # 4. report ------------------------------------------------------------------------------------------------------
    moves_out = sorted(selected - current_hold)
    moves_back = sorted(current_hold - selected)
    for base in sorted(lines):
        ids = [vid for vid, _, _ in lines[base]]
        c = collections.Counter(reason.get(i, "eligible") for i in ids)
        tgt = sum(round_half_up(frac * n) for (b, _), n in stratum_size.items() if b == base)
        print(f"FILE {os.path.relpath(by_base[base], root)} total={len(ids)} core={c['core']} cited={c['cited']} "
              f"ep_excluded={c['ep']} eligible={c['eligible']} target={tgt} holdout={sum(1 for i in ids if i in selected)}")
    if args.list:
        for i in sorted(selected):
            print(f"SELECT {i}")
    prunes = [(path, ln, i) for (path, ln, ids, _) in tags for i in sorted(ids & selected)]
    if args.check:
        for path, ln, i in prunes:
            print(f"PRUNE {os.path.relpath(path, root)}:{ln + 1} {i}")
        for i in moves_out:
            print(f"MOVE {i} shipped -> holdout")
        for i in moves_back:
            print(f"MOVE {i} holdout -> shipped")
    n_elig = sum(1 for i in vec if i not in reason)
    pct = (100.0 * len(selected) / len(vec)) if vec else 0.0

    # 5. write ---------------------------------------------------------------------------------------------------------
    if args.write and prunes:
        for path in sorted({p for p, _, _ in prunes}):
            prune_file(path, selected)
    if args.write and (moves_out or moves_back):
        os.makedirs(hold_dir, exist_ok=True)
        for base, items in sorted(lines.items()):
            items = sorted(items, key=lambda t: t[0])
            keep = [raw for vid, raw, _ in items if vid not in selected]
            hold = [raw for vid, raw, _ in items if vid in selected]
            _write(by_base[base], keep)
            hp = os.path.join(hold_dir, base)
            if hold:
                _write(hp, hold)
            elif os.path.exists(hp):
                os.remove(hp)
    mode = "write" if args.write else "check"
    print(f"SUMMARY holdout-split: seed={args.seed} fraction={frac} vectors={len(vec)} eligible={n_elig} "
          f"holdout={len(selected)} ({pct:.1f} %) moves={len(moves_out) + len(moves_back)} prunes={len(prunes)} "
          f"mode={mode}")
    if args.check and (moves_out or moves_back or prunes):
        return 1
    return 0


RE_TAG = re.compile(r"\[vec:([^\]]*)\]")
RE_WHOLE_ID = re.compile(r"^" + ID_BODY + r"\.[0-9]{3}x?$")


def _in_code(line, pos):
    """Whether position `pos` of `line` lies inside a `backtick` span (examples, not citations)."""
    return any(a <= pos < b for a, b in ((m.start(), m.end()) for m in re.finditer(r"`[^`]*`", line)))


def _tag_tokens(body):
    return [t.strip().rstrip(".;:") for t in body.split(",")]


def scan_tags(path, text, vec, tags):
    """Record each [vec: ...] tag outside code fences; return the text with whole-token vector ids of those tags
    removed, so that the caller's citation scan protects only ids written elsewhere (prose, tables, composites)."""
    out, fence = [], False
    for ln, line in enumerate(text.split("\n")):
        if line.strip().startswith("```"):
            fence = not fence
        if fence or "[vec:" not in line:
            out.append(line)
            continue

        def strip(m, line=line):
            body = m.group(1)
            if re.match(r"\s*(none|prose)", body, re.I) or _in_code(line, m.start()):
                return m.group(0)
            ids, other, rest = set(), 0, []
            for t in _tag_tokens(body):
                if RE_WHOLE_ID.match(t) and t in vec:
                    ids.add(t)
                else:
                    rest.append(t)
                    if t.startswith("scn.") or t.startswith("EPC-") or "*" in t:
                        other += 1
            tags.append((path, ln, ids, other))
            return "[vec: " + ", ".join(rest) + "]"
        out.append(RE_TAG.sub(strip, line))
    return "\n".join(out)


def prune_file(path, selected):
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().split("\n")
    fence = False
    for k, line in enumerate(lines):
        if line.strip().startswith("```"):
            fence = not fence
        if fence or "[vec:" not in line:
            continue

        def keep(m, line=line):
            body = m.group(1)
            if re.match(r"\s*(none|prose)", body, re.I) or _in_code(line, m.start()):
                return m.group(0)
            toks = [t for t in body.split(",") if t.strip().rstrip(".;:") not in selected]
            return "[vec:" + ",".join(toks).rstrip() + "]" if toks else m.group(0)
        lines[k] = RE_TAG.sub(keep, line)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("\n".join(lines))
    os.replace(tmp, path)


def _write(path, raws):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("".join(r + "\n" for r in raws))
    os.replace(tmp, path)


if __name__ == "__main__":
    sys.exit(main())
