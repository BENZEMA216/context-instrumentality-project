"""Bilingual (English + Chinese) Temporal Query Parser for Raw Memory.

Extracts relative and calendar time windows from natural-language user queries
anchored at `reference_time_ms` (current wall clock in production, or `question_date`
during historical time-travel / benchmark evaluation).

Used by `HubStore.search_context()` as a **soft temporal proximity boost & candidate
signal** (never a destructive hard filter) so queries like *"two weeks ago"*,
*"last Tuesday"*, *"during the past month"*, or *"上周二"* / *"两周前"* reliably lift
matching timestamped episodes and raw turns without breaking multi-hop recall.
"""

from __future__ import annotations

import calendar
import datetime
import math
import re
from dataclasses import dataclass

DAY_MS = 86_400_000

_NUM_WORDS: dict[str, int] = {
    "a": 1,
    "an": 1,
    "one": 1,
    "two": 2,
    "couple": 2,
    "three": 3,
    "few": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
    "eleven": 11,
    "twelve": 12,
    "一": 1,
    "两": 2,
    "二": 2,
    "三": 3,
    "几": 3,
    "四": 4,
    "五": 5,
    "六": 6,
    "七": 7,
    "八": 8,
    "九": 9,
    "十": 10,
}

_WEEKDAYS_EN: dict[str, int] = {
    "monday": 0,
    "tuesday": 1,
    "wednesday": 2,
    "thursday": 3,
    "friday": 4,
    "saturday": 5,
    "sunday": 6,
}

_WEEKDAYS_ZH: dict[str, int] = {
    "一": 0,
    "二": 1,
    "三": 2,
    "四": 3,
    "五": 4,
    "六": 5,
    "日": 6,
    "天": 6,
}

_MONTHS_EN: dict[str, int] = {
    "january": 1,
    "jan": 1,
    "february": 2,
    "feb": 2,
    "march": 3,
    "mar": 3,
    "april": 4,
    "apr": 4,
    "may": 5,
    "june": 6,
    "jun": 6,
    "july": 7,
    "jul": 7,
    "august": 8,
    "aug": 8,
    "september": 9,
    "sep": 9,
    "sept": 9,
    "october": 10,
    "oct": 10,
    "november": 11,
    "nov": 11,
    "december": 12,
    "dec": 12,
}


@dataclass(frozen=True)
class TemporalWindow:
    start_ms: int
    end_ms: int
    center_ms: int
    specificity: str  # "point" (high boost) | "range" (moderate boost)
    matched_phrase: str


def _parse_num(token: str) -> int | None:
    tok = token.strip().lower()
    if tok.isdigit():
        return int(tok)
    return _NUM_WORDS.get(tok)


def _dt_to_ms(dt: datetime.datetime) -> int:
    return int(dt.timestamp() * 1000)


def _subtract_months(dt: datetime.datetime, months: int) -> datetime.datetime:
    total = dt.year * 12 + (dt.month - 1) - months
    year, rem = divmod(total, 12)
    month = rem + 1
    day = min(dt.day, calendar.monthrange(year, month)[1])
    return dt.replace(year=year, month=month, day=day)


