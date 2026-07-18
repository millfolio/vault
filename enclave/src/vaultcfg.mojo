"""vaultcfg — resolve the millfolio vault paths the orchestrator's vault path needs.

The vault path compiles a frontier-written program that does `from vault import *`
and runs it. To do that enclave needs to know, all relative to a configured
millfolio checkout (or the sibling layout):

  - the millfolio `build/millfolio` binary    (to print the aliased manifest)
  - the `-I` include set for `mojo build` (the single `<millfolio>/pkgs` dir of
    precompiled `.mojoc`s — vault + flare/json/lancedb/pdf/docx/csv/zlib — so
    the generated program + its transitive deps resolve with NO source)
  - the LanceDB index dir                 (~/.config/millfolio — read-allowed in
    the vault run sandbox)

Resolution (highest precedence first):
  ENCLAVE_VAULT_SRC  — explicit colon-separated -I list (overrides everything)
  ENCLAVE_MILLFOLIO    — path to the millfolio checkout; deps assumed sibling to it
  default             — the sibling layout: <enclave>/../millfolio etc.

`_millfolio_dir()` defaults to ../millfolio relative to the enclave cwd. Everything
else (flare/json/…) is a sibling of millfolio, matching millfolio/pixi.toml's own
`-I ../flare -I ../json -I ../lancedb.mojo/src -I ../pdftotext.mojo/src
-I ../zlib.mojo/src`.
"""

from std.os import getenv


def resource_path(rel: String) raises -> String:
    """Resolve a enclave resource (a `sandbox/*.sb.template` profile, the
    `resources/enclave-system.md` prompt) to an ABSOLUTE path under
    `ENCLAVE_HOME` — resolution NEVER depends on the process's cwd. Every launcher
    exports `ENCLAVE_HOME` = the enclave install dir (mill's run script, the
    app-server launch agent, the demo's run-demo.sh); dev/eval set `ENCLAVE_PROMPT`
    to bypass this. An already-absolute `rel` is returned unchanged.

    RAISES when `ENCLAVE_HOME` is unset rather than guessing from cwd — a silent
    cwd fallback once made codegen load a wrong stub prompt (the file wasn't found from
    the caller's cwd), which is far worse than a clear startup error."""
    if rel.startswith("/"):
        return rel
    var home = getenv("ENCLAVE_HOME", "")
    if home == "":
        raise Error(
            "ENCLAVE_HOME is not set — refusing to resolve resource '"
            + rel
            + "' from cwd. Export ENCLAVE_HOME=<enclave install dir>"
            " (or set ENCLAVE_PROMPT to the prompt file)."
        )
    return home + "/" + rel


def _split_colon(s: String) raises -> List[String]:
    var out = List[String]()
    var parts = s.split(":")
    for i in range(len(parts)):
        var p = String(String(parts[i]).strip())
        if p.byte_length() > 0:
            out.append(p^)
    return out^


def millfolio_dir() raises -> String:
    """The millfolio checkout. ENCLAVE_MILLFOLIO overrides; else ../millfolio (sibling
    of the enclave cwd — how the repos are laid out)."""
    var d = getenv("ENCLAVE_MILLFOLIO", "")
    if d != "":
        return d
    return String("../millfolio")


def millfolio_bin() raises -> String:
    """The compiled millfolio CLI (used to print the aliased manifest)."""
    return millfolio_dir() + "/build/millfolio"


def vault_include_paths() raises -> List[String]:
    """The `-I` dirs for compiling a `from vault import *` program.

    The install ships PRECOMPILED packages (commercial IP protection — no `.mojo`
    source for the vault surface or its libs), so this is a SINGLE include dir:
    `<millfolio>/pkgs`, which holds vault.mojoc + the flare/json/lancedb/pdf/
    docx/csv/zlib `.mojoc`s. A generated `from vault import *` program compiles
    against those packages alone (the FFI shims it dlopens are already in the
    toolchain's lib/).

    ENCLAVE_VAULT_SRC (colon-separated) still overrides the whole set (e.g. a
    dev run pointing at source trees or a custom pkgs dir)."""
    var override = getenv("ENCLAVE_VAULT_SRC", "")
    if override != "":
        return _split_colon(override)

    var out = List[String]()
    out.append(millfolio_dir() + "/pkgs")
    return out^


def vault_dir() raises -> String:
    """Resolve the vault dir for the SERVER's vault mode: ENCLAVE_VAULT_DIR wins,
    then $MILLFOLIO_VAULT, then $ENCLAVE_DATA, then ~/millfolio (millfolio's own
    default). Mirrors enclave.mojo `_vault_dir()` (with no CLI arg) + millfolio/src/
    vault.mojo `_vault_dir()`."""
    var d = getenv("ENCLAVE_VAULT_DIR", "")
    if d != "":
        return d
    d = getenv("MILLFOLIO_VAULT", "")
    if d != "":
        return d
    d = getenv("ENCLAVE_DATA", "")
    if d != "":
        return d
    return getenv("HOME", ".") + "/millfolio"


def vault_index_dir() raises -> String:
    """The millfolio DATA/index dir — read-allowed in the vault run sandbox so a
    generated program can reach the vector store, chunks.tsv, and the manifest.tsv /
    transactions.tsv side-tables. MUST mirror vault/core `derive/store.config_dir()`:
    `MILLFOLIO_DATA_DIR` overrides; else the macOS-native
    `~/Library/Application Support/Millfolio/data` (moved from `~/.config/millfolio` —
    a stale path here makes the sandbox DENY `manifest.tsv` with `Operation not
    permitted`)."""
    var d = getenv("MILLFOLIO_DATA_DIR", "")
    if d != "":
        return d
    return getenv("HOME", ".") + "/Library/Application Support/Millfolio/data"
