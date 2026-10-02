#!/usr/bin/env python3
"""validate-vectors.py — schema, lint, evidence, budget and content checks for the kit's vectors and texts.

Usage:
  validate-vectors.py [--kit-root DIR] [FILE ...] [--gate] [--rule-coverage] [--include-holdout DIR]
                      [--no-text] [--quiet] [--inventory]

  Without FILE arguments every shipped vector file (<kit-root>/<skill>/vectors/*.jsonl), the runner fixtures
  (reimplementation-kit/selftest/*.jsonl), every scenario (<kit-root>/<skill>/scenarios/scn.*.json), the maintainer
  holdout and the kit texts are checked. With FILE
  arguments only those files are reported on (vector .jsonl, scenario .json, or Markdown); the rest of the kit is
  still loaded for cross-file checks (id uniqueness, twins, holdout overlap). A file given both by a relative path
  and through discovery is checked once.

Rule families (reference/vector-format.md section 9): SCHEMA, ID, OP, PAIR, REF, NUM, TIME, EVID, CMP, EXPECT,
BUDGET, CONTENT, HOLDOUT, TEXT, plus GATE (--gate: evidence-mix thresholds of acceptance/thresholds.json) and
COVER (--rule-coverage: every defined BE/EP rule is exercised by a vector or marked prose-only).

Holdout awareness: the maintainer holdout never ships, so kit text must not depend on it. HOLDOUT reports a holdout id
mentioned in shipped text (Markdown, scenarios, schemas, shipped vectors), twins split between the shipped set and
the holdout, and a [vec: ...] wildcard that matches only holdout vectors; --rule-coverage does not count holdout
vectors as coverage (a rule exercised only by them is reported as holdout_only).

Budget caps come from acceptance/thresholds.json "kit_budget" (the BUDGET_DEFAULT values below when absent).

Output: one line per finding `ERROR|WARN <RULE> <file>:<line> [<id>] <message>`, then
  SUMMARY validate-vectors: files=N vectors=N scenarios=N errors=N warnings=N
Exit: 0 no errors; 1 errors; 2 usage error. Standard library only; Python >= 3.10.
"""
from __future__ import annotations

import argparse
import collections
import glob
import json
import os
import re
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import kitlib  # noqa: E402
from kitlib import Lit  # noqa: E402

KNOWN_TAGS = {"core", "boundary", "float-island", "premium", "literal", "optional", "store-ch", "slow", "unexecuted",
              "test-key", "order-dependent", "dst", "negative", "regression"}
EXECUTED_BY = {"oracle-adapter", "spec-green", "harness", "go-binary", "go-unit", "ep-oracle", "replay-on-lago"}
RECOMPUTED_BY = {"recompute", "sql-recompute", "stdlib"}
EXTRACTED_BY = {"spec-read", "code-read"}
PAYLOAD_KEYS = {"properties", "payload", "amount_details", "object", "metadata", "raw", "body", "event", "events",
                "stored_event", "message", "params", "failure", "customer_setting", "billing_entity_setting"}
CHAPTER_OF = {"DM": "01", "EV": "02", "EX": "03", "AG": "04", "PR": "05", "SP": "06", "IV": "07", "CN": "08",
              "WL": "09", "PB": "10", "AL": "10", "API": "11", "WH": "12", "CK": "13", "IF": "14"}
RE_RULE = re.compile(r"\b(BE-(?:DM|EV|EX|AG|PR|SP|IV|CN|WL|PB|AL|API|WH|CK|IF)-[0-9]+[a-z]?|EP-[A-Z][0-9]+[a-z]?)\b")
RE_RBD = re.compile(r"\bRBD-[0-9]+\b")
RE_VEC_TAG = re.compile(r"\[vec:\s*([^\]]*)\]")
RE_API_CITE = re.compile(r"\$API/[A-Za-z0-9_./-]+:[0-9]+")
RE_UUID = re.compile(r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b")
REF_FORMS = [re.compile(r"^\$API/\S+:[0-9]+(-[0-9]+)?$"), re.compile(r"^(\$EP|events-processor)/\S+:[0-9]+(-[0-9]+)?$"),
             re.compile(r"^RBD-[0-9]+(,\s*RBD-[0-9]+)*$"), re.compile(r"^derived$"), re.compile(r"^EPC-[0-9]{2}$"),
             re.compile(r"^(golden|corpus|fixture):\S+$")]
FORBIDDEN = [
    (re.compile(r"/tmp/" + "claude|scratch" + "pad"), "scratch path"),
    (re.compile(r"/home/[a-z]"), "home path"),
    (re.compile(r"/root/"), "root home path"),
    (re.compile(r"\.cache/lago-" + "skills"), "cache path (use $LAGO_SKILLS_CACHE)"),
    (re.compile(r"\bk[1-8](?:-[a-z]+)?\s+(?:V|R|G|E|D|S|P|Q|GV|TM|WH|WC|PU|UT|CF|NP|SL|IN|DD)-?[0-9]{1,3}[a-c]?\b"), "discovery-note id"),
    (re.compile(r"\bk[1-8]-(?:probe|probes|harness|recompute|run-lago-api|vector-recorder|vectors-sample|scenario-vectors)"), "discovery artefact"),
    (re.compile(r"\b(?:R-[A-N][0-9]{1,2}|GV-[0-9]{2}[a-c]?)\b"), "discovery-note id"),
    (re.compile(r"KIT-" + "PLAN|KIT-" + "BRIEF|disco" + "very/k[1-8]"), "planning document reference"),
]
SECRETS = [
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key"),
    (re.compile(r"\bsk_live_[0-9A-Za-z]{8,}"), "live API secret"),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), "cloud access key"),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{30,}"), "GitHub token"),
    (re.compile(r"\bxox[abpr]-[0-9A-Za-z-]{10,}"), "chat token"),
]
INTERNAL_TABLES = ["events_enriched", "enriched_events", "events_raw", "cached_aggregations", "quantified_events",
                   "invoice_subscriptions", "schema_migrations", "ar_internal_metadata", "charge_filter_values",
                   "billable_metric_filters", "idempotency_records", "wallet_transaction_consumptions"]
