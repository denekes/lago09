"""Expression language of billable metrics (processor surface).

Numbers are exact decimals (significand, scale); strings never convert unless they come from a property.
"""
import re
from math import gcd


class ParseError(Exception):
    pass


class EvalError(Exception):
    pass


class Dec:
    """c * 10**-s with s possibly negative."""
    __slots__ = ("c", "s")

    def __init__(self, c, s=0):
        self.c = c
        self.s = s

    def is_zero(self):
        return self.c == 0


def dec_from_text(t):
    """Parse a decimal text: optional sign, digits with optional fraction, optional exponent."""
    m = re.match(r"^([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d+))?$", t)
    ip, fp = m.group(2), m.group(3) or ""
    c = int((ip + fp) or "0")
    if m.group(1) == "-":
        c = -c
    s = len(fp) - int(m.group(4) or 0)
    return Dec(c, s)


# ------------------------------------------------------------------ number text (BE-EX-21)

def num_text(n):
    c, s = n.c, n.s
    digits = str(abs(c))
    nd = len(digits)
    neg = "-" if c < 0 else ""
    if c == 0:
        return "0" if s <= 0 else "0." + "0" * s
    if s - nd > 5:
        m = digits[0] + ("." + digits[1:] if nd > 1 else "")
        return "%s%sE%d" % (neg, m, nd - 1 - s)
    if s < -15:
        return "%s%se+%d" % (neg, digits, -s)
    if s <= 0:
        return neg + digits + "0" * (-s)
    if s >= nd:
        return neg + "0." + "0" * (s - nd) + digits
    return neg + digits[:nd - s] + "." + digits[nd - s:]


# ------------------------------------------------------------------ arithmetic

def add(a, b, sign=1):
    s = max(a.s, b.s)
    return Dec(a.c * 10 ** (s - a.s) + sign * b.c * 10 ** (s - b.s), s)


def mul(a, b):
    return Dec(a.c * b.c, a.s + b.s)


def _round_half_away(n, d):
    """n/d (d > 0) rounded half away from zero."""
    q, r = divmod(abs(n), d)
    if 2 * r >= d:
        q += 1
    return q if n >= 0 else -q


