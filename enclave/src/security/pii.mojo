"""PII shapes — one definition of "looks like private data", two consumers.

  • `redact_pii(payload)` — the EgressGuard's LAST line (egress.mojo mechanism
    3): scrub PII-shaped spans from an outbound payload that already cleared
    the canary/fingerprint tripwires.
  • `looks_pii(value)` — fingerprint SELECTION (seed.mojo): which real cell
    values from the vault's CSVs are worth arming the guard with.

Both are deliberately IDENTIFIER-shaped only — emails and long digit runs
(SSNs, cards, phones, account numbers). Free text (merchant names, dates,
amounts) must never qualify: users legitimately type merchant names into
questions, and the manifest legitimately carries dates and byte sizes, so
matching those would block real asks.

Redaction thresholds (why two):
  • dash-grouped runs redact at ≥ 9 digits — catches `123-45-6789` (SSN) and
    `555-123-4567` (phone) while ISO dates (`2026-07-15` = 8 digits) survive.
  • contiguous runs redact at ≥ 12 digits — catches 15/16-digit card numbers
    while manifest byte sizes (≤ ~10 digits) and the Mojo nightly pin
    (`2026062706`) survive. A contiguous 9-digit SSN slips REDACTION, but a
    real one from the vault is caught upstream by the fingerprint tripwire
    (seed.mojo samples it via `looks_pii`, which takes whole cells at ≥ 9).
"""

comptime _NONE = 0
comptime _EMAIL = 1
comptime _NUMBER = 2

comptime _GROUPED_DIGITS = 9  # dash-grouped runs: SSN/phone shaped
comptime _CONTIGUOUS_DIGITS = 12  # single runs: card/account shaped


def _is_digit(c: Int) -> Bool:
    return c >= 48 and c <= 57  # '0'..'9'


def _is_alpha(c: Int) -> Bool:
    return (c >= 97 and c <= 122) or (c >= 65 and c <= 90)


def _is_email_local(c: Int) -> Bool:
    """RFC-lite local-part chars: alnum + `._%+-`."""
    if _is_digit(c) or _is_alpha(c):
        return True
    return c == 46 or c == 95 or c == 37 or c == 43 or c == 45


def _is_email_domain(c: Int) -> Bool:
    """Domain chars: alnum + `.-`."""
    if _is_digit(c) or _is_alpha(c):
        return True
    return c == 46 or c == 45


def _mark_emails(payload: String, mut marks: List[Int]):
    """Mark every email-shaped span (`local@domain.tld`) in `marks`."""
    var b = payload.as_bytes()
    var n = len(b)
    for i in range(n):
        if Int(b[i]) != 64 or marks[i] != _NONE:  # '@'
            continue
        # Expand LEFT over local-part chars.
        var s = i
        while (
            s > 0 and _is_email_local(Int(b[s - 1])) and marks[s - 1] == _NONE
        ):
            s -= 1
        if s == i:
            continue  # empty local part — a bare '@' is not an email
        # Expand RIGHT over domain chars, then trim trailing `.`/`-` (an email
        # at the end of a sentence keeps its period out of the span).
        var e = i + 1
        while e < n and _is_email_domain(Int(b[e])):
            e += 1
        while e > i + 1 and (Int(b[e - 1]) == 46 or Int(b[e - 1]) == 45):
            e -= 1
        # The domain needs an interior dot with ≥ 1 char before and ≥ 2 after.
        var has_dot = False
        var j = i + 2
        while j <= e - 3:
            if Int(b[j]) == 46:
                has_dot = True
                break
            j += 1
        if not has_dot:
            continue
        for k in range(s, e):
            marks[k] = _EMAIL


def _mark_digit_runs(payload: String, mut marks: List[Int]):
    """Mark digit runs (digits optionally joined by single dashes) that clear
    the grouped/contiguous thresholds documented in the module docstring."""
    var b = payload.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        if marks[i] != _NONE or not _is_digit(Int(b[i])):
            i += 1
            continue
        var start = i
        var end = i  # one past the last DIGIT (a trailing dash stays out)
        var digits = 0
        var groups = 1
        var j = i
        while j < n and marks[j] == _NONE:
            var c = Int(b[j])
            if _is_digit(c):
                digits += 1
                j += 1
                end = j
                continue
            # A single dash joining two digit groups extends the run.
            if (
                c == 45
                and j + 1 < n
                and _is_digit(Int(b[j + 1]))
                and marks[j + 1] == _NONE
            ):
                groups += 1
                j += 1
                continue
            break
        if (groups >= 2 and digits >= _GROUPED_DIGITS) or (
            groups == 1 and digits >= _CONTIGUOUS_DIGITS
        ):
            for k in range(start, end):
                marks[k] = _NUMBER
        i = j if j > i else i + 1


def redact_pii(payload: String) raises -> String:
    """Best-effort scrub of PII-shaped spans: emails → `[redacted-email]`,
    qualifying digit runs → `[redacted-number]`. Belt-and-suspenders BEHIND the
    tripwires — sends are never blocked here, only cleaned."""
    var b = payload.as_bytes()
    var n = len(b)
    if n == 0:
        return payload.copy()
    var marks = List[Int](capacity=n)
    for _ in range(n):
        marks.append(_NONE)
    _mark_emails(payload, marks)
    _mark_digit_runs(payload, marks)
    var out = String("")
    var i = 0
    while i < n:
        var kind = marks[i]
        var j = i
        while j < n and marks[j] == kind:
            j += 1
        if kind == _NONE:
            out += String(payload[byte=i:j])
        elif kind == _EMAIL:
            out += "[redacted-email]"
        else:
            out += "[redacted-number]"
        i = j
    return out^


def looks_pii(value: String) -> Bool:
    """Whole-value test for fingerprint selection: is this CSV cell an
    identifier-shaped span? True for emails and for digit groups (separated by
    dashes/spaces) totalling ≥ 9 digits — SSNs, cards, phones, account numbers.
    Merchant names, amounts, and dates all fail, on purpose (see module
    docstring): a fingerprinted merchant name would block the very questions
    users are supposed to ask."""
    var v = String(value.strip())
    var b = v.as_bytes()
    var n = len(b)
    if n < 6:  # shortest plausible identifier (a@b.cd)
        return False
    # Email shape: one '@', non-empty valid local, dotted valid domain.
    var at = v.find("@")
    if at > 0 and v.find("@", at + 1) == -1:
        var ok = True
        for i in range(at):
            if not _is_email_local(Int(b[i])):
                ok = False
                break
        var has_dot = False
        if ok and at + 4 <= n:  # room for x.yz
            var i2 = at + 1
            while i2 < n:
                var c = Int(b[i2])
                if not _is_email_domain(c):
                    ok = False
                    break
                if c == 46 and i2 > at + 1 and i2 <= n - 3:
                    has_dot = True
                i2 += 1
        else:
            ok = False
        if ok and has_dot:
            return True
    # Digit-group shape: nothing but digits, dashes, and spaces — and enough
    # digits. (Spaces allowed HERE, unlike redaction: a whole cell of
    # `4111 1111 1111 1111` is unambiguously one value.)
    var digits = 0
    for i3 in range(n):
        var c2 = Int(b[i3])
        if _is_digit(c2):
            digits += 1
        elif c2 != 45 and c2 != 32:
            return False
    return digits >= _GROUPED_DIGITS
