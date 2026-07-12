#!/usr/bin/env bash
#
# setup-bgent.sh — ONE-TIME setup, run ON the bgent account (after the first
# `deploy.sh` has synced ~/demo, ~/demo-vault, and the millfolio runtime). Installs
# the launchd job that runs the demo app persistently (survives reboot, restarts on
# crash):
#
#   app.millfolio.demo  → scripts/run-demo.sh  (replay proxy + the app server, :10010)
#
# The Cloudflare tunnel is NOT a launchd job here — it runs as cloudflared's OWN native
# system daemon (`cloudflared … service install`, see scripts/setup-tunnel.sh), which is
# what serves demo.millfolio.app/.com + demo.millfoil.app/.com. (An older version of this
# script installed an app.millfolio.demo-tunnel agent → scripts/tunnel.sh; that's gone.)
#
# TWO modes:
#   (default) LaunchAgents — load inside bgent's desktop (Aqua) login session. Needs
#             someone logged into bgent (or Automatic Login). Won't run if the
#             account is logged out.
#   --daemon  LaunchDaemons — system jobs that start AT BOOT with NO ONE logged in,
#             running as the bgent user. Use this on a headless Mac mini where you
#             can't/won't enable auto-login. Needs sudo (admin) to install into
#             /Library/LaunchDaemons. The demo is transactions-only, so it needs no
#             GPU/keychain/window-server — it runs fine headless.
#
# Cloudflare is a separate one-time step (interactive) — see the printout at the end.
set -euo pipefail

MODE=agent
[[ "${1:-}" == "--daemon" ]] && MODE=daemon

UID_NUM="$(id -u)"

# ── LaunchDaemon mode: headless, runs at boot without login (needs sudo) ─────────
if [[ "$MODE" == daemon ]]; then
  DEST=/Library/LaunchDaemons
  # A system LaunchDaemon must be installed as root, and it runs the demo as a TARGET
  # account (the one the demo lives in — e.g. bgent — which need NOT be an admin, since
  # WE are root here). Resolve that account from TARGET_USER, else the sudo invoker.
  # Crucially we resolve its REAL home via dscl — under sudo $HOME is the invoker's, not
  # the target's. This is why you run it from your ADMIN account:
  #   sudo TARGET_USER=bgent bash ~/dev/demo/scripts/setup-bgent.sh --daemon
  [[ "$(id -u)" == 0 ]] || { echo "error: --daemon installs a system LaunchDaemon — run it with sudo from an admin account:"; echo "  sudo TARGET_USER=<demo-account> bash $0 --daemon"; exit 1; }
  RUN_USER="${TARGET_USER:-${SUDO_USER:-}}"
  [[ -n "$RUN_USER" && "$RUN_USER" != root ]] || { echo "error: set TARGET_USER to the demo account (it can be a non-admin user):"; echo "  sudo TARGET_USER=bgent bash $0 --daemon"; exit 1; }
  RUN_HOME="$(dscl . -read "/Users/$RUN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  [[ -n "$RUN_HOME" && -d "$RUN_HOME" ]] || { echo "error: can't resolve a home directory for user '$RUN_USER'"; exit 1; }
  DEMO="$RUN_HOME/demo"
  [[ -x "$DEMO/scripts/run-demo.sh" ]] || { echo "error: $DEMO not synced — first run, from your admin account:  BGENT=$RUN_USER@<host> bash ~/dev/demo/scripts/deploy.sh"; exit 1; }
  install -d -o "$RUN_USER" -g staff "$RUN_HOME/Library/Logs"
  echo "==> installing LaunchDaemons into $DEST, running as UserName=$RUN_USER (HOME=$RUN_HOME)"

  write_daemon() {  # <label> <script> <logname>
    local label="$1" script="$2" log="$3"
    local tmp; tmp="$(mktemp)"
    cat > "$tmp" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>UserName</key><string>$RUN_USER</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$DEMO/scripts/$script</string></array>
  <key>EnvironmentVariables</key><dict>
    <key>HOME</key><string>$RUN_HOME</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$RUN_HOME/Library/Logs/$log.log</string>
  <key>StandardErrorPath</key><string>$RUN_HOME/Library/Logs/$log.log</string>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
PLIST
    install -m 0644 -o root -g wheel "$tmp" "$DEST/$label.plist"
    rm -f "$tmp"
    echo "  wrote $DEST/$label.plist"
    launchctl bootout "system/$label" 2>/dev/null || true
    if launchctl bootstrap system "$DEST/$label.plist"; then
      echo "    loaded $label (system domain — no login needed)"
    else
      echo "    error: could not load $label — check $RUN_HOME/Library/Logs/$log.log"
    fi
  }

  write_daemon "app.millfolio.demo"        "run-demo.sh"  "millfolio-demo"
  # The tunnel is installed separately via cloudflared's OWN service installer
  # (scripts/setup-tunnel.sh) — see the printout at the end.

  echo
  echo "==> daemon installed. It starts at boot with no one logged in."
  echo "    The Mac mini must stay AWAKE: System Settings ▸ Energy ▸ 'Prevent automatic"
  echo "    sleeping' (or: sudo pmset -a sleep 0 disablesleep 1) — a sleeping Mac drops"
  echo "    the tunnel. Demo should be serving on http://localhost:10010 now."
  echo "    Manage:  sudo launchctl bootout system/app.millfolio.demo   (stop)"
  echo "             sudo launchctl kickstart -k system/app.millfolio.demo  (restart)"

