#!/usr/bin/env bash
# Summarize millfolio DEMO accesses from demo-access.jsonl.
# Each JSON line: {"ts":<epoch>,"ip":<cf-connecting-ip or "-">,"ua":..,"path":..}
#
# Sections (all "real" = requests carrying a Cloudflare client IP, i.e. actual
# visitors, not local curl/internal which log ip "-"; the logger already skips
# high-frequency telemetry polls):
#   1. Per-day: ACCESSES (all logged), REAL, UNIQUE IP.
#   2. OS breakdown (real) — parsed from the user-agent.
#   3. Human vs agent/bot (real) — UA classified as automation vs a browser.
#   4. Top paths (real) — most-requested paths (query strings stripped).
#
# Usage:  ./demo-access-summary.sh [path-to-demo-access.jsonl] [--top N]
set -euo pipefail
LOG="${1:-$HOME/.config/millfolio/demo-access.jsonl}"
[ -f "$LOG" ] || { echo "no demo access log at $LOG" >&2; exit 1; }
TOP="${3:-20}"
python3 - "$LOG" "$TOP" <<'PY'
import sys, json, re, collections, datetime
log = sys.argv[1]
TOP = int(sys.argv[2]) if len(sys.argv) > 2 else 20

BOT = re.compile(r"bot|crawl|spider|slurp|curl|wget|python|go-http|okhttp|java/|"
                 r"libwww|lwp|axios|node-fetch|scrapy|http[-_]?client|headless|"
                 r"phantom|puppeteer|playwright|selenium|agent-browser|"
                 r"facebookexternalhit|slackbot|twitterbot|whatsapp|telegram|"
                 r"discordbot|applebot|petalbot|yandex|ahrefs|semrush|mj12|"
                 r"bytespider|gptbot|claudebot|ccbot|amazonbot|dataforseo|censys|"
                 r"expanse|measurement|monitor|uptime|pingdom|dotbot", re.I)

def os_of(ua):
    u = ua or ""
    if re.search(r"iPhone|iPad|iPod", u): return "iOS"
    if "Android" in u: return "Android"
    if "Windows NT" in u or "Windows" in u: return "Windows"
    if "CrOS" in u: return "ChromeOS"
    if "Mac OS X" in u or "Macintosh" in u: return "macOS"
    if re.search(r"^curl|^Wget|python|Go-http|okhttp|libwww|java/", u, re.I): return "CLI/tool"
    if "Linux" in u: return "Linux"
    if not u: return "(none)"
    return "Other"

def is_agent(ua):
    u = ua or ""
    if not u: return True
    if BOT.search(u): return True
    if "Mozilla" in u and re.search(r"Safari|Chrome|Firefox|Gecko|Edg|OPR", u):
        return False
    return True

day = collections.defaultdict(lambda: {"n":0,"real":0,"ips":set()})
os_req=collections.Counter(); os_ip=collections.defaultdict(set)
kind_req=collections.Counter(); kind_ip=collections.defaultdict(set)
path_req=collections.Counter(); path_ip=collections.defaultdict(set)
total=real_total=0; allips=set()
for line in open(log):
    line=line.strip()
    if not line: continue
    try: r=json.loads(line)
    except: continue
    ts=r.get("ts")
    if not isinstance(ts,(int,float)): continue
    d=datetime.datetime.fromtimestamp(ts).strftime("%Y-%m-%d")
    b=day[d]; b["n"]+=1; total+=1
    ip=r.get("ip","-"); ua=r.get("ua","")
    if ip and ip!="-":
        b["real"]+=1; real_total+=1; b["ips"].add(ip); allips.add(ip)
        o=os_of(ua); os_req[o]+=1; os_ip[o].add(ip)
        k="agent/bot" if is_agent(ua) else "human"; kind_req[k]+=1; kind_ip[k].add(ip)
        p=(r.get("path","") or "/").split("?",1)[0]; path_req[p]+=1; path_ip[p].add(ip)

print(f"{'DATE':<12}{'ACCESSES':>10}{'REAL':>8}{'UNIQUE IP':>11}")
print("-"*41)
for d in sorted(day):
    b=day[d]; print(f"{d:<12}{b['n']:>10}{b['real']:>8}{len(b['ips']):>11}")
print("-"*41)
print(f"{'TOTAL':<12}{total:>10}{real_total:>8}{len(allips):>11}")

print("\nOS breakdown (real visitors)")
print(f"{'OS':<12}{'REQUESTS':>10}{'UNIQUE IP':>11}"); print("-"*33)
for o,_ in os_req.most_common(): print(f"{o:<12}{os_req[o]:>10}{len(os_ip[o]):>11}")

print("\nHuman vs agent (real visitors)")
print(f"{'TYPE':<12}{'REQUESTS':>10}{'UNIQUE IP':>11}"); print("-"*33)
for k in ("human","agent/bot"): print(f"{k:<12}{kind_req[k]:>10}{len(kind_ip[k]):>11}")

print(f"\nTop {TOP} paths (real visitors)")
print(f"{'PATH':<40}{'REQUESTS':>10}{'UNIQUE IP':>11}"); print("-"*61)
for p,_ in path_req.most_common(TOP):
    lbl=(p[:37]+"...") if len(p)>40 else p
    print(f"{lbl:<40}{path_req[p]:>10}{len(path_ip[p]):>11}")
PY
