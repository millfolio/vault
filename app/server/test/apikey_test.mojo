"""apikey_test — unit tests for the pure API-key helpers (apikey.mojo).

Builds + runs as a plain Mojo program (no flare/enclave): `pixi run
test-apikey`. Asserts the validation gate, the last-4 masking (the hint NEVER
leaks more than 4 chars), and the status-JSON shape. Pure functions → fully
deterministic, no fixtures.
"""

from apikey import apikey_looks_valid, apikey_hint, apikey_status_json
from json import loads


def expect(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def expect_eq(got: String, want: String, what: String) raises:
    if got != want:
        raise Error("FAIL: " + what + "\n  got:  " + got + "\n  want: " + want)


def main() raises:
    # ── apikey_looks_valid ──────────────────────────────────────────────────────
    expect(
        apikey_looks_valid("sk-ant-api03-abcdefghij"), "real-looking key valid"
    )
    expect(not apikey_looks_valid(""), "empty rejected")
    expect(not apikey_looks_valid("   "), "blank rejected")
    expect(not apikey_looks_valid("short"), "too-short rejected")
    expect(
        not apikey_looks_valid("sk-ant-with a space"),
        "embedded space rejected",
    )
    expect(not apikey_looks_valid("sk-ant-tab\there"), "embedded tab rejected")
    expect(
        apikey_looks_valid("  sk-ant-padded-key-value  "),
        "surrounding whitespace trimmed then valid",
    )

    # ── apikey_hint: only ever the last 4 chars ─────────────────────────────────
    expect_eq(apikey_hint("sk-ant-api03-XY99"), "…XY99", "last-4 masked")
    expect_eq(apikey_hint(""), "", "empty key → empty hint")
    expect_eq(apikey_hint("  sk-ant-api03-XY99  "), "…XY99", "hint trims first")
    # The hint must NEVER reveal the body of the key.
    var full = String("sk-ant-secret-body-1234")
    var hint = apikey_hint(full)
    expect(hint.find("secret") == -1, "hint hides the key body")
    expect(hint.count_codepoints() <= 5, "hint is ellipsis + at most 4 chars")

    # ── apikey_status_json ──────────────────────────────────────────────────────
    var set_json = apikey_status_json(True, "…XY99")
    _ = loads(set_json)  # raises if not valid JSON
    expect(set_json.find('"set":true') != -1, "set:true present")
    expect(set_json.find('"hint":"…XY99"') != -1, "hint present")

    var unset_json = apikey_status_json(False, "")
    _ = loads(unset_json)
    expect(unset_json.find('"set":false') != -1, "set:false present")
    expect(unset_json.find('"hint":""') != -1, "empty hint present")

    print("apikey_test: OK")
