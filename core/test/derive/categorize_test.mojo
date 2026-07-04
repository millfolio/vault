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
    # A card transfer is NOT a phone bill — but it IS legitimately a `transfers`
    # (the "transfer" keyword). The guarantee is it never mislabels as `phone`.
    var xfer = reg.tags_for("Online Transfer to VISA Signature Card Xxxx5744")
    expect(
        _has(xfer, "transfers") and not _has(xfer, "phone"),
        "card transfer → transfers, never phone",
    )
    expect(
        len(reg.tags_for("Paypal Inst Xfer 190109 Github Inc Marius")) == 0,
        (
            "PayPal/GitHub → NO tag (PayPal is often a real purchase — not a"
            " transfer)"
        ),
    )

    # ── new default tags: transfers (account activity) + rewards (cash back) ─────
    expect(
        _has(reg.tags_for("ACH DEPOSIT PAYROLL"), "transfers"),
        "ACH deposit → transfers",
    )
    expect(
        _has(reg.tags_for("Zelle payment to Alex"), "transfers")
        and _has(reg.tags_for("VENMO CASHOUT"), "transfers")
        and _has(reg.tags_for("WIRE TRANSFER OUT"), "transfers"),
        "Zelle / Venmo / wire → transfers",
    )
    expect(
        _has(reg.tags_for("APPLECARD GSBANK DAILY CASH"), "rewards"),
        "Apple Card Daily Cash → rewards",
    )
    expect(
        _has(reg.tags_for("CASH BACK REDEMPTION"), "rewards")
        and _has(reg.tags_for("Statement Cashback Credit"), "rewards")
        and _has(reg.tags_for("REWARD REDEMPTION"), "rewards"),
        "cash back / cashback / reward → rewards",
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

    # ── tag references: `group = @member, @member, keyword` (union) ──────────────
    # A deterministic term starting with '@' is a REFERENCE to another tag; the
    # group tag is assigned when any keyword matches OR any referenced tag is
    # present. Refs are resolved by the fixpoint (derive_ref_tags) over a full tag
    # set — tags_for stays description-only.
    var refrules = parse_rules(
        String(
            "groceries = costco, whole foods\n"
            "utilities = pg&e, water district\n"
            "essentials = @groceries, @utilities, cash withdrawal\n"
        )
    )
    # parsing: `essentials` has two refs + one keyword; the members have none.
    expect(
        len(refrules) == 3,
        "three rules parsed (groceries/utilities/essentials)",
    )
    expect(
        len(refrules[2].refs) == 2
        and _has(refrules[2].refs, "groceries")
        and _has(refrules[2].refs, "utilities"),
        "essentials parses two @refs (groceries, utilities)",
    )
    expect(
        len(refrules[2].keywords) == 1
        and _has(refrules[2].keywords, "cash withdrawal"),
        "essentials keeps its non-@ term as a keyword",
    )
    # a rule is NOT ML just because it has refs (deterministic).
    expect(not refrules[2].is_ml(), "a ref rule is deterministic, not ML")
    var refreg = Registry(refrules.copy())

    # union via a referenced KEYWORD tag: a Costco txn is groceries → so essentials.
    var e1 = refreg.tags_for("COSTCO WHSE #0044")  # seed = keyword matches only
    expect(_has(e1, "groceries"), "Costco → groceries (seed)")
    expect(
        not _has(e1, "essentials"),
        "tags_for stays description-only (no ref resolution)",
    )
    refreg.derive_ref_tags("COSTCO WHSE #0044", e1)  # resolve refs over the set
    expect(
        _has(e1, "essentials"),
        "essentials picked up via @groceries (a referenced member is present)",
    )
    # union via the second member.
    var e2 = refreg.tags_for("CITY WATER DISTRICT AUTOPAY")
    refreg.derive_ref_tags("CITY WATER DISTRICT AUTOPAY", e2)
    expect(
        _has(e2, "utilities") and _has(e2, "essentials"),
        "essentials rolls up @utilities too",
    )
    # keyword + ref MIX: essentials' own keyword fires with no member present.
    var e3 = refreg.tags_for("ATM CASH WITHDRAWAL 0042")
    expect(_has(e3, "essentials"), "essentials own keyword matches (seed)")
    refreg.derive_ref_tags("ATM CASH WITHDRAWAL 0042", e3)
    expect(
        _has(e3, "essentials") and not _has(e3, "groceries"),
        "keyword-only hit tags essentials without any member",
    )
    # a txn matching NOTHING gets no group tag.
    var e4 = refreg.tags_for("ACME WIDGETS LLC 0099")
    refreg.derive_ref_tags("ACME WIDGETS LLC 0099", e4)
    expect(len(e4) == 0, "unknown merchant → no group tag")

    # ── multi-level groups: a group referencing a group ─────────────────────────
    var multi = Registry(
        parse_rules(
            String(
                "groceries = costco\n"
                "food = @groceries, restaurant\n"  # references groceries
                "spending = @food\n"  # references food → transitively groceries
            )
        )
    )
    var m1 = multi.tags_for("COSTCO WHSE #1")
    multi.derive_ref_tags("COSTCO WHSE #1", m1)
    expect(
        _has(m1, "groceries") and _has(m1, "food") and _has(m1, "spending"),
        "multi-level: costco → groceries → food → spending (transitive)",
    )

    # ── a reference cycle converges (does not hang) ─────────────────────────────
    var cyc = Registry(
        parse_rules(String("a = @b, seedword\nb = @a\nc = @a\n"))  # a↔b cycle
    )
    var cy = cyc.tags_for("SEEDWORD MERCHANT")  # seeds 'a' via its keyword
    cyc.derive_ref_tags("SEEDWORD MERCHANT", cy)
    expect(
        _has(cy, "a") and _has(cy, "b") and _has(cy, "c"),
        "cycle a↔b converges: a (keyword) → b, and c → a all stabilise",
    )
    # nothing seeds the cycle → it stays empty (no spurious tags, still converges).
    var cy0 = cyc.tags_for("NOTHING HERE")
    cyc.derive_ref_tags("NOTHING HERE", cy0)
    expect(len(cy0) == 0, "unseeded cycle adds nothing (still terminates)")

    # ── a group referencing an ML tag picks it up when that tag is present ───────
    # An ML member's tag is only ever added by a model call, then carried onto the
    # row's tag set; the group re-derives over that set (as retag does).
    var mlref = Registry(
        parse_rules(
            String(
                "gym : is this a gym or fitness studio?\n"
                "wellness = @gym, @health\n"
                "health = pharmacy\n"  # ML member
            )
        )
    )
    # simulate the row already carrying the backfilled ML 'gym' tag.
    var w = List[String]()
    w.append(String("gym"))
    mlref.derive_ref_tags("PLANET FITNESS 0042", w)
    expect(
        _has(w, "wellness"),
        "group rolls up an ML member (@gym) once its tag is present",
    )
    # without the ML tag present, the ML-referencing branch doesn't fire (but a
    # keyword member still can).
    var w2 = Registry(mlref.rules.copy()).tags_for("CVS PHARMACY")
    Registry(mlref.rules.copy()).derive_ref_tags("CVS PHARMACY", w2)
    expect(
        _has(w2, "health") and _has(w2, "wellness"),
        "wellness via @health (keyword member) even with gym absent",
    )

    # ── fixpoint: a group declared BEFORE its member still resolves ─────────────
    # Rules in REVERSE dependency order — a single in-order pass could not resolve
    # `spending` (its member `food` isn't tagged yet when the pass reaches it); the
    # fixpoint's re-iteration is what makes it converge.
    var rev = Registry(
        parse_rules(
            String(
                "spending = @food\n"  # depends on food (declared below)
                "food = @groceries\n"  # depends on groceries (declared below)
                "groceries = costco\n"  # the only keyword seed
            )
        )
    )
    var rv = rev.tags_for("COSTCO WHSE #7")  # seeds only 'groceries'
    rev.derive_ref_tags("COSTCO WHSE #7", rv)
    expect(
        _has(rv, "groceries") and _has(rv, "food") and _has(rv, "spending"),
        "reverse-order groups resolve (genuine multi-pass fixpoint)",
    )

    # ── case-INsensitive @ref: `@Groceries` resolves tag `groceries` ────────────
    var ci = Registry(
        parse_rules(
            String(
                "groceries = costco\n"
                "essentials = @Groceries\n"  # mixed-case ref
            )
        )
    )
    var civ = ci.tags_for("COSTCO WHSE #9")
    ci.derive_ref_tags("COSTCO WHSE #9", civ)
    expect(
        _has(civ, "essentials"),
        "mixed-case @Groceries resolves lowercase tag groceries",
    )

    # ── a dangling ref never fires and doesn't crash ────────────────────────────
    var dangling = Registry(parse_rules(String("essentials = @nonexistent\n")))
    var dv = dangling.tags_for("COSTCO WHSE #3")
    dangling.derive_ref_tags("COSTCO WHSE #3", dv)
    expect(len(dv) == 0, "dangling @ref (no such tag) → never fires, no crash")

    # ── whitespace around refs parses ───────────────────────────────────────────
    var ws = parse_rules(String("essentials =  @groceries , @utilities \n"))
    expect(
        len(ws[0].refs) == 2
        and _has(ws[0].refs, "groceries")
        and _has(ws[0].refs, "utilities"),
        "whitespace around @refs is trimmed on parse",
    )

    # ── idempotency: deriving twice yields the same set (no dup tags) ────────────
    var idem = refreg.tags_for("COSTCO WHSE #0044")
    refreg.derive_ref_tags("COSTCO WHSE #0044", idem)
    var n_after_first = len(idem)
    refreg.derive_ref_tags("COSTCO WHSE #0044", idem)  # again over the same set
    expect(
        len(idem) == n_after_first and _has(idem, "essentials"),
        "derive_ref_tags is idempotent (no duplicate tags on re-run)",
    )

    # ── refs round-trip through the file format + canon ─────────────────────────
    var reftext = registry_to_text(refreg, String("beadfeed"))
    var refround = Registry(parse_rules(reftext))
    expect(
        rules_canon(refround) == rules_canon(refreg),
        "@refs round-trip through registry_to_text (canon stable)",
    )
    # a ref edit changes the canon (→ checksum diverges → file authoritative).
    var refedit = Registry(parse_rules(reftext + String("\nx = @groceries\n")))
    expect(
        rules_canon(refedit) != rules_canon(refreg),
        "adding a @ref rule changes the canon (loader sees an edit)",
    )
    # the DEFAULT (ref-less) registry canon is byte-unchanged by the refs feature.
    expect(
        not ("@" in rules_canon(default_registry())),
        "ref-less default registry canon carries no '@' (checksum unchanged)",
    )

    print("ok: all categorize tests passed")
