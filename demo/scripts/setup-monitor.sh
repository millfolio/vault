#!/usr/bin/env bash
#
# setup-monitor.sh — install the demo health monitor (monitor.py) on the demo host.
#
# Two install modes:
#   (default, SSH-friendly) a per-user CRON entry every 5 min. Also installs the
#     twice-daily access digest (08:00 + 14:00).
#   --gui  a gui LaunchAgent (StartInterval 300), for the account that stays logged
#     in. Must be run from the CONSOLE (Screen Sharing / desktop), NOT plain SSH —
#     same as setup-demo-engine.sh.
#
# Either way the ENGINE is detect-and-alert ONLY — never auto-restarted. A kickstart
# helps neither failure mode: warmup just needs time, and the decode wedge survives a
# process restart (only a reboot clears it), so a wedge escalates to a REBOOT-REQUIRED
# alert. The only auto-heal is the demo APP-SERVER, via the scoped
# `sudo -n launchctl kickstart system/app.millfolio.demo` rule (gate with HEAL_DEMO).
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
REPORT_TAG="# millfolio-demo-access-report"
PY="$(command -v python3)"

[[ -f "$MON" ]] || { echo "error: monitor.py not found at $MON"; exit 1; }

uninstall_cron() { (crontab -l 2>/dev/null | grep -v "$CRON_TAG" | grep -v "$REPORT_TAG") | crontab - 2>/dev/null || true; }
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
  # twice-daily access digest (separate from the health alerts) — only on the host
  # that holds the access log; no-ops quietly unless DISCORD_REPORT_WEBHOOK_URL is set.
  if [[ -f "$DIR/demo-access-report.sh" ]]; then
    (crontab -l 2>/dev/null | grep -v "$REPORT_TAG") | crontab -
    RLINE="0 8,14 * * * /bin/bash $DIR/demo-access-report.sh >/dev/null 2>&1 $REPORT_TAG"
    (crontab -l 2>/dev/null; echo "$RLINE") | crontab -
    echo "==> installed ACCESS DIGEST cron (08:00 + 14:00):"
    echo "    $RLINE"
    echo "    (set DISCORD_REPORT_WEBHOOK_URL in the config to enable it)"
  fi
  echo "    NOTE: the engine is alert-only (a wedge needs a REBOOT, not a restart)."
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
      echo "==> loaded gui LaunchAgent (every 5 min)."
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
