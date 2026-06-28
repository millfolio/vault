"""amounts — parse a money string from a bank statement into a Float64.

Statement amounts come through as `$4,000.00`, `1,234.56`, `-31.00`, `(42.10)`
(accounting negative), sometimes with a trailing currency word. Plain `atof`
chokes on the `$`, the comma thousands-separators, and parens — crashing a
generated "total spent" program mid-sum. `parse_amount` strips all of that and
returns the value (`0.0` when there's no number, so it's safe to add in a sum).

Pure Mojo, no deps — re-exported by vault.mojo into the `from vault import *` tool
surface and unit-tested by amounts_test.mojo (`pixi run test-amounts`).
"""


def parse_amount(s: String) raises -> Float64:
    """Parse a statement money string into a Float64. Ignores `$`, commas, spaces,
    and a trailing currency word; treats a leading `-` OR surrounding `()` as
    negative; keeps only the first `.` as the decimal point. Returns `0.0` when no
    digits are present (e.g. "none", ""), so callers can sum results unconditionally."""
    var t = String(s.strip())
    if t == "":
        return 0.0
    var neg = False
    var digits = String("")   # accumulates 0-9 and a single '.'
    var seen_dot = False
    var b = t.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 48 and c <= 57:          # 0-9
            digits += chr(c)
        elif c == 46:                    # '.'  — keep only the first (decimal)
            if not seen_dot:
                digits += "."
                seen_dot = True
        elif c == 45:                    # '-'  — negative only if it leads the number
            if digits.byte_length() == 0:
                neg = True
        elif c == 40:                    # '('  — accounting negative
            neg = True
        # everything else ($, commas, spaces, letters) is dropped
    if digits == "" or digits == ".":
        return 0.0
    var v = atof(digits)
    return -v if neg else v


def format_money(x: Float64) raises -> String:
    """Format a Float64 as a clean currency string — `$31,241.06`, `-$5.00`, `$0.00`
    — rounded to cents with thousands separators. Use this for any dollar amount in
    an answer instead of `String(x)`, which prints raw floats (`$31241.0599999998`)."""
    var neg = x < 0.0
    var v = -x if neg else x
    var cents = Int(v * 100.0 + 0.5)        # round to the nearest cent
    var dollars = cents // 100
    var rem = cents % 100
    var ds = String(dollars)
    var b = ds.as_bytes()
    var n = len(b)
    var grouped = String("")
    for i in range(n):
        if i > 0 and (n - i) % 3 == 0:
            grouped += ","
        grouped += chr(Int(b[i]))
    var cs = String(rem) if rem >= 10 else (String("0") + String(rem))
    var out = String("$") + grouped + "." + cs
    return ("-" + out) if neg else out^
