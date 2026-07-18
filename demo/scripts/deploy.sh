#!/usr/bin/env bash
#
# deploy.sh — push the millfolio demo to the `bgent` account over SSH and (re)start it.
# Run from your DEV Mac. Idempotent — run it for every update.
#
# By DEFAULT it syncs only the demo + synthetic vault (a few MB). The millfolio
# RUNTIME (Mojo toolchain + bundle, ~670MB) is expected to be installed on bgent via
# `brew install millfolio/tap/mill && mill install` — far more robust than rsyncing
# it from your dev Mac. (That needs a release with the new code — cut v0.4.26 first.)
#
# For the PRE-RELEASE dev build, pass SYNC_RUNTIME=1 to also push the local
# bundle+toolchain. It's heavy: it drops -z (binaries don't compress) and uses
# --partial, but free memory on the dev Mac first (e.g. `mill stop`) or it can OOM.
#
#   BGENT=bgent@bgent  bash scripts/deploy.sh                 # demo + data only
#   BGENT=bgent@bgent  SYNC_RUNTIME=1  bash scripts/deploy.sh # also push the dev runtime
#
# TIP: set up key auth ONCE to stop the password prompts:  ssh-copy-id "$BGENT"
set -euo pipefail

BGENT="${BGENT:?set BGENT=<user>@<host>, e.g. bgent@bgent}"
DEMO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VAULT_DIR="${DEMO_VAULT_DIR:-$DEMO_DIR/../demo-vault}"
SUPPORT="$HOME/Library/Application Support/Millfolio"
R_SUPPORT="Library/Application Support/Millfolio"     # relative to bgent's HOME

[[ -d "$VAULT_DIR/vault"  ]] || { echo "error: demo-vault at $VAULT_DIR (set DEMO_VAULT_DIR)"; exit 1; }
[[ -d "$VAULT_DIR/index"  ]] || { echo "error: $VAULT_DIR/index missing — pre-build it (fixtures/README.md)"; exit 1; }

# One shared SSH connection for every call below → a single auth prompt, faster.
CM="$HOME/.ssh/cm-millfolio-demo-%C"
SSH=(ssh -o ControlMaster=auto -o ControlPath="$CM" -o ControlPersist=180)
RSH="ssh -o ControlMaster=auto -o ControlPath=$CM -o ControlPersist=180"
# Prefer a modern rsync (3.x) on the SENDER if installed: macOS's bundled openrsync
# (2.6.9) is memory-hungry on large trees and gets SIGKILL'd (Killed: 9) on the
# ~670MB runtime sync; Homebrew's rsync streams an incremental file list (flat memory).
# NOTE: we deliberately do NOT use -s/--secluded-args — it must be supported on BOTH
# ends, and bgent's receiver is openrsync ("rsync: invalid option -- s"). The remote
# path's space is handled by syncing through a no-space symlink (see below) instead.
RSYNC_BIN=rsync
for c in /opt/homebrew/bin/rsync /usr/local/bin/rsync; do
  [[ -x "$c" ]] && { RSYNC_BIN="$c"; break; }
done
rsync_to() { "$RSYNC_BIN" -a --partial -e "$RSH" "$@"; }

echo "==> opening SSH connection to $BGENT (one auth)"
"${SSH[@]}" "$BGENT" true