BUDGET_DEFAULT = {"billing_unit": 1_400_000, "scenarios": 600_000, "ep_conformance": 650_000, "ep_units": 130_000,
                  "schemas_meta": 420_000, "total": 3_000_000}
SCENARIO_DEFAULT = {"scenario_target_bytes": 12_000, "scenario_max_bytes": 16_000,
                    "scenario_exception_max_bytes": 24_000, "scenario_exceptions_max": 5}
RE_ANY_VECTOR_ID = re.compile(r"(?<![A-Za-z0-9_.])(?:" + "|".join(kitlib.AREAS) + r")(?:\.[a-z0-9_]+)+\.[0-9]{3}x?(?![A-Za-z0-9_])")
CATALOGUE_DOC = os.path.join("reimplementation-kit", "reference", "vector-format.md")


PENDING_REFS = collections.Counter()


class Findings:
    def __init__(self, report_files=None, quiet=False):
        self.items = []
        self.report_files = report_files
        self.quiet = quiet

    def add(self, level, rule, file, line, vid, msg):
        if self.report_files is not None and file is not None and os.path.abspath(file) not in self.report_files:
            return
        self.items.append((level, rule, file, line, vid, msg))

    def err(self, rule, file, line, vid, msg):
        self.add("ERROR", rule, file, line, vid, msg)

    def warn(self, rule, file, line, vid, msg):
        self.add("WARN", rule, file, line, vid, msg)

    def print(self, root):
        for level, rule, file, line, vid, msg in self.items:
            if self.quiet and level == "WARN":
                continue
            loc = os.path.relpath(file, root) if file else "-"
            if line:
                loc += f":{line}"
            print(f"{level} {rule} {loc}" + (f" {vid}" if vid else "") + f" {msg}")

    def count(self, level):
        return sum(1 for i in self.items if i[0] == level)


def walk(obj, path="", payload=False, parents=()):
    """Yield (path, value, in_payload, ancestors) for every node."""
    yield path, obj, payload, parents
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from walk(v, kitlib.join_path(path, k), payload or k in PAYLOAD_KEYS or k.endswith("_json"),
                            parents + (obj,))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from walk(v, kitlib.join_path(path, i), payload, parents + (obj,))


def schema_payload_paths(op_doc):
    """Top-level input property names whose schema is a payload ($ref payload / x-kit-payload)."""
    keys = set()
    for side in ("input", "output"):
        props = op_doc.get("$defs", {}).get(side, {}).get("properties", {})
        for k, s in props.items():
            if isinstance(s, dict) and (s.get("x-kit-payload") or "payload" in str(s.get("$ref", ""))):
                keys.add(k)
    return keys


def has_timezone(parents, obj, top_input):
    for o in (obj,) + tuple(parents):
        if isinstance(o, dict) and any(k == "timezone" or k.endswith("_timezone") or k == "tz" for k in o):
            return True
    return isinstance(top_input, dict) and any(k == "timezone" or k.endswith("_timezone") for k in top_input)


class Kit:
    def __init__(self, root):
        self.root = root
        self.rk = os.path.join(root, "reimplementation-kit")
        self.catalogue = kitlib.load_catalogue(root)
        self.sv = kitlib.SchemaValidator(os.path.join(self.rk, "schemas"))
        self.thresholds = kitlib.load_thresholds(os.path.join(self.rk, "acceptance", "thresholds.json"))
        kb = self.thresholds.get("kit_budget") or {}
        self.budget = {k: int(kb.get(k, v)) for k, v in BUDGET_DEFAULT.items()}
        self.scenario_limits = {k: int(kb.get(k, v)) for k, v in SCENARIO_DEFAULT.items()}
        self.holdout_ids = set()   # filled by main() once every vector is loaded
        self.allowed_uuids = set()
        p = os.path.join(self.rk, "schemas", "allowed-uuids.json")
        if os.path.exists(p):
            with open(p, encoding="utf-8") as f:
                self.allowed_uuids = {u.lower() for u in json.load(f).get("uuids", [])}
        self._defs = None

    def md_files(self):
        out = []
        for skill in ("reimplementation-kit", "billing-engine-spec", "events-processor-spec"):
            out += glob.glob(os.path.join(self.root, skill, "**", "*.md"), recursive=True)
        return sorted(out)

    def is_home(self, rule_id, path):
        """Whether `path` is the chapter that defines `rule_id` (vector-format.md section 1.1): BE-<XX> in its
        billing-engine-spec chapter, EP-* in events-processor-spec/reference, RBD-* in rebuild-decisions.md.
        An anchor anywhere else (a summary list in a SKILL.md, a chapter's RBD table) is only a mention."""
        rel = os.path.relpath(path, self.root).replace(os.sep, "/")
        if rule_id.startswith("BE-"):
            num = CHAPTER_OF.get(rule_id.split("-")[1])
            return bool(num) and rel.startswith(f"billing-engine-spec/reference/{num}-")
        if rule_id.startswith("EP-"):
            return rel.startswith("events-processor-spec/reference/")
        if rule_id.startswith("RBD-"):
            return rel == "reimplementation-kit/reference/rebuild-decisions.md"
        return True

    def definitions(self):
        """{rule_id: (file, line, line_text)} for rules defined in their home chapter texts; plus mentions."""
        if self._defs is not None:
            return self._defs
        defs, mentions = {}, collections.defaultdict(list)
        anchor = re.compile(r"^\s*(?:[-*]\s+|\|\s*|#+\s+.*?|)\**`?(BE-[A-Z]+-[0-9]+[a-z]?|EP-[A-Z][0-9]+[a-z]?|RBD-[0-9]+|KQ-[0-9]+)`?\**")
        for f in self.md_files():
            with open(f, encoding="utf-8", errors="replace") as fh:
                for n, line in enumerate(fh, 1):
                    m = anchor.match(line)
                    if m and m.group(1) not in defs and self.is_home(m.group(1), f):
                        defs[m.group(1)] = (f, n, line.rstrip("\n"))
                    for t in re.findall(r"\b(?:BE-[A-Z]+-[0-9]+[a-z]?|EP-[A-Z][0-9]+[a-z]?|RBD-[0-9]+|KQ-[0-9]+)\b", line):
                        mentions[t].append((f, n))
        self._defs = (defs, mentions)
        return self._defs

    def chapter_exists(self, rule_id):
        if rule_id.startswith("BE-"):
            code = rule_id.split("-")[1]
            num = CHAPTER_OF.get(code)
            return bool(num and glob.glob(os.path.join(self.root, "billing-engine-spec", "reference", f"{num}-*.md")))
        if rule_id.startswith("EP-"):
            return bool(glob.glob(os.path.join(self.root, "events-processor-spec", "reference", "*.md")))
        if rule_id.startswith("RBD-"):
            return os.path.exists(os.path.join(self.rk, "reference", "rebuild-decisions.md"))
        return False


