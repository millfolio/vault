#!/usr/bin/env bash
#
# Build millfolio.zip — the PRECOMPILED millfolio bundle the Millfolio app downloads.
# For commercial IP protection this bundle ships NO `.mojo` source for the vault
# tool surface or its Mojo libs: only precompiled `.mojopkg`s, the prebuilt
# `millfolio` binary, and the prebuilt FFI shims (`.so`/`.dylib`).
#
# The bundle unzips to a single self-contained `millfolio/` dir:
#
#   millfolio/
#     pkgs/      vault.mojopkg + flare/json/lancedb/pdf/docx/csv/zlib .mojopkg
#                (precompiled by scripts/precompile_pkgs.sh — the ONLY way the
#                 vault surface + libs reach the install; no source)
#     build/     millfolio                              (prebuilt vault CLI binary)
#                libzlibmojo.so / liblancedbmojo.dylib / libflare_{tls,zlib,brotli,fs}.so
#                + their OpenSSL/zlib/brotli dep dylibs (rpath-fixed to @loader_path)
#
# The app then:
#   - places build/millfolio directly (no on-device source build), and
#   - copies build/*.{so,dylib} into the toolchain's lib/ so the FFI shims resolve
#     via $CONDA_PREFIX/lib at runtime (Bootstrapper.installMillfolioShims), and
#   - compiles generated `from vault import *` programs with `-I millfolio/pkgs`.
#
# Building the shims needs clang + cargo + OpenSSL/zlib, so we ship them prebuilt
# + made relocatable via @loader_path. The `.mojopkg`s are tied to the exact
# compiler nightly — CI rebuilds them on every nightly bump (never hand-ship a
# stale set). Run via pixi (needs CONDA_PREFIX) AFTER `pixi run ffi`.
# Usage: scripts/package_millfolio.sh [out.zip]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"             # vault/core
OUT="${1:-$ROOT/millfolio.zip}"
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac   # zip runs from a temp dir — need absolute
PREFIX="${CONDA_PREFIX:?run via pixi — need CONDA_PREFIX for the FFI shims + their deps}"
[[ -f "$PREFIX/lib/liblancedbmojo.dylib" ]] || { echo "error: FFI shims missing — run 'pixi run ffi' first" >&2; exit 1; }

MOJO="${MOJO:-mojo}"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
D="$STAGE/millfolio"
mkdir -p "$D/build" "$D/pkgs"

echo "==> precompiling the vault tool surface + libs into pkgs/" >&2
# scripts/precompile_pkgs.sh inherits the lib path overrides (FLARE/JSON/…) that
# package_bundle.sh exports; standalone it defaults to the umbrella sibling layout.
MOJO="$MOJO" bash "$ROOT/scripts/precompile_pkgs.sh" "$D/pkgs"

echo "==> building the prebuilt millfolio binary against the .mojopkg set" >&2
"$MOJO" build "$ROOT/src/millfolio.mojo" -I "$D/pkgs" -o "$D/build/millfolio"

echo "==> bundling FFI shims + deps (relocatable)" >&2
# The shims millfolio dlopens at runtime + the conda dylibs they link (otool -L,
# non-system). liblancedbmojo is a self-contained Rust cdylib (system libs only).
SHIMS=(libzlibmojo.so liblancedbmojo.dylib \
       libflare_tls.so libflare_zlib.so libflare_brotli.so libflare_fs.so)
DEPS=(libssl.3.dylib libcrypto.3.dylib libz.1.dylib \
      libbrotlienc.1.dylib libbrotlidec.1.dylib libbrotlicommon.1.dylib)

for f in "${SHIMS[@]}" "${DEPS[@]}"; do
    [[ -f "$PREFIX/lib/$f" ]] && cp "$PREFIX/lib/$f" "$D/build/$f"
done

# Make every shipped dylib self-contained: id as @rpath/<name>, find its siblings
# via @loader_path (so they resolve next to each other regardless of cwd), and take
# libc++ from the OS rather than the (unshipped) conda one.
for f in "$D"/build/*.so "$D"/build/*.dylib; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    install_name_tool -id "@rpath/$base" "$f" 2>/dev/null || true
    install_name_tool -delete_rpath "$PREFIX/lib" "$f" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
    install_name_tool -change "@rpath/libc++.1.dylib" "/usr/lib/libc++.1.dylib" "$f" 2>/dev/null || true
    codesign --force --sign - "$f" 2>/dev/null || true
done

echo "==> zipping -> $OUT" >&2
rm -f "$OUT"
( cd "$STAGE" && zip -qr -X "$OUT" millfolio )
echo "==> done — bundle contains ONLY .mojopkg + prebuilt binary + FFI shims (no .mojo)" >&2
ls -lh "$OUT" >&2