def parse_temporal_window(query: str, reference_time_ms: int) -> TemporalWindow | None:
    """Parse the strongest relative or calendar time constraint from `query`."""
    if not query or not query.strip() or reference_time_ms <= 0:
        return None
    q = query.strip()
    low = q.lower()
    ref_dt = datetime.datetime.fromtimestamp(reference_time_ms / 1000.0, tz=datetime.UTC)
    day_start = ref_dt.replace(hour=0, minute=0, second=0, microsecond=0)

    # 1. Exact relative days: yesterday / day before yesterday / 昨天 / 前天
    if re.search(r"\bthe day before yesterday\b", low) or "前天" in q:
        center = day_start - datetime.timedelta(days=2) + datetime.timedelta(hours=12)
        return TemporalWindow(
            start_ms=_dt_to_ms(center - datetime.timedelta(days=1, hours=18)),
            end_ms=_dt_to_ms(center + datetime.timedelta(days=1, hours=18)),
            center_ms=_dt_to_ms(center),
            specificity="point",
            matched_phrase="day_before_yesterday",
        )
    if re.search(r"\byesterday\b", low) or "昨天" in q:
        center = day_start - datetime.timedelta(days=1) + datetime.timedelta(hours=12)
        return TemporalWindow(
            start_ms=_dt_to_ms(center - datetime.timedelta(days=1, hours=12)),
            end_ms=_dt_to_ms(ref_dt + datetime.timedelta(hours=12)),
            center_ms=_dt_to_ms(center),
            specificity="point",
            matched_phrase="yesterday",
        )

    # 2. Specific weekday: "last Tuesday" / "this past Monday" / "上周二"
    m_wd = re.search(
        r"\b(?:last|this past|previous)\s+(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b",
        low,
    )
    if m_wd:
        target_wd = _WEEKDAYS_EN[m_wd.group(1)]
        delta = (ref_dt.weekday() - target_wd) % 7
        if delta == 0:
            delta = 7
        elif delta < 3 and "last" in m_wd.group(0):
            # e.g. asking "last Tuesday" on Wednesday often means 1 or 8 days ago; keep window generous
            pass
        center = day_start - datetime.timedelta(days=delta) + datetime.timedelta(hours=12)
        return TemporalWindow(
            start_ms=_dt_to_ms(center - datetime.timedelta(days=2, hours=12)),
            end_ms=_dt_to_ms(center + datetime.timedelta(days=2, hours=12)),
            center_ms=_dt_to_ms(center),
            specificity="point",
            matched_phrase=m_wd.group(0),
        )
    m_wd_zh = re.search(r"上(?:个)?(?:周|星期)([一二三四五六日天])", q)
    if m_wd_zh:
        target_wd = _WEEKDAYS_ZH[m_wd_zh.group(1)]
        # Last week's weekday
        start_of_this_week = day_start - datetime.timedelta(days=ref_dt.weekday())
        center = start_of_this_week - datetime.timedelta(days=7 - target_wd) + datetime.timedelta(hours=12)
        return TemporalWindow(
            start_ms=_dt_to_ms(center - datetime.timedelta(days=2)),
            end_ms=_dt_to_ms(center + datetime.timedelta(days=2)),
            center_ms=_dt_to_ms(center),
            specificity="point",
            matched_phrase=m_wd_zh.group(0),
        )

    # 3. "a couple of days ago" / "a few days ago" / "N days ago" / "几天前" / "N天前"
    m_couple = re.search(r"\b(?:a\s+)?(couple|few)\s+(?:of\s+)?(days?|weeks?|months?)\s+ago\b", low)
    if m_couple:
        n = 2 if m_couple.group(1) == "couple" else 3
        unit = m_couple.group(2)
        if unit.startswith("day"):
            center = ref_dt - datetime.timedelta(days=n)
            margin = datetime.timedelta(days=3)
        elif unit.startswith("week"):
            center = ref_dt - datetime.timedelta(weeks=n)
            margin = datetime.timedelta(days=7)
        else:
            center = _subtract_months(ref_dt, n)
            margin = datetime.timedelta(days=20)
        return TemporalWindow(
            start_ms=_dt_to_ms(center - margin),
            end_ms=_dt_to_ms(min(ref_dt + datetime.timedelta(days=1), center + margin)),
            center_ms=_dt_to_ms(center),
            specificity="point",
            matched_phrase=m_couple.group(0),
        )

    m_ago = re.search(
        r"\b(\d+|a|an|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)\s+(day|days|week|weeks|month|months)\s+ago\b",
        low,
    )
    if m_ago:
        n = _parse_num(m_ago.group(1))
        unit = m_ago.group(2)
        if n is not None and n > 0:
            if unit.startswith("day"):
                center = ref_dt - datetime.timedelta(days=n)
                margin = datetime.timedelta(days=max(2, int(round(n * 0.35))))
            elif unit.startswith("week"):
                center = ref_dt - datetime.timedelta(weeks=n)
                margin = datetime.timedelta(days=max(4, min(10, n * 3)))
            else:
                center = _subtract_months(ref_dt, n)
                margin = datetime.timedelta(days=14)
            return TemporalWindow(
                start_ms=_dt_to_ms(center - margin),
                end_ms=_dt_to_ms(min(ref_dt + datetime.timedelta(days=1), center + margin)),
                center_ms=_dt_to_ms(center),
                specificity="point",
                matched_phrase=m_ago.group(0),
            )

    m_ago_zh = re.search(r"(\d+|[一两二三几四五六七八九十]+)\s*(?:个)?(天|周|星期|月)前", q)
    if m_ago_zh:
        n = _parse_num(m_ago_zh.group(1))
        unit = m_ago_zh.group(2)
        if n is not None and n > 0:
            if unit == "天":
                center = ref_dt - datetime.timedelta(days=n)
                margin = datetime.timedelta(days=max(2, int(round(n * 0.35))))
            elif unit in ("周", "星期"):
                center = ref_dt - datetime.timedelta(weeks=n)
                margin = datetime.timedelta(days=max(4, min(10, n * 3)))
            else:
                center = _subtract_months(ref_dt, n)
                margin = datetime.timedelta(days=14)
            return TemporalWindow(
                start_ms=_dt_to_ms(center - margin),
                end_ms=_dt_to_ms(min(ref_dt + datetime.timedelta(days=1), center + margin)),
                center_ms=_dt_to_ms(center),
                specificity="point",
                matched_phrase=m_ago_zh.group(0),
            )

    # 4. Range windows: "in/during/over the past/last (N) days/weeks/months" / "过去N天/周/月"
    m_past = re.search(
        r"\b(?:in|during|over|within)\s+the\s+(?:past|last)\s+(?:(\d+|one|two|three|four|five|six|couple\s+of|few)\s+)?(day|days|week|weeks|month|months)\b",
        low,
    )
    if m_past:
        raw_n = (m_past.group(1) or "1").replace(" of", "").strip()
        n = _parse_num(raw_n) or 1
        unit = m_past.group(2)
        if unit.startswith("day"):
            start = ref_dt - datetime.timedelta(days=n + 1)
        elif unit.startswith("week"):
            start = ref_dt - datetime.timedelta(weeks=n, days=2)
        else:
            start = _subtract_months(ref_dt, n) - datetime.timedelta(days=3)
        end = ref_dt + datetime.timedelta(days=1)
        return TemporalWindow(
            start_ms=_dt_to_ms(start),
            end_ms=_dt_to_ms(end),
            center_ms=_dt_to_ms(start + (end - start) / 2),
            specificity="range",
            matched_phrase=m_past.group(0),
        )

    m_past_zh = re.search(r"(?:过去|最近|近)\s*(\d+|[一两二三几四五六七八九十]+)?\s*(?:个)?(天|周|星期|月)", q)
    if m_past_zh:
        n = _parse_num(m_past_zh.group(1) or "1") or 1
        unit = m_past_zh.group(2)
        if unit == "天":
            start = ref_dt - datetime.timedelta(days=n + 1)
        elif unit in ("周", "星期"):
            start = ref_dt - datetime.timedelta(weeks=n, days=2)
        else:
            start = _subtract_months(ref_dt, n) - datetime.timedelta(days=3)
        end = ref_dt + datetime.timedelta(days=1)
        return TemporalWindow(
            start_ms=_dt_to_ms(start),
            end_ms=_dt_to_ms(end),
            center_ms=_dt_to_ms(start + (end - start) / 2),
            specificity="range",
            matched_phrase=m_past_zh.group(0),
        )

    # 5. "last week" / "last month" / "earlier this week/month" / "上周" / "上个月"
    if re.search(r"\blast week\b", low) or "上周" in q:
        center = ref_dt - datetime.timedelta(days=7)
        return TemporalWindow(
            start_ms=_dt_to_ms(center - datetime.timedelta(days=5)),
            end_ms=_dt_to_ms(min(ref_dt, center + datetime.timedelta(days=5))),
            center_ms=_dt_to_ms(center),
            specificity="point",
            matched_phrase="last_week",
        )
    if re.search(r"\blast month\b", low) or "上个月" in q or "上月" in q:
        prev = _subtract_months(ref_dt.replace(day=1), 1)
        last_day = calendar.monthrange(prev.year, prev.month)[1]
        start = prev.replace(day=1, hour=0, minute=0, second=0, microsecond=0) - datetime.timedelta(days=2)
        end = prev.replace(day=last_day, hour=23, minute=59, second=59) + datetime.timedelta(days=2)
        return TemporalWindow(
            start_ms=_dt_to_ms(start),
            end_ms=_dt_to_ms(end),
            center_ms=_dt_to_ms(start + (end - start) / 2),
            specificity="range",
            matched_phrase="last_month",
        )
    if re.search(r"\b(?:earlier\s+)?this\s+week\b", low) or "本周" in q or "这周" in q:
        start = day_start - datetime.timedelta(days=ref_dt.weekday() + 1)
        end = ref_dt + datetime.timedelta(days=1)
        return TemporalWindow(
            start_ms=_dt_to_ms(start),
            end_ms=_dt_to_ms(end),
            center_ms=_dt_to_ms(start + (end - start) / 2),
            specificity="range",
            matched_phrase="this_week",
        )
    if re.search(r"\b(?:earlier\s+)?this\s+month\b", low) or "这个月" in q or "本月" in q:
        start = day_start.replace(day=1) - datetime.timedelta(days=1)
        end = ref_dt + datetime.timedelta(days=1)
        return TemporalWindow(
            start_ms=_dt_to_ms(start),
            end_ms=_dt_to_ms(end),
            center_ms=_dt_to_ms(start + (end - start) / 2),
            specificity="range",
            matched_phrase="this_month",
        )

    # 6. Explicit calendar month (e.g. "in May", "in April 2023", "on May 15", "2023年5月")
    m_mon = re.search(
        r"\b(?:in|during|on|since|from)\s+(january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sep|sept|oct|nov|dec)(?:\s+(\d{1,2})(?:st|nd|rd|th)?)?(?:,?\s+(\d{4}))?\b",
        low,
    )
    if m_mon:
        mon = _MONTHS_EN[m_mon.group(1)]
        day = int(m_mon.group(2)) if m_mon.group(2) else None
        year = int(m_mon.group(3)) if m_mon.group(3) else ref_dt.year
        if m_mon.group(3) is None and mon > ref_dt.month:
            year -= 1
        last_day = calendar.monthrange(year, mon)[1]
        if day is not None and 1 <= day <= last_day:
            center = datetime.datetime(year, mon, day, 12, 0, tzinfo=datetime.UTC)
            return TemporalWindow(
                start_ms=_dt_to_ms(center - datetime.timedelta(days=2)),
                end_ms=_dt_to_ms(center + datetime.timedelta(days=2)),
                center_ms=_dt_to_ms(center),
                specificity="point",
                matched_phrase=m_mon.group(0),
            )
        start = datetime.datetime(year, mon, 1, tzinfo=datetime.UTC) - datetime.timedelta(days=2)
        end = datetime.datetime(year, mon, last_day, 23, 59, tzinfo=datetime.UTC) + datetime.timedelta(days=2)
        return TemporalWindow(
            start_ms=_dt_to_ms(start),
            end_ms=_dt_to_ms(end),
            center_ms=_dt_to_ms(start + (end - start) / 2),
            specificity="range",
            matched_phrase=m_mon.group(0),
        )

    return None