def check_vector(kit, v, F, ids_all):
    o, f, ln = v.obj, v.file, v.line_no
    vid = o.get("id") if isinstance(o.get("id"), str) else None
    # SCHEMA: envelope
    for e in kit.sv.validate(o, kit.sv.load("vector.schema.json")[0], kit.sv.load("vector.schema.json")[1]):
        F.err("SCHEMA", f, ln, vid, f"envelope {e}")
    if not vid:
        return
    area = o.get("area")
    first = vid.split(".")[0]
    file_area = os.path.basename(f).split(".")[0]
    if area != first:
        F.err("ID", f, ln, vid, f"area {area!r} differs from the id prefix {first!r}")
    if file_area != first:
        F.err("ID", f, ln, vid, f"file {os.path.basename(f)} holds area {file_area!r} vectors only")
    op_name = f"{area}.{o.get('op')}"
    doc = kit.catalogue.get(op_name)
    if doc is None:
        F.err("OP", f, ln, vid, f"op {op_name} is not in schemas/ops")
    if area == "system":
        F.err("OP", f, ln, vid, "system.* ops are scenario-tier only")
    # tags
    tags = o.get("tags") or []
    for t in tags:
        if isinstance(t, str) and t not in KNOWN_TAGS:
            F.warn("TAG", f, ln, vid, f"unknown tag {t!r}")
    if not (o.get("rules") or o.get("rbd")):
        F.warn("REF", f, ln, vid, "neither rules nor rbd: the vector is not tied to a spec rule")
    # profile / pair / ruling
    prof, pair, ruling = o.get("profile"), o.get("pair"), o.get("ruling")
    if prof == "both":
        if pair is not None:
            F.err("PAIR", f, ln, vid, "profile both must have pair null")
        if vid.endswith("x"):
            F.err("PAIR", f, ln, vid, "ids ending in x are reserved for corrected twins")
        if ruling != "decided":
            F.err("PAIR", f, ln, vid, "profile both must be ruling decided")
    elif prof == "compat":
        if pair is None:
            if not o.get("notes"):
                F.err("PAIR", f, ln, vid, "a compat-only vector (pair null) needs a note saying why it has no corrected twin")
        elif pair != vid + "x":
            F.err("PAIR", f, ln, vid, f"compat vector must pair with {vid}x")
        if ruling != "decided":
            F.warn("PAIR", f, ln, vid, "compat vectors reproduce the reference: ruling should be decided")
    elif prof == "corrected":
        if pair is None:
            if not o.get("notes"):
                F.err("PAIR", f, ln, vid, "a corrected-only vector (pair null) needs a note saying why it has no compat twin")
            if not vid.endswith("x"):
                F.err("PAIR", f, ln, vid, "corrected vector ids end in x")
        elif not vid.endswith("x") or pair != vid[:-1]:
            F.err("PAIR", f, ln, vid, f"corrected twin must be <compat id>x and pair with {vid[:-1]}")
    if prof in ("compat", "corrected") and pair is not None:
        twin = ids_all.get(pair)
        if twin is None:
            F.err("PAIR", f, ln, vid, f"twin {pair} not found")
        else:
            t = twin.obj
            if t.get("pair") != vid:
                F.err("PAIR", f, ln, vid, f"twin {pair} does not point back")
            if {t.get("profile"), prof} != {"compat", "corrected"}:
                F.err("PAIR", f, ln, vid, "twins must be one compat and one corrected")
            if sorted(map(str, t.get("rules") or [])) != sorted(map(str, o.get("rules") or [])) or \
                    sorted(map(str, t.get("rbd") or [])) != sorted(map(str, o.get("rbd") or [])):
                F.err("PAIR", f, ln, vid, "twins must list the same rules and rbd")
            if t.get("op") != o.get("op"):
                F.err("PAIR", f, ln, vid, "twins must use the same op")
            if (twin.set == "holdout") != (v.set == "holdout"):
                F.err("HOLDOUT", f, ln, vid, f"twin {pair} is in the {twin.set} set and this vector in the {v.set} set: "
                                             "twins move to the holdout together")
    if prof in ("compat", "corrected") and not o.get("rbd"):
        F.err("PAIR", f, ln, vid, "a compat or corrected vector must cite its RBD")
    # REF
    defs, mentions = kit.definitions()
    for r in list(o.get("rules") or []) + list(o.get("rbd") or []):
        if not isinstance(r, str):
            continue
        if r in defs:
            continue
        if not kit.chapter_exists(r):
            if F.report_files is None or os.path.abspath(f) in F.report_files:
                PENDING_REFS[r] += 1
        elif r in mentions:
            F.warn("REF", f, ln, vid, f"{r} is mentioned but not defined (definition = list item, table cell, heading or bold anchor)")
        else:
            F.err("REF", f, ln, vid, f"{r} is not defined in its chapter")
    # op schema
    inp, exp = o.get("input"), o.get("expected")
    if doc is not None and isinstance(inp, dict) and isinstance(exp, dict):
        status = doc.get("x-kit", {}).get("status", "skeleton")
        level = F.err if status == "final" else F.warn
        sp = doc.get("_path")
        defs_ = doc.get("$defs", {})
        if "input" in defs_:
            for e in kit.sv.validate(inp, defs_["input"], sp, "input"):
                level("SCHEMA", f, ln, vid, f"{e}" + ("" if status == "final" else " (op schema is a skeleton)"))
        if kitlib.is_error_expectation(exp):
            for e in kit.sv.validate(exp["error"], kit.sv.load("common.schema.json")[0]["$defs"]["error"],
                                     kit.sv.load("common.schema.json")[1], "expected.error"):
                F.err("SCHEMA", f, ln, vid, e)
            if exp["error"].get("code") in kitlib.PROTOCOL_ERROR_CODES:
                F.err("EXPECT", f, ln, vid, f"expected error uses protocol code {exp['error'].get('code')}")
        elif "output" in defs_:
            for e in kit.sv.validate(exp, defs_["output"], sp, "expected", partial=True):
                level("SCHEMA", f, ln, vid, f"{e}" + ("" if status == "final" else " (op schema is a skeleton)"))
        if status == "final":
            props = defs_.get("input", {}).get("properties", {})
            req = set(defs_.get("input", {}).get("required", []))
            for k, s in props.items():
                if k not in req and isinstance(s, dict) and "default" not in s and "x-kit-absent" not in s:
                    # vector-format.md section 8: a final schema MUST declare what absence means
                    F.err("SCHEMA", f, ln, vid, f"optional input {k} of final op schema {op_name} declares no "
                                                f"default or x-kit-absent")
    if isinstance(exp, dict) and not exp:
        F.warn("EXPECT", f, ln, vid, "expected is {}: the vector only asserts that the op succeeds (no domain error)")
    payload_keys = schema_payload_paths(doc) if doc else set()
    # NUM-1 and TIME
    for side, tree in (("input", inp), ("expected", exp)):
        if not isinstance(tree, dict):
            continue
        for path, val, in_payload, parents in walk(tree):
            top = path.split(".")[0].split("[")[0]
            if in_payload or top in payload_keys:
                continue
            if isinstance(val, Lit) and not val.is_int:
                F.err("NUM", f, ln, vid, f"{side}.{path}: JSON float {val.text} outside a payload field (use a decimal string)")
            if isinstance(val, Lit) and val.is_int and abs(int(val.text)) >= 2 ** 53:
                F.err("NUM", f, ln, vid, f"{side}.{path}: integer beyond 2^53 (use a decimal string)")
            if isinstance(val, str):
                if kitlib.RE_DATETIME_LIKE.match(val) and not kitlib.RE_INSTANT.match(val):
                    F.err("TIME", f, ln, vid, f"{side}.{path}: {val!r} is not an instant with a zone")
                elif kitlib.RE_DATE.match(val) and not has_timezone(parents, {}, inp):
                    F.warn("TIME", f, ln, vid, f"{side}.{path}: local date without a timezone in scope")
    # compare overrides
    cmp_ = o.get("compare") or {}
    if isinstance(cmp_, dict) and isinstance(exp, dict):
        paths = [p for p, *_ in walk(exp)]
        for pat, spec in cmp_.items():
            rx, _ = kitlib._pattern_regex(pat)
            hits = [p for p in paths if rx.match(p)]
            if not hits:
                F.warn("CMP", f, ln, vid, f"compare path {pat!r} matches nothing in expected")
            mode = spec.get("mode") if isinstance(spec, dict) else None
            if mode == "abs_tol" and "tol" not in spec:
                F.err("CMP", f, ln, vid, f"{pat}: abs_tol needs tol")
            if mode == "range":
                for p in hits:
                    node = _get(exp, p)
                    if not (isinstance(node, dict) and {"min", "max"} & set(node)):
                        F.err("CMP", f, ln, vid, f"{pat}: range needs {{min,max}} in expected")
            if mode == "ignore" and pat in ("$", ""):
                F.err("CMP", f, ln, vid, "ignoring the whole output makes the vector unfalsifiable")
    # EVID
    ev = o.get("evidence") or {}
    kind, by, ref, pin = ev.get("kind"), ev.get("by"), ev.get("ref"), ev.get("pin")
    notes = (o.get("notes") or "") + (ev.get("note") or "")
    if kind == "EXECUTED" and by not in EXECUTED_BY:
        F.err("EVID", f, ln, vid, f"EXECUTED evidence cannot be by {by!r}")
    if kind == "RECOMPUTED" and by not in RECOMPUTED_BY:
        F.err("EVID", f, ln, vid, f"RECOMPUTED evidence cannot be by {by!r}")
    if kind == "EXTRACTED":
        if by not in EXTRACTED_BY:
            F.err("EVID", f, ln, vid, f"EXTRACTED evidence cannot be by {by!r}")
        if "unexecuted" not in tags or not notes:
            F.err("EVID", f, ln, vid, "EXTRACTED vectors need tag unexecuted and a note")
    if kind == "EXECUTED" and "substitute" in str(ev.get("runtime", "")):
        F.warn("EVID", f, ln, vid, "substitute runtime: re-run on the pinned toolchain")
    if kind == "RECOMPUTED" and prof != "corrected" and not notes:
        F.warn("EVID", f, ln, vid, "RECOMPUTED both/compat vector without a note saying why the oracle cannot run it")
    if prof == "corrected":
        if kind != "RECOMPUTED":
            F.err("EVID", f, ln, vid, "corrected twins are RECOMPUTED by definition")
        refs = [x.strip() for x in re.split(r"[;,]", str(ref)) if x.strip()]
        if not refs or any(x not in (o.get("rbd") or []) for x in refs):
            F.err("EVID", f, ln, vid, "corrected vector evidence.ref must list RBD ids of the vector (separated by ', ' or '; ')")
    # the pin follows the vector's AREA, not the surface under test (vector-format.md section 5)
    want_pin = kitlib.EP_PIN if area == "ep" else kitlib.BILLING_PIN
    if pin is not None and pin != want_pin:
        F.err("EVID", f, ln, vid, f"pin {pin!r} (expected {want_pin!r})")
    if area == "expression" and kind == "EXECUTED" and isinstance(inp, dict) and inp.get("mode") == "ep" \
            and "expression" not in str(ev.get("runtime", "")).lower():
        F.warn("EVID", f, ln, vid, "mode ep vector: runtime must name the events-processor expression-engine build that "
                                   "produced the value (mixed-surface convention)")
    if isinstance(ref, str):
        # several references are separated by "; " (a comma-separated RBD list also passes as one part)
        bad = [part for part in (x.strip() for x in ref.split(";")) if not any(rx.match(part) for rx in REF_FORMS)]
        if bad:
            F.warn("EVID", f, ln, vid, f"unrecognised evidence.ref form {bad[0]!r}")
    # CONTENT
    check_content(v.raw, f, ln, vid, F, tags, scenario=False, kit=kit)
    if v.set != "holdout":
        check_holdout_leak(kit, v.raw, f, ln, vid, F, exclude={vid, pair})


