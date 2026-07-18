#!/usr/bin/env bash
#
# Build enclave.zip — the enclave bundle the Millfolio app downloads. The
# enclave binary is now shipped PREBUILT (built here in CI, not `mojo build`d
# on-device — mirrors vault/core/scripts/package_millfolio.sh).
#
# The bundle unzips to one dir:
#
#   enclave/    build/enclave                     (prebuilt orchestrator binary)
#                sandbox/ (Seatbelt profiles) + scripts/ + resources/ + web/dist +
#                build/{libflare_{tls,zlib,brotli,fs}.so + their OpenSSL/zlib/brotli
#                deps, all rpath-fixed to @loader_path}
#
# so the app runs build/enclave directly — no on-device source build, no
# `.mojo` source shipped for the orchestrator. (The per-query codegen still shells
# `mojo build` at runtime, but against the millfolio pkgs/*.mojoc — see the app's
# vault include paths — not enclave's own source.)
#
# The binary is built here with the SAME `mojo build` invocation the installer
# used, its rpath relocated to a device-relative @loader_path (the CI machine's
# $CONDA_PREFIX/lib is absent on the user's box), and ad-hoc signed. enclave
# runs WITH CONDA_PREFIX set and dlopens its flare shims from $CONDA_PREFIX/lib
# (installEnclaveShims puts them there), so the shims need no rpath; only the
# Mojo runtime dylibs (linked via @rpath) resolve from the toolchain's mojo/lib.
#
# We ship the prebuilt flare FFI shims (building them needs clang + OpenSSL/zlib/
# brotli) + their dylib deps, made relocatable via @loader_path. Run via pixi
# (needs CONDA_PREFIX) AFTER `pixi run flare-ffi`. The build needs the vault
# pkgs/*.mojoc on its include path (in-process tag reads) — pass PKGS=<dir>, else
# it precompiles a throwaway set. Usage: scripts/package_enclave.sh [out.zip]
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLARE="${FLARE:-$ROOT/../flare}"
JSON="${JSON:-$ROOT/../json}"
JINJA2="${JINJA2:-$ROOT/../jinja2.mojo}"
LOGGING="${LOGGING:-$ROOT/../logging.mojo}"   # `from logging import log` (orchestrator/sandbox)
OUT="${1:-$ROOT/enclave.zip}"
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac   # zip runs from a temp dir — need absolute
PREFIX="${CONDA_PREFIX:?run via pixi — need CONDA_PREFIX for the flare FFI shims + their deps}"
MOJO="${MOJO:-mojo}"
[[ -f "$PREFIX/lib/libflare_tls.so" ]] || { echo "error: flare FFI shims missing — run 'pixi run flare-ffi' first" >&2; exit 1; }

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
H="$STAGE/enclave"

# The precompiled vault package set (vault.mojoc etc.) — needed on the build's
# include path for the orchestrator's in-process tag reads. Reuse a caller-built
# set (package_bundle passes PKGS) or precompile a throwaway one for standalone runs.
PKGS="${PKGS:-}"
if [[ -z "$PKGS" ]]; then
    echo "==> PKGS unset — precompiling the vault package set" >&2
    PKGS="$STAGE/pkgs"
    MOJO="$MOJO" bash "$ROOT/../core/scripts/precompile_pkgs.sh" "$PKGS"
fi
[[ -f "$PKGS/vault.mojoc" ]] || { echo "error: PKGS=$PKGS has no vault.mojoc" >&2; exit 1; }

echo "==> staging enclave runtime files (no .mojo source)" >&2
mkdir -p "$H/build"
cp -R "$ROOT/sandbox" "$H/sandbox"
cp -R "$ROOT/scripts" "$H/scripts"
[[ -d "$ROOT/resources" ]] && cp -R "$ROOT/resources" "$H/resources"   # runtime-loaded system prompt
cp "$ROOT/../pixi.toml" "$H/pixi.toml"
[[ -f "$ROOT/config.example.json" ]] && cp "$ROOT/config.example.json" "$H/"

echo "==> building prebuilt enclave binary" >&2
# The SAME invocation the on-device installer used (Bootstrapper.installEnclaveEngine):
# flare/json/jinja2/logging SOURCE + the vault pkgs (in-process tag reads).
"$MOJO" build "$ROOT/src/enclave.mojo" \
    -I "$FLARE" -I "$JSON" -I "$JINJA2/src" -I "$LOGGING/src" -I "$PKGS" \
    -o "$H/build/enclave"

# Relocate the rpath: drop the CI $CONDA_PREFIX/lib (absent on the user's box), add
# a device-relative @loader_path to the toolchain's mojo/lib. The on-device layout
# is fixed — the binary lands at <support>/bundle/enclave/enclave/build/
# enclave and the toolchain at <support>/mojo/lib, so 4 dirs up to <support>
# then mojo/lib. Only the Mojo runtime dylibs resolve here; the flare shims are
# dlopen'd from $CONDA_PREFIX/lib at runtime. Ad-hoc sign (matches package_millfolio).
install_name_tool -delete_rpath "$PREFIX/lib" "$H/build/enclave" 2>/dev/null || true
install_name_tool -add_rpath "@loader_path/../../../../mojo/lib" "$H/build/enclave" 2>/dev/null || true
codesign --force --sign - "$H/build/enclave" 2>/dev/null || true

# Build + bundle the web UI (web/dist) so the enclave server can serve it at
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

# flare/json/jinja2.mojo/logging.mojo are no longer shipped: they were only on
# the include path for the on-device build, which now happens here. The runtime
# per-query codegen builds against the millfolio pkgs/*.mojoc, not this source.

echo "==> zipping -> $OUT" >&2
rm -f "$OUT"
( cd "$STAGE" && zip -qr -X "$OUT" enclave )
echo "==> done — bundle contains ONLY the prebuilt binary + runtime files + FFI shims (no .mojo)" >&2
ls -lh "$OUT" >&2