# ── LaunchAgent mode (default): needs a GUI login session ────────────────────────
else
  DEMO="$HOME/demo"
  [[ -x "$DEMO/scripts/run-demo.sh" ]] || { echo "error: ~/demo not synced yet — run deploy.sh from your dev Mac first"; exit 1; }
  mkdir -p "$HOME/Library/Logs"
  LA="$HOME/Library/LaunchAgents"
  mkdir -p "$LA"
  # A GUI (Aqua) login session is required to LOAD a LaunchAgent. Over SSH there is
  # none, so `launchctl bootstrap gui/<uid>` fails ("Domain does not support specified
  # action"). We always WRITE the plists (that works over SSH); we only try to load
  # them when a GUI session actually exists.
  GUI_SESSION=0
  launchctl print "gui/$UID_NUM" >/dev/null 2>&1 && GUI_SESSION=1

  write_agent() {  # <label> <script> <logname>
    local label="$1" script="$2" log="$3"
    cat > "$LA/$label.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$label</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$DEMO/scripts/$script</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/$log.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/$log.log</string>
  <key>ProcessType</key><string>Interactive</string>
</dict></plist>
PLIST
    echo "  wrote $LA/$label.plist"
    if [[ "$GUI_SESSION" == 1 ]]; then
      launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
      if launchctl bootstrap "gui/$UID_NUM" "$LA/$label.plist" 2>/dev/null; then
        echo "    loaded $label"
      else
        echo "    (could not load now — it will start at the next login)"
      fi
    fi
  }

  write_agent "app.millfolio.demo"        "run-demo.sh"  "millfolio-demo"
  # Tunnel is installed separately via cloudflared's own service installer
  # (scripts/setup-tunnel.sh) — see the printout at the end.

  if [[ "$GUI_SESSION" == 1 ]]; then
    echo; echo "==> agents loaded. The demo should be serving on http://localhost:10010"
  else
    cat <<'NOGUI'

==> Agents WRITTEN but not loaded — you ran this over SSH (no GUI session).
    LaunchAgents only load inside bgent's desktop (Aqua) login session. Since you
    CAN'T enable auto-login on this account, use the headless daemon mode instead:

        sudo bash ~/demo/scripts/setup-bgent.sh --daemon

    That installs LaunchDaemons that start at boot with no one logged in. The other
    options (auto-login, or Screen-Sharing in to load the agents) need a GUI session.

    To TEST right now over SSH without launchd:
        nohup bash ~/demo/scripts/run-demo.sh > ~/Library/Logs/millfolio-demo.log 2>&1 &
        curl -s -o /dev/null -w '%{http_code}\n' http://localhost:10010/
NOGUI
  fi
fi

cat <<'NEXT'

ONE-TIME Cloudflare setup (interactive, as the demo account):
  brew install cloudflared
  cloudflared tunnel login                          # authorize the millfolio.app zone
  cloudflared tunnel create millfolio-demo          # note the TUNNEL_ID
  cloudflared tunnel route dns millfolio-demo demo.millfolio.app
  cp ~/demo/replay/cloudflared-config.example.yml ~/demo/replay/cloudflared-config.yml
  # edit it: set tunnel: <TUNNEL_ID> and credentials-file: ~/.cloudflared/<TUNNEL_ID>.json

Then install the tunnel as a system service that survives reboot (no login):
  sudo DEMO_USER=<demo-account> bash ~/demo/scripts/setup-tunnel.sh

From your dev Mac, every update is just:
  BGENT=<user>@<host>  bash scripts/deploy.sh
NEXT
