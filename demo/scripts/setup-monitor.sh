#!/usr/bin/env bash
#
# setup-monitor.sh — install the demo health monitor (monitor.py) on the demo host.
#
# Two install modes:
#   (default, SSH-friendly) a per-user CRON entry every 5 min. Checks + alerts +
#     auto-heals the demo APP-SERVER (the scoped `sudo -n launchctl kickstart
#     system/app.millfolio.demo` works from cron). It CANNOT kickstart the engine
#     (a gui-domain agent) — an engine wedge is detected + alerted, not auto-healed.
#   --gui  a gui LaunchAgent (StartInterval 300). Must be run from the bgent CONSOLE
#     (Screen Sharing / desktop), NOT plain SSH — same as setup-demo-engine.sh. This
#     one CAN also kickstart the engine agent, so engine wedges auto-heal too.
#
# Idempotent. Writes the config template to ~/.config/millfolio/demo-monitor.env if
# absent (fill in the Discord webhook there). Runs one probe at the end.
#
#   bash scripts/setup-monitor.sh          # cron (over SSH) — demo-daemon heal only
#   bash scripts/setup-monitor.sh --gui    # gui agent (from console) — full heal
#   bash scripts/setup-monitor.sh --uninstall
set -euo pipefail

MODE="cron"
[[ "${1:-}" == "--gui" ]] && MODE="gui"
[[ "${1:-}" == "--uninstall" ]] && MODE="uninstall"

DIR="$(cd "$(dirname "$0")" && pwd)"
MON="$DIR/monitor.py"
CFG_DIR="$HOME/.config/millfolio"
ENV_FILE="$CFG_DIR/demo-monitor.env"
LABEL="app.millfolio.demo-monitor"
LA="$HOME/Library/LaunchAgents"
PLIST="$LA/$LABEL.plist"
CRON_TAG="# millfolio-demo-monitor"
PY="$(command -v python3)"

[[ -f "$MON" ]] || { echo "error: monitor.py not found at $MON"; exit 1; }

uninstall_cron() { (crontab -l 2>/dev/null | grep -v "$CRON_TAG") | crontab - 2>/dev/null || true; }
uninstall_gui()  { launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true; rm -f "$PLIST"; }

if [[ "$MODE" == "uninstall" ]]; then
  uninstall_cron; uninstall_gui
  echo "==> uninstalled the demo monitor (cron + gui agent)."
  exit 0
fi

mkdir -p "$CFG_DIR"
if [[ ! -f "$ENV_FILE" ]]; then
  cp "$DIR/demo-monitor.env.example" "$ENV_FILE"
  echo "==> wrote config template → $ENV_FILE"
  echo "    ▸ EDIT it: paste your Discord webhook into DISCORD_WEBHOOK_URL (else log-only)."
else
  echo "==> config exists → $ENV_FILE (left as-is)"
fi

if [[ "$MODE" == "cron" ]]; then
  uninstall_cron
  # every 5 minutes; stdout/stderr already tee'd into the log by monitor.py
  LINE="*/5 * * * * $PY $MON >/dev/null 2>&1 $CRON_TAG"
  (crontab -l 2>/dev/null; echo "$LINE") | crontab -
  echo "==> installed CRON entry (every 5 min):"
  echo "    $LINE"
  echo "    NOTE: engine wedges are ALERTED but not auto-healed in cron mode."
  echo "    For engine auto-heal too, run from the bgent console:  bash $0 --gui"
else
  mkdir -p "$LA"
  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$PY</string><string>$MON</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/millfolio-demo-monitor.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/millfolio-demo-monitor.log</string>
</dict></plist>
PLIST
  echo "==> wrote $PLIST"
  UID_NUM="$(id -u)"
  if launchctl print "gui/$UID_NUM" >/dev/null 2>&1; then
    launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
    if launchctl bootstrap "gui/$UID_NUM" "$PLIST"; then
      echo "==> loaded gui LaunchAgent (every 5 min) — full auto-heal (demo + engine)."
    else
      echo "==> WROTE but could not load (bootstrap failed). Are you on the console?"
    fi
  else
    echo "==> WROTE but not loaded — no GUI session here. Run this from bgent's DESKTOP"
    echo "    (Screen Sharing / console), not plain SSH."
  fi
  # also remove any cron entry so they don't double-run
  uninstall_cron
fi

echo "==> one probe now (dry visibility):"
"$PY" "$MON" || echo "    (probe reported a failure — see above / $CFG_DIR/demo-monitor.log)"
echo "==> done. Log: $CFG_DIR/demo-monitor.log   State: $CFG_DIR/demo-monitor.state.json"
