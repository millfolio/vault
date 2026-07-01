"""Transactions — invariant-aware, reconcile-validated transaction extraction.

A statement's full text (extracted ONCE at index time, with whole-document
context) is parsed into structured `Txn` records WITHOUT a per-issuer template.
We never trust a layout we haven't seen; instead we:

  1. extract candidate (date, description, amount) records using FORMAT-AGNOSTIC
     token shapes — date tokens (`M/D`) and money tokens (a number with exactly
     two decimal places, which also drops the `$5`/`$50` noise that pollutes
     statement legalese), and
  2. VALIDATE the extraction against the statement's OWN arithmetic — either the
     running-balance recurrence (`balance[i] == balance[i-1] ± amount[i]`, which
     also yields each transaction's direction) or reconciliation against the
     statement's printed control totals (Total deposits / withdrawals / purchases).

The records are trusted ONLY when they reconcile (`Extraction.reconciled`).
Otherwise the caller falls back (the local model, or an honest "couldn't parse
statement X reliably") instead of emitting a confident-but-wrong number — every
statement ships its own checksum, so we can tell when we're right.

Pure Mojo; depends only on `vault.amounts` + `vault.dates`. Unit-tested with
SYNTHETIC statement text (no private data) by transactions_test.mojo
(`pixi run test-transactions`).
"""

from vault.extract.amounts import parse_amount
from vault.extract.dates import iso_date


comptime _EPS = 0.005  # half-a-cent tolerance for money reconciliation


struct Txn(Copyable, Movable):
    """One extracted transaction. `amount` is a non-negative MAGNITUDE; the sign of
    the money flow is in `direction` (`"credit"` = money in, `"debit"` = money out,
    `""` = unknown). `date` is the raw statement date token (e.g. `"4/20"`).
    `tags` are derived category tags (e.g. `phone`, `travel`) materialised at index
    time from the description — empty at extraction, populated when read back from
    the index (see `select_txns`); multi-valued (see `vault.derive`)."""

    var date: String
    var desc: String
    var amount: Float64
    var direction: String
    var tags: List[String]

    def __init__(
        out self,
        var date: String,
        var desc: String,
        amount: Float64,
        var direction: String,
    ):
        # 4-arg constructor: `tags` default empty and are assigned at
        # materialisation (index time) / when read back from the index, not at
        # extraction — so the extraction sites stay unchanged.
        self.date = date^
        self.desc = desc^
        self.amount = amount
        self.direction = direction^
        self.tags = List[String]()


@fieldwise_init
struct Extraction(Copyable, Movable):
    """The result of extracting one document. `reconciled` is the trust signal: the
    extracted set matched the statement's own arithmetic (`method` says how —
    `"balance-recurrence"` or `"sum-vs-total"`; `"unreconciled"` if neither closed).
    `note` is a short human-readable detail."""

    var txns: List[Txn]
    var reconciled: Bool
    var method: String
    var note: String


# ── format-agnostic token scanners ────────────────────────────────────────────


def _is_digit(c: Int) -> Bool:
    return c >= 48 and c <= 57


def _has_cents(tok: String) -> Bool:
    """True iff `tok` ends in `.dd` (a real money amount). This is what separates a
    transaction amount (`193.69`, `1,854.00`) from statement noise like `$5`, `$50`,
    `100 miles`, account/ref numbers — they have no two-decimal tail."""
    var b = tok.as_bytes()
    var dot = -1
    for i in range(len(b)):
        if Int(b[i]) == 46:  # '.'
            dot = i
    if dot < 0 or len(b) - dot - 1 != 2:
        return False
    return _is_digit(Int(b[dot + 1])) and _is_digit(Int(b[dot + 2]))


def _money_tokens(line: String) raises -> List[String]:
    """Every money amount on `line`, in order, as parse_amount-ready strings. A token
    is a maximal run of digits/commas/dots ending in `.dd`; a surrounding `( )` (or
    leading `(`) marks an accounting negative, preserved for parse_amount."""
    var out = List[String]()
    var b = line.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = Int(b[i])
        if _is_digit(c):
            var tok = String("")
            var j = i
            while j < n:
                var d = Int(b[j])
                if _is_digit(d) or d == 44 or d == 46:  # digit , .
                    tok += chr(d)
                    j += 1
                else:
                    break
            if _has_cents(tok):
                var neg = i > 0 and Int(b[i - 1]) == 40  # leading '('
                if j < n and Int(b[j]) == 41:  # trailing ')'
                    neg = True
                    j += 1
                out.append((String("(") + tok + ")") if neg else tok)
            i = j
        else:
            i += 1
    return out^


