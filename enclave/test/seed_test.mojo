"""Seed-test — canary persistence + CSV fingerprint sampling, end to end with
the guard. `pixi run test-seed` (runs over a THROWAWAY dir the task wipes).

Proves the three seeding contracts (security/seed.mojo):
  1. the canary is minted once, persisted as a DOTFILE in the vault dir
     (invisible to the manifest walker's dotfile rule), and stable across calls;
  2. fingerprints pick up PII-shaped CSV cells (SSN/card/email) plus the
     secret and the real vault path — and NOT merchant names/amounts/dates;
  3. a guard armed from those seeds actually blocks a leak.
"""

from std.os import getenv, makedirs
from std.os.path import isfile

from security.egress import EgressGuard
from security.seed import (
    ensure_canary,
    vault_fingerprints,
    CANARY_FILENAME,
    CANARY_PREFIX,
)


def _has(fps: List[String], v: String) -> Bool:
    for f in fps:
        if f == v:
            return True
    return False


def _check(mut all_ok: Bool, ok: Bool, label: String):
    print("[" + ("PASS" if ok else "FAIL") + "] " + label)
    all_ok = all_ok and ok


def main() raises:
    var all_ok = True
    var dir = String(getenv("SEED_TEST_DIR", ""))
    if dir == "":
        raise Error("seed-test: SEED_TEST_DIR not set")
    makedirs(dir, exist_ok=True)
    with open(dir + "/statements.csv", "w") as f:
        f.write(
            String("Date,Description,Account,Amount\n")
            + "2026-07-01,WHOLE FOODS #123,123-45-6789,$84.12\n"
            + '2026-07-02,bob@corp.example.org,"4111 1111 1111 1111",$12.00\n'
        )

    # ── canary: minted once, persisted, dotfile, stable ────────────────────
    var c1 = ensure_canary(dir)
    var c2 = ensure_canary(dir)
    _check(all_ok, c1.startswith(String(CANARY_PREFIX)), "canary token minted")
    _check(all_ok, c1 == c2, "canary stable across calls (persisted)")
    _check(
        all_ok,
        isfile(dir + "/" + String(CANARY_FILENAME)),
        "canary lives in the vault dir",
    )
    _check(
        all_ok,
        String(CANARY_FILENAME).startswith("."),
        "canary is a dotfile (manifest/index walkers skip it)",
    )

    # ── fingerprints: identifiers in, free text out ────────────────────────
    var secret = String("sk-ant-test-secret-key")
    var fps = vault_fingerprints(dir, secret)
    _check(all_ok, _has(fps, secret), "secret fingerprinted")
    _check(all_ok, _has(fps, dir), "real vault path fingerprinted")
    _check(all_ok, _has(fps, String("123-45-6789")), "SSN cell fingerprinted")
    _check(
        all_ok,
        _has(fps, String("4111 1111 1111 1111")),
        "quoted card cell fingerprinted",
    )
    _check(
        all_ok,
        _has(fps, String("bob@corp.example.org")),
        "email cell fingerprinted",
    )
    _check(
        all_ok,
        not _has(fps, String("WHOLE FOODS #123")),
        "merchant name NOT fingerprinted",
    )
    _check(all_ok, not _has(fps, String("$84.12")), "amount NOT fingerprinted")
    _check(
        all_ok, not _has(fps, String("2026-07-01")), "date NOT fingerprinted"
    )

    # ── end to end: a guard armed from the seeds blocks the leak ──────────
    var canaries = List[String]()
    canaries.append(c1.copy())
    var guard = EgressGuard(fps^, canaries^)
    var clean_ok: Bool
    try:
        _ = guard.check(String("Aggregate col_1 grouped by col_0."))
        clean_ok = True
    except:
        clean_ok = False
    _check(all_ok, clean_ok, "clean payload still passes the armed guard")
    var leak_blocked: Bool
    try:
        _ = guard.check(String("debug: the account cell was 123-45-6789"))
        leak_blocked = False
    except:
        leak_blocked = True
    _check(all_ok, leak_blocked, "sampled real value blocks the send")
    var canary_blocked: Bool
    try:
        _ = guard.check(String("raw dir dump: ") + c1)
        canary_blocked = False
    except:
        canary_blocked = True
    _check(all_ok, canary_blocked, "echoed canary blocks the send")

    print()
    if all_ok:
        print("ALL CHECKS PASSED")
    else:
        print("CHECKS FAILED")
        raise Error("seed-test: seeding failed a check")
