#!/usr/bin/env bash
#
# Package the millfolio app server — millfolio-app.zip. The app server binary is
# now shipped PREBUILT (built here in CI, not `mojo build`d on-device — mirrors
# vault/core/scripts/package_millfolio.sh). The bundle unzips to:
#
#   build/millfolio-server   the prebuilt app server (UI + REST + chat WS on one port)
#   web/dist/                the built SvelteKit UI (served by millfolio-server)
#
# so the CLI runs build/millfolio-server directly — no on-device source build, no
# `.mojo` source shipped for the app server.
#
# The binary is built here with the SAME `mojo build` invocation the installer
# used (Bootstrapper.installAppServer): its own src + the privacy_box orchestrator
# source + the vendored flare/json/jinja2/logging siblings + the vault pkgs/*.mojoc
# (in-process `from vault.derive.store import …`). Its rpath is relocated to a
# device-relative @loader_path (the CI machine's $CONDA_PREFIX/lib is absent on the
# user's box) and it is ad-hoc signed. The app server runs WITH CONDA_PREFIX set
# and dlopens flare shims from $CONDA_PREFIX/lib, so the shims need no rpath; only
# the Mojo runtime dylibs (linked via @rpath) resolve from the toolchain's mojo/lib.
#
# The build needs a Mojo toolchain (run via pixi) and the vault pkgs/*.mojoc —
# pass PKGS=<dir>, else it precompiles a throwaway set.
#   scripts/package-app.sh [out.zip]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"                 # app/
UMBRELLA="${UMBRELLA:-$(cd "$ROOT/.." && pwd)}"               # the vault repo root (monorepo)
PRIVACY_BOX="${PRIVACY_BOX:-$UMBRELLA/privacy-box}"
FLARE="${FLARE:-$UMBRELLA/../flare}"
JSON="${JSON:-$UMBRELLA/../json}"
JINJA2="${JINJA2:-$UMBRELLA/../jinja2.mojo}"
LOGGING="${LOGGING:-$UMBRELLA/../logging.mojo}"
OUT="${1:-$ROOT/millfolio-app.zip}"
case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac       # zip runs from a temp dir — need absolute
MOJO="${MOJO:-mojo}"

[ -d "$ROOT/web/build" ] || { echo "missing $ROOT/web/build — run 'npm run build' in web/ first" >&2; exit 1; }

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/build" "$STAGE/web/dist"

# The precompiled vault package set (vault.mojoc etc.) — needed on the build's
# include path (server.mojo: `from vault.derive.store import …`). Reuse a
# caller-built set (package_bundle passes PKGS) or precompile a throwaway one.
PKGS="${PKGS:-}"
if [[ -z "$PKGS" ]]; then
    echo "==> PKGS unset — precompiling the vault package set" >&2
    PKGS="$STAGE/pkgs"
    MOJO="$MOJO" bash "$UMBRELLA/core/scripts/precompile_pkgs.sh" "$PKGS"
fi
[[ -f "$PKGS/vault.mojoc" ]] || { echo "error: PKGS=$PKGS has no vault.mojoc" >&2; exit 1; }

echo "==> building prebuilt millfolio-server" >&2
# The SAME include set the on-device installer used. `-I src` = the app's own
# modules (events.mojo, runqueue.mojo, store.mojo, imported by server.mojo).
"$MOJO" build "$ROOT/server/src/server.mojo" \
    -I "$ROOT/server/src" \
    -I "$PRIVACY_BOX/src" \
    -I "$FLARE" -I "$JSON" -I "$JINJA2/src" -I "$LOGGING/src" \
    -I "$PKGS" \
    -o "$STAGE/build/millfolio-server"

# Relocate the rpath: drop the CI $CONDA_PREFIX/lib (absent on the user's box), add
# a device-relative @loader_path to the toolchain's mojo/lib. The on-device layout
# is fixed — the binary lands at <support>/bundle/app/build/millfolio-server and
# the toolchain at <support>/mojo/lib, so 3 dirs up to <support> then mojo/lib
# (one level shallower than privacy_box/millfolio — the app tree isn't double-
# nested). Only the Mojo runtime dylibs resolve here; the flare shims are dlopen'd
# from $CONDA_PREFIX/lib at runtime. Ad-hoc sign (matches package_millfolio).
PREFIX="${CONDA_PREFIX:-}"
[[ -n "$PREFIX" ]] && install_name_tool -delete_rpath "$PREFIX/lib" "$STAGE/build/millfolio-server" 2>/dev/null || true
install_name_tool -add_rpath "@loader_path/../../../mojo/lib" "$STAGE/build/millfolio-server" 2>/dev/null || true
codesign --force --sign - "$STAGE/build/millfolio-server" 2>/dev/null || true

cp -R "$ROOT/web/build/." "$STAGE/web/dist/"

( cd "$STAGE" && zip -qr -X "$OUT" build web )
echo "wrote $OUT ($(du -h "$OUT" | cut -f1))" >&2