def check_holdout_leak(kit, text, f, ln, vid, F, exclude=()):
    """HOLDOUT: shipped text (vectors, scenarios, schemas, kit Markdown) must not mention a holdout vector id."""
    if not kit.holdout_ids:
        return
    leaked = sorted({m.group(0) for m in RE_ANY_VECTOR_ID.finditer(text)} & kit.holdout_ids - set(exclude))
    if leaked:
        F.err("HOLDOUT", f, ln, vid, f"mentions holdout vector {leaked[0]}" + (f" (+{len(leaked) - 1} more)" if len(leaked) > 1 else "")
              + ": the id would leak into a clean-room pack and resolve to nothing there")


def _get(tree, path):
    node = tree
    for tok in re.findall(r"[^.\[\]]+|\[[0-9]+\]", path):
        if tok.startswith("["):
            node = node[int(tok[1:-1])]
        else:
            node = node[tok]
    return node


def check_content(text, f, ln, vid, F, tags=(), scenario=False, kit=None, maintainer=False):
    for rx, what in FORBIDDEN:
        m = rx.search(text)
        if m:
            (F.warn if maintainer else F.err)("CONTENT", f, ln, vid, f"{what}: {m.group(0)!r}")
    if not maintainer:
        for rx, what in SECRETS:
            m = rx.search(text)
            if m and not (what == "private key" and "test-key" in (tags or [])):
                F.err("CONTENT", f, ln, vid, f"{what} in kit content (tag test-key only for the kit test key)")
    if kit is not None and not maintainer:
        for m in RE_UUID.finditer(text):
            u = m.group(0).lower()
            hexd = u.replace("-", "")
            if u in kit.allowed_uuids or collections.Counter(hexd).most_common(1)[0][1] >= 16:
                continue
            (F.err if scenario else F.warn)("CONTENT", f, ln, vid, f"UUID {u} is not a fixture id (schemas/allowed-uuids.json)")
            break
    if scenario:
        for t in INTERNAL_TABLES:
            if re.search(r"\b" + t + r"\b", text):
                F.err("CONTENT", f, ln, vid, f"internal table name {t!r} in a scenario")