@fieldwise_init
struct _Money(Copyable, ImplicitlyCopyable, Movable):
    """A money token with its parsed value AND its character offset (column) in the
    source line. On LAYOUT-PRESERVED statement text (columns aligned with spaces),
    the offset tells which column — deposit / withdrawal / running balance — a token
    sits in, which recovers per-transaction direction on intra-day rows where the
    balance alone is ambiguous."""

    var value: Float64  # signed (accounting parens / leading '-' preserved)
    var col: Int  # END offset of the token (right edge — columns are right-aligned)


def _money_with_cols(line: String) raises -> List[_Money]:
    """Like `_money_tokens`, but each token carries its parsed value AND its right-edge
    character offset. Statement amount columns are right-aligned, so the END offset is
    the stable column key (a 5-digit amount and a 3-digit amount in the same column
    share a right edge, not a left edge)."""
    var out = List[_Money]()
    var b = line.as_bytes()
    var n = len(b)
    var i = 0
    while i < n:
        var c = Int(b[i])
        if _is_digit(c):
            var tok = String("")
            var j = i
            while j < n:
                var d = Int(b[j])
                if _is_digit(d) or d == 44 or d == 46:  # digit , .
                    tok += chr(d)
                    j += 1
                else:
                    break
            if _has_cents(tok):
                var neg = i > 0 and Int(b[i - 1]) == 40  # leading '('
                var end = j
                if j < n and Int(b[j]) == 41:  # trailing ')'
                    neg = True
                    end = j + 1
                var v = parse_amount(tok)
                if v < 0.0:
                    v = -v
                out.append(_Money(-v if neg else v, end))
                i = j + 1 if (j < n and Int(b[j]) == 41) else j
            else:
                i = j
        else:
            i += 1
    return out^


def _leading_date(line: String) raises -> String:
    """The leading `M/D`(`/YY`) date token of `line` (after spaces), or `""`. Validated
    via iso_date so check numbers / ref numbers (no valid month/day) are rejected.
    """
    var t = String(line.strip())
    var b = t.as_bytes()
    var i = 0
    var tok = String("")
    while i < len(b):
        var c = Int(b[i])
        if _is_digit(c) or c == 47:  # digit or '/'
            tok += chr(c)
            i += 1
        else:
            break
    if iso_date(2000, tok) != "":  # valid month/day shape
        return tok^
    return String("")


def _lower(s: String) raises -> String:
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        out += chr(c + 32) if (c >= 65 and c <= 90) else chr(c)
    return out^


def _contains_any(hay: String, needles: List[String]) raises -> Bool:
    for i in range(len(needles)):
        if hay.find(needles[i]) != -1:
            return True
    return False


def _replace(s: String, old: String, new: String) raises -> String:
    if old == "":
        return s
    var parts = s.split(old)
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += new
        out += String(parts[i])
    return out^


def _strip_money_and_date(line: String, date: String) raises -> String:
    """`line` with its leading date token and money tokens blanked, collapsed to a
    description fragment (single-spaced, trimmed)."""
    var moneys = _money_tokens(line)
    var s = String(line)
    if date != "":
        var t = String(s.strip())
        if t.startswith(date):
            s = String(
                String(unsafe_from_utf8=t.as_bytes()[date.byte_length() :])
            )
    for m in range(len(moneys)):
        var bare = moneys[m]
        if bare.startswith("("):  # restore the digits-only form to blank it out
            bare = String(
                String(
                    unsafe_from_utf8=bare.as_bytes()[1 : bare.byte_length() - 1]
                )
            )
        s = _replace(s, bare, String(" "))
    var parts = s.split()
    var out = String("")
    for p in range(len(parts)):
        if p > 0:
            out += " "
        out += String(parts[p])
    return out^


# ── section / summary classification (lowercased lines) ───────────────────────


