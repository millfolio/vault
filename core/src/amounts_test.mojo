"""amounts-test — parse_amount handles $/comma/paren money strings. `pixi run
test-amounts`. Regression guard for the "total spent" crash (atof choked on the
comma in '4,000.00')."""

from vault.amounts import parse_amount


def _close(got: Float64, want: Float64) -> Bool:
    var d = got - want
    return d < 0.0001 and d > -0.0001


def _eq(got: Float64, want: Float64, label: String) -> Bool:
    var ok = _close(got, want)
    print("[" + ("PASS" if ok else "FAIL") + "] " + label + " -> " + String(got) + " (want " + String(want) + ")")
    return ok


def main() raises:
    var ok = True
    ok = _eq(parse_amount("4,000.00"), 4000.0, "comma thousands (the crash)") and ok
    ok = _eq(parse_amount("$1,234.56"), 1234.56, "dollar + comma") and ok
    ok = _eq(parse_amount("42.10"), 42.10, "plain decimal") and ok
    ok = _eq(parse_amount("100"), 100.0, "integer") and ok
    ok = _eq(parse_amount("-31.00"), -31.0, "leading minus") and ok
    ok = _eq(parse_amount("(42.10)"), -42.10, "accounting parens = negative") and ok
    ok = _eq(parse_amount("$2,500.00 USD"), 2500.0, "trailing currency word") and ok
    ok = _eq(parse_amount(" 7.50 "), 7.50, "surrounding spaces") and ok
    ok = _eq(parse_amount("none"), 0.0, "non-number -> 0") and ok
    ok = _eq(parse_amount(""), 0.0, "empty -> 0") and ok

    # The point: a sum over mixed strings doesn't crash and is correct.
    var total = parse_amount("$4,000.00") + parse_amount("1,234.56") \
        + parse_amount("(50.00)") + parse_amount("none")
    var sum_ok = _close(total, 5184.56)
    print("[" + ("PASS" if sum_ok else "FAIL") + "] sum of mixed strings = " + String(total) + " (want 5184.56)")
    ok = sum_ok and ok

    print()
    if ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("amounts-test failed")
