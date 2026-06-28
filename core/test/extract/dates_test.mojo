"""dates-test — iso_date folds M/D statement dates with the statement year into
sortable ISO. `pixi run test-dates`. Regression guard for the M/D-date fix (a
mid-statement chunk has no year, so the program supplies the header year)."""

from vault.extract.dates import iso_date


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


def main() raises:
    var ok = True
    ok = _eq(iso_date(2026, "4/6"), "2026-04-06", "M/D + header year") and ok
    ok = (
        _eq(
            iso_date(2026, "04/06"),
            "2026-04-06",
            "MM/DD zero-pads consistently",
        )
        and ok
    )
    ok = (
        _eq(iso_date(2026, "12/31"), "2026-12-31", "two-digit month/day") and ok
    )
    ok = _eq(iso_date(2026, "4-6"), "2026-04-06", "dash separator") and ok
    ok = _eq(iso_date(2026, " 4/6 "), "2026-04-06", "surrounding spaces") and ok
    ok = (
        _eq(
            iso_date(2026, "1/3/24"),
            "2024-01-03",
            "embedded 2-digit year overrides",
        )
        and ok
    )
    ok = (
        _eq(
            iso_date(2026, "1/3/2019"),
            "2019-01-03",
            "embedded 4-digit year overrides",
        )
        and ok
    )
    ok = _eq(iso_date(2026, "none"), "", "non-date -> empty") and ok
    ok = (
        _eq(iso_date(2026, "13/40"), "", "out-of-range month/day -> empty")
        and ok
    )
    ok = _eq(iso_date(2026, ""), "", "empty -> empty") and ok

    # The whole point: ISO strings sort chronologically with plain `<`.
    var sort_ok = iso_date(2026, "4/6") < iso_date(2026, "4/13") and iso_date(
        2025, "12/31"
    ) < iso_date(2026, "1/1")
    print(
        "["
        + ("PASS" if sort_ok else "FAIL")
        + "] ISO dates compare chronologically"
    )
    ok = sort_ok and ok

    print()
    if ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("dates-test failed")
