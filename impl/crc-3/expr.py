"""Expression language (BE-EX): parser, exact-decimal evaluator, number text forms."""
import re
from dataclasses import dataclass


class ParseError(Exception):
    pass


class EvalError(Exception):
    pass


class DivZero(EvalError):
    pass


@dataclass(frozen=True)
class Num:
    c: int  # significand (trailing zeros kept)
    s: int  # scale, value = c * 10**-s


class NumText(str):
    """A JSON number token with its spelling preserved (ep surface)."""


NUM_RE = re.compile(r'^([+-]?)(?:(\d[\d_]*)(?:\.([\d_]*))?|\.(\d[\d_]*))(?:[eE]([+-]?\d+))?$')


def parse_num(text):
    """Numeric string (BE-EX-11) -> Num or None."""
    m = NUM_RE.match(text)
    if not m:
        return None
    sign, ip, fp, fp2, ex = m.groups()
    if ip is None:
        ip, fp = '', fp2
    ip = ip.replace('_', '')
    fp = (fp or '').replace('_', '')
    digits = ip + fp
    if not digits:
        return None
    c = int(digits)
    s = len(fp)
    if ex:
        if abs(int(ex)) > 100000:
            return None
        s -= int(ex)
    return Num(-c if sign == '-' else c, s)


def ruby_float_text(f):
    r = repr(float(f))
    if r in ('inf', '-inf', 'nan'):
        return {'inf': 'Infinity', '-inf': '-Infinity', 'nan': 'NaN'}[r]
    neg = r.startswith('-')
    if neg:
        r = r[1:]
    mant, _, ex = r.partition('e')
    ip, _, fp = mant.partition('.')
    ex = int(ex) if ex else 0
    digits = (ip + fp)
    decpt = len(ip) + ex
    stripped = digits.lstrip('0')
    decpt -= len(digits) - len(stripped)
    digits = stripped.rstrip('0')
    if not digits:
        out = '0.0'
    elif -4 < decpt <= 16:
        if decpt <= 0:
            out = '0.' + '0' * (-decpt) + digits
        elif decpt >= len(digits):
            out = digits + '0' * (decpt - len(digits)) + '.0'
        else:
            out = digits[:decpt] + '.' + digits[decpt:]
    else:
        e = decpt - 1
        out = digits[0] + '.' + (digits[1:] or '0') + 'e' + ('-' if e < 0 else '+') + '%02d' % abs(e)
    return ('-' if neg else '') + out


def ruby_str_inspect(s):
    out = ['"']
    for ch in s:
        if ch == '"' or ch == '\\':
            out.append('\\' + ch)
        elif ch == '#':
            out.append('#')
        elif ch == '\n':
            out.append('\\n')
        elif ch == '\t':
            out.append('\\t')
        elif ch == '\r':
            out.append('\\r')
        elif ch == '\x1b':
            out.append('\\e')
        elif ord(ch) < 32 or ord(ch) == 127:
            out.append('\\x%02X' % ord(ch))
        else:
            out.append(ch)
    out.append('"')
    return ''.join(out)


def ruby_inspect(v):
    if v is None:
        return 'nil'
    if v is True:
        return 'true'
    if v is False:
        return 'false'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        return ruby_float_text(v)
    if isinstance(v, str):
        return ruby_str_inspect(v)
    if isinstance(v, list):
        return '[' + ', '.join(ruby_inspect(x) for x in v) + ']'
    if isinstance(v, dict):
        if not v:
            return '{}'
        return '{' + ', '.join(ruby_str_inspect(k) + ' => ' + ruby_inspect(x) for k, x in v.items()) + '}'
    return str(v)


# ---------------------------------------------------------------- parser

FUNCS = {'round', 'ceil', 'floor', 'concat', 'least', 'greatest'}
NAME_RE = re.compile(r'[A-Za-z][A-Za-z0-9_]*')
DEC_RE = re.compile(r'\d+(?:\.\d+)?')
VAR_RE = re.compile(r'event\.(?:code|timestamp|properties\.[A-Za-z][A-Za-z0-9_]*)')


