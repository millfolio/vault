"""Categorize_test — the deterministic tag matcher + seed taxonomy.

Builds + runs as a plain Mojo program with only `-I core/src` (no FFI/network):
`pixi run test-categorize`. Pins the matcher contract: case-insensitive
substring keywords assign multi-valued tags, the seed taxonomy tags
phone/travel/restaurant/groceries/health, and — the key guarantee — a
credit-card/transfer line with a long digit run gets NO tag (the false-positive
class the on-device phone classifier hit).
"""

from vault.derive.categorize import (
    Registry,
    default_registry,
    parse_rules,
    merge_registry,
    tag_names,
    tag_descriptions,
    rules_canon,
    registry_to_text,
)


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def _has(tags: List[String], tag: String) -> Bool:
    for i in range(len(tags)):
        if tags[i] == tag:
            return True
    return False


def main() raises:
    var reg = default_registry()

    # ── carriers → phone (incl. with phone numbers / ACH digits present) ─────────
    expect(
        _has(reg.tags_for("Verizon Wireless Pmt 8005220500"), "phone"),
        "Verizon → phone",
    )
    expect(
        _has(reg.tags_for("AT&T Payment 800-331-0500 TX"), "phone"),
        "AT&T → phone (name dominates the phone-number digits)",
    )
    expect(
        _has(reg.tags_for("T-Mobile autopay 190115"), "phone"),
        "T-Mobile → phone",
    )

    # ── the false-positive class: NO carrier name → NO tag (deterministic) ───────
    expect(
        len(reg.tags_for("Chase Credit Crd Epay 190115 3932598184 Marius S"))
        == 0,
        "Chase Crd Epay with a digit run → NO tag (the bug the ML model hit)",
    )
    expect(
        len(reg.tags_for("Online Transfer to VISA Signature Card Xxxx5744"))
        == 0,
        "card transfer → NO tag",
    )
    expect(
        len(reg.tags_for("Paypal Inst Xfer 190109 Github Inc Marius")) == 0,
        "PayPal/GitHub → NO tag",
    )

    # ── the other seed categories ────────────────────────────────────────────────
    expect(
        _has(reg.tags_for("DELTA AIR LINES 0062460071234"), "travel"),
        "Delta Air Lines → travel",
    )
    expect(
        _has(reg.tags_for("STARBUCKS STORE 00123 SEATTLE"), "restaurant"),
        "Starbucks → restaurant",
    )
    expect(
        _has(reg.tags_for("WHOLE FOODS MKT #10234"), "groceries"),
        "Whole Foods → groceries",
    )
    expect(_has(reg.tags_for("CVS/PHARMACY 04567 Q"), "health"), "CVS → health")

    # ── case-insensitive ─────────────────────────────────────────────────────────
    expect(
        _has(reg.tags_for("verizon wireless payment"), "phone"),
        "lowercase verizon → phone",
    )

    # ── multi-valued: one txn can carry several tags ─────────────────────────────
    var t = reg.tags_for("MARRIOTT HOTEL GRILL #88")
    expect(_has(t, "travel"), "Marriott hotel grill → travel")
    expect(
        _has(t, "restaurant"), "Marriott hotel grill → restaurant (multi-tag)"
    )
    expect(len(t) == 2, "exactly the two expected tags, no spurious ones")

    # ── a generic merchant nothing names → untagged (falls back to ML tail) ──────
    expect(
        len(reg.tags_for("ACME WIDGETS LLC 0099")) == 0,
        "unknown merchant → no deterministic tag",
    )

    # ── user-editable registry: parse + merge ────────────────────────────────────
    var cfg = String(
        "# my categories\n"
        "\n"
        "pets = chewy, petco, the vet\n"
        "phone = acme wireless\n"  # extends the built-in phone tag
        "  health  =  my doctor ,  \n"  # whitespace + a trailing empty keyword
        "malformed line with no equals\n"
        "= no tag\n"  # empty tag → skipped
    )
    var user = parse_rules(cfg)
    expect(
        len(user) == 3, "parse_rules: 3 valid rules (skips malformed/empty-tag)"
    )

    # ── malformed tag NAMES are dropped (separators would corrupt .tags) ─────────
    # A tag name may contain SPACES (multi-word categories) but must NOT contain a
    # field separator: `,` (splits the comma-joined .tags column / codegen list),
    # `=` (the tag/keyword separator), or tab/newline. Such rules are skipped.
    var dangerous = parse_rules(
        String(
            "bad,name = x\n"  # comma → would split into phantom 'bad'/'name' tags
            "a=b = x\n"  # '=' in name; split-on-'=' must not yield an 'a=b' tag
            "credit cards = visa, mastercard\n"  # SPACES are fine — must survive
            "bad\tname = y\n"  # tab in name → dropped
        )
    )
    var dnames = tag_names(Registry(dangerous.copy()))
    expect(
        not _has(dnames, "bad,name") and not _has(dnames, "bad"),
        "comma in tag name → rule dropped (no 'bad,name'/'bad' tag)",
    )
    # `a=b = x` splits on '=' BEFORE validation → parts[0] is just 'a', so the
    # dangerous 'a=b' tag is never formed (a benign 'a'→'b' rule survives instead).
    expect(not _has(dnames, "a=b"), "'=' in tag name → no 'a=b' tag")
    expect(not _has(dnames, "bad\tname"), "tab in tag name → rule dropped")
    expect(
        _has(dnames, "credit cards"),
        "multi-word tag name with spaces still parses ('credit cards')",
    )
    # only the two structurally-safe rules survive: 'credit cards' and 'a'
    # (the comma/tab rules are dropped, 'a=b' never forms).
    expect(
        len(dangerous) == 2,
        "comma/tab rules dropped; only 'credit cards' + benign 'a' survive",
    )
    var cc = merge_registry(default_registry(), dangerous)
    expect(
        _has(cc.tags_for("AMEX CREDIT CARDS PMT VISA 0012"), "credit cards"),
        "multi-word 'credit cards' tag matches via its keyword",
    )

    var merged = merge_registry(default_registry(), user)

    # new tag from a user-only keyword
    expect(_has(merged.tags_for("CHEWY.COM 0123"), "pets"), "user rule → pets")
    expect(
        len(default_registry().tags_for("CHEWY.COM 0123")) == 0,
        "defaults alone don't know pets (merge added it, base unchanged)",
    )
    # a user keyword EXTENDS a built-in tag (additive)
    expect(
        _has(merged.tags_for("ACME WIRELESS PMT 5551212"), "phone"),
        "user keyword extends built-in phone tag",
    )
    # and the built-in phone keywords still work after merge
    expect(
        _has(merged.tags_for("Verizon Wireless Pmt"), "phone"),
        "built-in phone keywords survive the merge (additive)",
    )
    # whitespace trimmed; trailing empty keyword dropped
    expect(
        _has(merged.tags_for("Visit to MY DOCTOR LLC"), "health"),
        "trimmed user keyword 'my doctor' → health",
    )

    # tag_names lists the registry's tags (built-ins + the new user tag)
    var names = tag_names(merged)
    expect(
        _has(names, "phone") and _has(names, "pets"),
        "tag_names includes built-in + user tags",
    )

    # ── seed round-trip: the file is the source of truth ─────────────────────────
    # registry_to_text writes the defaults as editable `tag = kw, kw` lines; an
    # UNTOUCHED seed must re-parse to exactly the default rules (same canon), so the
    # loader's "did the user edit?" checksum is stable.
    var seed = registry_to_text(default_registry(), String("deadbeef"))
    var reparsed = Registry(parse_rules(seed))
    expect(
        rules_canon(reparsed) == rules_canon(default_registry()),
        "seeded defaults round-trip through the config format (canon stable)",
    )
    # an edit changes the canon (→ checksum diverges → file becomes authoritative)
    var edited = Registry(parse_rules(seed + String("\npets = chewy, petco\n")))
    expect(
        rules_canon(edited) != rules_canon(default_registry()),
        "adding a rule changes the canon (the loader sees it as edited)",
    )

    # ── ML rules: `<tag> : <question>` parse, stay deterministic-free, round-trip ──
    var mlrules = parse_rules(
        String(
            "gym : is this merchant a gym or fitness studio?\n"  # ML rule
            "phone = verizon, at&t\n"  # a normal keyword rule alongside
            "vibe : was this an impulse splurge = treat?\n"  # ':' before '=' → ML; '=' kept
        )
    )
    var mlreg = Registry(mlrules.copy())
    # the ML tag is advertised (codegen sees it) but NEVER matches by keyword —
    # tags_for is deterministic-only, so an ML category is materialised separately.
    expect(_has(tag_names(mlreg), "gym"), "ML tag name is advertised")
    expect(
        len(mlreg.tags_for("PLANET FITNESS 0042")) == 0,
        "ML rule never matches deterministically (no model call in tags_for)",
    )
    expect(mlrules[0].is_ml(), "'gym :' parsed as an ML rule")
    expect(not mlrules[1].is_ml(), "'phone =' stays a keyword rule")
    expect(
        mlrules[2].is_ml()
        and mlrules[2].ml_prompt == "was this an impulse splurge = treat?",
        "':' before '=' → ML rule whose question keeps its '='",
    )
    # ML rules round-trip through the editable file format AND the canon (so the
    # loader's untouched-vs-edited checksum still works with ML rules present).
    var mltext = registry_to_text(mlreg, String("cafef00d"))
    var mlround = Registry(parse_rules(mltext))
    expect(
        rules_canon(mlround) == rules_canon(mlreg),
        "ML rules round-trip through registry_to_text (canon stable)",
    )

    # ── per-tag descriptions: `<tag> (note) = …` — the model's disambiguator ─────
    # The note goes in parens after the tag, BEFORE the separator; it may contain
    # commas / '=' / ':' (split off first) and never breaks the rule parse.
    var drules = parse_rules(
        String(
            "health (medical care — NOT gyms or fitness) = pharmacy, cvs\n"
            "gym (gyms & fitness studios) : is this a gym?\n"
            "weird (a = b, c: d) = kw\n"  # separators inside the note are safe
            "plain = visa\n"  # no note → empty description
        )
    )
    expect(
        drules[0].description == "medical care — NOT gyms or fitness",
        "keyword rule note parsed (em-dash + 'NOT gyms' survives)",
    )
    expect(
        _has(drules[0].keywords, "pharmacy")
        and _has(drules[0].keywords, "cvs"),
        "keyword rule with a note still parses its keywords",
    )
    expect(
        drules[1].is_ml() and drules[1].description == "gyms & fitness studios",
        "ML rule carries a note too",
    )
    expect(
        drules[2].description == "a = b, c: d"
        and _has(drules[2].keywords, "kw"),
        "'=' and ':' inside the note don't confuse the rule parse",
    )
    expect(
        drules[3].description == "", "a rule with no note → empty description"
    )
    # tag_descriptions is parallel to tag_names
    var dreg = Registry(drules.copy())
    var dn = tag_names(dreg)
    var dd = tag_descriptions(dreg)
    expect(
        len(dn) == len(dd) and dd[1] == "gyms & fitness studios",
        "tag_descriptions parallels tag_names",
    )
    # the built-in health tag now disambiguates away from gyms
    var dflt_d = tag_descriptions(default_registry())
    var dflt_n = tag_names(default_registry())
    var health_has_not_gyms = False
    for i in range(len(dflt_n)):
        if dflt_n[i] == "health" and "NOT gyms" in dflt_d[i]:
            health_has_not_gyms = True
    expect(health_has_not_gyms, "built-in health description excludes gyms")
    # notes round-trip through the file format (canon stable with descriptions)
    var droundtext = registry_to_text(dreg, String("d00d"))
    var dround = Registry(parse_rules(droundtext))
    expect(
        rules_canon(dround) == rules_canon(dreg),
        "descriptions round-trip through registry_to_text (canon stable)",
    )

    print("ok: all categorize tests passed")