if [[ "${SYNC_RUNTIME:-0}" == 1 ]]; then
  [[ -d "$SUPPORT/bundle" ]] || { echo "error: no bundle at $SUPPORT/bundle"; exit 1; }

  # Refresh the bundle from the dev BUILD outputs before syncing. `moon run
  # app-server:build` / `app-web:build` write to app/{server,web}/build — NOT into
  # the installed bundle the sync copies — so without this step the deploy ships a
  # STALE binary/web ("I don't see the new version"). Stage the two artifacts the
  # demo server actually uses ($BUNDLE/app/build/millfolio-server + app/web/dist).
  APP_DIR="${MILLFOLIO_APP_DIR:-$DEMO_DIR/../app}"
  SRV_SRC="$APP_DIR/server/build/millfolio-server"
  WEB_SRC="$APP_DIR/web/build"
  if [[ -x "$SRV_SRC" ]]; then
    echo "==> stage fresh app server → bundle ($(basename "$SRV_SRC"), $(date -r "$SRV_SRC" +%H:%M))"
    cp "$SRV_SRC" "$SUPPORT/bundle/app/build/millfolio-server"
  else
    echo "warning: no fresh server build at $SRV_SRC — bundle keeps its current binary (build it: moon run app-server:build)"
  fi
  if [[ -f "$WEB_SRC/index.html" ]]; then
    echo "==> stage fresh web UI → bundle (app/web/dist)"
    "$RSYNC_BIN" -a --delete "$WEB_SRC/" "$SUPPORT/bundle/app/web/dist/"
  else
    echo "warning: no fresh web build at $WEB_SRC — bundle keeps its current web (build it: moon run app-web:build)"
  fi

  [[ "$RSYNC_BIN" == "rsync" ]] && echo "warning: using macOS openrsync — the ~670MB sync may be SIGKILL'd; 'brew install rsync' is far more reliable"
  echo "==> runtime (bundle + toolchain, ~670MB, -z off, via $RSYNC_BIN) → $BGENT  (free RAM first: mill stop)"
  # The real dest ("…/Application Support/Millfolio") has a space, which no rsync
  # flavor protects portably (-s needs a 3.x receiver; a backslash is taken literally
  # by a 3.x sender). Sync through a no-space symlink — robust on any rsync, any end.
  "${SSH[@]}" "$BGENT" 'mkdir -p "$HOME/Library/Application Support/Millfolio" && ln -sfn "$HOME/Library/Application Support/Millfolio" "$HOME/.millfolio-support"'
  # KEEP_STALE_BUNDLE=1 drops --delete on the bundle sync so a still-running OLD demo
  # process keeps the binaries it spawns per query (e.g. the sandbox) on disk while the
  # NEW layout lands alongside it — used for a prime-then-cutover deploy where the live
  # demo must keep serving until the kickstart. A later normal deploy (--delete) prunes
  # the stale files. Without it, --delete can unlink a binary the old process re-spawns.
  BUNDLE_DELETE=(--delete); [[ "${KEEP_STALE_BUNDLE:-0}" == 1 ]] && BUNDLE_DELETE=()
  # bash-3.2-safe expansion for a possibly-EMPTY array under `set -u`.
  rsync_to ${BUNDLE_DELETE[@]+"${BUNDLE_DELETE[@]}"} "$SUPPORT/bundle/" "$BGENT:.millfolio-support/bundle/"
  # Exclude the Mojo compile cache from the --delete: it lives UNDER the toolchain
  # (share/max/cache/.mojo_cache) and is bgent-specific + warmed there. Wiping it made
  # every post-deploy compile a cold ~32s instead of the warm ~4s (the dependency
  # closure — vault + flare + lancedb + … — has to re-elaborate). Keep it across deploys.
  rsync_to --delete --exclude 'share/max/cache/' "$SUPPORT/mojo/"   "$BGENT:.millfolio-support/mojo/"

  # Relocate the Mojo toolchain config. modular.cfg hard-codes the DEV user's home in
  # every path (package_root, import_path, compilerrt_path, …). import_path is where
  # the compiler finds std.mojoc, so on bgent it can't locate 'std' ("unable to locate
  # module 'std'") when the sandbox compiles a generated program. Only the home prefix
  # differs from bgent's, so rewrite /Users/<dev>/…/Millfolio → \$HOME/…/Millfolio.
  echo "==> relocate Mojo toolchain config (modular.cfg) for bgent's home"
  "${SSH[@]}" "$BGENT" 'bash -s' <<REMOTE
set -euo pipefail
CFG="\$HOME/$R_SUPPORT/mojo/share/max/modular.cfg"
if [[ -f "\$CFG" ]]; then
  sed -i '' -E "s#/Users/[^/]+/Library/Application Support/Millfolio#\$HOME/Library/Application Support/Millfolio#g" "\$CFG"
  foreign="\$(grep '/Users/' "\$CFG" | grep -vc "\$HOME" || true)"
  echo "  rewrote toolchain paths → \$HOME (remaining foreign-home refs: \$foreign)"
else
  echo "  (skip — \$CFG not found)"
fi
REMOTE

  # Relocate the prebuilt app server. `mill install` builds millfolio-server
  # on-device, but here we rsync the binary built on the DEV Mac — and its Mojo
  # runtime rpath is the dev user's absolute path (…/<dev-home>/…/Millfolio/mojo/lib),
  # which bgent can't read (errno=13) → "Library not loaded: @rpath/…". Add a
  # user-agnostic @loader_path rpath (…/bundle/app/build → …/Millfolio/mojo/lib)
  # and ad-hoc re-sign (required on Apple Silicon after install_name_tool).
  echo "==> relocate app server rpath for bgent's home"
  "${SSH[@]}" "$BGENT" 'bash -s' <<REMOTE
set -euo pipefail
BIN="\$HOME/$R_SUPPORT/bundle/app/build/millfolio-server"
RPATH="@loader_path/../../../mojo/lib"
if [[ ! -x "\$BIN" ]]; then
  echo "  (skip — \$BIN not found)"