def func_name(word):
    if word in FUNCS or word.lower() in FUNCS and (word.isupper() or word == word.capitalize()):
        return word.lower()
    return None


class Parser:
    def __init__(self, text):
        self.t = text
        self.i = 0

    def ws(self):
        while self.i < len(self.t) and self.t[self.i] == ' ':
            self.i += 1

    def peek(self):
        self.ws()
        return self.t[self.i] if self.i < len(self.t) else ''

    def parse(self):
        node = self.expression()
        self.ws()
        if self.i != len(self.t):
            raise ParseError('unexpected input')
        return node

    def expression(self):
        node = self.product()
        while self.peek() in ('+', '-') and self.peek() != '':
            op = self.t[self.i]
            self.i += 1
            node = ('bin', op, node, self.product())
        return node

    def product(self):
        node = self.term()
        while self.peek() in ('*', '/') and self.peek() != '':
            op = self.t[self.i]
            self.i += 1
            node = ('bin', op, node, self.term())
        return node

    def term(self):
        neg = False
        if self.peek() == '-':
            self.i += 1
            neg = True
        node = self.primary()
        return ('neg', node) if neg else node

    def primary(self):
        ch = self.peek()
        if ch == '':
            raise ParseError('unexpected end')
        if ch == '(':
            self.i += 1
            node = self.expression()
            if self.peek() != ')':
                raise ParseError('expected )')
            self.i += 1
            return node
        if ch == "'":
            j = self.t.find("'", self.i + 1)
            if j < 0:
                raise ParseError('unterminated string')
            s = self.t[self.i + 1:j]
            self.i = j + 1
            return ('str', s)
        if ch.isdigit() and ch.isascii():
            m = DEC_RE.match(self.t, self.i)
            self.i = m.end()
            return ('num', parse_num(m.group(0)))
        m = VAR_RE.match(self.t, self.i)
        if m:
            self.i = m.end()
            # the variable must not continue with name characters or a dot
            if self.i < len(self.t) and (self.t[self.i].isalnum() and self.t[self.i].isascii() or self.t[self.i] in '_.'):
                raise ParseError('bad variable')
            return ('var', m.group(0))
        m = NAME_RE.match(self.t, self.i)
        if m:
            name = func_name(m.group(0))
            if name is None:
                raise ParseError('unknown name')
            self.i = m.end()
            if self.peek() != '(':
                raise ParseError('expected (')
            self.i += 1
            args = [self.expression()]
            while self.peek() == ',':
                self.i += 1
                args.append(self.expression())
            if self.peek() != ')':
                raise ParseError('expected )')
            self.i += 1
            if name in ('round', 'ceil', 'floor') and len(args) > 2:
                raise ParseError('arity')
            return ('call', name, args)
        raise ParseError('unexpected character')


def parse(text):
    if text is None:
        raise ParseError('empty')
    return Parser(text).parse()


# ---------------------------------------------------------------- arithmetic

def need_num(v):
    if not isinstance(v, Num):
        raise EvalError('Expected a decimal')
    return v


def align(a, b):
    s = max(a.s, b.s)
    return a.c * 10 ** (s - a.s), b.c * 10 ** (s - b.s), s


