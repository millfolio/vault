#!/usr/bin/env bash
#
# Package the millfolio app server for on-device install — millfolio-app.zip:
#
#   src/server.mojo      the app server SOURCE — serves the UI + REST + the
#                        streaming chat WS on ONE port, built on-device against the
#                        already-installed privacy_box engine tree (safe for Mojo's ABI)
#   src/events.mojo      WS event serialization (imported by server.mojo)
#   web/dist/            the built SvelteKit UI (served by millfolio-server)
#
# The CLI unzips this next to the privacy_box engine, builds millfolio-server with
# privacy_box's Mojo toolchain (`-I src -I <privacy_box>/src -I <flare> -I <json>
# -I <jinja2.mojo>/src`), and runs it from here so `./web/dist` resolves.
#
#   scripts/package-app.sh [out.zip]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/millfolio-app.zip}"

[ -d "$ROOT/web/build" ] || { echo "missing $ROOT/web/build — run 'npm run build' in web/ first" >&2; exit 1; }

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/src" "$STAGE/web/dist"

cp "$ROOT/server/src/server.mojo" "$STAGE/src/"
cp "$ROOT/server/src/events.mojo" "$STAGE/src/"   # server.mojo imports this (WS events)
cp -R "$ROOT/web/build/." "$STAGE/web/dist/"

( cd "$STAGE" && zip -qr -X "$OUT" src web )
echo "wrote $OUT" >&2
