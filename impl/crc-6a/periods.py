"""Small period algebra (billing spec chapter 06 section 2) used by termination notes and the commitment true-up."""
from __future__ import annotations

import calendar
import datetime as dt
from zoneinfo import ZoneInfo

STEP = {"weekly": 7, "monthly": 1, "quarterly": 3, "semiannual": 6, "yearly": 12}
UTC = dt.timezone.utc


def clamp(y, m, d):
    return dt.date(y, m, min(d, calendar.monthrange(y, m)[1]))


def parse_instant(s: str) -> dt.datetime:
    t = dt.datetime.fromisoformat(s.replace("Z", "+00:00"))
    if t.tzinfo is None:
        t = t.replace(tzinfo=UTC)
    return t.astimezone(UTC)


def to_local_date(t: dt.datetime, tz: str) -> dt.date:
    return t.astimezone(ZoneInfo(tz)).date()


def local_start(d: dt.date, tz: str) -> dt.datetime:
    return dt.datetime(d.year, d.month, d.day, tzinfo=ZoneInfo(tz)).astimezone(UTC)


def local_end(d: dt.date, tz: str) -> dt.datetime:
    return dt.datetime(d.year, d.month, d.day, 23, 59, 59, 999999, tzinfo=ZoneInfo(tz)).astimezone(UTC)


class Plan:
    def __init__(self, interval, billing_time, anchor: dt.date):
        self.interval = interval
        self.anniv = billing_time == "anniversary"
        self.anchor = anchor

    def period(self, x: dt.date):
        """(start, end) local dates of the period containing x."""
        n = STEP[self.interval]
        if n == 7:
            wd = self.anchor.weekday() if self.anniv else 0
            start = x - dt.timedelta(days=(x.weekday() - wd) % 7)
            return start, start + dt.timedelta(days=6)
        am = self.anchor.month if self.anniv else 1
        ad = self.anchor.day if self.anniv else 1
        k = x.year * 12 + x.month - 1
        start = None
        for back in range(0, 13):
            kk = k - back
            y, m = divmod(kk, 12)
            m += 1
            if (m - am) % n == 0:
                s = clamp(y, m, ad)
                if s <= x:
                    start = s
                    sk = kk
                    break
        k2 = sk + n
        y, m = divmod(k2, 12)
        nxt = clamp(y, m + 1, ad)
        return start, nxt - dt.timedelta(days=1)

    def prev_period_end_date(self, x: dt.date):
        s, _ = self.period(x)
        return s - dt.timedelta(days=1)

    def length(self, x: dt.date) -> int:
        s, e = self.period(x)
        return (e - s).days + 1


def day_count(a: dt.datetime, b: dt.datetime, tz: str) -> int:
    """BE-DM-15: ceil of the local wall-clock duration in days."""
    z = ZoneInfo(tz)
    la = a.astimezone(z).replace(tzinfo=None)
    lb = b.astimezone(z).replace(tzinfo=None)
    secs = (lb - la).total_seconds()
    import math
    return math.ceil(secs / 86400)