def _summary_phrases() raises -> List[String]:
    """Lines that are control totals / headers, NOT transactions — they close the
    current transaction run so their figures don't pollute a record."""
    var p = List[String]()
    p.append(String("total "))
    p.append(String("totals"))
    p.append(String("beginning balance"))
    p.append(String("previous balance"))
    p.append(String("opening balance"))
    p.append(String("ending balance"))
    p.append(String("new balance"))
    p.append(String("deposits/additions"))  # summary totals (may sit BELOW the
    p.append(
        String("withdrawals/subtractions")
    )  # transaction list) — close the run
    p.append(
        String("deposits and additions")
    )  # so they don't pollute the last record
    p.append(String("withdrawals and subtractions"))
    p.append(String("minimum payment"))
    p.append(String("account summary"))
    p.append(String("statement period"))
    return p^


def _credit_header_phrases() raises -> List[String]:
    var p = List[String]()
    p.append(String("payments and other credits"))
    p.append(String("deposits and other"))
    p.append(String("deposits and additions"))
    return p^


def _debit_header_phrases() raises -> List[String]:
    var p = List[String]()
    p.append(String("purchases and"))
    p.append(String("withdrawals and"))
    p.append(String("charges"))
    return p^


# ── printed control totals ────────────────────────────────────────────────────


def _printed_total(text_lower: String, phrases: List[String]) raises -> Float64:
    """The amount on the FIRST line containing any of `phrases` (case-insensitive) —
    statements print these once, with the figure last on the line. Returns a magnitude,
    or a negative sentinel (-1.0) when no such line/amount is found."""
    var lines = text_lower.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if _contains_any(line, phrases):
            var moneys = _money_tokens(line)
            if len(moneys) > 0:
                var v = parse_amount(moneys[len(moneys) - 1])
                return v if v >= 0.0 else -v
    return -1.0


def _credit_total_phrases() raises -> List[String]:
    var p = List[String]()
    p.append(String("total deposits"))
    p.append(String("deposits and other"))
    p.append(String("deposits/additions"))  # Wells Fargo account summary
    p.append(String("payments and other credits"))
    p.append(String("total credits"))
    p.append(String("total payments"))
    return p^


def _debit_total_phrases() raises -> List[String]:
    var p = List[String]()
    p.append(String("total withdrawals"))
    p.append(String("withdrawals and other"))
    p.append(String("withdrawals/subtractions"))  # Wells Fargo account summary
    p.append(String("total purchases"))
    p.append(String("total debits"))
    p.append(String("total charges"))
    return p^


def _begin_balance(text_lower: String) raises -> Float64:
    """The statement's opening balance (anchors the running-balance recurrence), or a
    negative sentinel when not printed."""
    var lines = text_lower.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if (
            line.find("beginning balance") != -1
            or line.find("previous balance") != -1
            or line.find("opening balance") != -1
        ):
            var moneys = _money_tokens(line)
            if len(moneys) > 0:
                return parse_amount(moneys[len(moneys) - 1])
    return -1.0


# ── records → reconciled extraction ───────────────────────────────────────────


@fieldwise_init
struct _Record(Copyable, Movable):
    var date: String
    var desc: String
    var moneys: List[String]  # money tokens in the record window, in order
    var section: String  # "credit" | "debit" | "" — from the section header above it