def div(a, b):
    if b.c == 0:
        raise DivZero('Division by zero')
    if a.c == 0:
        return a
    if a.c % b.c == 0:
        return Num(a.c // b.c, a.s - b.s)
    sign = -1 if (a.c < 0) != (b.c < 0) else 1
    n, d = abs(a.c), abs(b.c)
    e = b.s - a.s
    if e >= 0:
        n *= 10 ** e
    else:
        d *= 10 ** (-e)
    ip = n // d
    if ip > 0:
        st = max(100 - len(str(ip)), 0)
    else:
        p = 1
        while n * 10 ** p < d:
            p += 1
        st = p + 99
    q, r = divmod(n * 10 ** st, d)
    if r == 0:
        while st > 0 and q % 10 == 0:
            q //= 10
            st -= 1
    elif 2 * r >= d:
        q += 1
    return Num(sign * q, st)


def trunc_int(x):
    if x.s <= 0:
        return x.c * 10 ** (-x.s)
    q = abs(x.c) // 10 ** x.s
    return q if x.c >= 0 else -q


def rescale(x, d, mode):
    if abs(d) > 100000:
        raise EvalError('digits out of range')
    if d >= x.s:
        return Num(x.c * 10 ** (d - x.s), d)
    div_ = 10 ** (x.s - d)
    q, r = divmod(abs(x.c), div_)
    neg = x.c < 0
    if mode == 'round':
        if 2 * r >= div_:
            q += 1
    elif mode == 'ceil':
        if r and not neg:
            q += 1
    else:
        if r and neg:
            q += 1
    return Num(-q if neg else q, d)


def to_value(v):
    """Convert a surface value: strings that are numeric become numbers."""
    if isinstance(v, NumText):
        n = parse_num(str(v))
        if n is None:
            raise EvalError('bad number')
        return n
    if isinstance(v, str):
        n = parse_num(v)
        return n if n is not None else v
    return v


def evaluate(node, ev, zero_keep):
    k = node[0]
    if k == 'num':
        return node[1]
    if k == 'str':
        return node[1]
    if k == 'var':
        name = node[1]
        if name == 'event.code':
            return ev['code']
        if name == 'event.timestamp':
            if 'timestamp' not in ev:
                raise EvalError('Variable: timestamp not found')
            return to_value(ev['timestamp'])
        prop = name[len('event.properties.'):]
        props = ev['properties']
        if prop not in props:
            raise EvalError('Variable: %s not found' % prop)
        return to_value(props[prop])
    if k == 'neg':
        x = need_num(evaluate(node[1], ev, zero_keep))
        return Num(-x.c, x.s)
    if k == 'bin':
        op = node[1]
        a = need_num(evaluate(node[2], ev, zero_keep))
        b = need_num(evaluate(node[3], ev, zero_keep))
        if op == '*':
            return Num(a.c * b.c, a.s + b.s)
        if op == '/':
            return div(a, b)
        if op == '-':
            if b.c == 0:
                return a
            if a.c == 0:
                return Num(-b.c, b.s)
        x, y, s = align(a, b)
        return Num(x + y if op == '+' else x - y, s)
    name, args = node[1], node[2]
    vals = [evaluate(a, ev, zero_keep) for a in args]
    if name in ('round', 'ceil', 'floor'):
        x = need_num(vals[0])
        d = trunc_int(need_num(vals[1])) if len(vals) > 1 else 0
        return rescale(x, d, name)
    if name in ('least', 'greatest'):
        nums = [need_num(v) for v in vals]
        best = nums[0]
        for n in nums[1:]:
            x, y, _ = align(n, best)
            if name == 'least' and x < y:
                best = n
            elif name == 'greatest' and x >= y:
                best = n
        return best
    return ''.join(v if isinstance(v, str) else num_text(v, zero_keep) for v in vals)


# ---------------------------------------------------------------- number text

def plain(c, s):
    sign = '-' if c < 0 else ''
    d = str(abs(c))
    if s <= 0:
        return sign + d + '0' * (-s)
    d = d.rjust(s + 1, '0')
    return sign + d[:-s] + '.' + d[-s:]


def num_text(x, zero_keep):
    c, s = x.c, x.s
    if c == 0:
        if not zero_keep:
            return '0'
    n = len(str(abs(c)))
    if s - n > 5:
        d = str(abs(c))
        body = d[0] + ('.' + d[1:] if len(d) > 1 else '')
        return ('-' if c < 0 else '') + body + 'E' + str(n - 1 - s)
    if s < -15:
        return str(c) + 'e+' + str(-s)
    return plain(c, s)


def canonical(x):
    t = plain(x.c, x.s)
    if '.' in t:
        t = t.rstrip('0').rstrip('.')
    return t if t not in ('', '-') else '0'


def stored_text(x):
    """Number as written into properties (BE-EX-31): plain, >= 1 fractional digit."""
    t = plain(x.c, x.s)
    if '.' in t:
        t = t.rstrip('0')
        if t.endswith('.'):
            t += '0'
        return t
    return t + '.0'
