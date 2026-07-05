"""Location — a deterministic (merchant, country, state) split of a bank/card
transaction descriptor. No model call: a fast, pure heuristic run ONCE per
transaction at index time, its result persisted on the `TxnRow` so generated
programs can group/filter by merchant or geography without re-parsing.

Ported from the validated `experiments/parse-location.mojo` prototype (proven on
real statements: country ~82.6%, US state ~78%, and the misses are legitimately
location-less — transfers / online / PayPal). Card & bank descriptors trail a
location on the raw string, e.g.

    AMAZON MKTPLACE AMZN.COM/BILL WA USA   -> merchant=AMAZON MKTPLACE  state=WA country=USA
    TESCO STORES 3421 LONDON GBR           -> merchant=TESCO STORES     state=""  country=GBR
    UBER   *TRIP HELP.UBER.C AMSNLD        -> merchant=UBER             state=""  country=NLD

The heuristic (all case-insensitive, whitespace-tokenized):
  country — the TRAILING token: a 3-letter ISO code (`USA`) or a 6-char
            `<city3><ISO3>` pack (`AMSNLD` -> `NLD`, `LNDGBR` -> `GBR`);
  state   — the next trailing token if it's a US 2-letter state code (`WA`);
  merchant— the LEADING brand tokens, stopping at the first address marker
            (STREET/WAY/AVE/UNIT/…), a long digit run, a `#store` token, or the
            already-consumed state/country region — then a residual trailing
            store/account digit token is stripped and whitespace collapsed.

Stdlib-only (like `vault.derive.categorize` / `vault.index.sha256`), so it
unit-tests with just `-I core/src`.
"""


def _upper(s: String) -> String:
    """ASCII-uppercase a token so matching is case-insensitive."""
    var out = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        if c >= 97 and c <= 122:  # 'a'..'z'
            c -= 32
        out += chr(c)
    return out^


def _all_alpha(s: String) -> Bool:
    """True iff every byte is an ASCII letter (and the token is non-empty)."""
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if not ((c >= 65 and c <= 90) or (c >= 97 and c <= 122)):
            return False
    return True


def _all_digit(s: String) -> Bool:
    """True iff every byte is an ASCII digit (and the token is non-empty)."""
    var b = s.as_bytes()
    if len(b) == 0:
        return False
    for i in range(len(b)):
        var c = Int(b[i])
        if c < 48 or c > 57:
            return False
    return True


def _last3(s: String) -> String:
    """The last 3 bytes of an all-ASCII token (the ISO3 tail of a 6-char pack).
    """
    var b = s.as_bytes()
    var n = len(b)
    var out = String("")
    for i in range(n - 3, n):
        out += chr(Int(b[i]))
    return out^


def _in(needle: String, hay: List[String]) -> Bool:
    for i in range(len(hay)):
        if hay[i] == needle:
            return True
    return False


def _tokens(s: String) raises -> List[String]:
    """Whitespace-split a descriptor into non-empty tokens (spaces + tabs)."""
    var norm = String("")
    var b = s.as_bytes()
    for i in range(len(b)):
        var c = Int(b[i])
        # Fold tabs/newlines/CR to a plain space so a single split covers them.
        norm += " " if (c == 9 or c == 10 or c == 13) else chr(c)
    var raw = norm.split(" ")
    var out = List[String]()
    for i in range(len(raw)):
        var t = String(String(raw[i]).strip())
        if t.byte_length() > 0:
            out.append(t^)
    return out^


def _iso3() -> List[String]:
    """Common ISO-3166 alpha-3 country codes (plus the legacy `ROM` for Romania,
    which real card descriptors still emit alongside `ROU`)."""
    return [
        String("USA"),
        String("CAN"),
        String("MEX"),
        String("GBR"),
        String("IRL"),
        String("FRA"),
        String("DEU"),
        String("ESP"),
        String("ITA"),
        String("PRT"),
        String("NLD"),
        String("BEL"),
        String("CHE"),
        String("AUT"),
        String("SWE"),
        String("NOR"),
        String("DNK"),
        String("FIN"),
        String("POL"),
        String("ROU"),
        String("ROM"),
        String("GRC"),
        String("TUR"),
        String("RUS"),
        String("UKR"),
        String("CZE"),
        String("HUN"),
        String("AUS"),
        String("NZL"),
        String("JPN"),
        String("CHN"),
        String("HKG"),
        String("SGP"),
        String("KOR"),
        String("IND"),
        String("IDN"),
        String("THA"),
        String("VNM"),
        String("PHL"),
        String("MYS"),
        String("ARE"),
        String("SAU"),
        String("ISR"),
        String("ZAF"),
        String("BRA"),
        String("ARG"),
        String("CHL"),
        String("COL"),
        String("PER"),
    ]


def _states() -> List[String]:
    """US 2-letter state/territory codes (incl. DC)."""
    return [
        String("AL"),
        String("AK"),
        String("AZ"),
        String("AR"),
        String("CA"),
        String("CO"),
        String("CT"),
        String("DE"),
        String("FL"),
        String("GA"),
        String("HI"),
        String("ID"),
        String("IL"),
        String("IN"),
        String("IA"),
        String("KS"),
        String("KY"),
        String("LA"),
        String("ME"),
        String("MD"),
        String("MA"),
        String("MI"),
        String("MN"),
        String("MS"),
        String("MO"),
        String("MT"),
        String("NE"),
        String("NV"),
        String("NH"),
        String("NJ"),
        String("NM"),
        String("NY"),
        String("NC"),
        String("ND"),
        String("OH"),
        String("OK"),
        String("OR"),
        String("PA"),
        String("RI"),
        String("SC"),
        String("SD"),
        String("TN"),
        String("TX"),
        String("UT"),
        String("VT"),
        String("VA"),
        String("WA"),
        String("WV"),
        String("WI"),
        String("WY"),
        String("DC"),
    ]