def _parse_records(text: String) raises -> List[_Record]:
    """Walk lines; each date-led line opens a record that runs until the next date or
    a summary/header line. Section headers ("Payments and Other Credits", "Purchases…")
    tag the records beneath them so direction is known without a running balance.
    """
    var recs = List[_Record]()
    var lines = text.split("\n")
    var summ = _summary_phrases()
    var credit_hdr = _credit_header_phrases()
    var debit_hdr = _debit_header_phrases()

    var open = False
    var cur_date = String("")
    var cur_desc = String("")
    var cur_money = List[String]()
    var cur_section = String("")
    var section = String("")

    for i in range(len(lines)):
        var line = String(lines[i])
        var ll = _lower(line)
        var d = _leading_date(line)

        # A summary/total line ends the current run (and isn't a transaction).
        if d == "" and _contains_any(ll, summ):
            if open:
                recs.append(
                    _Record(
                        cur_date.copy(),
                        String(cur_desc.strip()),
                        cur_money.copy(),
                        cur_section.copy(),
                    )
                )
                open = False
            continue

        # Section headers set the running direction for records that follow.
        if d == "":
            if _contains_any(ll, credit_hdr):
                section = String("credit")
            elif _contains_any(ll, debit_hdr):
                section = String("debit")

        if d != "":
            if open:
                recs.append(
                    _Record(
                        cur_date.copy(),
                        String(cur_desc.strip()),
                        cur_money.copy(),
                        cur_section.copy(),
                    )
                )
            open = True
            cur_date = d
            cur_desc = String("")
            cur_money = List[String]()
            cur_section = section.copy()

        if not open:
            continue

        var ms = _money_tokens(line)
        for m in range(len(ms)):
            cur_money.append(ms[m].copy())
        var frag = _strip_money_and_date(line, d)
        if frag != "":
            if cur_desc != "":
                cur_desc += " "
            cur_desc += frag

    if open:
        recs.append(
            _Record(
                cur_date.copy(),
                String(cur_desc.strip()),
                cur_money.copy(),
                cur_section.copy(),
            )
        )
    return recs^


def _close(a: Float64, b: Float64) -> Bool:
    var d = a - b
    return d < _EPS and d > -_EPS


# ── column-position direction detection (layout-preserved text) ────────────────


@fieldwise_init
struct _PosRecord(Copyable, Movable):
    """A transaction record that preserves each money token's column (right-edge
    offset) — the input for column-position direction detection."""

    var date: String
    var desc: String
    var moneys: List[_Money]


def _parse_pos_records(text: String) raises -> List[_PosRecord]:
    """Like `_parse_records` but keeps each money token's column. A date-led line opens
    a record that runs until the next date / a summary line; continuation lines (no date,
    no totals) extend the description and contribute any money tokens they carry.
    """
    var recs = List[_PosRecord]()
    var lines = text.split("\n")
    var summ = _summary_phrases()

    var open = False
    var cur_date = String("")
    var cur_desc = String("")
    var cur_money = List[_Money]()

    for i in range(len(lines)):
        var line = String(lines[i])
        var ll = _lower(line)
        var d = _leading_date(line)

        if d == "" and _contains_any(ll, summ):
            if open:
                recs.append(
                    _PosRecord(
                        cur_date.copy(),
                        String(cur_desc.strip()),
                        cur_money.copy(),
                    )
                )
                open = False
            continue

        if d != "":
            if open:
                recs.append(
                    _PosRecord(
                        cur_date.copy(),
                        String(cur_desc.strip()),
                        cur_money.copy(),
                    )
                )
            open = True
            cur_date = d
            cur_desc = String("")
            cur_money = List[_Money]()

        if not open:
            continue

        var ms = _money_with_cols(line)
        for m in range(len(ms)):
            cur_money.append(ms[m].copy())
        var frag = _strip_money_and_date(line, d)
        if frag != "":
            if cur_desc != "":
                cur_desc += " "
            cur_desc += frag

    if open:
        recs.append(
            _PosRecord(
                cur_date.copy(), String(cur_desc.strip()), cur_money.copy()
            )
        )
    return recs^


