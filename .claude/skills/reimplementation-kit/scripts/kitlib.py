"""kitlib — shared helpers of the re-implementation kit runners (Python >= 3.10, standard library only).

Imported by kitrun.py, validate-vectors.py, adapter_ref.py and the maintainer scripts. Contents:

* literal-preserving JSON: ``loads_lit`` keeps every JSON number as a ``Lit`` (its exact source text), ``dumps_lit``
  writes it back unchanged; ``member_spans`` returns the raw text span of each top-level member of an object, so the
  runner can forward ``input`` byte-for-byte;
* vector discovery and loading (``discover``, ``load_vector_file``);
* value grammars (canonical decimal, instant, local date) and instant arithmetic with nanosecond precision;
* the comparison engine of vector-format.md section 4 (``Comparator``);
* a JSON-Schema subset validator (``SchemaValidator``) for the kit schemas;
* the op catalogue and threshold loaders.

Behaviour of every function is part of the kit contract described in reference/vector-format.md and
reference/adapter-protocol.md; change them only together with those documents.
"""
from __future__ import annotations

import datetime as _dt
import decimal
import glob
import json
import os
import re
from dataclasses import dataclass, field
from decimal import Decimal, ROUND_HALF_UP

KITLIB_VERSION = "1.0.0"
PROTO = 1
KIT_SCHEMA = 1
BILLING_PIN = "591ae9005110"
EP_PIN = "ep:83e012866f29"

AREAS = ["domain", "events", "expression", "aggregation", "pricing", "periods", "invoice", "credit_notes", "wallets",
         "progressive", "alerts", "api", "webhooks", "clock", "ep"]
RE_VECTOR_ID = re.compile(r"^(" + "|".join(AREAS) + r")(\.[a-z0-9_]+)+\.[0-9]{3}x?$")
RE_SCENARIO_ID = re.compile(r"^scn(\.[a-z0-9_]+)+\.[0-9]{3}x?$")
RE_DECIMAL = re.compile(r"^-?(0|[1-9][0-9]*)(\.[0-9]+)?$")
RE_DECIMAL_LOOSE = re.compile(r"^[-+]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][-+]?[0-9]+)?$")
RE_INSTANT = re.compile(r"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2}):([0-9]{2})(\.([0-9]{1,9}))?(Z|[+-][0-9]{2}:[0-9]{2})$")
RE_DATETIME_LIKE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9]{2}:[0-9]{2}")
RE_DATE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
PROTOCOL_ERROR_CODES = {"unsupported_op", "bad_input", "internal"}
COMPARE_MODES = {"exact", "text", "numeric", "float64", "abs_tol", "range", "instant", "set", "ignore", "subset", "strict"}

decimal.getcontext().prec = 80


# ---------------------------------------------------------------------------------------------------------------
# Literal-preserving JSON
# ---------------------------------------------------------------------------------------------------------------
class Lit:
    """A JSON number with its exact source text."""

    __slots__ = ("text", "is_int")

    def __init__(self, text: str, is_int: bool):
        self.text = text
        self.is_int = is_int

    def dec(self) -> Decimal:
        return Decimal(self.text)

    def __repr__(self) -> str:
        return self.text

    def __eq__(self, other):  # structural equality used by tests only
        return isinstance(other, Lit) and other.text == self.text

    def __hash__(self):
        return hash(self.text)


def _reject_constant(name):
    raise ValueError(f"non-standard JSON constant {name}")


def loads_lit(text: str):
    """Parse JSON keeping numbers as Lit (exact text). Rejects NaN/Infinity."""
    return json.loads(text, parse_float=lambda s: Lit(s, False), parse_int=lambda s: Lit(s, True),
                      parse_constant=_reject_constant)


