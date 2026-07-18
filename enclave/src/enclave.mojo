"""Privacy_box — CLI entry point. The private-VAULT harness: a frontier model writes
a Mojo program that uses the millfolio vault tools; it runs locally over the real
data and only the printed answer surfaces.

Layering (pi-shaped, PRIOR-ART.md):

    enclave.mojo        (this file — CLI)          server.mojo (HTTP, web)
              \\                                      /
               wiring.mojo   build_vault_harness(cfg, vault_dir)
                                  |
    harness.mojo    core loop: codegen -> compile-fix -> run (loopback)
        |        \\
    transport.mojo       egress.mojo   (confidentiality policy)
        |
    sandbox.mojo + broker.mojo   (containment — PROVEN, see SPIKE.md)

Usage:
    enclave vault "<question>" [dir]  answer a question about your private VAULT
                                       (CSV/PDF/Markdown). The frontier model writes
                                       a Mojo program that uses the millfolio vault
                                       tools; it runs locally over the real data and
                                       only the printed answer surfaces.

The vault dir defaults to $MILLFOLIO_VAULT, else $ENCLAVE_DATA, else ~/millfolio.
Index it first with `mill index <dir>` (needs the embedding server live).
"""

from std.sys import argv
from std.os import getenv

from settings import load_config
from wiring import build_vault_harness


def _vault_dir(var arg: String) raises -> String:
    """Resolve the vault dir for the `vault` subcommand: an explicit CLI arg wins,
    then $MILLFOLIO_VAULT, then $ENCLAVE_DATA, then ~/millfolio (millfolio's own
    default). Kept consistent with millfolio/src/vault.mojo `_vault_dir()`."""
    if arg != "":
        return arg^
    var d = getenv("MILLFOLIO_VAULT", "")
    if d != "":
        return d
    d = getenv("ENCLAVE_DATA", "")
    if d != "":
        return d
    return getenv("HOME", ".") + "/millfolio"


def _run_vault(question: String, var vault_dir: String) raises:
    """`enclave vault "<question>" [dir]` — the vault codegen loop."""
    var cfg = load_config()
    var dir = _vault_dir(vault_dir^)
    var harness = build_vault_harness(cfg, dir)
    print(harness.run_vault_task(question, dir.copy()))


def _run_program(program_path: String, var vault_dir: String) raises:
    """`enclave run <program-file> [dir]` — run a SUPPLIED program over the
    vault WITHOUT calling the model. Reads the program from `program_path` (the
    CLI writes a temp file for a URL / passes the local file directly), then runs
    it through the SAME compile + Seatbelt + capture path a generated program
    takes (harness.run_vault_program). No codegen, no manifest, no budget —
    but the program is UNTRUSTED, so it runs in the identical loopback sandbox.
    """
    var cfg = load_config()
    var dir = _vault_dir(vault_dir^)
    var harness = build_vault_harness(cfg, dir)
    var program: String
    with open(program_path, "r") as f:
        program = f.read()
    print(harness.run_vault_program(program, dir.copy()))


def _run_codegen(
    question: String, manifest_path: String, var vault_dir: String
) raises:
    """`enclave codegen "<question>" [--manifest <file> | <dir>]` — print ONLY
    the generated program; no compile, no run. Codegen only ever sees the aliased
    MANIFEST, so the pre-release prompt eval feeds a hand-written synthetic manifest
    (`--manifest`) and lints the program the frontier model writes — no index or
    embedding server needed, just the frontier key. With a `<dir>` instead, the real
    `mill manifest <dir>` is used (needs millfolio built + the vault indexed).
    """
    var cfg = load_config()
    var dir = _vault_dir(vault_dir^)
    var harness = build_vault_harness(cfg, dir)
    var manifest: String
    if manifest_path != "":
        with open(manifest_path, "r") as f:
            manifest = f.read()
    else:
        manifest = harness.vault_manifest(dir)
    print(harness.vault_codegen(question, manifest))


def main() raises:
    # `enclave vault "<question>" [dir]` — the private-vault codegen loop. This is
    # THE query path: enclave is the vault harness, not a CSV tool.
    var argv0 = argv()
    if len(argv0) > 1 and String(argv0[1]) == "vault":
        if len(argv0) < 3:
            print('usage: enclave vault "<question>" [vault_dir]')
            return
        var question = String(argv0[2])
        var vdir = String(argv0[3]) if len(argv0) >= 4 else String("")
        _run_vault(question, vdir^)
        return

    # `enclave run <program-file> [vault_dir]` — run a SUPPLIED program (a
    # human-written / shared `from vault import *` file, NOT the model) over the
    # vault, through the exact same sandbox path as a generated program. Drives
    # `mill run <path-or-url>`.
    if len(argv0) > 1 and String(argv0[1]) == "run":
        if len(argv0) < 3:
            print("usage: enclave run <program-file> [vault_dir]")
            return
        var prog = String(argv0[2])
        var vdir = String(argv0[3]) if len(argv0) >= 4 else String("")
        _run_program(prog, vdir^)
        return

    # `enclave codegen "<question>" [--manifest <file> | <vault_dir>]` — print
    # the generated program only (the pre-release prompt eval drives this).
    if len(argv0) > 1 and String(argv0[1]) == "codegen":
        if len(argv0) < 3:
            print(
                'usage: enclave codegen "<question>" [--manifest <file> |'
                " <vault_dir>]"
            )
            return
        var question = String(argv0[2])
        var mpath = String("")
        var vdir = String("")
        var a = 3
        while a < len(argv0):
            var tok = String(argv0[a])
            if tok == "--manifest" and a + 1 < len(argv0):
                mpath = String(argv0[a + 1])
                a += 2
            else:
                vdir = tok
                a += 1
        _run_codegen(question, mpath, vdir^)
        return

    print('usage: enclave vault "<question>" [vault_dir]')
    print("       enclave run <program-file> [vault_dir]")
    print("  Answer a question about your private VAULT (CSV/PDF/Markdown).")
    print("  `run` executes a SUPPLIED program (no model) in the same sandbox.")
    print("  Index it first with `mill index <dir>` (embedding server live).")
    print(
        "  The vault dir defaults to $MILLFOLIO_VAULT, else $ENCLAVE_DATA,"
        " else ~/millfolio."
    )
