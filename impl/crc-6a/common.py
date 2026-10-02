"""Shared numeric helpers: exact decimals plus the documented binary64 islands."""
from __future__ import annotations

import math
from decimal import ROUND_DOWN, ROUND_HALF_UP, Decimal, getcontext

getcontext().prec = 80

ZERO = Decimal(0)
Q5 = Decimal("0.00001")


class KitError(Exception):
    def __init__(self, code, field=None, message=None):
        super().__init__(message or code)
        self.code, self.field, self.message = code, field, message


class Unsupported(Exception):
    pass


def dec(x) -> Decimal:
    if isinstance(x, Decimal):
        return x
    if isinstance(x, bool):
        raise ValueError("bool is not a decimal")
    if isinstance(x, float):
        return Decimal(repr(x))
    return Decimal(x)


def rnd(x, places=0) -> Decimal:
    """Round half away from zero (exact decimal)."""
    return dec(x).quantize(Decimal(1).scaleb(-places), rounding=ROUND_HALF_UP)


def rint(x) -> int:
    return int(rnd(x))


def trunc(x) -> int:
    return int(dec(x).to_integral_value(rounding=ROUND_DOWN))


def store5(x) -> Decimal:
    return rnd(x, 5)


def frnd(f: float) -> int:
    """Round half away from zero the exact binary value of a float to an integer."""
    return int(Decimal(f).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def float_round(x: float, nd: int) -> float:
    """Ruby Float#round(nd) (round_half_up variant) for small nd."""
    s = 10.0 ** nd
    xs = x * s
    f = math.floor(abs(xs) + 0.5)
    if xs < 0:
        f = -f
    if x > 0:
        if (f + 0.5) / s <= x:
            f += 1
    elif x < 0:
        if (f - 0.5) / s >= x:
            f -= 1
    return f / s


def pct16(rate) -> Decimal:
    """rate / 100 taken as binary64 and read back at 16 significant digits."""
    f = float(dec(rate)) / 100.0
    return Decimal(format(f, ".15e"))


def fnum(f: float):
    """A float as output decimal (shortest repr), integral floats stay plain integers."""
    return Decimal(repr(float(f)))


def out_num(x):
    """JSON-encodable number: Decimal passes through the encoder, ints stay ints."""
    return x


def exact(ctx) -> bool:
    return (ctx or {}).get("profile") == "corrected"
