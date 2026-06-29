"""Categorize_test — the deterministic tag matcher + seed taxonomy.

Builds + runs as a plain Mojo program with only `-I core/src` (no FFI/network):
`pixi run test-categorize`. Pins the matcher contract: case-insensitive
substring keywords assign multi-valued tags, the seed taxonomy tags
phone/travel/restaurant/groceries/health, and — the key guarantee — a
credit-card/transfer line with a long digit run gets NO tag (the false-positive
class the on-device phone classifier hit).
"""

from vault.derive.categorize import (
    default_registry,
    parse_rules,
    merge_registry,
    tag_names,
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

    print("ok: all categorize tests passed")