def dumps_lit(obj, sort_keys: bool = False) -> str:
    """Compact JSON text; Lit numbers are written with their original spelling."""
    if isinstance(obj, Lit):
        return obj.text
    if obj is None:
        return "null"
    if obj is True:
        return "true"
    if obj is False:
        return "false"
    if isinstance(obj, (int, float)):
        return json.dumps(obj)
    if isinstance(obj, Decimal):
        return canonical_decimal(obj)
    if isinstance(obj, str):
        return json.dumps(obj, ensure_ascii=False)
    if isinstance(obj, dict):
        items = sorted(obj.items()) if sort_keys else obj.items()
        return "{" + ",".join(json.dumps(str(k), ensure_ascii=False) + ":" + dumps_lit(v, sort_keys) for k, v in items) + "}"
    if isinstance(obj, (list, tuple)):
        return "[" + ",".join(dumps_lit(v, sort_keys) for v in obj) + "]"
    raise TypeError(f"cannot encode {type(obj).__name__}")


def to_plain(obj):
    """Lit -> int / Decimal, recursively (for code that does arithmetic)."""
    if isinstance(obj, Lit):
        return int(obj.text) if obj.is_int else Decimal(obj.text)
    if isinstance(obj, dict):
        return {k: to_plain(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [to_plain(v) for v in obj]
    return obj


_WS = " \t\r\n"


def _skip_ws(s: str, i: int) -> int:
    while i < len(s) and s[i] in _WS:
        i += 1
    return i


def _scan_string(s: str, i: int) -> int:
    """s[i] == '"'; return index just past the closing quote."""
    i += 1
    n = len(s)
    while i < n:
        c = s[i]
        if c == "\\":
            i += 2
            continue
        if c == '"':
            return i + 1
        i += 1
    raise ValueError("unterminated string")


def _scan_value(s: str, i: int) -> int:
    """Return the index just past the JSON value starting at s[i]."""
    i = _skip_ws(s, i)
    if i >= len(s):
        raise ValueError("unexpected end of text")
    c = s[i]
    if c == '"':
        return _scan_string(s, i)
    if c in "{[":
        depth = 0
        n = len(s)
        while i < n:
            c = s[i]
            if c == '"':
                i = _scan_string(s, i)
                continue
            if c in "{[":
                depth += 1
            elif c in "}]":
                depth -= 1
                if depth == 0:
                    return i + 1
            i += 1
        raise ValueError("unbalanced brackets")
    j = i
    while j < len(s) and s[j] not in ",}] \t\r\n":
        j += 1
    if j == i:
        raise ValueError(f"unexpected character {c!r} at {i}")
    return j


def member_spans(text: str) -> dict:
    """Raw text span (start, end) of every top-level member value of a JSON object text."""
    spans = {}
    i = _skip_ws(text, 0)
    if i >= len(text) or text[i] != "{":
        raise ValueError("not a JSON object")
    i += 1
    while True:
        i = _skip_ws(text, i)
        if i < len(text) and text[i] == "}":
            return spans
        if i >= len(text) or text[i] != '"':
            raise ValueError(f"expected a member name at {i}")
        j = _scan_string(text, i)
        key = json.loads(text[i:j])
        i = _skip_ws(text, j)
        if i >= len(text) or text[i] != ":":
            raise ValueError(f"expected ':' at {i}")
        start = _skip_ws(text, i + 1)
        end = _scan_value(text, start)
        spans[key] = (start, end)
        i = _skip_ws(text, end)
        if i < len(text) and text[i] == ",":
            i += 1
            continue
        if i < len(text) and text[i] == "}":
            return spans
        raise ValueError(f"expected ',' or '}}' at {i}")


# ---------------------------------------------------------------------------------------------------------------
# Value grammars
# ---------------------------------------------------------------------------------------------------------------
def canonical_decimal(d) -> str:
    """Canonical decimal text: no exponent, no '+', '-0' -> '0'. Trailing zeros are kept as given."""
    if isinstance(d, Lit):
        d = d.dec()
    if not isinstance(d, Decimal):
        d = Decimal(str(d))
    if not d.is_finite():
        raise ValueError("non-finite decimal")
    s = format(d, "f")
    if s.startswith("-") and Decimal(s) == 0:
        s = s[1:]
    return s


def as_decimal(v):
    """Decimal from a decimal string (loose: exponent allowed), Lit or int; None when not numeric."""
    if isinstance(v, Lit):
        return v.dec()
    if isinstance(v, bool) or v is None:
        return None
    if isinstance(v, int):
        return Decimal(v)
    if isinstance(v, Decimal):
        return v
    if isinstance(v, str) and RE_DECIMAL_LOOSE.match(v):
        try:
            return Decimal(v)
        except decimal.InvalidOperation:
            return None
    return None


def round_half_away(d: Decimal, places: int) -> Decimal:
    """Round half away from zero at `places` decimal places (Decimal ROUND_HALF_UP is away from zero)."""
    return d.quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)


def parse_instant(s):
    """(epoch_seconds:int, nanos:int) of an instant string, or None when it does not match the grammar."""
    if not isinstance(s, str):
        return None
    m = RE_INSTANT.match(s)
    if not m:
        return None
    y, mo, d, h, mi, se = (int(m.group(k)) for k in range(1, 7))
    frac = (m.group(8) or "").ljust(9, "0")
    zone = m.group(9)
    try:
        base = _dt.datetime(y, mo, d, h, mi, min(se, 59), tzinfo=_dt.timezone.utc)
    except ValueError:
        return None
    secs = int(base.timestamp()) + (1 if se == 60 else 0)
    if zone != "Z":
        sign = 1 if zone[0] == "+" else -1
        oh, om = int(zone[1:3]), int(zone[4:6])
        secs -= sign * (oh * 3600 + om * 60)
    return secs, int(frac)


def format_instant(secs: int, nanos: int = 0) -> str:
    t = _dt.datetime.fromtimestamp(secs, tz=_dt.timezone.utc)
    s = t.strftime("%Y-%m-%dT%H:%M:%S")
    if nanos:
        s += "." + f"{nanos:09d}".rstrip("0")
    return s + "Z"


def value_kind(v) -> str:
    """Default compare class of an expected value (vector-format.md section 4.1)."""
    if isinstance(v, bool):
        return "bool"
    if v is None:
        return "null"
    if isinstance(v, Lit):
        return "int" if v.is_int else "number"
    if isinstance(v, int):
        return "int"
    if isinstance(v, str):
        if RE_DECIMAL.match(v):
            return "decimal"
        if RE_INSTANT.match(v):
            return "instant"
        return "text"
    if isinstance(v, dict):
        return "object"
    if isinstance(v, list):
        return "array"
    return "other"


def show(v) -> str:
    try:
        t = dumps_lit(v)
    except TypeError:
        t = repr(v)
    return t if len(t) <= 120 else t[:117] + "..."


def is_error_expectation(expected) -> bool:
    return isinstance(expected, dict) and list(expected.keys()) == ["error"] and isinstance(expected["error"], dict)


# ---------------------------------------------------------------------------------------------------------------
# Comparison engine
# ---------------------------------------------------------------------------------------------------------------
def _pattern_regex(pat: str):
    p = pat.strip()
    if p.startswith("$."):
        p = p[2:]
    elif p.startswith("$["):
        p = p[1:]
    if p == "$":
        return re.compile(r"^$"), 0
    wild = p.count("*")
    rx = re.escape(p)
    rx = rx.replace(r"\[\*\]", r"\[[0-9]+\]")
    rx = re.sub(r"(^|\\\.)\\\*(?=\\\.|\\\[|$)", lambda m: m.group(1) + r"[^.\[]+", rx)
    return re.compile("^" + rx + "$"), wild


def join_path(base: str, key) -> str:
    if isinstance(key, int):
        return f"{base}[{key}]"
    return f"{base}.{key}" if base else str(key)


@dataclass
class Comparator:
    """Compares an expected value with an actual one per vector-format.md section 4."""

    compare: dict = field(default_factory=dict)
    strict: bool = False
    warnings: list = field(default_factory=list)

    def __post_init__(self):
        self._rules = []
        for pat, spec in (self.compare or {}).items():
            rx, wild = _pattern_regex(pat)
            self._rules.append((wild, rx, spec, pat))
        self._rules.sort(key=lambda r: r[0])

    def spec_for(self, path: str):
        for _wild, rx, spec, _pat in self._rules:
            if rx.match(path):
                return spec
        return None

    def run(self, expected, actual) -> list:
        diffs: list = []
        self._cmp(expected, actual, "", diffs, present=True)
        return diffs

    # -- helpers ------------------------------------------------------------------------------------------------
    def _label(self, path):
        return path or "$"

    def _num_warn(self, path, act):
        if isinstance(act, Lit) and not act.is_int:
            self.warnings.append(f"NUM-OUT {self._label(path)}: JSON number {act.text} (decimals should be strings)")

    def _cmp(self, exp, act, path, diffs, present):
        spec = self.spec_for(path)
        mode = spec.get("mode") if spec else None
        if mode == "ignore":
            return
        if not present:
            if exp is None and mode is None:
                return
            diffs.append(f"{self._label(path)}: expected {show(exp)} got <missing>")
            return
        if mode in (None, "subset", "strict"):
            self._default(exp, act, path, diffs, mode)
            return
        handler = getattr(self, "_m_" + mode, None)
        if handler is None:
            diffs.append(f"{self._label(path)}: unknown compare mode {mode!r}")
            return
        handler(exp, act, path, diffs, spec)

    def _default(self, exp, act, path, diffs, mode):
        kind = value_kind(exp)
        label = self._label(path)
        if kind == "object":
            if not isinstance(act, dict):
                diffs.append(f"{label}: expected an object got {show(act)}")
                return
            for k, v in exp.items():
                self._cmp(v, act.get(k), join_path(path, k), diffs, present=k in act)
            strict = mode == "strict" or (self.strict and mode != "subset")
            if strict:
                extra = [k for k in act if k not in exp]
                if extra:
                    diffs.append(f"{label}: unexpected keys {sorted(extra)} (strict)")
            return
        if kind == "array":
            if not isinstance(act, list):
                diffs.append(f"{label}: expected an array got {show(act)}")
                return
            if len(act) != len(exp):
                diffs.append(f"{label}: expected {len(exp)} elements got {len(act)}")
                return
            for i, (e, a) in enumerate(zip(exp, act)):
                self._cmp(e, a, join_path(path, i), diffs, present=True)
            return
        if kind == "int":
            ea = as_decimal(exp)
            if isinstance(act, Lit) or (isinstance(act, int) and not isinstance(act, bool)):
                aa = as_decimal(act)
                if aa == ea and aa == aa.to_integral_value():
                    if isinstance(act, Lit) and not act.is_int:
                        self.warnings.append(f"NUM-OUT {label}: integer field returned as {act.text}")
                    return
            diffs.append(f"{label}: expected {show(exp)} (integer) got {show(act)}")
            return
        if kind in ("decimal", "number"):
            aa = as_decimal(act)
            if aa is not None and not isinstance(act, bool):
                self._num_warn(path, act)
                if aa == as_decimal(exp):
                    return
            diffs.append(f"{label}: expected {show(exp)} (numeric) got {show(act)}")
            return
        if kind == "instant":
            if parse_instant(act) is not None and parse_instant(act) == parse_instant(exp):
                return
            diffs.append(f"{label}: expected {show(exp)} (instant) got {show(act)}")
            return
        if kind == "text":
            if isinstance(act, str) and act == exp:
                return
            diffs.append(f"{label}: expected {show(exp)} (text) got {show(act)}")
            return
        if kind == "bool":
            if isinstance(act, bool) and act == exp:
                return
            diffs.append(f"{label}: expected {show(exp)} got {show(act)}")
            return
        if kind == "null":
            if act is None:
                return
            diffs.append(f"{label}: expected null got {show(act)}")
            return
        diffs.append(f"{label}: cannot compare expected {show(exp)}")

    # -- explicit modes ----------------------------------------------------------------------------------------
    def _m_exact(self, exp, act, path, diffs, spec):
        if not _json_equal(exp, act):
            diffs.append(f"{self._label(path)}: expected {show(exp)} (exact) got {show(act)}")

    def _m_text(self, exp, act, path, diffs, spec):
        et = exp.text if isinstance(exp, Lit) else exp
        at = act.text if isinstance(act, Lit) else act
        if not isinstance(et, str):
            diffs.append(f"{self._label(path)}: text mode needs a string or number in expected")
            return
        if not (isinstance(at, str) and at == et):
            diffs.append(f"{self._label(path)}: expected {show(exp)} (text) got {show(act)}")

    def _m_numeric(self, exp, act, path, diffs, spec):
        ea, aa = as_decimal(exp), as_decimal(act)
        if ea is None:
            diffs.append(f"{self._label(path)}: numeric mode needs a decimal in expected")
            return
        if aa is None or isinstance(act, bool):
            diffs.append(f"{self._label(path)}: expected {show(exp)} (numeric) got {show(act)}")
            return
        self._num_warn(path, act)
        scale = spec.get("scale")
        if scale is not None:
            s = int(scale.text) if isinstance(scale, Lit) else int(scale)
            ea, aa = round_half_away(ea, s), round_half_away(aa, s)
        if ea != aa:
            extra = f", scale {scale}" if scale is not None else ""
            diffs.append(f"{self._label(path)}: expected {show(exp)} (numeric{extra}) got {show(act)}")

    def _m_float64(self, exp, act, path, diffs, spec):
        ea, aa = as_decimal(exp), as_decimal(act)
        if ea is None or aa is None or isinstance(act, bool):
            diffs.append(f"{self._label(path)}: expected {show(exp)} (float64) got {show(act)}")
            return
        if float(ea) != float(aa):
            diffs.append(f"{self._label(path)}: expected {show(exp)} (float64) got {show(act)}")

    def _m_abs_tol(self, exp, act, path, diffs, spec):
        ea, aa = as_decimal(exp), as_decimal(act)
        tol = as_decimal(spec.get("tol", "0"))
        if ea is None or aa is None or tol is None or isinstance(act, bool):
            diffs.append(f"{self._label(path)}: expected {show(exp)} (abs_tol) got {show(act)}")
            return
        if abs(ea - aa) > tol:
            diffs.append(f"{self._label(path)}: expected {show(exp)} +/- {canonical_decimal(tol)} got {show(act)}")

    def _m_range(self, exp, act, path, diffs, spec):
        if not isinstance(exp, dict) or not ({"min", "max"} & set(exp)):
            diffs.append(f"{self._label(path)}: range mode needs {{min, max}} in expected")
            return
        aa = as_decimal(act)
        lo, hi = as_decimal(exp.get("min")), as_decimal(exp.get("max"))
        if aa is None or isinstance(act, bool) or (lo is not None and aa < lo) or (hi is not None and aa > hi):
            diffs.append(f"{self._label(path)}: expected within [{show(exp.get('min'))}, {show(exp.get('max'))}] got {show(act)}")

    def _m_instant(self, exp, act, path, diffs, spec):
        pe, pa = parse_instant(exp), parse_instant(act)
        if pe is None:
            diffs.append(f"{self._label(path)}: instant mode needs an instant in expected")
        elif pa != pe:
            diffs.append(f"{self._label(path)}: expected {show(exp)} (instant) got {show(act)}")

    def _m_set(self, exp, act, path, diffs, spec):
        label = self._label(path)
        if not isinstance(exp, list) or not isinstance(act, list):
            diffs.append(f"{label}: set mode needs arrays, got {show(act)}")
            return
        if len(exp) != len(act):
            diffs.append(f"{label}: expected {len(exp)} elements (set) got {len(act)}")
            return
        # Maximum bipartite matching (augmenting paths), not greedy: with subset object comparison one expected element
        # can match several actual elements, and a greedy pick could steal the only match of a later element.
        ok = []
        for i, e in enumerate(exp):
            row = []
            for a in act:
                probe: list = []
                Comparator(self.compare, self.strict)._cmp(e, a, f"{path}[{i}]", probe, present=True)
                row.append(not probe)
            ok.append(row)
        owner = [None] * len(act)  # owner[j] = expected index matched to actual j

        def augment(i, seen):
            for j in range(len(act)):
                if ok[i][j] and j not in seen:
                    seen.add(j)
                    if owner[j] is None or augment(owner[j], seen):
                        owner[j] = i
                        return True
            return False

        for i, e in enumerate(exp):
            if not augment(i, set()):
                diffs.append(f"{label}: no actual element matches expected {show(e)} (set)")
                return


def _json_equal(a, b) -> bool:
    if isinstance(a, Lit) or isinstance(b, Lit):
        if not (isinstance(a, (Lit, int)) and isinstance(b, (Lit, int))) or isinstance(a, bool) or isinstance(b, bool):
            return False
        ai = a.is_int if isinstance(a, Lit) else True
        bi = b.is_int if isinstance(b, Lit) else True
        return ai == bi and as_decimal(a) == as_decimal(b)
    if isinstance(a, bool) or isinstance(b, bool):
        return a is b
    if isinstance(a, dict):
        return isinstance(b, dict) and a.keys() == b.keys() and all(_json_equal(a[k], b[k]) for k in a)
    if isinstance(a, list):
        return isinstance(b, list) and len(a) == len(b) and all(_json_equal(x, y) for x, y in zip(a, b))
    return type(a) is type(b) and a == b


def compare_result(expected, result_msg: dict, compare=None, strict=False):
    """Grade one adapter result against a vector's expected value.

    Returns (status, diffs, warnings) with status in PASS, FAIL, ERROR, SKIP."""
    warnings: list = []
    err = result_msg.get("error")
    out = result_msg.get("output")
    if err is not None:
        if not isinstance(err, dict) or not isinstance(err.get("code"), str):
            return "ERROR", ["adapter error without a string code"], warnings
        code = err["code"]
        if code == "unsupported_op":
            return "SKIP", [f"adapter: unsupported_op {err.get('message', '')}".strip()], warnings
        if code in ("bad_input", "internal"):
            return "ERROR", [f"adapter error {code}: {err.get('message', '')}".strip()], warnings
        if not is_error_expectation(expected):
            return "FAIL", [f"$: expected an output, got error {code}" + (f" (field {err.get('field')})" if err.get("field") else "")], warnings
        want = expected["error"]
        diffs = []
        if want.get("code") != code:
            diffs.append(f"error.code: expected {show(want.get('code'))} got {show(code)}")
        if "field" in want and want["field"] != err.get("field"):
            diffs.append(f"error.field: expected {show(want['field'])} got {show(err.get('field'))}")
        return ("FAIL" if diffs else "PASS"), diffs, warnings
    if out is None or not isinstance(out, dict):
        return "ERROR", ["result has neither an output object nor an error"], warnings
    if is_error_expectation(expected):
        return "FAIL", [f"$: expected error {show(expected['error'].get('code'))}, got an output"], warnings
    cmp = Comparator(compare or {}, strict)
    diffs = cmp.run(expected, out)
    return ("FAIL" if diffs else "PASS"), diffs, cmp.warnings


# ---------------------------------------------------------------------------------------------------------------
# Vector files
# ---------------------------------------------------------------------------------------------------------------
@dataclass
class Vector:
    file: str
    line_no: int
    raw: str
    obj: dict
    set: str = "shipped"

    @property
    def id(self):
        return self.obj.get("id")

    @property
    def area(self):
        return self.obj.get("area")

    @property
    def op(self):
        return self.obj.get("op")

    def raw_member(self, key):
        s, e = member_spans(self.raw)[key]
        return self.raw[s:e]


@dataclass
class LoadError:
    file: str
    line_no: int
    message: str


def load_vector_file(path: str, set_name: str = "shipped"):
    vectors, errors = [], []
    with open(path, encoding="utf-8") as f:
        for n, line in enumerate(f, 1):
            text = line.rstrip("\n").rstrip("\r")
            if not text.strip():
                continue
            try:
                obj = loads_lit(text)
                if not isinstance(obj, dict):
                    raise ValueError("line is not a JSON object")
                member_spans(text)
            except (ValueError, json.JSONDecodeError) as e:
                errors.append(LoadError(path, n, f"invalid JSON: {e}"))
                continue
            vectors.append(Vector(path, n, text, obj, set_name))
    return vectors, errors


def skill_root_default(script_file: str) -> str:
    """The skills directory that holds reimplementation-kit/ (two levels above scripts/)."""
    here = os.path.dirname(os.path.abspath(script_file))
    while os.path.basename(here) != "reimplementation-kit" and here != os.path.dirname(here):
        here = os.path.dirname(here)
    return os.path.dirname(here)


def discover(kit_root: str):
    """Shipped unit-vector files: <kit_root>/<skill>/vectors/*.jsonl (sorted)."""
    return sorted(glob.glob(os.path.join(kit_root, "*", "vectors", "*.jsonl")))


def discover_holdout(kit_root: str):
    return sorted(glob.glob(os.path.join(kit_root, "reimplementation-kit", "maintainer-data", "holdout", "*.jsonl")))


def discover_scenarios(kit_root: str):
    return sorted(glob.glob(os.path.join(kit_root, "*", "scenarios", "scn.*.json")))


def kit_version(kit_root: str) -> str:
    p = os.path.join(kit_root, "reimplementation-kit", "kit.json")
    try:
        with open(p, encoding="utf-8") as f:
            return str(json.load(f).get("kit_version", "1.0.0-dev"))
    except (OSError, ValueError):
        return "1.0.0-dev"


def load_catalogue(kit_root: str) -> dict:
    """{"area.op": schema_document} from reimplementation-kit/schemas/ops/*.schema.json."""
    cat = {}
    for p in sorted(glob.glob(os.path.join(kit_root, "reimplementation-kit", "schemas", "ops", "*.schema.json"))):
        name = os.path.basename(p)[: -len(".schema.json")]
        try:
            with open(p, encoding="utf-8") as f:
                doc = json.load(f)
        except (OSError, ValueError) as e:
            doc = {"x-kit": {"status": "broken"}, "_error": str(e)}
        doc["_path"] = p
        cat[name] = doc
    return cat


def load_thresholds(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as f:
            return json.load(f)
    except (OSError, ValueError):
        return {"default": {"shipped": 0.95, "holdout": 0.90, "core": 1.0}, "areas": {}}


def threshold_for(th: dict, area: str, set_name: str):
    a = th.get("areas", {}).get(area) or th.get("default", {})
    return a.get(set_name, th.get("default", {}).get(set_name)), a.get("core", 1.0)


def op_supported(op_name: str, ops) -> bool:
    if not ops:
        return False
    area = op_name.split(".", 1)[0]
    return "*" in ops or op_name in ops or f"{area}.*" in ops


# ---------------------------------------------------------------------------------------------------------------
# JSON Schema subset validator
# ---------------------------------------------------------------------------------------------------------------
class SchemaValidator:
    """Validates the JSON-Schema subset used by the kit: type, enum, const, pattern, min/maxLength, minimum,
    maximum, required, properties, additionalProperties, items, min/maxItems, oneOf, anyOf, allOf, not, $ref
    (relative file + JSON pointer). `partial=True` ignores `required` (expected values are subsets)."""

    def __init__(self, schemas_dir: str):
        self.dir = schemas_dir
        self._cache: dict = {}

    def load(self, rel_or_abs: str, base: str | None = None):
        # Always an absolute path: same-document refs ("#/$defs/x") re-load the base path as given, which must not be
        # re-joined onto self.dir when the validator was created with a relative directory.
        path = rel_or_abs if os.path.isabs(rel_or_abs) else os.path.abspath(
            os.path.join(os.path.dirname(base) if base else self.dir, rel_or_abs))
        if path not in self._cache:
            with open(path, encoding="utf-8") as f:
                self._cache[path] = json.load(f)
        return self._cache[path], path

    def _resolve(self, ref: str, base_path: str):
        file_part, _, pointer = ref.partition("#")
        if file_part:
            doc, path = self.load(file_part, base_path)
        else:
            doc, path = self.load(base_path)
        node = doc
        for tok in [t for t in pointer.split("/") if t]:
            tok = tok.replace("~1", "/").replace("~0", "~")
            node = node[tok]
        return node, path

    def validate(self, instance, schema, base_path: str, path: str = "$", partial: bool = False) -> list:
        errs: list = []
        self._v(instance, schema, base_path, path, partial, errs)
        return errs

    @staticmethod
    def _type_ok(inst, t) -> bool:
        if t == "object":
            return isinstance(inst, dict)
        if t == "array":
            return isinstance(inst, list)
        if t == "string":
            return isinstance(inst, str)
        if t == "boolean":
            return isinstance(inst, bool)
        if t == "null":
            return inst is None
        if t == "integer":
            return (isinstance(inst, Lit) and inst.is_int) or (isinstance(inst, int) and not isinstance(inst, bool))
        if t == "number":
            return isinstance(inst, Lit) or (isinstance(inst, (int, float)) and not isinstance(inst, bool))
        return False

    def _v(self, inst, sch, base, path, partial, errs):
        if sch is True or sch == {}:
            return
        if sch is False:
            errs.append(f"{path}: not allowed")
            return
        if sch.get("x-kit-payload"):
            return
        if "$ref" in sch:
            target, tpath = self._resolve(sch["$ref"], base)
            self._v(inst, target, tpath, path, partial, errs)
        if "type" in sch:
            types = sch["type"] if isinstance(sch["type"], list) else [sch["type"]]
            if not any(self._type_ok(inst, t) for t in types):
                errs.append(f"{path}: expected type {'|'.join(types)} got {show(inst)}")
                return
        if "const" in sch and not _json_equal(_from_plain(sch["const"]), inst):
            errs.append(f"{path}: expected constant {json.dumps(sch['const'])} got {show(inst)}")
        if "enum" in sch and not any(_json_equal(_from_plain(e), inst) for e in sch["enum"]):
            errs.append(f"{path}: {show(inst)} not in {json.dumps(sch['enum'])}")
        if isinstance(inst, str):
            if "pattern" in sch and not re.search(sch["pattern"], inst):
                errs.append(f"{path}: {show(inst)} does not match {sch['pattern']}")
            if "minLength" in sch and len(inst) < sch["minLength"]:
                errs.append(f"{path}: shorter than {sch['minLength']}")
            if "maxLength" in sch and len(inst) > sch["maxLength"]:
                errs.append(f"{path}: longer than {sch['maxLength']}")
        if isinstance(inst, Lit) or (isinstance(inst, (int, float)) and not isinstance(inst, bool)):
            v = as_decimal(inst) if isinstance(inst, Lit) else Decimal(str(inst))
            if "minimum" in sch and v < Decimal(str(sch["minimum"])):
                errs.append(f"{path}: below minimum {sch['minimum']}")
            if "maximum" in sch and v > Decimal(str(sch["maximum"])):
                errs.append(f"{path}: above maximum {sch['maximum']}")
        if isinstance(inst, dict):
            if not partial:
                for k in sch.get("required", []):
                    if k not in inst:
                        errs.append(f"{path}: missing required '{k}'")
            props = sch.get("properties", {})
            addl = sch.get("additionalProperties", True)
            for k, v in inst.items():
                if k in props:
                    self._v(v, props[k], base, f"{path}.{k}", partial, errs)
                elif addl is False:
                    errs.append(f"{path}: unexpected property '{k}'")
                elif isinstance(addl, dict):
                    self._v(v, addl, base, f"{path}.{k}", partial, errs)
        if isinstance(inst, list):
            if "minItems" in sch and len(inst) < sch["minItems"]:
                errs.append(f"{path}: fewer than {sch['minItems']} items")
            if "maxItems" in sch and len(inst) > sch["maxItems"]:
                errs.append(f"{path}: more than {sch['maxItems']} items")
            if isinstance(sch.get("items"), dict):
                for i, v in enumerate(inst):
                    self._v(v, sch["items"], base, f"{path}[{i}]", partial, errs)
        for sub in sch.get("allOf", []):
            self._v(inst, sub, base, path, partial, errs)
        if "anyOf" in sch:
            if not any(not self.validate(inst, s, base, path, partial) for s in sch["anyOf"]):
                errs.append(f"{path}: {show(inst)} matches none of anyOf")
        if "oneOf" in sch:
            n = sum(1 for s in sch["oneOf"] if not self.validate(inst, s, base, path, partial))
            if n != 1:
                errs.append(f"{path}: matches {n} of oneOf (need exactly 1)")
        if "not" in sch and not self.validate(inst, sch["not"], base, path, partial):
            errs.append(f"{path}: matches a forbidden schema")


def _from_plain(v):
    """Schema constants (plain JSON) -> Lit form, so they compare with literal-parsed instances."""
    if isinstance(v, bool) or v is None or isinstance(v, str):
        return v
    if isinstance(v, int):
        return Lit(str(v), True)
    if isinstance(v, float):
        return Lit(repr(v), False)
    if isinstance(v, list):
        return [_from_plain(x) for x in v]
    if isinstance(v, dict):
        return {k: _from_plain(x) for k, x in v.items()}
    return v