def _column_direction(
    recs: List[_PosRecord],
    begin: Float64,
    ending: Float64,
    credit_total: Float64,
    debit_total: Float64,
) raises -> Extraction:
    """Reconcile via column position + the running-balance recurrence, handling
    INTRA-DAY rows (several transactions share a day; only the last shows a balance).

    Layout assumption (standard statement column order, validated by the arithmetic
    below — never trusted on its own): each record's LAST money token is its running
    balance IFF the record has ≥2 tokens; a 1-token record is an intra-day amount with
    no balance. Among the amount tokens, the left column = deposits (credit), the right
    column = withdrawals (debit) — but the column is only a HINT to seed the sign search.

    The trust gate is the recurrence: walking records in order, `running ± amount` must
    equal every printed balance checkpoint (within half a cent). Within a checkpoint
    group of intra-day amounts we search sign assignments (seeded by the column hint) for
    the one that closes the group. We reconcile only when EVERY checkpoint closes and the
    final balance matches the printed ending balance (or the per-direction sums match the
    printed deposit/withdrawal totals). Otherwise we abstain."""
    if begin < 0.0 or len(recs) == 0:
        return Extraction(
            List[Txn](), False, String("unreconciled"), String("")
        )

    # Gather amount-token columns (every non-balance token) to find the deposit |
    # withdrawal split. The balance token is the last on a ≥2-token record.
    var amt_cols = List[Int]()
    for i in range(len(recs)):
        ref r = recs[i]
        var nm = len(r.moneys)
        if nm == 0:
            continue
        var amt_n = nm - 1 if nm >= 2 else nm  # last token is balance when ≥2
        for k in range(amt_n):
            amt_cols.append(r.moneys[k].col)
    if len(amt_cols) == 0:
        return Extraction(
            List[Txn](), False, String("unreconciled"), String("")
        )

    # Split the amount columns into a left (deposit) and right (withdrawal) band at
    # the LARGEST gap among sorted right-edges. This is just the sign seed; wide
    # 5-digit amounts that drift across the boundary are corrected by the recurrence.
    var cols = amt_cols.copy()
    for a in range(1, len(cols)):  # insertion sort
        var key = cols[a]
        var b = a - 1
        while b >= 0 and cols[b] > key:
            cols[b + 1] = cols[b]
            b -= 1
        cols[b + 1] = key
    var split = cols[len(cols) - 1] + 1  # default: everything is "deposit"
    var best_gap = 0
    for k in range(1, len(cols)):
        var g = cols[k] - cols[k - 1]
        if g > best_gap:
            best_gap = g
            split = (cols[k] + cols[k - 1]) // 2
    # A meaningful split needs a real gap; if the columns are one tight band, treat
    # them all as the same (left) band — the recurrence sign-search still resolves.
    if best_gap < 3:
        split = cols[len(cols) - 1] + 1

    # Walk records; reconcile the running balance through intra-day groups.
    var prev = begin
    var pend_amt = List[Float64]()  # amount magnitudes pending a checkpoint
    var pend_left = List[Bool]()  # column hint: True = left/deposit band
    var pend_date = List[String]()
    var pend_desc = List[String]()
    var out = List[Txn]()
    var sum_credit = 0.0
    var sum_debit = 0.0
    var done = (
        False  # set once the running balance reaches the printed ending balance
    )

    for i in range(len(recs)):
        # Once the running balance has reached the statement's printed ending balance,
        # the transaction history is over; ignore the recap pages ("Summary of checks
        # written", legalese) that follow and may re-list amounts.
        if done:
            break
        ref r = recs[i]
        var nm = len(r.moneys)
        if nm == 0:
            continue
        var has_bal = nm >= 2
        var amt_n = nm - 1 if has_bal else nm
        for k in range(amt_n):
            var m = r.moneys[k]
            var mag = m.value if m.value >= 0.0 else -m.value
            pend_amt.append(mag)
            pend_left.append(m.col <= split)
            pend_date.append(r.date.copy())
            pend_desc.append(r.desc.copy())

        if has_bal:
            var bal = r.moneys[nm - 1].value
            var target = bal - prev
            var ng = len(pend_amt)
            if (
                ng == 0 or ng > 16
            ):  # nothing to place / refuse to brute-force huge groups
                return Extraction(
                    List[Txn](), False, String("unreconciled"), String("")
                )

            # Seed from the column hint: deposits +, withdrawals −.
            var seed = 0
            for g in range(ng):
                if pend_left[g]:
                    seed |= 1 << g  # bit set ⇒ positive (deposit)
            # Search sign assignments, the column-hint seed first, for one closing the group.
            var found = -1
            var limit = 1 << ng
            for s in range(limit):
                var bits = seed ^ s  # explore around the seed
                var ssum = 0.0
                for g in range(ng):
                    if (bits >> g) & 1:
                        ssum += pend_amt[g]
                    else:
                        ssum -= pend_amt[g]
                if _close(ssum, target):
                    found = bits
                    break
            if found < 0:
                return Extraction(
                    List[Txn](), False, String("unreconciled"), String("")
                )

            for g in range(ng):
                var is_credit = ((found >> g) & 1) == 1
                if is_credit:
                    sum_credit += pend_amt[g]
                    out.append(
                        Txn(
                            pend_date[g].copy(),
                            pend_desc[g].copy(),
                            pend_amt[g],
                            String("credit"),
                        )
                    )
                else:
                    sum_debit += pend_amt[g]
                    out.append(
                        Txn(
                            pend_date[g].copy(),
                            pend_desc[g].copy(),
                            pend_amt[g],
                            String("debit"),
                        )
                    )
            prev = bal
            pend_amt = List[Float64]()
            pend_left = List[Bool]()
            pend_date = List[String]()
            pend_desc = List[String]()
            if ending >= 0.0 and _close(prev, ending):
                done = True

    # Any amounts left without a closing balance ⇒ the recurrence didn't fully close.
    if len(pend_amt) != 0:
        return Extraction(
            List[Txn](), False, String("unreconciled"), String("")
        )

    # Final trust gate: the recurrence must land on the printed ending balance, OR the
    # per-direction sums must match the printed deposit/withdrawal control totals.
    var ends_ok = ending >= 0.0 and _close(prev, ending)
    var sums_ok = (
        credit_total >= 0.0
        and debit_total >= 0.0
        and _close(sum_credit, credit_total)
        and _close(sum_debit, debit_total)
    )
    if ends_ok or sums_ok:
        return Extraction(
            out^,
            True,
            String("column-direction"),
            String("running balance + column directions reconcile across ")
            + String(len(out))
            + " transaction(s)",
        )
    return Extraction(List[Txn](), False, String("unreconciled"), String(""))


