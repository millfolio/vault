"""home_path_test — unit tests for the persisted-path portability helpers
(vault.storage `contract_home` / `expand_home`).

Builds + runs as a plain Mojo program: `pixi run test-homepath`. Drives $HOME
via setenv, so it is hermetic. Covers contraction (under-home → `~/…`, the
prefix-boundary case, outside-home pass-through), expansion (`~`/`~/…` →
current $HOME, absolute pass-through for legacy rows), and the roundtrip.
"""

from std.os import setenv

from vault.storage import contract_home, expand_home


def expect_eq(got: String, want: String, what: String) raises:
    if got != want:
        raise Error("FAIL: " + what + "\n  got:  " + got + "\n  want: " + want)


def main() raises:
    _ = setenv("HOME", "/Users/alice", overwrite=True)

    # ── contract_home ────────────────────────────────────────────────────────────
    expect_eq(
        contract_home("/Users/alice/docs/q1.pdf"),
        "~/docs/q1.pdf",
        "under-home path contracts",
    )
    expect_eq(contract_home("/Users/alice"), "~", "home itself contracts to ~")
    expect_eq(
        contract_home("/Users/alicey/docs"),
        "/Users/alicey/docs",
        "prefix boundary: a sibling user does NOT contract",
    )
    expect_eq(
        contract_home("/opt/data/x.csv"),
        "/opt/data/x.csv",
        "outside-home path passes through",
    )
    expect_eq(
        contract_home("~/already/contracted"),
        "~/already/contracted",
        "already-contracted path passes through",
    )

    # ── expand_home ──────────────────────────────────────────────────────────────
    expect_eq(expand_home("~"), "/Users/alice", "bare ~ expands to $HOME")
    expect_eq(
        expand_home("~/docs/q1.pdf"),
        "/Users/alice/docs/q1.pdf",
        "~/ path expands under the CURRENT home",
    )
    expect_eq(
        expand_home("/Users/bob/docs/q1.pdf"),
        "/Users/bob/docs/q1.pdf",
        "legacy absolute row passes through unchanged",
    )

    # ── roundtrip + the cross-machine move ───────────────────────────────────────
    expect_eq(
        expand_home(contract_home("/Users/alice/vault/st.pdf")),
        "/Users/alice/vault/st.pdf",
        "contract∘expand is identity on the same machine",
    )
    var stored = contract_home("/Users/alice/vault/st.pdf")
    _ = setenv("HOME", "/Users/bob", overwrite=True)
    expect_eq(
        expand_home(stored),
        "/Users/bob/vault/st.pdf",
        "a contracted row follows the new machine's home",
    )

    # ── degenerate homes never mangle ────────────────────────────────────────────
    _ = setenv("HOME", "/", overwrite=True)
    expect_eq(contract_home("/anything"), "/anything", "HOME=/ never contracts")
    _ = setenv("HOME", "", overwrite=True)
    expect_eq(
        contract_home("/anything"), "/anything", "empty HOME never contracts"
    )

    print("home_path_test: all tests passed")
