"""Shared numeric helpers: exact decimals plus the documented binary64 islands."""
from __future__ import annotations

import math
from decimal import ROUND_DOWN, ROUND_HALF_EVEN, ROUND_HALF_UP, Decimal, getcontext

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


def col5(f: float) -> Decimal:
    """Column rule for a binary64 stored in a 5-place column: round5, 16 significant digits (nearest, tie to even), 5 places."""
    d = Decimal(float_round(float(f), 5))
    if d != 0:
        d = d.quantize(Decimal(1).scaleb(d.adjusted() - 15), rounding=ROUND_HALF_EVEN)
    return rnd(d, 5)


def frnd(f: float) -> int:
    """Round half away from zero the exact binary value of a float to an integer."""
    return int(Decimal(f).quantize(Decimal(1), rounding=ROUND_HALF_UP))


def float_round(x: float, nd: int) -> float:
    """Ruby Float#round(nd) (round_half_up variant) for small nd."""
    s = 10.0 ** nd
    xs = x * s
    f = float(Decimal(xs).quantize(Decimal(1), rounding=ROUND_HALF_UP))
    if x > 0:
        if (f + 0.5) / s <= x:
            f += 1
    elif x < 0:
        if (f - 0.5) / s >= x:
            f -= 1
    return f / s


def cut16(f: float) -> Decimal:
    """dec16: the shortest repr text of a binary64, cut (not rounded) after 16 significant digits."""
    d = Decimal(repr(float(f)))
    if d == 0:
        return Decimal(0)
    t = d.as_tuple()
    digs = t.digits
    if len(digs) <= 16:
        return d
    return Decimal((t.sign, digs[:16], t.exponent + len(digs) - 16))


def pct16(rate) -> Decimal:
    """rate / 100 taken as binary64 and read back at 16 significant digits."""
    return cut16(float(dec(rate)) / 100.0)


def fnum(f: float):
    """A float as output decimal (shortest repr), integral floats stay plain integers."""
    return Decimal(repr(float(f)))


def out_num(x):
    """JSON-encodable number: Decimal passes through the encoder, ints stay ints."""
    return x


def exact(ctx) -> bool:
    return (ctx or {}).get("profile") == "corrected"


CURRENCIES = frozenset("""
AED AFN ALL AMD ANG AOA ARS AUD AWG AZN BAM BBD BDT BGN
BHD BIF BMD BND BOB BRL BSD BWP BYN BZD CAD CDF CHF CLF
CLP CNY COP CRC CVE CZK DJF DKK DOP DZD EGP ETB EUR FJD
FKP GBP GEL GHS GIP GMD GNF GTQ GYD HKD HNL HRK HTG HUF
IDR ILS INR IRR ISK JMD JOD JPY KES KGS KHR KMF KRW KWD
KYD KZT LAK LBP LKR LRD LSL MAD MDL MGA MKD MMK MNT MOP
MRO MUR MVR MWK MXN MYR MZN NAD NGN NIO NOK NPR NZD PAB
PEN PGK PHP PKR PLN PYG QAR RON RSD RUB RWF SAR SBD SCR
SEK SGD SHP SLL SOS SRD STD SZL THB TJS TOP TRY TTD TWD
TZS UAH UGX USD UYU UZS VND VUV WST XAF XCD XOF XPF YER
ZAR ZMW
""".split())
