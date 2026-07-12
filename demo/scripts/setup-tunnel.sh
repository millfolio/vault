#!/usr/bin/env bash
#
# setup-tunnel.sh — install the Cloudflare Tunnel as a NATIVE system service via
# `cloudflared service install`, so demo.millfolio.app comes back automatically after
# a reboot with NO ONE logged in.
#
# This is the PREFERRED way to run the tunnel (replaces the app.millfolio.demo-tunnel
# launchd job that setup-bgent.sh used to install). cloudflared manages its own system
# LaunchDaemon at /Library/LaunchDaemons/com.cloudflare.cloudflared.plist — it runs as
# root at boot, restarts on crash, and is the path Cloudflare supports.
#
# Run it with sudo, from the demo account (so ~/.cloudflared resolves to the account
# that holds the tunnel creds), or pass DEMO_USER explicitly:
#
#   sudo bash ~/demo/scripts/setup-tunnel.sh                 # demo account is the sudo invoker
#   sudo DEMO_USER=bgent bash ~/demo/scripts/setup-tunnel.sh # from an admin account
#
# ── one-time Cloudflare setup (interactive, as the demo account, BEFORE this) ────
#   brew install cloudflared
#   cloudflared tunnel login                          # authorize the millfolio.app zone
#   cloudflared tunnel create millfolio-demo          # note the TUNNEL_ID
#   cloudflared tunnel route dns millfolio-demo demo.millfolio.app
#   cp ~/demo/replay/cloudflared-config.example.yml ~/demo/replay/cloudflared-config.yml
#   # edit it: tunnel: <TUNNEL_ID>  +  credentials-file: ~/.cloudflared/<TUNNEL_ID>.json
set -euo pipefail

[[ "$(id -u)" == 0 ]] || { echo "error: run with sudo — cloudflared installs a SYSTEM LaunchDaemon:"; echo "  sudo DEMO_USER=<demo-account> bash $0"; exit 1; }

# Resolve the demo account (holds ~/.cloudflared creds + the config) and its real home.
RUN_USER="${DEMO_USER:-${SUDO_USER:-}}"
[[ -n "$RUN_USER" && "$RUN_USER" != root ]] || { echo "error: set DEMO_USER to the demo account:"; echo "  sudo DEMO_USER=bgent bash $0"; exit 1; }
RUN_HOME="$(dscl . -read "/Users/$RUN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -n "$RUN_HOME" && -d "$RUN_HOME" ]] || { echo "error: can't resolve a home directory for user '$RUN_USER'"; exit 1; }

DEMO="$RUN_HOME/demo"
CONFIG="${CLOUDFLARED_CONFIG:-$DEMO/replay/cloudflared-config.yml}"

command -v cloudflared >/dev/null 2>&1 || { echo "error: cloudflared not installed (brew install cloudflared)"; exit 1; }
if [[ ! -f "$CONFIG" ]]; then
  echo "error: $CONFIG missing. Do the one-time Cloudflare setup first (see the header of this script):"
  echo "    cloudflared tunnel login / create millfolio-demo / route dns demo.millfolio.app"
  echo "    cp $DEMO/replay/cloudflared-config.example.yml $CONFIG   # then fill TUNNEL_ID + credentials-file"
  exit 1
fi
# Guard against the unfilled template slipping through.
grep -q 'TUNNEL_ID_HERE' "$CONFIG" && { echo "error: $CONFIG still has the TUNNEL_ID_HERE placeholder — fill it in"; exit 1; }

# cloudflared service install resolves the config via the standard search path
# (~/.cloudflared/config.yml of the user it runs as — here root → /var/root). Rather
# than rely on that, point at OUR config explicitly with the global --config flag and
# an absolute path (root can read the account's credentials-file regardless).
echo "==> removing any old per-account tunnel launchd job (avoids a double tunnel)"
launchctl bootout "system/app.millfolio.demo-tunnel" 2>/dev/null || true
rm -f /Library/LaunchDaemons/app.millfolio.demo-tunnel.plist 2>/dev/null || true
UID_NUM="$(id -u "$RUN_USER" 2>/dev/null || true)"
[[ -n "$UID_NUM" ]] && launchctl bootout "gui/$UID_NUM/app.millfolio.demo-tunnel" 2>/dev/null || true
rm -f "$RUN_HOME/Library/LaunchAgents/app.millfolio.demo-tunnel.plist" 2>/dev/null || true

echo "==> cloudflared service install  (config: $CONFIG)"
# Reinstall cleanly so a re-run is idempotent.
cloudflared service uninstall >/dev/null 2>&1 || true
cloudflared --config "$CONFIG" --no-autoupdate service install

echo
echo "==> installed com.cloudflare.cloudflared (system LaunchDaemon, starts at boot)."
echo "    The Mac mini must stay AWAKE or the tunnel drops:  sudo pmset -a sleep 0 disablesleep 1"
echo
echo "    Verify:"
echo "      sudo launchctl print system/com.cloudflare.cloudflared | grep state"
echo "      pgrep -fl cloudflared"
echo "      curl -sI https://demo.millfolio.app | head -1"
echo "    Logs:  /Library/Logs/com.cloudflare.cloudflared.{out,err}.log"
echo "    Stop/restart:"
echo "      sudo launchctl bootout system/com.cloudflare.cloudflared          (stop)"
echo "      sudo launchctl kickstart -k system/com.cloudflare.cloudflared     (restart)"
echo "      sudo cloudflared service uninstall                                (remove)"
