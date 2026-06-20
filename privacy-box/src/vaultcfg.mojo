"""vaultcfg — resolve the millfolio vault paths the orchestrator's vault path needs.

The vault path compiles a frontier-written program that does `from vault import *`
and runs it. To do that privacy_box needs to know, all relative to a configured
millfolio checkout (or the sibling layout):

  - the millfolio `build/millfolio` binary    (to print the aliased manifest)
  - the `-I` include set for `mojo build` (millfolio/src + flare/json/lancedb/
    pdftotext/zlib so the generated program + its transitive deps resolve)
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
    """The `-I` dirs for compiling a `from vault import *` program. Mirrors
    millfolio/pixi.toml's build line: millfolio/src + flare + json + lancedb.mojo/src
    + pdftotext.mojo/src + zlib.mojo/src.

    PRIVACY_BOX_VAULT_SRC (colon-separated) overrides the whole set. Otherwise the
    deps are resolved as SIBLINGS of the millfolio dir (so a moved millfolio keeps
    its deps adjacent)."""
    var override = getenv("PRIVACY_BOX_VAULT_SRC", "")
    if override != "":
        return _split_colon(override)

    var dac = millfolio_dir()
    # The sibling root: millfolio's parent dir. If millfolio is "../millfolio", the
    # parent is "..". We keep it relative so it resolves from the privacy_box cwd,
    # matching millfolio/pixi.toml's own relative `-I ../flare` style.
    var sib = dac + "/.."
    var out = List[String]()
    out.append(dac + "/src")
    out.append(sib + "/flare")
    out.append(sib + "/json")
    out.append(sib + "/lancedb.mojo/src")
    out.append(sib + "/pdftotext.mojo/src")
    out.append(sib + "/zlib.mojo/src")
    out.append(sib + "/csv.mojo/src")
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