def _ending_balance(text_lower: String) raises -> Float64:
    """The statement's printed ending/new balance, or a negative sentinel."""
    var lines = text_lower.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if (
            line.find("ending balance") != -1
            or line.find("new balance") != -1
            or line.find("ending daily balance") != -1
        ):
            # skip the legalese sentence ("The Ending Daily Balance does not reflect…")
            var moneys = _money_tokens(line)
            if len(moneys) > 0:
                return parse_amount(moneys[len(moneys) - 1])
    return -1.0


def extract_transactions(text: String) raises -> Extraction:
    """Extract + reconcile the transactions in one statement's text.

    Tries the running-balance recurrence first (where records carry amount AND a
    running balance — it both validates and assigns direction), then sum-vs-printed-
    total (using section headers for direction). Sets `reconciled` only when the
    statement's own arithmetic closes."""
    var recs = _parse_records(text)
    var tl = _lower(text)
    var begin0 = _begin_balance(tl)
    var ending0 = _ending_balance(tl)
    var credit0 = _printed_total(tl, _credit_total_phrases())
    var debit0 = _printed_total(tl, _debit_total_phrases())

    # ── Method 1: running-balance recurrence ──────────────────────────────────
    # Needs ≥2 money tokens per record (amount, …, running balance) + an anchor
    # (printed beginning balance). For each record, the last token must equal the
    # previous balance ± the first token; the matching sign IS the direction.
    var begin = begin0
    if begin >= 0.0 and len(recs) > 0:
        var ok = True
        var prev = begin
        var bal_txns = List[Txn]()
        for i in range(len(recs)):
            ref r = recs[i]
            if len(r.moneys) < 2:
                ok = False
                break
            var amt = parse_amount(r.moneys[0])
            if amt < 0.0:
                amt = -amt
            var bal = parse_amount(r.moneys[len(r.moneys) - 1])
            if _close(prev + amt, bal):
                bal_txns.append(
                    Txn(r.date.copy(), r.desc.copy(), amt, String("credit"))
                )
            elif _close(prev - amt, bal):
                bal_txns.append(
                    Txn(r.date.copy(), r.desc.copy(), amt, String("debit"))
                )
            else:
                ok = False
                break
            prev = bal
        if ok:
            return Extraction(
                bal_txns^,
                True,
                String("balance-recurrence"),
                String("running balance closes across ")
                + String(len(recs))
                + " record(s)",
            )

    # ── Method "column-direction": column position + recurrence over intra-day groups ─
    # On LAYOUT-PRESERVED text each money token carries its column; this resolves
    # intra-day rows (only the day's last row prints a balance) that strict Method 1
    # rejects (it requires a balance on EVERY record). Gated by the same arithmetic.
    var pos_recs = _parse_pos_records(text)
    var cd = _column_direction(pos_recs, begin0, ending0, credit0, debit0)
    if cd.reconciled:
        return cd^

    # ── Method 2: sum vs printed control totals (direction from section headers) ─
    var credit_total = credit0
    var debit_total = debit0
    var txns = List[Txn]()
    var sum_credit = 0.0
    var sum_debit = 0.0
    var sum_all = 0.0
    for i in range(len(recs)):
        ref r = recs[i]
        if len(r.moneys) == 0:
            continue
        var amt = parse_amount(r.moneys[0])
        if amt < 0.0:
            amt = -amt
        var dir = r.section if r.section != "" else String("debit")
        if dir == "credit":
            sum_credit += amt
        else:
            sum_debit += amt
        sum_all += amt
        txns.append(Txn(r.date.copy(), r.desc.copy(), amt, dir^))

    # Both totals printed (sectioned statement): each side must close.
    if credit_total >= 0.0 and debit_total >= 0.0:
        if _close(sum_credit, credit_total) and _close(sum_debit, debit_total):
            return Extraction(
                txns^,
                True,
                String("sum-vs-total"),
                String("credits + debits reconcile to printed totals"),
            )
    # Single total printed (e.g. a card statement's purchases only).
    elif debit_total >= 0.0 and _close(sum_all, debit_total):
        return Extraction(
            txns^,
            True,
            String("sum-vs-total"),
            String("transactions sum to the printed total ")
            + String(debit_total),
        )
    elif credit_total >= 0.0 and _close(sum_all, credit_total):
        return Extraction(
            txns^,
            True,
            String("sum-vs-total"),
            String("transactions sum to the printed total ")
            + String(credit_total),
        )

    # ── Couldn't reconcile: return best-effort, flagged untrusted. ─────────────
    return Extraction(
        txns^,
        False,
        String("unreconciled"),
        String("extracted ")
        + String(len(txns))
        + " candidate(s) but they did not reconcile against the statement's"
        " totals",
    )


