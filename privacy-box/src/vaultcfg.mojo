"""vaultcfg — resolve the millfolio vault paths the orchestrator's vault path needs.

The vault path compiles a frontier-written program that does `from vault import *`
and runs it. To do that privacy_box needs to know, all relative to a configured
millfolio checkout (or the sibling layout):

  - the millfolio `build/millfolio` binary    (to print the aliased manifest)
  - the `-I` include set for `mojo build` (the single `<millfolio>/pkgs` dir of
    precompiled `.mojopkg`s — vault + flare/json/lancedb/pdf/docx/csv/zlib — so
    the generated program + its transitive deps resolve with NO source)
  - the LanceDB index dir                 (~/.config/millfolio — read-allowed in
    the vault run sandbox)

Resolution (highest precedence first):
  PRIVACY_BOX_VAULT_SRC  — explicit colon-separated -I list (overrides everything)
  PRIVACY_BOX_MILLFOLIO    — path to the millfolio checkout; deps assumed sibling to it
  default             — the sibling layout: <privacy_box>/../millfolio etc.

`_millfolio_dir()` defaults to ../millfolio relative to the privacy_box cwd. Everything
else (flare/json/…) is a sibling of millfolio, matching millfolio/pixi.toml's own
`-I ../flare -I ../json -I ../lancedb.mojo/src -I ../pdftotext.mojo/src
-I ../zlib.mojo/src`.
"""

from std.os import getenv


def _split_colon(s: String) raises -> List[String]:
    var out = List[String]()
    var parts = s.split(":")
    for i in range(len(parts)):
        var p = String(String(parts[i]).strip())
        if p.byte_length() > 0:
            out.append(p^)
    return out^


def millfolio_dir() raises -> String:
    """The millfolio checkout. PRIVACY_BOX_MILLFOLIO overrides; else ../millfolio (sibling
    of the privacy_box cwd — how the repos are laid out)."""
    var d = getenv("PRIVACY_BOX_MILLFOLIO", "")
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
    `<millfolio>/pkgs`, which holds vault.mojopkg + the flare/json/lancedb/pdf/
    docx/csv/zlib `.mojopkg`s. A generated `from vault import *` program compiles
    against those packages alone (the FFI shims it dlopens are already in the
    toolchain's lib/).

    PRIVACY_BOX_VAULT_SRC (colon-separated) still overrides the whole set (e.g. a
    dev run pointing at source trees or a custom pkgs dir)."""
    var override = getenv("PRIVACY_BOX_VAULT_SRC", "")
    if override != "":
        return _split_colon(override)

    var out = List[String]()
    out.append(millfolio_dir() + "/pkgs")
    return out^


def vault_dir() raises -> String:
    """Resolve the vault dir for the SERVER's vault mode: PRIVACY_BOX_VAULT_DIR wins,
    then $MILLFOLIO_VAULT, then $PRIVACY_BOX_DATA, then ~/millfolio (millfolio's own
    default). Mirrors privacy_box.mojo `_vault_dir()` (with no CLI arg) + millfolio/src/
    vault.mojo `_vault_dir()`."""
    var d = getenv("PRIVACY_BOX_VAULT_DIR", "")
    if d != "":
        return d
    d = getenv("MILLFOLIO_VAULT", "")
    if d != "":
        return d
    d = getenv("PRIVACY_BOX_DATA", "")
    if d != "":
        return d
    return getenv("HOME", ".") + "/millfolio"


def vault_index_dir() raises -> String:
    """The millfolio LanceDB index dir — read-allowed in the vault run sandbox so
    search() can reach the vector store + chunks.tsv side-table. Mirrors
    millfolio/src/index.mojo `_config_dir()`."""
    return getenv("HOME", ".") + "/.config/millfolio"
