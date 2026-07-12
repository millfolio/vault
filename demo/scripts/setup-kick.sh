#!/usr/bin/env bash
#
# setup-kick.sh — let the NON-admin demo account restart the millfolio demo daemon
# WITHOUT a sudo password, so `deploy.sh`'s `sudo -n launchctl kickstart` (and a
# manual kick) work over SSH. Run ONCE from an ADMIN account (it needs root).
#
# Two mechanisms — pick one:
#   (default)  a scoped sudoers NOPASSWD rule — RECOMMENDED. Grants ONLY the exact
#              kickstart command, is auditable in /etc/sudoers.d, reversible (rm the
#              file), and makes deploy.sh auto-restart with NO other change.
#   --setuid   a tiny setuid-root helper binary (<demo-home>/demo/bin/kick) — the
#              "+s binary" approach. Works, but a setuid-root binary is a heavier,
#              higher-risk artifact (any flaw = root-for-anyone). Prefer sudoers.
#
#   sudo DEMO_USER=bgent bash ~/demo/scripts/setup-kick.sh
#   sudo DEMO_USER=bgent bash ~/demo/scripts/setup-kick.sh --setuid
set -euo pipefail

[[ "$(id -u)" == 0 ]] || { echo "error: run with sudo from an admin account:"; echo "  sudo DEMO_USER=<demo-account> bash $0 [--setuid]"; exit 1; }
RUN_USER="${DEMO_USER:-${SUDO_USER:-}}"
[[ -n "$RUN_USER" && "$RUN_USER" != root ]] || { echo "error: set DEMO_USER to the demo account:"; echo "  sudo DEMO_USER=bgent bash $0"; exit 1; }
RUN_HOME="$(dscl . -read "/Users/$RUN_USER" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[[ -n "$RUN_HOME" && -d "$RUN_HOME" ]] || { echo "error: can't resolve a home directory for user '$RUN_USER'"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"

if [[ "${1:-}" == "--setuid" ]]; then
  SRC="$HERE/../src/kick.c"
  [[ -f "$SRC" ]] || { echo "error: $SRC missing"; exit 1; }
  BIN="$RUN_HOME/demo/bin/kick"
  install -d -o "$RUN_USER" -g staff "$RUN_HOME/demo/bin"
  echo "==> compiling setuid helper → $BIN"
  cc -O2 -Wall -o "$BIN" "$SRC"
  chown root:wheel "$BIN"      # must be root-owned for setuid-root
  chmod 4755 "$BIN"            # the +s (setuid) bit
  codesign --force -s - "$BIN" 2>/dev/null || true   # Apple Silicon: re-sign after chmod
  echo "==> done. As $RUN_USER, restart the demo with:"
  echo "      $BIN"
  echo "    (deploy.sh still uses sudo for its restart step — for auto-restart on"
  echo "     deploy, install the sudoers rule instead: re-run WITHOUT --setuid.)"
else
  SUDOERS=/etc/sudoers.d/millfolio-demo
  tmp="$(mktemp)"
  cat > "$tmp" <<EOF
# millfolio demo — $RUN_USER may restart ONLY the demo daemon, no password.
# Installed by demo/scripts/setup-kick.sh. Remove with: sudo rm $SUDOERS
Cmnd_Alias MILLFOLIO_DEMO_KICK = /bin/launchctl kickstart -k system/app.millfolio.demo, \\
                                 /bin/launchctl kickstart system/app.millfolio.demo
$RUN_USER ALL=(root) NOPASSWD: MILLFOLIO_DEMO_KICK
EOF
  # Validate BEFORE installing — a malformed sudoers file can lock out sudo entirely.
  visudo -cf "$tmp" >/dev/null || { echo "error: sudoers validation failed (not installed)"; rm -f "$tmp"; exit 1; }
  install -m 0440 -o root -g wheel "$tmp" "$SUDOERS"
  rm -f "$tmp"
  echo "==> installed $SUDOERS"
  echo "    $RUN_USER can now restart the daemon with no password:"
  echo "      sudo -n launchctl kickstart -k system/app.millfolio.demo"
  echo "    deploy.sh's restart step will now auto-kick the daemon over SSH."
fi