# ── persistence + enumeration (PURE; index.mojo wraps these with I/O) ──────────
# These live here, not in index.mojo, so the hermetic `pixi run test` suite can
# exercise them without pulling in the lancedb FFI that index.mojo imports.


def _esc(s: String) raises -> String:
    """Backslash-escape \\, tab, newline, CR so a value is a single TSV cell."""
    var o = _replace(s, String("\\"), String("\\\\"))
    o = _replace(o, String("\t"), String("\\t"))
    o = _replace(o, String("\n"), String("\\n"))
    o = _replace(o, String("\r"), String("\\r"))
    return o^


def _unesc(s: String) raises -> String:
    var out = String("")
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        var c = Int(b[i])
        if c == 92 and i + 1 < len(b):  # backslash
            var n = Int(b[i + 1])
            if n == 116:  # 't'
                out += "\t"
                i += 2
                continue
            elif n == 110:  # 'n'
                out += "\n"
                i += 2
                continue
            elif n == 114:  # 'r'
                out += "\r"
                i += 2
                continue
            elif n == 92:  # backslash
                out += "\\"
                i += 2
                continue
        out += chr(c)
        i += 1
    return out^


@fieldwise_init
struct TxnRow(Copyable, Movable):
    """A persisted, file-keyed transaction row. Only RECONCILED transactions are
    written, so every row is trusted; an empty `select_txns` result means "none /
    couldn't verify" → the caller falls back to reading chunks."""

    var falias: String
    var date: String
    var amount: Float64
    var direction: String
    var desc: String
    var tags: List[String]
    # Monotonic INSERTION generation, assigned at index time (see the manifest's
    # `next_gen`) — the key the ML-materialization ledger uses to tell which rows a
    # rule still needs classified, DECOUPLED from `date` so a back-dated statement
    # indexed late is correctly seen as pending. Rows written before this column
    # existed parse as gen 0 (see `tsv_to_txn_rows`).
    var added_gen: Int


def _tags_to_field(tags: List[String]) -> String:
    """Join tags with `,` for the TSV's last column. Tags are safe lowercase
    identifiers (no tab/comma/newline), so no escaping is needed."""
    var out = String("")
    for i in range(len(tags)):
        if i > 0:
            out += ","
        out += tags[i]
    return out^


