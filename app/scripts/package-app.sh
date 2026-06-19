#!/usr/bin/env bash
#
# Package the Veilens app server for on-device install — veilens-app.zip:
#
#   src/ws_server.mojo   the streaming WS server SOURCE (built on-device against
#   src/server.mojo      the already-installed headgate engine tree, like the
#                        other engines — safe for Mojo's nightly ABI)
#   web/dist/            the built SvelteKit UI (served by veilens-ws)
#
# The CLI unzips this next to the headgate engine, builds veilens-ws with
# headgate's Mojo toolchain (`-I <headgate>/src -I <flare> -I <json>
# -I <jinja2.mojo>/src`), and runs it from here so `./web/dist` resolves.
#
#   scripts/package-app.sh [out.zip]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/veilens-app.zip}"

[ -d "$ROOT/web/build" ] || { echo "missing $ROOT/web/build — run 'npm run build' in web/ first" >&2; exit 1; }

STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE/src" "$STAGE/web/dist"

cp "$ROOT/server/src/ws_server.mojo" "$STAGE/src/"
cp "$ROOT/server/src/server.mojo" "$STAGE/src/"
cp -R "$ROOT/web/build/." "$STAGE/web/dist/"

( cd "$STAGE" && zip -qr -X "$OUT" src web )
echo "wrote $OUT" >&2