def check_scenario(kit, path, F, ids_all):
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    try:
        o = kitlib.loads_lit(text)
    except ValueError as e:
        F.err("SCHEMA", path, 1, None, f"invalid JSON: {e}")
        return None
    vid = o.get("id")
    if not isinstance(vid, str) or not kitlib.RE_SCENARIO_ID.match(vid):
        F.err("ID", path, 1, None, f"bad scenario id {vid!r}")
    elif os.path.basename(path) != vid + ".json":
        F.err("ID", path, 1, vid, "scenario file name must be <id>.json")
    sp = os.path.join(kit.rk, "schemas", "scenario.schema.json")
    if os.path.exists(sp):
        for e in kit.sv.validate(o, kit.sv.load(sp)[0], sp):
            F.err("SCHEMA", path, 1, vid, e)
    else:
        for k in ("kit_schema", "id", "title", "profile", "evidence", "setup", "steps", "expect"):
            if k not in o:
                F.err("SCHEMA", path, 1, vid, f"missing {k}")
    ev = o.get("evidence") or {}
    if ev.get("kind") not in ("EXECUTED", "RECOMPUTED", "EXTRACTED"):
        F.err("EVID", path, 1, vid, "evidence.kind missing or invalid")
    compact = len(json.dumps(json.loads(text), separators=(",", ":"), ensure_ascii=False).encode("utf-8"))
    check_content(text, path, 1, vid, F, o.get("tags") or [], scenario=True, kit=kit)
    check_holdout_leak(kit, text, path, 1, vid, F)
    return vid, compact, ev.get("kind"), o