def _field_to_tags(s: String) raises -> List[String]:
    """Parse the `,`-joined tags column; empty string → no tags."""
    var out = List[String]()
    if s.byte_length() == 0:
        return out^
    var parts = s.split(",")
    for i in range(len(parts)):
        var p = String(parts[i])
        if p.byte_length() > 0:
            out.append(p^)
    return out^


def txn_rows_to_tsv(rows: List[TxnRow]) raises -> String:
    """alias <TAB> date <TAB> amount <TAB> direction <TAB> escaped_desc <TAB>
    comma-joined-tags <TAB> added_gen, one per line. Trailing columns are
    append-only for backward compatibility: rows written before `tags`/`added_gen`
    existed parse with empty tags / gen 0 (see `tsv_to_txn_rows`)."""
    var out = String("")
    for i in range(len(rows)):
        ref r = rows[i]
        out += (
            _esc(r.falias)
            + "\t"
            + _esc(r.date)
            + "\t"
            + String(r.amount)
            + "\t"
            + r.direction
            + "\t"
            + _esc(r.desc)
            + "\t"
            + _tags_to_field(r.tags)
            + "\t"
            + String(r.added_gen)
            + "\n"
        )
    return out^


def tsv_to_txn_rows(text: String) raises -> List[TxnRow]:
    var rows = List[TxnRow]()
    var lines = text.split("\n")
    for i in range(len(lines)):
        var line = String(lines[i])
        if line.byte_length() == 0:
            continue
        var cols = line.split("\t")
        if len(cols) < 5:
            continue
        # Backward-compatible: rows written before the tags column (5 fields)
        # parse with no tags; rows before added_gen (6 fields) parse as gen 0.
        var tags = List[String]()
        if len(cols) >= 6:
            tags = _field_to_tags(String(cols[5]))
        var added_gen = 0
        if len(cols) >= 7:
            added_gen = atol(String(cols[6].strip()))
        rows.append(
            TxnRow(
                _unesc(String(cols[0])),
                _unesc(String(cols[1])),
                atof(String(cols[2])),
                String(cols[3]),
                _unesc(String(cols[4])),
                tags^,
                added_gen,
            )
        )
    return rows^


def drop_aliases(rows: List[TxnRow], drop: List[String]) raises -> List[TxnRow]:
    """Rows whose alias is NOT in `drop` (evict re-embedded / removed files before
    re-appending their freshly-extracted transactions)."""
    var out = List[TxnRow]()
    for i in range(len(rows)):
        var keep = True
        for d in range(len(drop)):
            if rows[i].falias == drop[d]:
                keep = False
                break
        if keep:
            out.append(rows[i].copy())
    return out^


def select_txns(rows: List[TxnRow], file_alias: String) raises -> List[Txn]:
    """The Txns for one file (in stored order)."""
    var out = List[Txn]()
    for i in range(len(rows)):
        ref r = rows[i]
        if r.falias == file_alias:
            var t = Txn(
                r.date.copy(), r.desc.copy(), r.amount, r.direction.copy()
            )
            t.tags = r.tags.copy()
            out.append(t^)
    return out^


def texts_for_alias(
    ids: List[Int],
    aliases: List[String],
    texts: List[String],
    file_alias: String,
) raises -> List[String]:
    """All of `file_alias`'s chunk texts, ordered by chunk id (document order). Pure
    over the side-table's parallel lists so it's unit-testable; `file_chunks` wraps it.
    """
    var sids = List[Int]()
    var stexts = List[String]()
    for i in range(len(ids)):
        if i < len(aliases) and aliases[i] == file_alias:
            sids.append(ids[i])
            stexts.append(texts[i].copy())
    for a in range(
        1, len(sids)
    ):  # insertion sort by id (modest per-file counts)
        var ki = sids[a]
        var kt = stexts[a].copy()
        var b = a - 1
        while b >= 0 and sids[b] > ki:
            sids[b + 1] = sids[b]
            stexts[b + 1] = stexts[b].copy()
            b -= 1
        sids[b + 1] = ki
        stexts[b + 1] = kt^
    return stexts^
