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

    # ── city + zip: `… <CITY> [<ZIP>] <STATE> <COUNTRY>` (verified on REAL
    # descriptors). Zip sits BETWEEN city and state; city = the consecutive alpha,
    # non-marker tokens before it, walking back to the first address marker / digit
    # token / `#…`.

    # Standalone 5-digit zip; city stops at the STREET marker (not the DALY prefix).
    var c1 = parse_location(
        String("CITY OF DALY CITY-UTIL333 90TH STREET DALY CITY 94015 CA USA")
    )
    ok = _expect("c1 city DALY CITY", c1.city == "DALY CITY", ok)
    ok = _expect("c1 zip 94015", c1.zip == "94015", ok)
    ok = _expect("c1 state CA", c1.state == "CA", ok)
    ok = _expect("c1 country USA", c1.country == "USA", ok)

    # MALL is a city-stop marker.
    var c2 = parse_location(
        String("SAFEWAY #3031 85 WESTLAKE MALL DALY CITY 94015 CA USA")
    )
    ok = _expect("c2 city DALY CITY", c2.city == "DALY CITY", ok)
    ok = _expect("c2 zip 94015", c2.zip == "94015", ok)

    # Multi-word city, AVE marker stop.
    var c3 = parse_location(
        String("TRADER JOE'S #187 QPS301 MCLELLAN AVE SO SAN FRAN 94080 CA USA")
    )
    ok = _expect("c3 city SO SAN FRAN", c3.city == "SO SAN FRAN", ok)
    ok = _expect("c3 zip 94080", c3.zip == "94080", ok)

    # Glued zip: `GROVE93950` → city word `GROVE` + zip `93950`.
    var c4 = parse_location(
        String(
            "ARAMARK ASILOMAR FOOD 800 ASILOMAR BLVD PACIFIC GROVE93950 CA USA"
        )
    )
    ok = _expect("c4 city PACIFIC GROVE", c4.city == "PACIFIC GROVE", ok)
    ok = _expect("c4 zip 93950 (glued split)", c4.zip == "93950", ok)

    # The TRAILING city occurrence (before the zip) wins over an earlier one.
    var c5 = parse_location(
        String("LUCKY #707 DALY CITY 6843 MISSION BLVD DALY CITY 94015 CA USA")
    )
    ok = _expect("c5 city DALY CITY (trailing)", c5.city == "DALY CITY", ok)
    ok = _expect("c5 zip 94015", c5.zip == "94015", ok)

    # A phone number (a digit token) precedes the zip → no city, zip still parses.
    var c6 = parse_location(
        String("SP * COOP HOME GOODS 4941 EASTERN AVE. 8883161886 90201 CA USA")
    )
    ok = _expect("c6 city empty (phone precedes zip)", c6.city == "", ok)
    ok = _expect("c6 zip 90201", c6.zip == "90201", ok)
    ok = _expect("c6 state CA", c6.state == "CA", ok)

    # No-zip card descriptor: city before the state, zip empty.
    var c7 = parse_location(String("STARBUCKS STORE 04821 SEATTLE WA USA"))
    ok = _expect("c7 city SEATTLE", c7.city == "SEATTLE", ok)
    ok = _expect("c7 zip empty", c7.zip == "", ok)
    ok = _expect("c7 state WA", c7.state == "WA", ok)

    # No-zip, multi-word city; the store-number digit token ends the walk.
    var c8 = parse_location(
        String("WHOLE FOODS MKT 55120 SAN FRANCISCO CA USA")
    )
    ok = _expect("c8 city SAN FRANCISCO", c8.city == "SAN FRANCISCO", ok)
    ok = _expect("c8 zip empty", c8.zip == "", ok)

    print()
    if ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("location-test failed")
