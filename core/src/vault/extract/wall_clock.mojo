"""Wall clock — today's date + calendar-correct relative dates as ISO strings.

A generated vault program (`from vault import *`) has no notion of "now", so on its
own it can't answer relative-date questions ("expenses in the last 3 months"). These
helpers give it one: they return ISO `"YYYY-MM-DD"` strings that compare directly
with `Txn.date` (also ISO), so relative-date filtering stays a plain string compare:

    for t in transactions(): if t.date >= months_ago(3): total += t.amount

Surface (all return ISO `"YYYY-MM-DD"`):
  wall_clock()   -> today's date
  days_ago(n)    -> today minus n days   (exact, day-number arithmetic)
  months_ago(n)  -> today minus n calendar months, day CLAMPED to the target
                    month's length (3/31 - 1 month -> 2/28 or 2/29)
  years_ago(n)   -> today minus n years, day clamped (2/29 -> 2/28 in a non-leap year)

Source of "now":
  * `MILLFOLIO_NOW` (an ISO `YYYY-MM-DD`) if set — a deterministic override used by
    the unit test + the prompt eval to pin a fixed date. A malformed value is
    ignored (falls through to the real clock).
  * otherwise the real system clock in LOCAL time, via libc `time(2)` +
    `localtime_r(3)`. Reading the clock is a pure syscall (no file/network);
    `localtime_r` reads the timezone database under `/var/db/timezone`, which the
    vault run sandbox re-allows read-only (tz data — no user content, no egress).

Pure integer date math (Howard Hinnant's civil<->days algorithms) for realistic
(post-1970) dates — no deps. Re-exported by `vault.tools` into the tool surface;
unit-tested by wall_clock_test.mojo (`pixi run test-wallclock`) with MILLFOLIO_NOW
pinned so it never touches the real clock.
"""

from std.os import getenv
from std.ffi import external_call
from std.memory import UnsafePointer


@fieldwise_init
struct _YMD(Copyable, Movable):
    """A plain year/month/day triple — internal glue between the parse, the
    day-number math, and the ISO formatter."""

    var y: Int
    var m: Int
    var d: Int


def _pad2(n: Int) -> String:
    return (String("0") + String(n)) if n < 10 else String(n)


def _pad4(n: Int) -> String:
    var s = String(n)
    while s.byte_length() < 4:
        s = "0" + s
    return s^


def _iso(t: _YMD) -> String:
    return _pad4(t.y) + "-" + _pad2(t.m) + "-" + _pad2(t.d)


def _atoi(s: String) -> Int:
    """Leading run of digits as an Int (skipping surrounding spaces); -1 if none.
    """
    var n = 0
    var any = False
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 48 and c <= 57:
            n = n * 10 + (c - 48)
            any = True
        elif any:
            break
    return n if any else -1


def _is_leap(y: Int) -> Bool:
    return (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0)


def _last_dom(y: Int, m: Int) -> Int:
    """The last day-of-month for `y`/`m` (leap-aware) — for end-of-month clamping.
    """
    if m == 2:
        return 29 if _is_leap(y) else 28
    if m == 4 or m == 6 or m == 9 or m == 11:
        return 30
    return 31


def _days_from_civil(y: Int, m: Int, d: Int) -> Int:
    """Days since the Unix epoch (1970-01-01) for a proleptic-Gregorian date —
    Howard Hinnant's algorithm. Correct for the post-1970 dates this module ever
    produces (all operands non-negative, so floor == truncated division)."""
    var yy = y - (1 if m <= 2 else 0)
    var era = yy // 400
    var yoe = yy - era * 400
    var doy = (153 * (m + (-3 if m > 2 else 9)) + 2) // 5 + d - 1
    var doe = yoe * 365 + yoe // 4 - yoe // 100 + doy
    return era * 146097 + doe - 719468


def _civil_from_days(z0: Int) -> _YMD:
    """Inverse of `_days_from_civil` — a day number back to y/m/d."""
    var z = z0 + 719468
    var era = z // 146097
    var doe = z - era * 146097
    var yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    var y = yoe + era * 400
    var doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    var mp = (5 * doy + 2) // 153
    var d = doy - (153 * mp + 2) // 5 + 1
    var m = mp + (3 if mp < 10 else -9)
    return _YMD(y + (1 if m <= 2 else 0), m, d)


def _epoch_s() -> Int64:
    """Unix epoch seconds — `time(2)` with a NULL arg (a pure syscall, no fs/net).
    """
    var null = UnsafePointer[NoneType, MutUntrackedOrigin](
        unsafe_from_address=Int(0)
    )
    return external_call["time", Int64](null)


