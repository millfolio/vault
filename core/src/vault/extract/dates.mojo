"""dates — fold a bank-statement M/D date into a sortable ISO date.

Statements print transaction dates as `M/D` or `MM/DD`; the year lives only in
the statement header / period line. `iso_date(year, md)` combines a known
statement year with such a date into `"YYYY-MM-DD"`, so a generated vault program
can compare/sort transactions lexicographically (and ask_local no longer has to
invent a year it can't see in a mid-statement chunk).

Pure Mojo, no deps — re-exported by vault.mojo into the `from vault import *` tool
surface and unit-tested by dates_test.mojo (`pixi run test-dates`).
"""


def _atoi(s: String) -> Int:
    """Leading run of digits as an Int (skips surrounding spaces); -1 if none.
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
            break  # digits ended (e.g. trailing space)
    return n if any else -1


def _pad2(n: Int) -> String:
    return (String("0") + String(n)) if n < 10 else String(n)


def iso_date(year: Int, md: String) raises -> String:
    """Combine `year` with a `M/D` (or `MM/DD`, `M/D/YY`, `M/D/YYYY`) date into
    `"YYYY-MM-DD"`. A 2- or 4-digit year embedded in `md` overrides `year`
    (2-digit -> 2000+). Accepts `/` or `-` separators and surrounding spaces.
    Returns `""` when month/day can't be parsed or are out of range — callers
    treat that as "not a date" (never fabricate)."""
    var t = String(md.strip())
    if t == "":
        return String("")
    # Normalize '-' separators to '/' so one split handles both.
    var norm = String("")
    var b = t.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        norm += "/" if c == 45 else chr(c)
    var parts = norm.split("/")
    if len(parts) < 2:
        return String("")
    var mo = _atoi(String(parts[0]))
    var da = _atoi(String(parts[1]))
    var yr = year
    if len(parts) >= 3:
        var y = _atoi(String(parts[2]))
        if y >= 0:
            yr = (2000 + y) if y < 100 else y
    if mo < 1 or mo > 12 or da < 1 or da > 31 or yr <= 0:
        return String("")
    return String(yr) + "-" + _pad2(mo) + "-" + _pad2(da)