def check_text(kit, path, F):
    maintainer = "/maintainer" in path.replace(os.sep, "/") or os.path.basename(path) == "maintainer-oracle.md"
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    in_prov = False
    in_fence = False
    agpl = False
    for n, line in enumerate(lines, 1):
        if line.startswith("#"):
            in_prov = "provenance" in line.lower()
        if line.strip().startswith("```"):
            in_fence = not in_fence
        if "AGPL" in line:
            agpl = True
        check_content(line, path, n, None, F, scenario=False, kit=None, maintainer=maintainer)
        if not maintainer:
            check_holdout_leak(kit, line, path, n, None, F)
        if RE_API_CITE.search(line) and not in_prov and not maintainer and not (in_fence and '"ref"' in line):
            F.err("TEXT", path, n, None, "$API citation outside a 'Provenance (maintainers)' section")
    is_chapter = "/reference/" in path.replace(os.sep, "/") and not maintainer
    if is_chapter and not agpl:
        F.warn("TEXT", path, None, None, "chapter has no AGPL note")


def check_catalogue_doc(kit, F):
    """OP (warning): the op-catalogue table of vector-format.md section 8 lists exactly the ops of schemas/ops."""
    path = os.path.join(kit.root, CATALOGUE_DOC)
    if not os.path.exists(path):
        return
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().split("\n")
    start = next((i for i, l in enumerate(lines) if l.startswith("## 8.")), None)
    if start is None:
        return
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    listed = {}
    for i in range(start, end):
        if lines[i].startswith("|"):
            for m in re.finditer(r"`([a-z_]+\.[a-z0-9_]+)`", lines[i]):
                listed.setdefault(m.group(1), i + 1)
    for op in sorted(set(kit.catalogue) - set(listed)):
        F.warn("OP", path, start + 1, None, f"op {op} (schemas/ops) has no row in the section 8 catalogue table")
    for op, ln in sorted(listed.items()):
        if op not in kit.catalogue:
            F.warn("OP", path, ln, None, f"catalogue row names {op}, which has no schema in schemas/ops")


RE_ID_TOKEN = re.compile(r"^(?:[a-z_]+(?:\.[a-z0-9_*]+)+x?|EPC-[0-9]{2})$")