def div(a, b):
    if b.c == 0:
        raise EvalError("Division by zero")
    if a.c == 0:
        return Dec(0, a.s)
    if a.c % b.c == 0:
        return Dec(a.c // b.c, a.s - b.s)
    # value = (a.c / b.c) * 10**(b.s - a.s)
    n, d = a.c, b.c
    sh = b.s - a.s
    if sh >= 0:
        n *= 10 ** sh
    else:
        d *= 10 ** (-sh)
    if d < 0:
        n, d = -n, -d
    g = gcd(abs(n), d)
    rn, rd = n // g, d // g
    # terminating expansion?
    x, a2, b5 = rd, 0, 0
    while x % 2 == 0:
        x //= 2
        a2 += 1
    while x % 5 == 0:
        x //= 5
        b5 += 1
    if x == 1:
        sc = max(a2, b5)
        c = rn * 10 ** sc // rd
        if len(str(abs(c))) <= 100:
            return Dec(c, sc)
    an = abs(rn)
    ip = an // rd
    if len(str(ip)) >= 100:
        return Dec(_round_half_away(rn, rd), 0)
    # exponent E = floor(log10(|v|))
    e0 = len(str(an)) - len(str(rd))
    if e0 >= 0:
        e = e0 if an >= rd * 10 ** e0 else e0 - 1
    else:
        e = e0 if an * 10 ** (-e0) >= rd else e0 - 1
    sc = 99 - e
    if sc >= 0:
        c = _round_half_away(rn * 10 ** sc, rd)
    else:
        c = _round_half_away(rn, rd * 10 ** (-sc))
    if len(str(abs(c))) > 100:
        c = c // 10 if c > 0 else -((-c) // 10)
        sc -= 1
    return Dec(c, sc)


def rescale(x, d, mode):
    if d >= x.s:
        return Dec(x.c * 10 ** (d - x.s), d)
    f = 10 ** (x.s - d)
    if mode == "round":
        q = _round_half_away(x.c, f)
    elif mode == "ceil":
        q = -((-x.c) // f)
    else:
        q = x.c // f
    return Dec(q, d)


# ------------------------------------------------------------------ parser

_FUNCS = {"round": (1, 2), "ceil": (1, 2), "floor": (1, 2), "concat": (1, None), "least": (1, None),
          "greatest": (1, None)}
_VAR = re.compile(r"^event\.(code|timestamp|properties\.[A-Za-z][A-Za-z0-9_]*)$")


def _tokenize(text):
    toks = []
    i, n = 0, len(text)
    while i < n:
        ch = text[i]
        if ch == " ":
            i += 1
        elif ch in "+-*/(),":
            toks.append((ch, ch))
            i += 1
        elif ch == "'":
            j = text.find("'", i + 1)
            if j < 0:
                raise ParseError("unterminated string")
            toks.append(("str", text[i + 1:j]))
            i = j + 1
        elif ch.isascii() and ch.isdigit():
            m = re.compile(r"\d+(?:\.\d+)?").match(text, i)
            j = m.end()
            if j < n and (text[j].isascii() and (text[j].isalnum() or text[j] in "_.")):
                raise ParseError("bad number")
            toks.append(("num", m.group(0)))
            i = j
        elif ch.isascii() and (ch.isalpha() or ch == "_"):
            m = re.compile(r"[A-Za-z0-9_.]+").match(text, i)
            w = m.group(0)
            i = m.end()
            if _VAR.match(w):
                toks.append(("var", w))
            else:
                lw = w.lower()
                if lw in _FUNCS and w in (lw, lw.upper(), lw.capitalize()):
                    toks.append(("func", lw))
                else:
                    raise ParseError("unknown word " + w)
        else:
            raise ParseError("unexpected character %r" % ch)
    return toks


class _Parser:
    def __init__(self, toks):
        self.t = toks
        self.i = 0

    def peek(self):
        return self.t[self.i][0] if self.i < len(self.t) else None

    def take(self, kind=None):
        if self.i >= len(self.t) or (kind and self.t[self.i][0] != kind):
            raise ParseError("unexpected token")
        tok = self.t[self.i]
        self.i += 1
        return tok

    def expression(self):
        node = self.term_chain()
        while self.peek() in ("+", "-"):
            op = self.take()[0]
            node = ("bin", op, node, self.term_chain())
        return node

    def term_chain(self):
        node = self.term()
        while self.peek() in ("*", "/"):
            op = self.take()[0]
            node = ("bin", op, node, self.term())
        return node

    def term(self):
        if self.peek() == "-":
            self.take()
            return ("neg", self.primary())
        return self.primary()

    def primary(self):
        k = self.peek()
        if k == "num":
            return ("num", self.take()[1])
        if k == "str":
            return ("str", self.take()[1])
        if k == "var":
            return ("var", self.take()[1])
        if k == "(":
            self.take()
            e = self.expression()
            self.take(")")
            return e
        if k == "func":
            name = self.take()[1]
            self.take("(")
            args = [self.expression()]
            while self.peek() == ",":
                self.take()
                args.append(self.expression())
            self.take(")")
            lo, hi = _FUNCS[name]
            if len(args) < lo or (hi is not None and len(args) > hi):
                raise ParseError("wrong argument count")
            return ("call", name, args)
        raise ParseError("unexpected token")


_cache = {}


def parse(text):
    p = _cache.get(text)
    if p is None:
        toks = _tokenize(text)
        ps = _Parser(toks)
        p = ps.expression()
        if ps.i != len(toks):
            raise ParseError("trailing input")
        if len(_cache) > 1000:
            _cache.clear()
        _cache[text] = p
    return p


# ------------------------------------------------------------------ evaluation

_NUMSTR = re.compile(r"^[+-]?(\d[\d_]*(\.[\d_]*)?|\.\d[\d_]*)([eE][+-]?\d+)?$")


def _from_property(v):
    """Property value (str or Dec) -> Dec or str."""
    if isinstance(v, Dec):
        return v
    if _NUMSTR.match(v):
        return dec_from_text(v.replace("_", ""))
    return v


def _num(v):
    if not isinstance(v, Dec):
        raise EvalError("Expected a decimal")
    return v


def _eval(node, env):
    k = node[0]
    if k == "num":
        return dec_from_text(node[1])
    if k == "str":
        return node[1]
    if k == "var":
        name = node[1]
        if name == "event.code":
            return env["code"]
        if name == "event.timestamp":
            return env["timestamp"]
        key = name[len("event.properties."):]
        if key not in env["properties"]:
            raise EvalError("Variable: %s not found" % key)
        return _from_property(env["properties"][key])
    if k == "neg":
        v = _num(_eval(node[1], env))
        return Dec(-v.c, v.s)
    if k == "bin":
        a = _num(_eval(node[2], env))
        b = _num(_eval(node[3], env))
        op = node[1]
        if op == "+":
            return add(a, b)
        if op == "-":
            return add(a, b, -1)
        if op == "*":
            return mul(a, b)
        return div(a, b)
    name, args = node[1], [_eval(a, env) for a in node[2]]
    if name in ("round", "ceil", "floor"):
        x = _num(args[0])
        d = 0
        if len(args) > 1:
            dv = _num(args[1])
            if dv.s <= 0:
                d = dv.c * 10 ** (-dv.s)
            else:
                q = abs(dv.c) // 10 ** dv.s
                d = q if dv.c >= 0 else -q
        return rescale(x, d, name)
    if name in ("least", "greatest"):
        best = None
        for a in args:
            a = _num(a)
            if best is None:
                best = a
                continue
            diff = add(a, best, -1).c
            if name == "least" and diff < 0:
                best = a
            elif name == "greatest" and diff >= 0:
                best = a
        return best
    return "".join(a if isinstance(a, str) else num_text(a) for a in args)


def evaluate(expression, code, timestamp_text, properties, exact_ints=True):
    """Processor surface. properties: dict of decoded JSON values (ep_core types) or None.
    Returns the result text (BE-EX-41). Raises ParseError / EvalError."""
    from ep_core import Num

    ast = parse(expression)
    if properties is None:
        raise EvalError("properties is null")
    props = {}
    for k, v in properties.items():
        if isinstance(v, Num):
            props[k] = _json_number(v.text, exact_ints)
        elif isinstance(v, str):
            props[k] = v
        else:
            raise EvalError("unsupported property type for " + k)
    env = {"code": code, "timestamp": dec_from_text(timestamp_text), "properties": props}
    res = _eval(ast, env)
    return res if isinstance(res, str) else num_text(res)


def _json_number(text, exact_ints):
    import ep_core

    if exact_ints and re.match(r"^-?\d+$", text):
        return Dec(int(text), 0)
    f = float(text)
    return dec_from_text(ep_core.go_json_float(f))
