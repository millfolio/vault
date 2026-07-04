"""Wall-clock test — wall_clock()/days_ago()/months_ago()/years_ago() with the
`MILLFOLIO_NOW` override pinned, so the checks are deterministic and never touch the
real system clock. `pixi run test-wallclock`.

Guards the relative-date API a generated program uses to answer "expenses in the
last 3 months": the helpers return ISO `"YYYY-MM-DD"` strings that compare directly
with `Txn.date`. Covers calendar rollover, end-of-month clamping, and leap years."""

from std.os import setenv
from vault.extract.wall_clock import wall_clock, days_ago, months_ago, years_ago


def _eq(got: String, want: String, label: String) -> Bool:
    var ok = got == want
    print(
        "["
        + ("PASS" if ok else "FAIL")
        + "] "
        + label
        + " -> '"
        + got
        + "' (want '"
        + want
        + "')"
    )
    return ok


def _pin(iso: String):
    _ = setenv("MILLFOLIO_NOW", iso, True)


def main() raises:
    var ok = True

    # ── base 2026-07-03 (the task's canonical anchor) ─────────────────────────
    _pin("2026-07-03")
    ok = _eq(wall_clock(), "2026-07-03", "wall_clock == pinned now") and ok
    ok = _eq(days_ago(0), "2026-07-03", "days_ago(0) == today") and ok
    ok = _eq(days_ago(10), "2026-06-23", "days_ago(10) crosses month") and ok
    ok = _eq(months_ago(3), "2026-04-03", "months_ago(3)") and ok
    ok = _eq(months_ago(9), "2025-10-03", "months_ago(9) year rollover") and ok
    ok = (
        _eq(months_ago(12), "2025-07-03", "months_ago(12) == a year back")
        and ok
    )
    ok = _eq(years_ago(1), "2025-07-03", "years_ago(1)") and ok

    # ── end-of-month clamping: 3/31 minus one month has no 31st ───────────────
    _pin("2026-03-31")
    ok = _eq(months_ago(1), "2026-02-28", "3/31 - 1mo clamps to 2/28") and ok
    ok = (
        _eq(months_ago(13), "2025-02-28", "3/31 - 13mo clamps + rolls year")
        and ok
    )

    # ── month rollover into the prior year, with clamp ────────────────────────
    _pin("2026-01-31")
    ok = _eq(months_ago(2), "2025-11-30", "1/31 - 2mo -> 11/30 (clamp)") and ok
    ok = _eq(days_ago(1), "2026-01-30", "days_ago(1)") and ok

    # ── day arithmetic across a year boundary ─────────────────────────────────
    _pin("2026-01-05")
    ok = _eq(days_ago(10), "2025-12-26", "days_ago(10) crosses the year") and ok

    # ── leap-year clamping: 2/29 doesn't exist a (non-leap) year/months back ──
    _pin("2024-02-29")
    ok = _eq(years_ago(1), "2023-02-28", "2/29 -1yr clamps to 2/28") and ok
    ok = _eq(months_ago(12), "2023-02-28", "2/29 -12mo clamps to 2/28") and ok
    ok = _eq(days_ago(1), "2024-02-28", "days_ago in a leap Feb") and ok

    # ── the point: results are ISO and sort chronologically with plain `<` ────
    _pin("2026-07-03")
    var order_ok = months_ago(3) < wall_clock() and days_ago(30) < days_ago(1)
    print(
        "["
        + ("PASS" if order_ok else "FAIL")
        + "] relative dates order with `<`"
    )
    ok = order_ok and ok

    # ── a malformed override is ignored → falls back to the real clock ────────
    # (we only assert it doesn't crash and returns a plausible ISO shape).
    _pin("not-a-date")
    var live = wall_clock()
    var shape_ok = (
        live.byte_length() == 10
        and String(live.split("-")[0]).byte_length() == 4
    )
    print(
        "["
        + ("PASS" if shape_ok else "FAIL")
        + "] bad override -> real clock ISO '"
        + live
        + "'"
    )
    ok = shape_ok and ok

    print()
    if ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("wall_clock-test failed")
