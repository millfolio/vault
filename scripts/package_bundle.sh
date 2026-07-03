#!/usr/bin/env bash
# Assemble the single millfolio.zip the `mill` installer downloads. Runs the four
# existing component packagers and combines their outputs into one archive whose
# subtrees the Bootstrapper unpacks 1:1 (no install-side changes):
#
#   millfolio.zip
#   ├── runner/        ← engine     (package_engine.sh:      inference-server + flare + jinja2 + TLS libs)
#   ├── privacy_box/   ← vault       (package_privacy_box.sh: privacy_box + web + FFI shims + flare/json/jinja2)
#   ├── millfolio/     ← vault       (package_millfolio.sh:   core + FFI shims + flare/json/lancedb/pdftotext/zlib/csv)
#   └── app/           ← app         (package-app.sh:         ws_server src + built web UI)
#
# Layout: sibling repos under one umbrella dir (engine/, app/, the mojo libs next
# to this vault/ checkout). The component packagers need their prebuilt FFI shims,
# so each runs inside its repo's pixi env (one unified Mojo toolchain now).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VAULT="$(cd "$HERE/.." && pwd)"
UMBRELLA="$(cd "$VAULT/.." && pwd)"
ENGINE="${ENGINE:-$UMBRELLA/engine}"
APP="${APP:-$UMBRELLA/app}"
OUT="${1:-$VAULT/millfolio.zip}"; case "$OUT" in /*) ;; *) OUT="$(pwd)/$OUT" ;; esac

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
ZIPS="$WORK/zips"; STAGE="$WORK/bundle"; mkdir -p "$ZIPS" "$STAGE"

# The component packagers reference the mojo libs by env override (default ../<lib>);
# point them at the umbrella-level checkouts so the consolidated layout resolves.
export FLARE="$UMBRELLA/flare" JSON="$UMBRELLA/json" JINJA2="$UMBRELLA/jinja2.mojo"
export LOGGING="$UMBRELLA/logging.mojo"   # privacy_box + app server: `from logging import log`
export LANCEDB="$UMBRELLA/lancedb.mojo" PDFTOTEXT="$UMBRELLA/pdftotext.mojo"
export ZLIB="$UMBRELLA/zlib.mojo" CSV="$UMBRELLA/csv.mojo" DOCX="$UMBRELLA/docx.mojo"

# The vault package set (vault.mojoc etc.) is now needed by THREE packagers:
# privacy_box + app compile against it (`-I $PKGS`), and millfolio ships it.
# Precompile it ONCE here and share via PKGS so a full bundle build doesn't repeat
# the (slow) precompile three times. Each packager self-builds a throwaway set when
# run standalone (PKGS unset).
echo "==> [0/4] precompiling the vault package set (shared)" >&2
export PKGS="$WORK/pkgs"
( cd "$VAULT" && pixi run bash core/scripts/precompile_pkgs.sh "$PKGS" )
[[ -f "$PKGS/vault.mojoc" ]] || { echo "error: precompile_pkgs produced no vault.mojoc" >&2; exit 1; }

echo "==> [1/4] engine → runner.zip (ships SOURCE — compiled on-device; its GPU/Metal kernels can't build on GPU-less CI)" >&2
( cd "$ENGINE" && pixi run flare-tls && pixi run bash scripts/package_engine.sh "$ZIPS/runner.zip" )

echo "==> [2/4] privacy_box → privacy_box.zip (prebuilt privacy_box)" >&2
( cd "$VAULT" && pixi run ffi && pixi run bash privacy-box/scripts/package_privacy_box.sh "$ZIPS/privacy_box.zip" )

echo "==> [3/4] vault engine → millfolio.zip (prebuilt millfolio, reuses PKGS)" >&2
( cd "$VAULT" && pixi run bash core/scripts/package_millfolio.sh "$ZIPS/millfolio.zip" )

echo "==> [4/4] app server → millfolio-app.zip (prebuilt millfolio-server)" >&2
( cd "$APP/web" && npm ci && npm run build ) >&2
( cd "$APP/server" && pixi run bash "$APP/scripts/package-app.sh" "$ZIPS/millfolio-app.zip" )

echo "==> combining into one bundle" >&2
unzip -q "$ZIPS/runner.zip"        -d "$STAGE/runner"
unzip -q "$ZIPS/privacy_box.zip"   -d "$STAGE/privacy_box"
unzip -q "$ZIPS/millfolio.zip"     -d "$STAGE/millfolio"
unzip -q "$ZIPS/millfolio-app.zip" -d "$STAGE/app"
rm -f "$OUT"
( cd "$STAGE" && zip -qr -X "$OUT" runner privacy_box millfolio app )
echo "==> wrote $OUT ($(du -h "$OUT" | cut -f1))" >&2