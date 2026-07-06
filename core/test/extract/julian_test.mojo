"""Julian-day test — julian_from_iso()/iso_from_julian() round-trip identity,
a known anchor, day-difference arithmetic, and total (never-crash) handling of a
malformed/empty date. `pixi run test-julian`.

Guards the pure date-bucketing API a generated program uses for day differences
(`julian_from_iso(a) - julian_from_iso(b)`) and week/period bucketing
(`julian_from_iso(d) // 7`) — Fliegel–Van Flandern, no clock/network."""

from vault.extract.wall_clock import julian_from_iso, iso_from_julian


def _eq_i(got: Int, want: Int, label: String) -> Bool:
    var ok = got == want
    print(
        "["
        + ("PASS" if ok else "FAIL")
        + "] "
        + label
        + " -> "
        + String(got)
        + " (want "
        + String(want)
        + ")"
    )
    return ok


def _eq_s(got: String, want: String, label: String) -> Bool:
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


def main() raises:
    var ok = True

    # ── known anchor: 2000-01-01 is JDN 2451545 ───────────────────────────────
    ok = (
        _eq_i(julian_from_iso("2000-01-01"), 2451545, "anchor 2000-01-01")
        and ok
    )

    # ── round-trip identity across a range incl. leap years / month ends ──────
    var dates = [
        "1970-01-01",
        "1999-12-31",
        "2000-02-29",  # leap
        "2001-02-28",  # non-leap Feb end
        "2024-02-29",  # leap
        "2026-01-31",
        "2026-02-28",
        "2026-07-06",
        "2026-12-31",
        "2100-03-01",  # 2100 is NOT a leap year (Gregorian century rule)
    ]
    for i in range(len(dates)):
        var d = String(dates[i])
        var rt = iso_from_julian(julian_from_iso(d))
        ok = _eq_s(rt, d, "round-trip " + d) and ok

    # ── day-difference arithmetic ─────────────────────────────────────────────
    ok = (
        _eq_i(
            julian_from_iso("2026-03-01") - julian_from_iso("2026-02-01"),
            28,
            "Feb 2026 spans 28 days",
        )
        and ok
    )
    ok = (
        _eq_i(
            julian_from_iso("2024-03-01") - julian_from_iso("2024-02-01"),
            29,
            "Feb 2024 (leap) spans 29 days",
        )
        and ok
    )
    ok = (
        _eq_i(
            julian_from_iso("2026-01-01") - julian_from_iso("2025-01-01"),
            365,
            "2025 spans 365 days",
        )
        and ok
    )

    # ── week bucketing: consecutive days land in the same or adjacent bucket ──
    var wk_a = julian_from_iso("2026-07-06") // 7
    var wk_b = (
        julian_from_iso("2026-07-12") // 7
    )  # 6 days later, same week span
    var diff = wk_b - wk_a
    var wk_ok = diff == 0 or diff == 1
    print(
        "["
        + ("PASS" if wk_ok else "FAIL")
        + "] week bucket adjacency (diff "
        + String(diff)
        + ")"
    )
    ok = wk_ok and ok

    # ── total on malformed / empty input → 0, no crash ────────────────────────
    ok = _eq_i(julian_from_iso(""), 0, "empty -> 0") and ok
    ok = _eq_i(julian_from_iso("2026-01"), 0, "too few parts -> 0") and ok
    ok = _eq_i(julian_from_iso("not-a-date"), 0, "non-numeric -> 0") and ok
    ok = (
        _eq_i(
            julian_from_iso("2026-1-1"),
            julian_from_iso("2026-01-01"),
            "unpadded parts parse the same",
        )
        and ok
    )

    print()
    if ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("julian-test failed")
