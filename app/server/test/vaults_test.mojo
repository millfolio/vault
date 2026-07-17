"""Vaults registry unit tests (vaults.mojo — the multi-vault switch model).

Builds + runs as a plain Mojo program: `pixi run test-vaults`. Hermetic — drives
$HOME (which roots the registry + per-vault data dirs) to a temp dir via setenv,
and clears the demo/active env so `_is_demo()` is false and the seed is
deterministic. Covers: first-run seeding of "main", boot env resolution
(PRIVACY_BOX_VAULT_DIR + MILLFOLIO_VAULT + MILLFOLIO_DATA_DIR), demo-vault add +
select + pendingRestart, folder add with slugified id, restart re-activation, and
remove semantics (main is protected; removing the active vault falls back to main).
"""

from std.os import setenv, getenv

import vaults


def expect_eq(got: String, want: String, what: String) raises:
    if got != want:
        raise Error("FAIL: " + what + "\n  got:  " + got + "\n  want: " + want)


def expect_true(cond: Bool, what: String) raises:
    if not cond:
        raise Error("FAIL: " + what)


def _has(s: String, sub: String) -> Bool:
    return s.find(sub) >= 0


def main() raises:
    # Hermetic: temp HOME roots everything; not the demo; no stale active id.
    _ = setenv("HOME", "/tmp/millfolio-vaults-test", overwrite=True)
    _ = setenv("MILLFOLIO_DEMO", "", overwrite=True)
    _ = setenv("MILLFOLIO_PORT", "", overwrite=True)
    _ = setenv("MILLFOLIO_ACTIVE_VAULT", "", overwrite=True)
    _ = setenv("MILLFOLIO_DATA_DIR", "", overwrite=True)
    _ = setenv("MILLFOLIO_VAULT", "", overwrite=True)
    _ = setenv("PRIVACY_BOX_VAULT_DIR", "/Users/me/realvault", overwrite=True)

    # ── first-run boot: seeds "main" from PRIVACY_BOX_VAULT_DIR, sets all 3 envs ──
    vaults.activate_selected_vault()
    expect_eq(
        getenv("MILLFOLIO_VAULT", ""),
        "/Users/me/realvault",
        "boot sets MILLFOLIO_VAULT to the active source",
    )
    expect_eq(
        getenv("PRIVACY_BOX_VAULT_DIR", ""),
        "/Users/me/realvault",
        "boot overrides PRIVACY_BOX_VAULT_DIR (it outranks MILLFOLIO_VAULT)",
    )
    expect_true(
        getenv("MILLFOLIO_DATA_DIR", "").find("/Millfolio/data") >= 0
        and getenv("MILLFOLIO_DATA_DIR", "").find("/vaults/") < 0,
        "main's data dir is the legacy base (no /vaults/ subdir)",
    )
    expect_eq(vaults.running_vault_id(), "main", "booted on main")

    var r1 = vaults.registry_json()
    expect_true(_has(r1, '"active":"main"'), "reg active=main")
    expect_true(
        _has(r1, '"pendingRestart":false'), "no pending restart at boot"
    )

    # ── add the demo vault + select it → pendingRestart flips true ───────────────
    var demo_id = vaults.ensure_demo_vault()
    expect_eq(demo_id, "demo", "demo vault id is 'demo'")
    expect_true(vaults.set_active("demo"), "select demo succeeds")
    var r2 = vaults.registry_json()
    expect_true(_has(r2, '"active":"demo"'), "active is now demo")
    expect_true(_has(r2, '"running":"main"'), "still running main")
    expect_true(
        _has(r2, '"pendingRestart":true'), "pending restart after switch"
    )

    # idempotent: ensuring the demo vault again does not duplicate it.
    _ = vaults.ensure_demo_vault()
    var r2b = vaults.registry_json()
    expect_true(
        r2b.find('"id":"demo"') == r2b.rfind('"id":"demo"'),
        "demo vault registered exactly once",
    )

    # ── add a folder vault: id is a slug of the name, uniqued ────────────────────
    var fid = vaults.add_vault("My Photos 2024!!", "/tmp/photos")
    expect_eq(fid, "my-photos-2024", "name slugifies to a filesystem-safe id")
    var fid2 = vaults.add_vault("My Photos 2024", "/tmp/photos2")
    expect_eq(fid2, "my-photos-2024-2", "colliding slug gets a numeric suffix")

    # ── restart re-activation on the demo vault: env points at its isolated dir ──
    vaults.activate_selected_vault()
    expect_true(
        getenv("MILLFOLIO_DATA_DIR", "").find("/vaults/demo") >= 0,
        (
            "after restart the demo vault's data dir is isolated under"
            " /vaults/demo"
        ),
    )
    expect_eq(vaults.running_vault_id(), "demo", "now running on demo")
    var r3 = vaults.registry_json()
    expect_true(
        _has(r3, '"pendingRestart":false'),
        "pending clears once running==active",
    )

    # ── remove semantics ─────────────────────────────────────────────────────────
    expect_true(not vaults.remove_vault("main"), "main cannot be removed")
    expect_true(not vaults.remove_vault("nope"), "unknown id cannot be removed")
    expect_true(vaults.remove_vault("demo"), "active demo removes")
    var r4 = vaults.registry_json()
    expect_true(
        _has(r4, '"active":"main"'),
        "removing the active vault falls back to main",
    )
    expect_true(
        r4.find('"id":"demo"') < 0,
        "demo is gone from the registry after remove",
    )

    print("vaults_test: all tests passed")