def _system_ymd() -> _YMD:
    """Today's LOCAL date from the real clock. `localtime_r` fills a `struct tm`
    whose leading fields are 4-byte ints: [3]=tm_mday, [4]=tm_mon (0-11),
    [5]=tm_year (years since 1900). We view the 64-byte, 8-aligned buffer as Int32
    to read them. macOS/osx-arm64 only (the pixi platform), where the layout is
    fixed."""
    var epoch = InlineArray[Int64, 1](fill=_epoch_s())
    var tm = InlineArray[Int64, 8](
        fill=Int64(0)
    )  # 64 bytes >= sizeof(struct tm)
    _ = external_call["localtime_r", UnsafePointer[Int64, MutUntrackedOrigin]](
        epoch.unsafe_ptr(), tm.unsafe_ptr()
    )
    var f = tm.unsafe_ptr().bitcast[Int32]()
    var mday = Int(f[3])
    var mon = Int(f[4]) + 1
    var year = Int(f[5]) + 1900
    return _YMD(year, mon, mday)


def _now_ymd() raises -> _YMD:
    """Today's y/m/d — the `MILLFOLIO_NOW` override (ISO) if set + valid, else the
    real local clock. A malformed override is ignored (falls back to the clock).
    """
    var override = String(getenv("MILLFOLIO_NOW", "").strip())
    if override != "":
        var p = override.split("-")
        if len(p) >= 3:
            var y = _atoi(String(p[0]))
            var m = _atoi(String(p[1]))
            var d = _atoi(String(p[2]))
            if y > 0 and m >= 1 and m <= 12 and d >= 1 and d <= 31:
                return _YMD(y, m, d)
    return _system_ymd()


def wall_clock() raises -> String:
    """Today's date as an ISO `"YYYY-MM-DD"` string (LOCAL time, or the
    `MILLFOLIO_NOW` override). Compares directly with `Txn.date`."""
    return _iso(_now_ymd())


def days_ago(n: Int) raises -> String:
    """Today minus `n` days as ISO `"YYYY-MM-DD"` (exact day-number arithmetic).
    """
    var t = _now_ymd()
    return _iso(_civil_from_days(_days_from_civil(t.y, t.m, t.d) - n))


def months_ago(n: Int) raises -> String:
    """Today minus `n` calendar months as ISO `"YYYY-MM-DD"`. The day is CLAMPED to
    the target month's length (from `2026-03-31`, `months_ago(1)` -> `2026-02-28`),
    and the year rolls over correctly (`months_ago(9)` from July -> the prior
    October)."""
    var t = _now_ymd()
    var total = (t.y * 12 + (t.m - 1)) - n  # months since year 0; stays > 0
    var y = total // 12
    var m = total % 12 + 1
    var last = _last_dom(y, m)
    var d = last if t.d > last else t.d
    return _iso(_YMD(y, m, d))


def years_ago(n: Int) raises -> String:
    """Today minus `n` years as ISO `"YYYY-MM-DD"`, with `2/29` clamped to `2/28`
    in a non-leap target year."""
    var t = _now_ymd()
    var y = t.y - n
    var last = _last_dom(y, t.m)
    var d = last if t.d > last else t.d
    return _iso(_YMD(y, t.m, d))


# ── Julian Day Number <-> ISO (Fliegel–Van Flandern) ─────────────────────────
# A single, correct conversion between an ISO `"YYYY-MM-DD"` string and its
# Julian Day Number (a plain Int day count) so a generated program can do date
# arithmetic — day differences (`julian_from_iso(a) - julian_from_iso(b)`) and
# week/period bucketing (`julian_from_iso(d) // 7`) — without re-deriving the
# calendar math in every program. The pair is a round-trip identity:
# `iso_from_julian(julian_from_iso(x)) == x`.


def julian_from_iso(iso: String) raises -> Int:
    """ISO `"YYYY-MM-DD"` -> its Julian Day Number (Int). TOTAL: malformed or empty
    input (fewer than 3 `-`-separated parts, or non-numeric fields — e.g. a `""`
    `Txn.date`) returns `0` rather than crashing. Use for day differences and
    week/period bucketing; inverse is `iso_from_julian`."""
    var p = iso.split("-")
    if len(p) < 3:
        return 0
    try:
        var y = Int(String(p[0]))
        var m = Int(String(p[1]))
        var d = Int(String(p[2]))
        var a = (14 - m) // 12
        var yy = y + 4800 - a
        var mm = m + 12 * a - 3
        return (
            d
            + (153 * mm + 2) // 5
            + 365 * yy
            + yy // 4
            - yy // 100
            + yy // 400
            - 32045
        )
    except:
        return 0


def iso_from_julian(jd: Int) raises -> String:
    """Julian Day Number (Int) -> ISO `"YYYY-MM-DD"` — the inverse of
    `julian_from_iso` (e.g. to label a computed date bucket)."""
    var a = jd + 32044
    var b = (4 * a + 3) // 146097
    var c = a - (146097 * b) // 4
    var d1 = (4 * c + 3) // 1461
    var e = c - (1461 * d1) // 4
    var m1 = (5 * e + 2) // 153
    var day = e - (153 * m1 + 2) // 5 + 1
    var month = m1 + 3 - 12 * (m1 // 10)
    var year = 100 * b + d1 - 4800 + m1 // 10
    return _iso(_YMD(year, month, day))
