#!/usr/bin/env bash
#
# precompile_pkgs.sh — produce the precompiled Mojo package set the vault tool
# surface ships as (commercial IP protection: the install bundle carries NO
# `.mojo` source for the vault surface or its libs, only these `.mojoc`s + the
# prebuilt binaries + the prebuilt FFI shims).
#
# Output: a single `pkgs/` dir holding ONE `.mojoc` per import name —
#   zlib.mojoc csv.mojoc lancedb.mojoc pdf.mojoc docx.mojoc
#   flare.mojoc json.mojoc vault.mojoc
# A generated `from vault import *` program then builds with `-I <pkgs>` against
# ONLY these packages (no `.mojo` on the include path) and dlopens the (already
# prebuilt) FFI shims at runtime.
#
# Tied to the exact compiler nightly that produced them — CI rebuilds these on
# every nightly bump; never hand-ship a stale set. Run via pixi (needs the
# pinned mojo). Usage: precompile_pkgs.sh [out-pkgs-dir]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"          # vault/core
FLARE="${FLARE:-$ROOT/../../flare}"
JSON="${JSON:-$ROOT/../../json}"
OUT="${1:-$ROOT/build/pkgs}"
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac

MOJO="${MOJO:-mojo}"

rm -rf "$OUT"; mkdir -p "$OUT"

# The tin libs (zlib, csv, lancedb, pdf, docx) are pixi source dependencies
# now: the env already holds their compiled packages under
# $CONDA_PREFIX/lib/mojo, built from the registry-pinned git revs. Ship those
# — no source assembly, and the set matches what the workspace builds against.
echo "==> copying tin packages from the pixi env" >&2
ENV_PKGS="${CONDA_PREFIX:?run via pixi}/lib/mojo"
copy_tin() {  # <import-name>
    local name="$1"
    if [[ -f "$ENV_PKGS/$name.mojoc" ]]; then
        cp "$ENV_PKGS/$name.mojoc" "$OUT/$name.mojoc"
    else
        cp "$ENV_PKGS/$name.mojopkg" "$OUT/$name.mojoc"
    fi
}
copy_tin zlib
copy_tin csv
copy_tin lancedb
copy_tin pdf
copy_tin docx

echo "==> precompiling in dependency order -> $OUT" >&2
# Leaves first (no inter-lib deps), then ones that depend on them, then vault.
#   zlib, csv, lancedb, json : leaves
#   flare                    : imports `from json import …`
#   pdf, docx                : import `from zlib import inflate`
#   vault                    : imports all of the above + the std lib
"$MOJO" precompile "$JSON/json"        -o "$OUT/json.mojoc"
"$MOJO" precompile "$FLARE/flare" -I "$OUT" -o "$OUT/flare.mojoc"
"$MOJO" precompile "$ROOT/src/vault" -I "$OUT" -o "$OUT/vault.mojoc"

echo "==> precompiled package set:" >&2
ls -1 "$OUT" >&2
