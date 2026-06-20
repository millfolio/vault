"""privacy_box — CLI entry point. The private-VAULT harness: a frontier model writes
a Mojo program that uses the millfolio vault tools; it runs locally over the real
data and only the printed answer surfaces.

Layering (pi-shaped, PRIOR-ART.md):

    privacy_box.mojo        (this file — CLI)          server.mojo (HTTP, web)
              \\                                      /
               wiring.mojo   build_vault_orchestrator(cfg, vault_dir)
                                  |
    orchestrator.mojo    core loop: codegen -> compile-fix -> run (loopback)
        |        \\
    transport.mojo       egress.mojo   (confidentiality policy)
        |
    sandbox.mojo + broker.mojo   (containment — PROVEN, see SPIKE.md)

Usage:
    privacy_box vault "<question>" [dir]  answer a question about your private VAULT
                                       (CSV/PDF/Markdown). The frontier model writes
                                       a Mojo program that uses the millfolio vault
                                       tools; it runs locally over the real data and
                                       only the printed answer surfaces.

The vault dir defaults to $MILLFOLIO_VAULT, else $PRIVACY_BOX_DATA, else ~/millfolio.
Index it first with `mill index <dir>` (needs the embedding server live).
"""

from std.sys import argv
from std.os import getenv

from settings import load_config
from wiring import build_vault_orchestrator


def _vault_dir(var arg: String) raises -> String:
    """Resolve the vault dir for the `vault` subcommand: an explicit CLI arg wins,
    then $MILLFOLIO_VAULT, then $PRIVACY_BOX_DATA, then ~/millfolio (millfolio's own
    default). Kept consistent with millfolio/src/vault.mojo `_vault_dir()`."""
    if arg != "":
        return arg^
    var d = getenv("MILLFOLIO_VAULT", "")
    if d != "":
        return d
    d = getenv("PRIVACY_BOX_DATA", "")
    if d != "":
        return d
    return getenv("HOME", ".") + "/millfolio"


def _run_vault(question: String, var vault_dir: String) raises:
    """`privacy_box vault "<question>" [dir]` — the vault codegen loop."""
    var cfg = load_config()
    var dir = _vault_dir(vault_dir^)
    var orch = build_vault_orchestrator(cfg, dir)
    print(orch.run_vault_task(question, dir.copy()))


def main() raises:
    # `privacy_box vault "<question>" [dir]` — the private-vault codegen loop. This is
    # THE query path: privacy_box is the vault harness, not a CSV tool.
    var argv0 = argv()
    if len(argv0) > 1 and String(argv0[1]) == "vault":
        if len(argv0) < 3:
            print('usage: privacy_box vault "<question>" [vault_dir]')
            return
        var question = String(argv0[2])
        var vdir = String(argv0[3]) if len(argv0) >= 4 else String("")
        _run_vault(question, vdir^)
        return

    print('usage: privacy_box vault "<question>" [vault_dir]')
    print("  Answer a question about your private VAULT (CSV/PDF/Markdown).")
    print("  Index it first with `mill index <dir>` (embedding server live).")
    print("  The vault dir defaults to $MILLFOLIO_VAULT, else $PRIVACY_BOX_DATA, else ~/millfolio.")
