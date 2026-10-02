"""Calendar helpers: instants, local dates, billing periods (BE-SP-5..11)."""
import calendar
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo

UTC = timezone.utc


def parse_instant(s):
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    return datetime.fromisoformat(s).astimezone(UTC)


def fmt_instant(dt, frac=False):
    dt = dt.astimezone(UTC)
    if frac and dt.microsecond:
        return dt.strftime("%Y-%m-%dT%H:%M:%S.%f").rstrip("0") + "Z"
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def tzinfo(tz):
    return UTC if tz in (None, "UTC") else ZoneInfo(tz)


def local_date(dt, tz):
    return dt.astimezone(tzinfo(tz)).date()


def start_of_local_day_utc(d, tz):
    return datetime(d.year, d.month, d.day, tzinfo=tzinfo(tz)).astimezone(UTC)


def end_of_local_day_utc(d, tz):
    return datetime(d.year, d.month, d.day, 23, 59, 59, 999999, tzinfo=tzinfo(tz)).astimezone(UTC)


def days_between(a, b, tz):
    """BE-DM-15: ceil of local wall-clock duration in days."""
    z = tzinfo(tz)
    la = a.astimezone(z).replace(tzinfo=None)
    lb = b.astimezone(z).replace(tzinfo=None)
    delta = lb - la
    secs = delta.total_seconds() if False else (delta.days * 86400 + delta.seconds + delta.microseconds / 1e6)
    q = secs / 86400
    import math
    return math.ceil(q)


def clamp(y, m, d):
    return date(y, m, min(d, calendar.monthrange(y, m)[1]))


def _add_months(y, m, k):
    t = y * 12 + (m - 1) + k
    return t // 12, t % 12 + 1


def period_starts(interval, billing_time, anchor, around):
    """List of period start dates around `around` (sorted)."""
    ys = range(around.year - 2, around.year + 3)
    out = []
    if interval == "weekly":
        base = around - timedelta(days=21)
        for i in range(0, 50):
            d = base + timedelta(days=i)
            if billing_time == "calendar":
                if d.weekday() == 0:
                    out.append(d)
            elif d.weekday() == anchor.weekday():
                out.append(d)
        return out
    step = {"monthly": 1, "quarterly": 3, "semiannual": 6, "yearly": 12}[interval]
    for y in ys:
        if interval == "yearly":
            if billing_time == "calendar":
                out.append(date(y, 1, 1))
            else:
                out.append(clamp(y, anchor.month, anchor.day))
            continue
        for m in range(1, 13):
            if billing_time == "calendar":
                if (m - 1) % step == 0:
                    out.append(date(y, m, 1))
            else:
                if (m - anchor.month) % step == 0:
                    out.append(clamp(y, m, anchor.day))
    return sorted(set(out))


def period_of(x, interval, billing_time, anchor):
    """(start, end) local dates of the period containing local date x (BE-SP-10)."""
    starts = period_starts(interval, billing_time, anchor, x)
    prev = max(s for s in starts if s <= x)
    nxt = min(s for s in starts if s > x)
    return prev, nxt - timedelta(days=1)
