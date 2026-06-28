#!/usr/bin/env bash
#
# precompile_pkgs.sh — produce the precompiled Mojo package set the vault tool
# surface ships as (commercial IP protection: the install bundle carries NO
# `.mojo` source for the vault surface or its libs, only these `.mojopkg`s + the
# prebuilt binaries + the prebuilt FFI shims).
#
# Output: a single `pkgs/` dir holding ONE `.mojopkg` per import name —
#   zlib.mojopkg csv.mojopkg lancedb.mojopkg pdf.mojopkg docx.mojopkg
#   flare.mojopkg json.mojopkg vault.mojopkg
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
LANCEDB="${LANCEDB:-$ROOT/../../lancedb.mojo}"
PDFTOTEXT="${PDFTOTEXT:-$ROOT/../../pdftotext.mojo}"
ZLIB="${ZLIB:-$ROOT/../../zlib.mojo}"
CSV="${CSV:-$ROOT/../../csv.mojo}"
DOCX="${DOCX:-$ROOT/../../docx.mojo}"
OUT="${1:-$ROOT/build/pkgs}"
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac

MOJO="${MOJO:-mojo}"

rm -rf "$OUT"; mkdir -p "$OUT"
ASM="$(mktemp -d)"; trap 'rm -rf "$ASM"' EXIT

# Give a loose single-file lib module ("$2".mojo at "$1") a package shape named
# by its import name ("$2"): a dir <name>/ with __init__.mojo re-exporting the
# module as a submodule. Keeps the lib REPOS as-is — we assemble the package dir
# here at package time.
make_pkg_dir() {  # <src-module-file> <import-name>
    local src="$1" name="$2"
    local d="$ASM/$name"
    mkdir -p "$d"
    cp "$src" "$d/$name.mojo"
    printf 'from %s.%s import *\n' "$name" "$name" > "$d/__init__.mojo"
}

echo "==> assembling loose-lib package dirs" >&2
make_pkg_dir "$ZLIB/src/zlib.mojo"          zlib
make_pkg_dir "$CSV/src/csv.mojo"            csv
make_pkg_dir "$LANCEDB/src/lancedb.mojo"    lancedb
make_pkg_dir "$PDFTOTEXT/src/pdf.mojo"      pdf
make_pkg_dir "$DOCX/src/docx.mojo"          docx

# `mojo precompile` compiles EVERY file in a package dir (unlike `mojo build`,
# which only pulls the submodules actually imported). The sibling lib REPOS are
# precompiled AS-IS: this script patches, trims, or deletes NOTHING. The
# package-shaped libs (json, flare) compile straight from their sibling checkouts
# under the pinned nightly — json ships its full backend including the GPU path
# (Apple Metal / CUDA), and flare's reflective `Extracted[H].serve` precompiles
# cleanly. The loose single-file libs above were given a package SHAPE by
# make_pkg_dir (a read-only wrapper dir), which never touches the sibling source.
echo "==> precompiling in dependency order -> $OUT" >&2
# Leaves first (no inter-lib deps), then ones that depend on them, then vault.
#   zlib, csv, lancedb, json : leaves
#   flare                    : imports `from json import …`
#   pdf, docx                : import `from zlib import inflate`
#   vault                    : imports all of the above + the std lib
"$MOJO" precompile "$ASM/zlib"        -o "$OUT/zlib.mojopkg"
"$MOJO" precompile "$ASM/csv"         -o "$OUT/csv.mojopkg"
"$MOJO" precompile "$ASM/lancedb"     -o "$OUT/lancedb.mojopkg"
"$MOJO" precompile "$JSON/json"        -o "$OUT/json.mojopkg"
"$MOJO" precompile "$FLARE/flare" -I "$OUT" -o "$OUT/flare.mojopkg"
"$MOJO" precompile "$ASM/pdf"  -I "$OUT" -o "$OUT/pdf.mojopkg"
"$MOJO" precompile "$ASM/docx" -I "$OUT" -o "$OUT/docx.mojopkg"
"$MOJO" precompile "$ROOT/src/vault" -I "$OUT" -o "$OUT/vault.mojopkg"

echo "==> precompiled package set:" >&2
ls -1 "$OUT" >&2
