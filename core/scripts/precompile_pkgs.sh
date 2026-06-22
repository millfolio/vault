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
# which only pulls the submodules actually imported). The package-shaped libs
# carry orphan submodules that the vault surface never imports and that don't
# build under the pinned nightly — copy each package and prune those subtrees so
# precompile sees only the reachable code. `json/gpu` is decoupled in this
# CPU-only nightly port (its import is already commented out in parser.mojo) but
# the broken source dir still ships; drop it.
echo "==> assembling trimmed json/flare package dirs" >&2
cp -R "$JSON/json"  "$ASM/json"
rm -rf "$ASM/json/gpu"
cp -R "$FLARE/flare" "$ASM/flare"

# flare's SERVER-side reflective extractor (`Extracted[H].serve`, http/extract.mojo)
# uses `reflect[Self.H]().field_count()` + `__struct_field_ref`, which `mojo build`
# leaves un-elaborated (never instantiated) but `mojo precompile` eagerly
# elaborates and fails to compile under the pinned nightly. The vault surface uses
# only flare's HTTP *client* (HttpClient/Request), never this server adapter, so we
# neutralise just that one method body in the assembled copy (the extractor TYPES it
# re-exports stay importable, so http/__init__'s re-exports still resolve).
python3 - "$ASM/flare/http/extract.mojo" <<'PY'
import re, sys
p = sys.argv[1]
src = open(p).read()
needle = "    def serve(self, req: Request) raises -> Response:\n        var h = Self.H()\n        comptime n = reflect[Self.H]().field_count()\n"
i = src.index(needle)
j = src.index("        return h.serve(req)\n", i)
stub = ("    def serve(self, req: Request) raises -> Response:\n"
        "        # Reflective extraction stubbed out for `mojo precompile` (the\n"
        "        # original uses reflect()/__struct_field_ref, which precompile\n"
        "        # cannot elaborate under the pinned nightly). The vault surface\n"
        "        # uses only flare's HTTP client, never this server adapter.\n"
        "        var h = Self.H()\n")
src = src[:i] + stub + src[j:]
open(p, "w").write(src)
print("==> patched flare http/extract.mojo Extracted.serve for precompile", file=sys.stderr)
PY

echo "==> precompiling in dependency order -> $OUT" >&2
# Leaves first (no inter-lib deps), then ones that depend on them, then vault.
#   zlib, csv, lancedb, json : leaves
#   flare                    : imports `from json import …`
#   pdf, docx                : import `from zlib import inflate`
#   vault                    : imports all of the above + the std lib
"$MOJO" precompile "$ASM/zlib"        -o "$OUT/zlib.mojopkg"
"$MOJO" precompile "$ASM/csv"         -o "$OUT/csv.mojopkg"
"$MOJO" precompile "$ASM/lancedb"     -o "$OUT/lancedb.mojopkg"
"$MOJO" precompile "$ASM/json"        -o "$OUT/json.mojopkg"
"$MOJO" precompile "$ASM/flare" -I "$OUT" -o "$OUT/flare.mojopkg"
"$MOJO" precompile "$ASM/pdf"  -I "$OUT" -o "$OUT/pdf.mojopkg"
"$MOJO" precompile "$ASM/docx" -I "$OUT" -o "$OUT/docx.mojopkg"
"$MOJO" precompile "$ROOT/src/vault" -I "$OUT" -o "$OUT/vault.mojopkg"

echo "==> precompiled package set:" >&2
ls -1 "$OUT" >&2
