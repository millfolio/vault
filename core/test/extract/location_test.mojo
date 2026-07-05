"""Location-test — the deterministic (merchant, country, state) descriptor split.

Pins the ported heuristic (see `vault.extract.location`) against representative
real-shaped card/bank descriptors: a trailing ISO3 country, a `<city3><ISO3>`
pack, a trailing US state, a digit-run cutoff for the merchant, the residual
trailing store-number strip (refine step), and the location-less fallback
(transfers / online). Stdlib-only — `pixi run test-location`.
"""

from vault.extract.location import parse_location


def _expect(name: String, cond: Bool, prev: Bool) -> Bool:
    print("[" + ("PASS" if cond else "FAIL") + "]", name)
    return prev and cond


def main() raises:
    var ok = True

    # Trailing ISO3 country + US state; store-number digit run cuts the merchant.
    var a = parse_location(String("STARBUCKS 0421 SEATTLE WA USA"))
    ok = _expect("country from trailing ISO3", a.country == "USA", ok)
    ok = _expect("state from trailing US code", a.state == "WA", ok)
    ok = _expect(
        "merchant cut at the store-number digit run",
        a.merchant == "STARBUCKS",
        ok,
    )

    # `<city3><ISO3>` pack → ISO3 tail; no US state.
    var b = parse_location(String("TESCO STORES 3421 LONDON GBR"))
    ok = _expect("GBR country", b.country == "GBR", ok)
    ok = _expect("no US state on a foreign row", b.state == "", ok)
    ok = _expect(
        "merchant is the leading brand", b.merchant == "TESCO STORES", ok
    )

    # A 6-char <city3><ISO3> pack resolves to its ISO3 tail.
    var c = parse_location(String("UBER *TRIP HELP.UBER.C AMSNLD"))
    ok = _expect("country from <city3><ISO3> pack", c.country == "NLD", ok)
    ok = _expect("no state on the pack row", c.state == "", ok)

    # A SHORT (<3-digit) store number isn't cut by the loop but the refine step
    # strips it as a residual trailing digit token.
    var d = parse_location(String("SHELL OIL 42 TX USA"))
    ok = _expect(
        "residual short store number stripped", d.merchant == "SHELL OIL", ok
    )
    ok = _expect("state TX", d.state == "TX", ok)

    # Location-less descriptor (a transfer) → no country/state, merchant survives.
    var e = parse_location(String("ACH DEPOSIT PAYROLL"))
    ok = _expect("no country on a transfer", e.country == "", ok)
    ok = _expect("no state on a transfer", e.state == "", ok)
    ok = _expect(
        "merchant is the whole descriptor when no geo",
        e.merchant == "ACH DEPOSIT PAYROLL",
        ok,
    )

    # A leading 2-letter token that happens to look like a state is NOT the trailing
    # token, so it stays part of the merchant (no false state).
    var f = parse_location(String("IN N OUT BURGER"))
    ok = _expect("non-trailing 2-letter isn't a state", f.state == "", ok)
    ok = _expect(
        "merchant keeps the whole brand", f.merchant == "IN N OUT BURGER", ok
    )

    # A trailing `(return)` annotation the bank appends must not displace the geo
    # tokens: strip it, then parse merchant/state/country as usual.
    var r = parse_location(String("WHOLE FOODS MKT SEATTLE WA USA (return)"))
    ok = _expect("trailing (return) → state WA", r.state == "WA", ok)
    ok = _expect("trailing (return) → country USA", r.country == "USA", ok)
    # No store-number digit run here, so the city stays in the merchant (as the
    # heuristic always does) — the point is the strip didn't corrupt it.
    ok = _expect(
        "trailing (return) → merchant WHOLE FOODS MKT SEATTLE",
        r.merchant == "WHOLE FOODS MKT SEATTLE",
        ok,
    )

    # A general trailing parenthetical (any word) is stripped — not just (return).
    var rv = parse_location(String("TESCO STORES LONDON GBR (reversal)"))
    ok = _expect("trailing (reversal) → country GBR", rv.country == "GBR", ok)
    ok = _expect("trailing (reversal) → no US state", rv.state == "", ok)

    # A LEGIT mid-string paren in a merchant name (the group is NOT the trailing
    # content) is untouched, and the geo still parses.
    var mp = parse_location(String("AT&T (WIRELESS) DALLAS TX USA"))
    ok = _expect("mid-string paren → state TX", mp.state == "TX", ok)
    ok = _expect("mid-string paren → country USA", mp.country == "USA", ok)
    ok = _expect(
        "mid-string paren kept in merchant",
        mp.merchant == "AT&T (WIRELESS) DALLAS",
        ok,
    )

    # Empty / whitespace descriptor → empty everything, no crash.
    var g = parse_location(String("   "))
    ok = _expect(
        "blank descriptor is safe", g.country == "" and g.state == "", ok
    )

    # Case-insensitive: a lowercase country code is recognized.
    var h = parse_location(String("cafe nero london gbr"))
    ok = _expect("lowercase ISO3 recognized", h.country == "GBR", ok)

    print()
    if ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("location-test failed")
