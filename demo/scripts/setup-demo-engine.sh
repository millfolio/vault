#!/usr/bin/env bash
#
# setup-demo-engine.sh — install a LaunchAgent for the DEMO inference server on :8001,
# loading the SHARED weights (/Users/Shared/millfolio/hf). Run this ON THE ADMIN
# account (the one with a GUI login) — Metal/GPU needs a real login session, and the
# production engine stays on :8000 untouched.
#
# A LaunchAgent (not Daemon) is required: it loads inside the admin's Aqua session, so
# the GPU is reachable. KeepAlive restarts it; RunAtLoad starts it at login.
#
#   ENGINE_BIN=/path/to/inference-server  bash scripts/setup-demo-engine.sh
#   (auto-detects the binary + the chat checkpoint under the shared hub if unset)
set -euo pipefail

HF_DIR="${HF_DIR:-/Users/Shared/millfolio/hf}"
PORT="${DEMO_ENGINE_PORT:-8001}"
HUB="$HF_DIR/hub"
LABEL="app.millfolio.demo-engine"
LA="$HOME/Library/LaunchAgents"

[[ -d "$HUB" ]] || { echo "error: shared hub not found at $HUB — move the weights there first:"; echo "  sudo mkdir -p /Users/Shared/millfolio && sudo mv ~/Library/Application\\ Support/Millfolio/hf /Users/Shared/millfolio/hf && sudo chmod -R a+rX /Users/Shared/millfolio"; exit 1; }

# Locate the server binary (override with ENGINE_BIN). Prefer the STANDALONE built by
# build-demo-engine.sh (relocatable, independent of the dev tree).
ENGINE_BIN="${ENGINE_BIN:-}"
if [[ -z "$ENGINE_BIN" ]]; then
  c="$HOME/Library/Application Support/Millfolio/demo-engine/server"
  [[ -x "$c" ]] && ENGINE_BIN="$c"
fi
[[ -n "$ENGINE_BIN" && -x "$ENGINE_BIN" ]] || { echo "error: standalone engine not found — build it first:  bash scripts/build-demo-engine.sh   (or pass ENGINE_BIN=/path/to/server)"; exit 1; }
# The server loads assets/ + dlopen's build/libflare_tls.so RELATIVE to cwd, so the
# LaunchAgent must run with WorkingDirectory = the engine dir.
ENGINE_DIR="$(cd "$(dirname "$ENGINE_BIN")" && pwd)"

# Locate the chat checkpoint snapshot (override with QWEN_SAFETENSORS).
CKPT="${QWEN_SAFETENSORS:-}"
if [[ -z "$CKPT" ]]; then
  CKPT="$(find "$HUB" -type d -path '*Qwen2.5-3B-Instruct*/snapshots/*' -maxdepth 4 2>/dev/null | head -1)"
fi
[[ -n "$CKPT" && -d "$CKPT" ]] || { echo "error: chat checkpoint not found under $HUB — pass QWEN_SAFETENSORS=/path/to/snapshot"; exit 1; }

echo "==> demo engine LaunchAgent"
echo "    binary:     $ENGINE_BIN"
echo "    checkpoint: $CKPT"
echo "    HF_HOME:    $HF_DIR     port: $PORT"

mkdir -p "$LA" "$HOME/Library/Logs"
cat > "$LA/$LABEL.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$ENGINE_BIN</string></array>
  <key>WorkingDirectory</key><string>$ENGINE_DIR</string>
  <key>EnvironmentVariables</key><dict>
    <key>HF_HOME</key><string>$HF_DIR</string>
    <key>QWEN_SAFETENSORS</key><string>$CKPT</string>
    <key>MILLFOLIO_PORT</key><string>$PORT</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/millfolio-demo-engine.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/millfolio-demo-engine.log</string>
</dict></plist>
PLIST
echo "    wrote $LA/$LABEL.plist"

# Load it (needs a GUI session — this is why it runs on the admin account).
UID_NUM="$(id -u)"
if launchctl print "gui/$UID_NUM" >/dev/null 2>&1; then
  launchctl bootout "gui/$UID_NUM/$LABEL" 2>/dev/null || true
  if launchctl bootstrap "gui/$UID_NUM" "$LA/$LABEL.plist"; then
    echo "    loaded — warming up (first load reads the weights, ~tens of s)."
    echo "    check:  curl -s http://127.0.0.1:$PORT/v1/models   |   tail -f ~/Library/Logs/millfolio-demo-engine.log"
  else
    echo "    (could not load now — it will start at next login)"
  fi
else
  echo "    WROTE but not loaded — no GUI session here. Run this from the admin account's"
  echo "    desktop (Screen Sharing / console), not over plain SSH, so Metal can init."
fi

cat <<'NOTE'

==> KEEP THE MINI AWAKE + LOGGED IN. The engine needs Metal, which needs this account's
    GUI session — if the mac sleeps or the account logs out, :8001 drops and ask_local/
    search questions fail. One-time:
        sudo pmset -a sleep 0 disablesleep 1        # never sleep
        # System Settings ▸ Users ▸ Login Options ▸ Automatic login → this account
    To refresh the engine after editing engine code:  bash scripts/build-demo-engine.sh
    (rebuilds the standalone AND restarts this LaunchAgent).
NOTE
