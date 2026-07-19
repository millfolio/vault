#!/usr/bin/env bash
#
# demo-access-report.sh — post the demo's REAL-ACCESS COUNT to Discord on a schedule
# (installed by setup-monitor.sh as cron entries at 08:00 and 14:00 local).
#
# This is the periodic DIGEST, distinct from monitor.py's health ALERTS:
#   • monitor.py  → "something is broken" (event-driven, only on state change)
#   • this        → "here's the traffic" (twice daily, always posts one line)
#
# "Real" matches demo-access-summary.sh: only requests carrying a Cloudflare client
# IP — i.e. actual visitors, not local curl/internal calls (which log ip "-").
# For the full breakdown (OS, human-vs-agent, top paths) run demo-access-summary.sh.
#
# It reads DISCORD_REPORT_WEBHOOK_URL — deliberately a SEPARATE key from the monitor's
# DISCORD_WEBHOOK_URL. On a two-user demo the alerting monitor lives on one account and
# stays silent on the other (empty DISCORD_WEBHOOK_URL, so alerts aren't duplicated);
# the digest still must post from whichever host owns the access log. Same URL is fine.
#
#   bash scripts/demo-access-report.sh
set -uo pipefail

CFG="${DEMO_MONITOR_ENV:-$HOME/.config/millfolio/demo-monitor.env}"
LOG="${DEMO_ACCESS_LOG:-$HOME/.config/millfolio/demo-access.jsonl}"

URL="$(grep '^DISCORD_REPORT_WEBHOOK_URL=' "$CFG" 2>/dev/null | cut -d= -f2- || true)"
if [ -z "${URL:-}" ]; then
  echo "no DISCORD_REPORT_WEBHOOK_URL in $CFG — nothing posted (set it to enable the digest)"
  exit 0
fi
[ -f "$LOG" ] || { echo "error: no demo access log at $LOG"; exit 1; }

python3 - "$URL" "$LOG" <<'PY'
import sys, json, urllib.request, datetime, collections

url, log = sys.argv[1], sys.argv[2]
today = datetime.date.today()
yesterday = today - datetime.timedelta(days=1)

hits = collections.Counter()
ips = collections.defaultdict(set)
with open(log, errors="replace") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
        except ValueError:
            continue
        ip = str(d.get("ip") or "-")
        if ip == "-":          # not a real visitor (local/internal)
            continue
        try:
            day = datetime.date.fromtimestamp(float(d.get("ts", 0)))
        except (TypeError, ValueError, OSError):
            continue
        hits[day] += 1
        ips[day].add(ip)

content = ("📊 **demo.millfolio.app** — %d real accesses today (%d unique IPs) · yesterday: %d"
           % (hits[today], len(ips[today]), hits[yesterday]))

# A User-Agent is REQUIRED: Discord (behind Cloudflare) 403-blocks urllib's default
# "Python-urllib/x.y" UA — without this the post fails silently.
req = urllib.request.Request(
    url, data=json.dumps({"content": content[:2000]}).encode(),
    headers={"Content-Type": "application/json", "User-Agent": "demo-report/1"})
try:
    urllib.request.urlopen(req, timeout=15).read()
    print("posted: %s" % content)
except Exception as e:
    print("post FAILED: %s" % str(e)[:120])
    sys.exit(1)
PY