def vec_tag_ids(kit):
    """[vec: ...] tags outside code; only tokens shaped like vector/scenario ids are returned (prose is ignored);
    a tag whose text starts with 'none' or 'prose' is a prose-only marker and yields nothing."""
    out = []
    for f in kit.md_files():
        fence = False
        with open(f, encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                if line.strip().startswith("```"):
                    fence = not fence
                    continue
                if fence:
                    continue
                text = re.sub(r"`[^`]*`", "", line)
                for m in RE_VEC_TAG.finditer(text):
                    body = m.group(1).strip()
                    if re.match(r"(none|prose)", body, re.I):
                        continue
                    toks = [x.strip().rstrip(".;:") for x in re.split(r"[,\s]+", body) if x.strip()]
                    out.append((f, n, line, [t for t in toks if RE_ID_TOKEN.match(t)]))
    return out


def main(argv=None):
    ap = argparse.ArgumentParser(description="Validate kit vectors, scenarios and texts.")
    ap.add_argument("files", nargs="*")
    ap.add_argument("--kit-root", default=kitlib.skill_root_default(__file__))
    ap.add_argument("--gate", action="store_true")
    ap.add_argument("--rule-coverage", action="store_true")
    ap.add_argument("--include-holdout", default=None)
    ap.add_argument("--no-text", action="store_true")
    ap.add_argument("--inventory", action="store_true", help="print one INVENTORY line per vector file (profiles, evidence mix)")
    ap.add_argument("--quiet", action="store_true", help="print errors only")
    try:
        args = ap.parse_args(argv)
    except SystemExit as e:
        return 2 if e.code else 0
    root = os.path.abspath(args.kit_root)
    if not os.path.isdir(os.path.join(root, "reimplementation-kit")):
        print(f"usage: --kit-root {root} has no reimplementation-kit/", file=sys.stderr)
        return 2
    kit = Kit(root)
    report = {os.path.abspath(p) for p in args.files} if args.files else None
    F = Findings(report, args.quiet)

    shipped_files = kitlib.discover(root)
    holdout_files = (sorted(glob.glob(os.path.join(os.path.abspath(args.include_holdout), "*.jsonl")))
                     if args.include_holdout else kitlib.discover_holdout(root))
    selftest_files = sorted(glob.glob(os.path.join(root, "reimplementation-kit", "selftest", "*.jsonl")))
    known = set(map(os.path.abspath, shipped_files + holdout_files + selftest_files))
    extra = [os.path.abspath(p) for p in args.files if p.endswith(".jsonl") and os.path.abspath(p) not in known]
    vectors = []
    for fl, set_name in [(shipped_files, "shipped"), (holdout_files, "holdout"), (selftest_files, "selftest"),
                         (extra, "extra")]:
        for path in fl:
            vs, errs = kitlib.load_vector_file(path, set_name)
            vectors += vs
            for e in errs:
                F.err("SCHEMA", e.file, e.line_no, None, e.message)
    for p in args.files:
        if not os.path.exists(p):
            print(f"usage: no such file {p}", file=sys.stderr)
            return 2

    ids_all, seen_where = {}, {}
    for v in vectors:
        vid = v.obj.get("id")
        if not isinstance(vid, str):
            continue
        if vid in ids_all:
            prev = ids_all[vid]
            rule = "HOLDOUT" if {prev.set, v.set} == {"shipped", "holdout"} else "ID"
            F.err(rule, v.file, v.line_no, vid, f"duplicate id (also {os.path.relpath(prev.file, root)}:{prev.line_no})")
            continue
        ids_all[vid] = v
    kit.holdout_ids = {vid for vid, v in ids_all.items() if v.set == "holdout"}
    visible_ids = [vid for vid, v in ids_all.items() if v.set != "holdout"]
    by_file = collections.defaultdict(list)
    for v in vectors:
        by_file[v.file].append(v)
    for path, vs in by_file.items():
        ids = [v.obj.get("id") for v in vs if isinstance(v.obj.get("id"), str)]
        if ids != sorted(ids):
            first_bad = next(i for i in range(1, len(ids)) if ids[i] < ids[i - 1])
            bad = vs[first_bad]
            F.err("ID", path, bad.line_no, ids[first_bad], "vectors must be sorted by id")
        for v in vs:
            check_vector(kit, v, F, ids_all)
        with open(path, "rb") as fh:
            data = fh.read()
        if data and not data.endswith(b"\n"):
            F.err("SCHEMA", path, None, None, "file must end with a newline")
        if b"\r\n" in data:
            F.err("SCHEMA", path, None, None, "CRLF line endings")
        if data.startswith(b"\n") or b"\n\n" in data:
            F.err("SCHEMA", path, None, None, "blank line in a vector file (VF-1)")

    scenarios = []
    discovered = [os.path.abspath(p) for p in kitlib.discover_scenarios(root)]
    scenario_paths = list(discovered)
    for p in args.files:   # explicit scenario files outside discovery; relative and absolute spellings are one file
        a = os.path.abspath(p)
        if a.endswith(".json") and "/scenarios/" in a.replace(os.sep, "/") and a not in scenario_paths:
            scenario_paths.append(a)
    for path in scenario_paths:
        r = check_scenario(kit, path, F, ids_all)
        if r:
            scenarios.append((path,) + r)
    sl = kit.scenario_limits
    over = [s for s in scenarios if s[2] > sl["scenario_max_bytes"]]
    for s in scenarios:
        if s[2] > sl["scenario_exception_max_bytes"]:
            F.err("BUDGET", s[0], None, s[1], f"scenario is {s[2]} bytes compact (max {sl['scenario_exception_max_bytes']})")
        elif s[2] > sl["scenario_target_bytes"]:
            F.warn("BUDGET", s[0], None, s[1], f"scenario is {s[2]} bytes compact (target {sl['scenario_target_bytes']})")
    if len(over) > sl["scenario_exceptions_max"]:
        F.err("BUDGET", None, None, None, f"{len(over)} scenarios exceed {sl['scenario_max_bytes']} bytes "
                                          f"(at most {sl['scenario_exceptions_max']} may)")

    if not args.no_text:
        texts = kit.md_files() if not args.files else [os.path.abspath(p) for p in args.files if p.endswith(".md")]
        for t in texts:
            check_text(kit, t, F)
        scn_ids = [s[1] or "" for s in scenarios]
        for f, n, line, ids in (vec_tag_ids(kit) if (not args.files or texts) else []):
            for i in ids:
                if "*" in i:
                    rx = re.compile("^" + re.escape(i).replace(r"\*", ".*") + "$")
                    if any(rx.match(k) for k in visible_ids) or any(rx.match(s) for s in scn_ids):
                        continue
                    if any(rx.match(k) for k in kit.holdout_ids):
                        (F.err if args.gate else F.warn)("HOLDOUT", f, n, None, f"[vec: {i}] matches only holdout "
                                                         "vectors: a clean-room pack resolves it to nothing")
                    else:
                        (F.err if args.gate else F.warn)("REF", f, n, None, f"[vec: {i}] matches no vector")
                elif i not in ids_all and i not in scn_ids and not re.match(r"^EPC-[0-9]{2}$", i):
                    (F.err if args.gate else F.warn)("REF", f, n, None, f"[vec: {i}] is not a known vector or scenario id")
        # explicit holdout ids in [vec: ...] tags are reported by check_text (HOLDOUT, any mention of a holdout id)
        if report is None or os.path.abspath(os.path.join(root, CATALOGUE_DOC)) in report:
            check_catalogue_doc(kit, F)
    if report is None and kit.holdout_ids:
        for sp in sorted(glob.glob(os.path.join(kit.rk, "schemas", "**", "*.json"), recursive=True)):
            with open(sp, encoding="utf-8", errors="replace") as fh:
                check_holdout_leak(kit, fh.read(), sp, None, None, F)

    # BUDGET over the whole kit (holdout files count with their area: ep.* as ep units, the rest as billing units)
    def size(pattern):
        return sum(os.path.getsize(p) for p in glob.glob(os.path.join(root, pattern), recursive=True) if os.path.isfile(p))
    hold_ep = sum(os.path.getsize(p) for p in holdout_files if os.path.basename(p).startswith("ep."))
    hold_bill = sum(os.path.getsize(p) for p in holdout_files) - hold_ep
    sizes = {
        "billing_unit": size("billing-engine-spec/vectors/*.jsonl") + hold_bill,
        "scenarios": size("billing-engine-spec/scenarios/*"),
        "ep_conformance": size("events-processor-spec/conformance/**/*"),
        "ep_units": size("events-processor-spec/vectors/*.jsonl") + hold_ep,
        "schemas_meta": size("reimplementation-kit/schemas/**/*.json") + size("reimplementation-kit/acceptance/*") +
                        size("billing-engine-spec/scenarios/MANIFEST.md"),
    }
    # kit.json (one sha256 per kit file, written last at integration) counts toward the total only
    sizes["total"] = sum(sizes.values()) + size("reimplementation-kit/kit.json")
    if report is None:
        for k, cap in kit.budget.items():
            if sizes[k] > cap:
                F.err("BUDGET", None, None, None, f"{k} is {sizes[k]} bytes (cap {cap})")

    # GATE
    if args.gate:
        th = kit.thresholds.get("kit_gates", {})
        bill = [v for v in vectors if v.set in ("shipped", "holdout") and v.obj.get("area") != "ep" and v.obj.get("profile") in ("both", "compat")]
        ep = [v for v in vectors if v.set in ("shipped", "holdout") and v.obj.get("area") == "ep" and v.obj.get("profile") in ("both", "compat")]
        kinds = collections.Counter((v.obj.get("evidence") or {}).get("kind") for v in bill)
        n = len(bill) or 1
        if bill and kinds["EXECUTED"] / n < th.get("billing_unit_both_or_compat_executed_min", 0.95):
            F.err("GATE", None, None, None, f"billing EXECUTED {kinds['EXECUTED']}/{len(bill)} below {th.get('billing_unit_both_or_compat_executed_min')}")
        if bill and kinds["RECOMPUTED"] / n > th.get("billing_unit_both_or_compat_recomputed_max", 0.05):
            F.err("GATE", None, None, None, f"billing RECOMPUTED {kinds['RECOMPUTED']}/{len(bill)} above {th.get('billing_unit_both_or_compat_recomputed_max')}")
        if kinds["EXTRACTED"] > th.get("billing_unit_extracted_max", 0):
            F.err("GATE", None, None, None, f"billing EXTRACTED {kinds['EXTRACTED']} (max {th.get('billing_unit_extracted_max')})")
        sk = collections.Counter(s[3] for s in scenarios)
        if scenarios and sk["EXECUTED"] / len(scenarios) < th.get("scenarios_executed_min", 1.0):
            F.err("GATE", None, None, None, f"scenarios EXECUTED {sk['EXECUTED']}/{len(scenarios)} below {th.get('scenarios_executed_min', 1.0)}")
        # corrected twins are RECOMPUTED by definition: the ep gate, like the billing one, counts both/compat only
        ek = collections.Counter((v.obj.get("evidence") or {}).get("kind") for v in ep)
        if ep and ek["EXECUTED"] / len(ep) < th.get("ep_executed_min", 0.95):
            F.err("GATE", None, None, None, f"ep EXECUTED {ek['EXECUTED']}/{len(ep)} below {th.get('ep_executed_min')}")
        if ek["EXTRACTED"]:
            F.err("GATE", None, None, None, f"ep EXTRACTED {ek['EXTRACTED']} (max 0)")

    # COVER (holdout vectors are not coverage: a clean-room pack does not contain them)
    if args.rule_coverage:
        defs, _ = kit.definitions()
        used = collections.Counter(r for v in vectors if v.set != "holdout"
                                   for r in (v.obj.get("rules") or []) if isinstance(r, str))
        used_hold = collections.Counter(r for v in vectors if v.set == "holdout"
                                        for r in (v.obj.get("rules") or []) if isinstance(r, str))
        per_chapter = collections.defaultdict(lambda: [0, 0, 0, 0])
        for rid, (f, n, line) in sorted(defs.items()):
            if not RE_RULE.fullmatch(rid):
                continue
            key = os.path.relpath(f, root)
            per_chapter[key][0] += 1
            tag = RE_VEC_TAG.search(line)
            prose = bool(tag and re.match(r"\s*(none|prose)", tag.group(1), re.I))
            if used[rid] or (tag and not prose):
                per_chapter[key][1] += 1
            elif prose:
                per_chapter[key][2] += 1
            elif used_hold[rid]:
                per_chapter[key][3] += 1
                (F.err if args.gate else F.warn)("COVER", f, n, rid, "rule is exercised only by holdout vectors "
                                                 "(uncovered in a clean-room pack): cite a shipped vector or keep one shipped")
            else:
                (F.err if args.gate else F.warn)("COVER", f, n, rid, "rule has no vector and no prose-only marker")
        for key, (tot, cov, prose, hold) in sorted(per_chapter.items()):
            print(f"COVERAGE {key} rules={tot} with_vectors={cov} prose_only={prose} "
                  f"uncovered={tot - cov - prose - hold} holdout_only={hold}")

    for r, n in sorted(PENDING_REFS.items()):
        F.add("WARN", "REF", None, None, r, f"defining chapter not written yet ({n} vector(s) cite it)")
    if args.inventory:
        for path, vs in sorted(by_file.items()):
            if report is not None and os.path.abspath(path) not in report:
                continue
            prof = collections.Counter(v.obj.get("profile") for v in vs)
            kind = collections.Counter((v.obj.get("evidence") or {}).get("kind") for v in vs)
            print(f"INVENTORY {os.path.relpath(path, root)} vectors={len(vs)} both={prof['both']} compat={prof['compat']} "
                  f"corrected={prof['corrected']} EXECUTED={kind['EXECUTED']} RECOMPUTED={kind['RECOMPUTED']} "
                  f"EXTRACTED={kind['EXTRACTED']} bytes={os.path.getsize(path)}")
    F.print(root)
    nfiles = len(by_file) + len(scenarios)
    shown = [v for v in vectors if report is None or os.path.abspath(v.file) in report]
    print(f"SIZES " + " ".join(f"{k}={sizes[k]}" for k in kit.budget))
    print(f"SUMMARY validate-vectors: files={nfiles if report is None else len(report)} vectors={len(shown)} "
          f"scenarios={len(scenarios)} errors={F.count('ERROR')} warnings={F.count('WARN')}")
    return 1 if F.count("ERROR") else 0


if __name__ == "__main__":
    sys.exit(main())
