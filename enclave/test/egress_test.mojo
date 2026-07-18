"""Egress-test — prove the EgressGuard actually blocks. `pixi run test-egress`.

The guard is enclave's confidentiality chokepoint. This is the test that makes
"confidential" true rather than nominal: a clean payload passes, a payload
carrying a real-data fingerprint OR a canary token is blocked (the guard raises,
so transport aborts the send) — even reformatted — and what survives the
tripwires comes back with PII-shaped spans redacted.
"""

from security.egress import EgressGuard
from security.pii import redact_pii, looks_pii


def _blocks(guard: EgressGuard, payload: String) -> Bool:
    try:
        _ = guard.check(payload)
        return False
    except:
        return True


def _check(mut all_ok: Bool, ok: Bool, label: String):
    print("[" + ("PASS" if ok else "FAIL") + "] " + label)
    all_ok = all_ok and ok


def main() raises:
    var all_ok = True
    var fps = List[String]()
    fps.append(String("123-45-6789"))  # a real SSN-shaped value
    fps.append(String("alice@example.com"))  # a real email value
    var canaries = List[String]()
    canaries.append(String("HG_CANARY_7f3a"))  # seeded ONLY into real data
    var guard = EgressGuard(fps^, canaries^)

    # ── tripwires ─────────────────────────────────────────────────────────
    _check(
        all_ok,
        not _blocks(guard, String("Aggregate col_1 grouped by col_0.")),
        "clean payload passes",
    )
    _check(
        all_ok,
        _blocks(guard, String("debug: offending row was 123-45-6789")),
        "real-value fingerprint blocked",
    )
    _check(
        all_ok,
        _blocks(guard, String("stack trace mentions HG_CANARY_7f3a here")),
        "canary token blocked",
    )

    # ── normalized matching: reformatting can't slip a seeded value past ──
    _check(
        all_ok,
        _blocks(guard, String("offending row was 123-45- 6789")),
        "whitespace-injected fingerprint still blocked",
    )
    _check(
        all_ok,
        _blocks(guard, String("contact ALICE@EXAMPLE.COM about this")),
        "case-changed fingerprint still blocked",
    )
    _check(
        all_ok,
        _blocks(guard, String("log line: hg_canary\n_7f3a end")),
        "case/newline-mangled canary still blocked",
    )

    # ── redaction: PII-shaped spans scrubbed from SURVIVING payloads ──────
    var r = guard.check(
        String("ask bob@corp.example.org about card 4111111111111111 today")
    )
    _check(
        all_ok,
        r.find("bob@corp.example.org") == -1
        and r.find("[redacted-email]") != -1,
        "unlisted email redacted",
    )
    _check(
        all_ok,
        r.find("4111111111111111") == -1 and r.find("[redacted-number]") != -1,
        "16-digit card number redacted",
    )
    var r2 = guard.check(String("row had 987-65-4320 in it"))
    _check(
        all_ok,
        r2.find("987-65-4320") == -1 and r2.find("[redacted-number]") != -1,
        "dash-grouped SSN shape redacted",
    )

    # ── redaction must NOT touch legitimate payload content ───────────────
    var legit = String(
        "between 2026-01-01 and 2026-07-15 total $224,303.00;"
        " file_0 [pdf] 104857600 bytes; pin 2026062706"
    )
    _check(
        all_ok, guard.check(legit) == legit, "dates/amounts/sizes/pins survive"
    )

    # ── fingerprint selection (seed uses this on real CSV cells) ──────────
    _check(all_ok, looks_pii(String("123-45-6789")), "looks_pii: SSN cell")
    _check(
        all_ok,
        looks_pii(String("4111 1111 1111 1111")),
        "looks_pii: spaced card cell",
    )
    _check(
        all_ok, looks_pii(String("alice@example.com")), "looks_pii: email cell"
    )
    _check(
        all_ok,
        not looks_pii(String("WHOLE FOODS #123")),
        "looks_pii: merchant is NOT",
    )
    _check(
        all_ok, not looks_pii(String("$1,234.56")), "looks_pii: amount is NOT"
    )
    _check(
        all_ok, not looks_pii(String("2026-07-15")), "looks_pii: date is NOT"
    )

    # ── guard hygiene ──────────────────────────────────────────────────────
    var degenerate = EgressGuard([String(""), String("a")], List[String]())
    _check(
        all_ok,
        not _blocks(degenerate, String("any payload at all")),
        "empty/short needles dropped (no self-DoS)",
    )

    print()
    if all_ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("egress-test: the guard failed a check")
