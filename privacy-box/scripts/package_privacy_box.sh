#!/usr/bin/env bash
#
# Build privacy_box.zip — the privacy_box source bundle the Millfolio menu app downloads,
# then `mojo build`s on-device against a separately-fetched Mojo compiler (see
# millfolio/app Bootstrapper). Mirrors inference-server/scripts/package_engine.sh.
#
# The bundle unzips to four siblings:
#
#   privacy_box/    src + sandbox/ (Seatbelt profiles) + scripts/ + pixi.toml +
#                build/{libflare_{tls,zlib,brotli,fs}.so + their OpenSSL/zlib/brotli
#                deps, all rpath-fixed to @loader_path}
#   flare/flare/ vendored flare package (HTTP client + TLS)
#   json/json/   vendored json package (response parsing)
#   jinja2.mojo/src/  vendored jinja2.mojo (JSON for config)
#
# so the app can run:
#   (cd privacy_box && mojo build src/privacy_box.mojo -I ../flare -I ../json -I ../jinja2.mojo/src -o build/privacy_box)
#
# We ship the prebuilt flare FFI shims (building them needs clang + OpenSSL/zlib/
# brotli) + their dylib deps, made relocatable via @loader_path so the binary finds
# them at runtime with NO pixi. Run via pixi (needs CONDA_PREFIX) AFTER `pixi run
# flare-ffi`. Usage: scripts/package_privacy_box.sh [out.zip]
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLARE="${FLARE:-$ROOT/../flare}"
JSON="${JSON:-$ROOT/../json}"
JINJA2="${JINJA2:-$ROOT/../jinja2.mojo}"
LOGGING="${LOGGING:-$ROOT/../logging.mojo}"   # `from logging import log` (orchestrator/sandbox)
OUT="${1:-$ROOT/privacy_box.zip}"
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac   # zip runs from a temp dir — need absolute
PREFIX="${CONDA_PREFIX:?run via pixi — need CONDA_PREFIX for the flare FFI shims + their deps}"
[[ -f "$PREFIX/lib/libflare_tls.so" ]] || { echo "error: flare FFI shims missing — run 'pixi run flare-ffi' first" >&2; exit 1; }

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
H="$STAGE/privacy_box"

echo "==> staging privacy_box source" >&2
mkdir -p "$H/build"
cp -R "$ROOT/src" "$H/src"
cp -R "$ROOT/sandbox" "$H/sandbox"
cp -R "$ROOT/scripts" "$H/scripts"
[[ -d "$ROOT/resources" ]] && cp -R "$ROOT/resources" "$H/resources"   # runtime-loaded system prompt
cp "$ROOT/../pixi.toml" "$H/pixi.toml"
[[ -f "$ROOT/config.example.json" ]] && cp "$ROOT/config.example.json" "$H/"

# Build + bundle the web UI (web/dist) so the privacy_box server can serve it at
# http://localhost:10000 with no Node at runtime. Needs npm at PACKAGE time.
if [[ -d "$ROOT/web" ]]; then
    echo "==> building web UI (npm)" >&2
    ( cd "$ROOT/web" && npm ci && npm run build ) >&2
    mkdir -p "$H/web"
    cp -R "$ROOT/web/dist" "$H/web/dist"
fi

echo "==> bundling flare FFI shims + deps (relocatable)" >&2
# The four flare FFI shims + the conda dylibs they link (otool -L, non-system).
SHIMS=(libflare_tls.so libflare_zlib.so libflare_brotli.so libflare_fs.so)
DEPS=(libssl.3.dylib libcrypto.3.dylib libz.1.dylib \
      libbrotlienc.1.dylib libbrotlidec.1.dylib libbrotlicommon.1.dylib)

for f in "${SHIMS[@]}" "${DEPS[@]}"; do
    [[ -f "$PREFIX/lib/$f" ]] && cp "$PREFIX/lib/$f" "$H/build/$f"
done

# Make every shipped dylib self-contained: id as @rpath/<name>, find its siblings
# via @loader_path (so they resolve next to each other regardless of cwd), and take
# libc++ from the OS rather than the (unshipped) conda one.
for f in "$H"/build/*.so "$H"/build/*.dylib; do
    [[ -f "$f" ]] || continue
    base="$(basename "$f")"
    install_name_tool -id "@rpath/$base" "$f" 2>/dev/null || true
    install_name_tool -delete_rpath "$PREFIX/lib" "$f" 2>/dev/null || true
    install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
    install_name_tool -change "@rpath/libc++.1.dylib" "/usr/lib/libc++.1.dylib" "$f" 2>/dev/null || true
    codesign --force --sign - "$f" 2>/dev/null || true
done

echo "==> staging flare + json + jinja2.mojo + logging.mojo" >&2
mkdir -p "$STAGE/flare" "$STAGE/json" "$STAGE/jinja2.mojo" "$STAGE/logging.mojo"
cp -R "$FLARE/flare" "$STAGE/flare/flare"
cp -R "$JSON/json" "$STAGE/json/json"
cp -R "$JINJA2/src" "$STAGE/jinja2.mojo/src"
cp -R "$LOGGING/src" "$STAGE/logging.mojo/src"   # orchestrator/sandbox: `from logging import log`

echo "==> zipping -> $OUT" >&2
rm -f "$OUT"
( cd "$STAGE" && zip -qr -X "$OUT" privacy_box flare json jinja2.mojo logging.mojo )
echo "==> done" >&2
ls -lh "$OUT" >&2