elif otool -l "\$BIN" | grep -q "path \$RPATH "; then
  echo "  (already relocated)"
else
  # The binary's runtime rpath is the DEV machine's absolute path (pixi env, or an
  # …/Application Support/… install prefix) — useless on bgent. REPLACE it in place
  # rather than -add_rpath: the binary has no header padding to grow load commands
  # ("larger updated load commands do not fit"), but the relative @loader_path target
  # is shorter than the absolute one, so an -rpath swap fits with no relinking.
  OLD="\$(otool -l "\$BIN" | awk '/LC_RPATH/{f=1} f&&/ path /{print \$2; f=0}' | grep -E '/lib\$' | head -1)"
  if [[ -n "\$OLD" ]]; then
    install_name_tool -rpath "\$OLD" "\$RPATH" "\$BIN"
  else
    install_name_tool -add_rpath "\$RPATH" "\$BIN"
  fi
  codesign --force -s - "\$BIN"
  echo "  relocated (\${OLD:-<added>} → \$RPATH) + re-signed"
fi
REMOTE
fi

echo "==> demo + synthetic vault (incl. its pre-built index) → $BGENT"
# IMPORTANT: exclude the LIVE cloudflared tunnel config from --delete. It lives at
# ~/demo/replay/cloudflared-config.yml on bgent (holds the real TUNNEL_ID + creds, so
# it's gitignored — only the .example is in the repo). Without this exclude, --delete
# WIPES it every deploy; the running tunnel survives on its in-memory copy but a reboot
# would then drop the demo with no config to load.
rsync_to --delete --exclude '.git' --exclude 'replay/cloudflared-config.yml' --exclude 'replay/cache' "$DEMO_DIR/"  "$BGENT:demo/"
rsync_to --delete --exclude '.git' "$VAULT_DIR/" "$BGENT:demo-vault/"

# Stamp the deployed build version into the demo dir (after the rsync, which --deletes)
# so run-demo.sh can label each stats record with the running version — the Stats page
# averages per deployed version. Matches the web's __APP_VERSION__ ("<app SHA> · <date>").
APP_DIR="${MILLFOLIO_APP_DIR:-$DEMO_DIR/../app}"
DEPLOY_VER="$(git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo dev) · $(date +%F)"
echo "==> stamp build version for stats: $DEPLOY_VER"
"${SSH[@]}" "$BGENT" "printf '%s' '$DEPLOY_VER' > \"\$HOME/demo/.deploy-version\""

echo "==> stage the synthetic index into ~/.config/millfolio (point source_dir at bgent's vault)"
"${SSH[@]}" "$BGENT" 'bash -s' <<'REMOTE'
set -euo pipefail
mkdir -p "$HOME/.config/millfolio"
cp -R "$HOME/demo-vault/index/." "$HOME/.config/millfolio/"
m="$HOME/.config/millfolio/manifest.tsv"
awk -F'\t' -v OFS='\t' -v v="$HOME/demo-vault/vault" 'NR==1 && $1=="#meta"{$4=v} {print}' "$m" >"$m.tmp" && mv "$m.tmp" "$m"
echo "  staged: $(wc -l <"$HOME/.config/millfolio/transactions.tsv") verified transactions"
REMOTE

if [[ "${NO_RESTART:-0}" == 1 ]]; then
  echo "==> NO_RESTART=1 — synced but NOT restarting (the live demo keeps serving its"
  echo "    in-memory build). Re-prime the cache, then cut over with:"
  echo "    ssh $BGENT sudo -n launchctl kickstart -k system/app.millfolio.demo"
else
echo "==> restart demo services"
# Try both launchd domains: gui/<uid> (LaunchAgent mode) and system (LaunchDaemon
# mode, headless — needs passwordless sudo, hence sudo -n). Whichever is installed wins.
"${SSH[@]}" "$BGENT" '
  if launchctl kickstart -k "gui/$(id -u)/app.millfolio.demo" 2>/dev/null; then
    echo "  demo restarted (agent)"
  elif sudo -n launchctl kickstart -k "system/app.millfolio.demo" 2>/dev/null; then
    echo "  demo restarted (daemon)"
  else
    echo "  (not restarted — no loaded launchd job, or sudo needs a password."
    echo "   set up: bash ~/demo/scripts/setup-bgent.sh [--daemon]; or for a daemon"
    echo "   run on bgent: sudo launchctl kickstart -k system/app.millfolio.demo)"
  fi'
fi

# Close the shared connection.
"${SSH[@]}" -O exit "$BGENT" 2>/dev/null || true
echo "==> done → https://demo.millfolio.app"
