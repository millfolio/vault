#!/usr/bin/env bash
#
# Build veilens.zip — the veilens source bundle the Millrace app downloads, then
# `mojo build`s on-device against a separately-fetched Mojo compiler (see
# millrace/app Bootstrapper). Mirrors headgate/scripts/package_headgate.sh.
#
# veilens links the whole toolbox, so the bundle unzips to six siblings:
#
#   veilens/         src + pixi.toml + build/{libzlibmojo, liblancedbmojo,
#                    libflare_{tls,zlib,brotli,fs} + their OpenSSL/zlib/brotli
#                    deps, all rpath-fixed to @loader_path}
#   flare/flare/     vendored flare package (HTTP client + TLS)
#   json/json/       vendored json package (response parsing)
#   lancedb.mojo/src vendored LanceDB binding (the vector store)
#   pdftotext.mojo/src + zlib.mojo/src   PDF text extraction (+ FlateDecode)
#
# so the app can run:
#   (cd veilens && mojo build src/veilens.mojo \
#      -I ../flare -I ../json -I ../lancedb.mojo/src \
#      -I ../pdftotext.mojo/src -I ../zlib.mojo/src -o build/veilens)
#
# The app then copies build/*.{so,dylib} into the toolchain's lib/ so the FFI
# shims resolve via $CONDA_PREFIX/lib at runtime (Bootstrapper.installVeilensShims).
# We ship the prebuilt shims (building them needs clang + cargo + OpenSSL/zlib)
# made relocatable via @loader_path. Run via pixi (needs CONDA_PREFIX) AFTER
# `pixi run ffi`. Usage: scripts/package_veilens.sh [out.zip]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLARE="${FLARE:-$ROOT/../flare}"
JSON="${JSON:-$ROOT/../json}"
LANCEDB="${LANCEDB:-$ROOT/../lancedb.mojo}"
PDFTOTEXT="${PDFTOTEXT:-$ROOT/../pdftotext.mojo}"
ZLIB="${ZLIB:-$ROOT/../zlib.mojo}"
CSV="${CSV:-$ROOT/../csv.mojo}"
OUT="${1:-$ROOT/veilens.zip}"
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac   # zip runs from a temp dir — need absolute
PREFIX="${CONDA_PREFIX:?run via pixi — need CONDA_PREFIX for the FFI shims + their deps}"
[[ -f "$PREFIX/lib/liblancedbmojo.dylib" ]] || { echo "error: FFI shims missing — run 'pixi run ffi' first" >&2; exit 1; }

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
D="$STAGE/veilens"

echo "==> staging veilens source" >&2
mkdir -p "$D/build"
cp -R "$ROOT/src" "$D/src"
cp "$ROOT/pixi.toml" "$D/pixi.toml"
[[ -f "$ROOT/pixi.lock" ]] && cp "$ROOT/pixi.lock" "$D/pixi.lock"

echo "==> bundling FFI shims + deps (relocatable)" >&2
# The shims veilens dlopens at runtime + the conda dylibs they link (otool -L,
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

echo "==> staging flare + json + lancedb.mojo + pdftotext.mojo + zlib.mojo + csv.mojo" >&2
mkdir -p "$STAGE/flare" "$STAGE/json" "$STAGE/lancedb.mojo" "$STAGE/pdftotext.mojo" "$STAGE/zlib.mojo" "$STAGE/csv.mojo"
cp -R "$FLARE/flare" "$STAGE/flare/flare"
cp -R "$JSON/json" "$STAGE/json/json"
cp -R "$LANCEDB/src" "$STAGE/lancedb.mojo/src"
cp -R "$PDFTOTEXT/src" "$STAGE/pdftotext.mojo/src"
cp -R "$ZLIB/src" "$STAGE/zlib.mojo/src"
cp -R "$CSV/src" "$STAGE/csv.mojo/src"

echo "==> zipping -> $OUT" >&2
rm -f "$OUT"
( cd "$STAGE" && zip -qr -X "$OUT" veilens flare json lancedb.mojo pdftotext.mojo zlib.mojo csv.mojo )
echo "==> done" >&2
ls -lh "$OUT" >&2