def temporal_proximity_score(t_start_ms: int, t_end_ms: int, window: TemporalWindow) -> float:
    """Return a smooth `[0.0, 1.0]` proximity score for an event/episode against `window`."""
    if t_end_ms < t_start_ms:
        t_end_ms = t_start_ms
    mid = (t_start_ms + t_end_ms) // 2
    # Check interval overlap first
    if t_end_ms >= window.start_ms and t_start_ms <= window.end_ms:
        if window.specificity == "range":
            return 1.0
        # Sharp Gaussian peak around center_ms (sigma ~= 1.75 days) so exact-day matches
        # stand out clearly over nearby distractor sessions inside the margin window.
        sigma = max(1.25 * DAY_MS, min(2.25 * DAY_MS, (window.end_ms - window.start_ms) / 4.0))
        dist = abs(mid - window.center_ms)
        return round(0.25 + 0.75 * math.exp(-0.5 * (dist / sigma) ** 2), 4)
    # Soft tail outside the window so near-boundary timestamps don't cliff-drop to 0
    edge_dist = (window.start_ms - t_end_ms) if t_end_ms < window.start_ms else (t_start_ms - window.end_ms)
    tail_scale = max(3 * DAY_MS, (window.end_ms - window.start_ms) * 0.5)
    score = 0.5 * math.exp(-edge_dist / tail_scale)
    return round(score, 4) if score >= 0.05 else 0.0