def _markers() -> List[String]:
    """Address-line marker words: once one appears the rest is an address, not the
    brand — so the merchant is everything BEFORE it."""
    return [
        String("STREET"),
        String("WAY"),
        String("AVE"),
        String("AVENUE"),
        String("UNIT"),
        String("OFFICE"),
        String("STRADA"),
        String("NR"),
        String("ET"),
        String("BLVD"),
        String("RD"),
        String("STE"),
        String("SUITE"),
    ]


def _strip_trailing_paren(desc: String) raises -> String:
    """Strip a single TRAILING parenthetical annotation — a `(...)` group at the
    very end of the descriptor (optionally preceded by whitespace) — so a bank's
    appended refund/return marker (`(return)`, `(reversal)`, `(pending)`, …)
    doesn't displace the trailing geo tokens the heuristic reads.

    Only a CLEAN trailing group is removed: the descriptor must end in `)` and
    contain a matching `(`; a mid-string paren inside a merchant name (the group
    isn't the last non-space content) is left untouched, and a stray `)` with no
    `(` is left alone. If stripping would empty the descriptor, the original
    (trimmed) string is returned instead.
    """
    var s = String(String(desc).strip())
    var b = s.as_bytes()
    var n = len(b)
    # Must end with ')' to be a trailing parenthetical.
    if n == 0 or Int(b[n - 1]) != 41:  # ')'
        return s^
    # The matching '(' is the last '(' before the trailing ')'.
    var open_idx = -1
    for i in range(n - 1):
        if Int(b[i]) == 40:  # '('
            open_idx = i
    if open_idx < 0:
        return s^  # a ')' with no '(' → not a clean group, leave it.
    # Rebuild the prefix [0, open_idx) and re-trim (drops the space before '(').
    var out = String("")
    for i in range(open_idx):
        out += chr(Int(b[i]))
    var trimmed = String(out.strip())
    # Never empty the descriptor out (a bare "(return)" has no brand to keep).
    if trimmed.byte_length() == 0:
        return s^
    return trimmed^


def _refine_merchant(var merch: String) raises -> String:
    """Clean up the raw merchant string: collapse repeated whitespace to single
    spaces and strip a residual TRAILING store/account digit-run token (e.g.
    `SAFEWAY 1425` -> `SAFEWAY`) that leaked past the token scan. Leaves an
    all-digit merchant untouched (nothing better to fall back to)."""
    # Collapse whitespace (split() drops empties → single-spaced rejoin).
    var toks = merch.split()
    var kept = List[String]()
    for i in range(len(toks)):
        kept.append(String(toks[i]))
    # Strip trailing pure-digit tokens, but never empty the merchant out.
    while len(kept) > 1 and _all_digit(kept[len(kept) - 1]):
        _ = kept.pop()
    var out = String("")
    for i in range(len(kept)):
        if i > 0:
            out += " "
        out += kept[i]
    return out^


@fieldwise_init
struct Location(Copyable, Movable):
    """A best-effort (merchant, country, state) split of one raw descriptor.
    `country` is an ISO3 code (`""` when none); `state` is a US 2-letter code
    (`""` when none); `merchant` is always non-empty (falls back to the first
    token)."""

    var merchant: String
    var country: String  # ISO3, "" when none
    var state: String  # US 2-letter, "" when none


def parse_location(desc: String) raises -> Location:
    """Split one raw transaction descriptor into (merchant, country, state).
    Deterministic + fast (no model). See the module docstring for the heuristic.
    """
    var iso3 = _iso3()
    var states = _states()
    var markers = _markers()

    # Strip a trailing parenthetical annotation (e.g. a bank's `(return)` /
    # `(reversal)` marker) so the geo tokens are trailing again; parse over that.
    var cleaned = _strip_trailing_paren(desc)
    var toks = _tokens(cleaned)
    if len(toks) == 0:
        return Location(String(cleaned.strip()), String(""), String(""))

    var country = String("")
    var state = String("")
    # `keep` is the count of leading tokens NOT yet consumed as state/country —
    # the merchant is drawn from tokens[0 .. keep).
    var keep = len(toks)

    # country from the trailing token: a 3-letter ISO, or a 6-char <city3><ISO3>.
    var last_up = _upper(toks[keep - 1])
    if _all_alpha(last_up):
        if last_up.byte_length() == 3 and _in(last_up, iso3):
            country = last_up.copy()
            keep -= 1
        elif last_up.byte_length() == 6:
            var tail3 = _last3(last_up)
            if _in(tail3, iso3):
                country = tail3^
                keep -= 1

    # state from the new trailing token: a US 2-letter code.
    if keep > 0:
        var st_up = _upper(toks[keep - 1])
        if st_up.byte_length() == 2 and _in(st_up, states):
            state = st_up^
            keep -= 1

    # merchant = leading brand tokens, stopping at the first address-ish token or
    # the (already-consumed) geo region.
    var merch = String("")
    var mcount = 0
    for i in range(len(toks)):
        if i >= keep:
            break  # reached the state/country region
        ref t = toks[i]
        var tu = _upper(t)
        var is_marker = _in(tu, markers)
        var is_digrun = _all_digit(t) and t.byte_length() >= 3
        var is_hash = Int(t.as_bytes()[0]) == 35  # leading '#'
        if is_marker or is_digrun or is_hash:
            break
        if mcount > 0:
            merch += " "
        merch += t
        mcount += 1
    if merch.byte_length() == 0:
        merch = toks[
            0
        ].copy()  # nothing survived → fall back to the first token
    return Location(_refine_merchant(merch^), country^, state^)
