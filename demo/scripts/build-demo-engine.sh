#!/usr/bin/env bash
#
# build-demo-engine.sh — build the inference server from the dev checkout and assemble
# a STANDALONE copy at /Users/Shared/millfolio/engine, so the demo engine runs from a
# frozen install (not the live dev tree you're editing). Relocatable: the Mojo runtime
# + flare-TLS/OpenSSL dylibs are bundled beside the binary with @loader_path rpaths, so
# it needs no pixi env at runtime. Run on the DEV/main account (has the toolchain).
#
#   ENGINE_SRC=/path/to/millfolio/engine  bash scripts/build-demo-engine.sh
set -euo pipefail

# The standalone engine lives in the MAIN account's home (it's the only account that
# runs the engine; bgent reaches it over loopback). No sudo / no shared dir needed —
# only the WEIGHTS are shared (/Users/Shared/millfolio/hf, read-only).
# demo/ lives in the vault monorepo; engine/ is a sibling of the repo →
# ../../../engine from demo/scripts/.
ENGINE_SRC="${ENGINE_SRC:-$(cd "$(dirname "$0")/../../../engine" 2>/dev/null && pwd)}"
DEST="${DEMO_ENGINE_DIR:-$HOME/Library/Application Support/Millfolio/demo-engine}"
[[ -f "$ENGINE_SRC/src/server.mojo" ]] || { echo "error: engine src not at $ENGINE_SRC (set ENGINE_SRC)"; exit 1; }
LIB="$ENGINE_SRC/.pixi/envs/default/lib"

echo "==> building inference server (pixi: flare-tls + server)"
( cd "$ENGINE_SRC" && pixi run flare-tls >/dev/null && \
  pixi run -- mojo build src/server.mojo -I ../jinja2.mojo/src -I ../flare -o build/server ) \
  || { echo "error: build failed"; exit 1; }

echo "==> staging standalone → $DEST"
mkdir -p "$DEST/build"
rm -rf "$DEST/assets" "$DEST/server" "$DEST/build" "$DEST"/*.dylib 2>/dev/null || true
mkdir -p "$DEST/build"
cp "$ENGINE_SRC/build/server" "$DEST/server"
cp -R "$ENGINE_SRC/assets" "$DEST/assets"
# flare-TLS + its OpenSSL are dlopen'd at runtime via the RELATIVE path
# build/libflare_tls.so (cwd = $DEST), so they go in $DEST/build/, not $DEST/.
for d in libflare_tls.so libssl.3.dylib libcrypto.3.dylib; do
  [[ -f "$LIB/$d" ]] && cp "$LIB/$d" "$DEST/build/$d" || echo "  (warn: $d not in pixi lib)"
done
# Bundle the TRANSITIVE @rpath closure (Mojo runtime: libKGEN…, libAsyncRT…,
# libMSupportGlobals, …) by BFS over otool -L until no new deps appear.
echo "==> resolving Mojo runtime dylib closure"
queue=("$DEST/server")
seen=" "
while [[ ${#queue[@]} -gt 0 ]]; do
  f="${queue[0]}"; queue=("${queue[@]:1}")
  for dep in $(otool -L "$f" 2>/dev/null | awk '/@rpath\//{print $1}' | sed 's#@rpath/##'); do
    case "$seen" in *" $dep "*) continue;; esac
    seen="$seen$dep "
    if [[ ! -f "$DEST/$dep" ]]; then
      if [[ -f "$LIB/$dep" ]]; then cp "$LIB/$dep" "$DEST/$dep"; echo "  + $dep"
      else echo "  (warn: $dep not found in $LIB)"; continue; fi
    fi
    queue+=("$DEST/$dep")
  done
done

# Make every binary find its sibling dylibs via @loader_path (replace the dev .pixi
# rpath — shorter, so it fits without relinking — else add it), then ad-hoc re-sign.
relocate() {
  local f="$1"
  local old; old="$(otool -l "$f" 2>/dev/null | awk '/LC_RPATH/{g=1} g&&/ path /{print $2; g=0}' | grep '/.pixi/envs/' | head -1)"
  if [[ -n "$old" ]]; then
    install_name_tool -rpath "$old" "@loader_path" "$f" 2>/dev/null || true
  elif ! otool -l "$f" 2>/dev/null | grep -q '@loader_path'; then
    install_name_tool -add_rpath "@loader_path" "$f" 2>/dev/null || true
  fi
  codesign --force -s - "$f" 2>/dev/null || true
}
echo "==> relocating rpaths → @loader_path + re-signing"
relocate "$DEST/server"
for f in "$DEST"/*.dylib "$DEST/build"/*.dylib "$DEST/build"/*.so; do [[ -e "$f" ]] && relocate "$f"; done

echo "==> done. Standalone engine: $DEST/server"

# Rebuild-and-restart: if the demo-engine LaunchAgent is already loaded, kickstart it
# onto this fresh build (so `build-demo-engine.sh` is the one-stop refresh). First time,
# point the user at the installer.
LABEL="app.millfolio.demo-engine"
if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
  launchctl kickstart -k "gui/$(id -u)/$LABEL" \
    && echo "==> restarted $LABEL on the new build (warming up ~15s; tail ~/Library/Logs/millfolio-demo-engine.log)"
else
  echo "    First time? install the LaunchAgent (GUI account):  bash scripts/setup-demo-engine.sh"
fi
