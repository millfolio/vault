#!/usr/bin/env bash
#
# prime-cache.sh — fill replay/cache with the programs the REAL frontier model writes
# for the curated demo questions, over the synthetic fixture vault. Run this ONCE
# (with a real Anthropic key); afterwards run-demo.sh replays forever, no paid calls.
#
# MUST run on the machine that SERVES the demo. The cache key is sha256(system prompt +
# question + aliased manifest), and the manifest comes from the on-device index
# (~/.config/millfolio) — which differs per machine. A cache primed elsewhere won't hit
# here. (So: run this on bgent for the bgent demo.)
#
# COEXISTS with running servers: the throwaway prime/verify stack uses dedicated ports
# (PRIME_PROXY_PORT 18788 / PRIME_APP_PORT 18010), not the live 8788/10010 — no killing.
#
# SELF-FILTERING: QUESTIONS below is a CANDIDATE set. Each is captured, then replayed
# under a bounded timeout; any that falls back, errors, or HANGS is DROPPED — its cache
# entries are deleted and it's excluded from the working list. (The demo has its own
# on-device engine on :8001, so ask_local()/search() programs are fine — they just need
# to answer in time.) Survivors are written to replay/cache/questions.json.
#
# Usage:  DEMO_CAPTURE_KEY=sk-ant-...  bash scripts/prime-cache.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE_DIR="${REPLAY_CACHE_DIR:-$ROOT/replay/cache}"
SCRATCH="${ENCLAVE_SCRATCH:-$HOME/.config/enclave/scratch}/gen.mojo"
QUESTIONS_JSON="$CACHE_DIR/questions.json"
FALLBACK_SENTINEL="This is the millfolio demo over a synthetic vault"
PROXY_PORT="${PRIME_PROXY_PORT:-18788}"
APP_PORT="${PRIME_APP_PORT:-18010}"
CAP_TIMEOUT="${PRIME_CAP_TIMEOUT:-240}"      # capture: real API + cold compile + real on-device run
VERIFY_TIMEOUT="${PRIME_VERIFY_TIMEOUT:-120}" # replay: cached codegen + real inference run (slower)
: "${DEMO_CAPTURE_KEY:?set DEMO_CAPTURE_KEY to a real Anthropic key to prime the cache}"

# CANDIDATE demo questions — survivors become the demo's dropdown set (questions.json).
QUESTIONS=(
  # Transaction analytics — answered from the reconciled index (no model call);
  # these exercise the vault-tool API counters (transactions/manifest).
  "how many transactions do I have"
  "how much did I spend"
  # Location — the index-time .state/.country fields → a geo_map (US-state map).
  "Show me a map of my spending by state"
  # Document Q&A — read a PDF + ask the on-device model; these exercise the
  # MODEL stats (prefill/gen tok/s) over the synthetic insurance + registration docs.
  "when does my car insurance renew"
  "what is my license plate number"
  "what does my insurance cover"
  # Rich output — a table + top-10 line graphs, grouping on the index-time .merchant
  # field over a wall_clock-relative 6-month window (exercises charts + location).
  "Give me a table with the monthly amounts I spent per merchant in the last 6 months for the merchants that had more than 2 transactions. Display line graphs for the top 10 merchants where I spent the most money."
)

# ── stack lifecycle (always on OUR dedicated ports) ──────────────────────────
STACK_PID=
STACK_LOG=
launch_stack() {  # $1: "capture" | "replay"
  STACK_LOG="$(mktemp -t prime-cache.XXXXXX)"
  if [[ "$1" == capture ]]; then
    DEMO_CAPTURE_KEY="$DEMO_CAPTURE_KEY" DEMO_PORT="$PROXY_PORT" MILLFOLIO_PORT="$APP_PORT" \
      bash "$ROOT/scripts/run-demo.sh" >"$STACK_LOG" 2>&1 &
  else
    env -u DEMO_CAPTURE_KEY DEMO_PORT="$PROXY_PORT" MILLFOLIO_PORT="$APP_PORT" \
      bash "$ROOT/scripts/run-demo.sh" >"$STACK_LOG" 2>&1 &
  fi
  STACK_PID=$!
  echo -n "    waiting for :$APP_PORT "
  for _ in $(seq 1 60); do
    if ! kill -0 "$STACK_PID" 2>/dev/null; then echo; echo "error: stack exited early:"; tail -n 25 "$STACK_LOG"; exit 1; fi
    if curl -fs -o /dev/null --max-time 2 "http://127.0.0.1:$APP_PORT/health" 2>/dev/null; then echo " up"; return; fi
    sleep 1; echo -n .
  done
  echo; echo "error: app server never came up — last log:"; tail -n 25 "$STACK_LOG"; exit 1
}
kill_port() {
  local pids; pids="$(lsof -ti "tcp:$1" -sTCP:LISTEN 2>/dev/null || true)"
  [[ -n "$pids" ]] && kill $pids 2>/dev/null || true
}
teardown_stack() {
  [[ -n "$STACK_PID" ]] && kill "$STACK_PID" 2>/dev/null || true
  kill_port "$APP_PORT"; kill_port "$PROXY_PORT"
  pkill -f 'gen.mojo' 2>/dev/null || true   # any run child left hung (e.g. a program that blocks on the engine)
  STACK_PID=
  sleep 1
}
trap teardown_stack EXIT

ask() {  # $1: question  $2: timeout → echoes the /chat reply text
  curl -fs --max-time "$2" -H 'Content-Type: application/json' \
    -d "{\"message\": \"$1\"}" "http://127.0.0.1:$APP_PORT/chat" 2>/dev/null || true
}
cache_listing() { (cd "$CACHE_DIR" 2>/dev/null && ls *.mojo 2>/dev/null | sort) || true; }
drop_entries() {  # $1: question index → delete the cache files it captured
  while IFS= read -r f; do [[ -n "$f" ]] && rm -f "$CACHE_DIR/$f"; done <<< "${QENTRIES[$1]}"
}
finalize_one() {  # $1: STACK_LOG line count BEFORE this question's replay
  # Replace the question's CODEGEN cache entry with the FINAL compiling program
  # (scratch/gen.mojo) so replay returns a program that compiles on the first try —
  # no fix round-trip, one compile instead of two. The orchestrator's FIRST replay
  # call per question is the codegen (manifest isn't a replay call), so the first HIT
  # after the mark is the codegen key. Returns 0 if it finalized.
  local key f
  key="$(tail -n +$(($1 + 1)) "$STACK_LOG" 2>/dev/null | grep -aoE '\[replay\] HIT  [0-9a-f]{12}' | head -1 | awk '{print $3}')"
  [[ -n "$key" ]] || return 1
  f="$(ls "$CACHE_DIR/$key"*.mojo 2>/dev/null | head -1)"
  [[ -f "$f" && -f "$SCRATCH" ]] || return 1
  [[ "$(wc -l <"$SCRATCH" 2>/dev/null || echo 0)" -ge 5 ]] || return 1
  grep -q "from vault import" "$SCRATCH" 2>/dev/null || return 1
  cp "$SCRATCH" "$f"
}

# ── preflight ────────────────────────────────────────────────────────────────
for p in "$PROXY_PORT" "$APP_PORT"; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "error: dedicated prime port :$p is in use. Override, e.g.:"
    echo "  PRIME_PROXY_PORT=18799 PRIME_APP_PORT=18011 DEMO_CAPTURE_KEY=… bash $0"
    exit 1
  fi
done
mkdir -p "$CACHE_DIR"
echo "==> prime/verify on dedicated ports (proxy :$PROXY_PORT, app :$APP_PORT) — live servers untouched"

# ── 1. CAPTURE (record each question's NEW cache entries, to drop later if broken) ──
echo "==> CAPTURE mode"
launch_stack capture
if ! curl -fs --max-time 3 "http://127.0.0.1:$PROXY_PORT/health" 2>/dev/null | grep -q '"mode": "capture"'; then
  echo "error: proxy is NOT in capture mode (see $STACK_LOG)"; exit 1
fi
declare -a QENTRIES   # QENTRIES[i] = newline-separated cache files added by QUESTIONS[i]
for i in "${!QUESTIONS[@]}"; do
  q="${QUESTIONS[$i]}"
  before="$(cache_listing)"
  ask "$q" "$CAP_TIMEOUT" >/dev/null
  after="$(cache_listing)"
  QENTRIES[$i]="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$after") | grep -v '^$' || true)"
  n="$(printf '%s\n' "${QENTRIES[$i]}" | grep -c . || true)"
  echo "    captured: $q  (+$n entries)"
done
teardown_stack

# ── 2. VERIFY (replay, bounded) — keep survivors, DROP the rest ──────────────
echo "==> VERIFY mode (replay; bound ${VERIFY_TIMEOUT}s — fallback/empty/hang ⇒ dropped)"
launch_stack replay
working=()
dropped=()
for i in "${!QUESTIONS[@]}"; do
  q="${QUESTIONS[$i]}"
  # The demo HAS an on-device engine (:8001), so ask_local()/search() are fine. We keep
  # any question that returns a real answer within the (engine-aware) timeout, and drop
  # only those that fall back / error / time out.
  cgmark="$(wc -l < "$STACK_LOG" 2>/dev/null || echo 0)"   # mark the log for finalize_one
  reply="$(ask "$q" "$VERIFY_TIMEOUT")"
  if [[ -n "$reply" && "$reply" != *"$FALLBACK_SENTINEL"* ]]; then
    working+=("$q")
    # FINALIZE: point the codegen entry at the final compiling program (no fix at replay).
    if finalize_one "$cgmark"; then echo "    ✓ keep + finalized:  $q"; else echo "    ✓ keep:  $q"; fi
  else
    dropped+=("$q"); drop_entries "$i"
    echo "    ✗ drop:  $q   (no real answer in ${VERIFY_TIMEOUT}s — removed its cache entries)"
  fi
done
teardown_stack

# ── 3. write the working set the demo may offer ──────────────────────────────
# Note: ${arr[@]+"${arr[@]}"} is the bash-3.2-safe expansion for a possibly-EMPTY
# array under `set -u` (a bare "${arr[@]}" throws "unbound variable" when empty).
printf '%s\n' ${working[@]+"${working[@]}"} \
  | python3 -c 'import json,sys; print(json.dumps([l.rstrip("\n") for l in sys.stdin if l.strip()], indent=2))' \
  > "$QUESTIONS_JSON"

echo
echo "==> kept ${#working[@]}, dropped ${#dropped[@]}. Working set → $QUESTIONS_JSON"
for q in ${working[@]+"${working[@]}"}; do echo "    ✓ $q"; done
for q in ${dropped[@]+"${dropped[@]}"}; do echo "    ✗ $q (dropped)"; done
echo
echo "    Commit it — that IS the demo:"
echo "      git -C $ROOT add replay/cache && git -C $ROOT commit -m 'prime replay cache (auto-filtered)'"
[[ "${#working[@]}" -gt 0 ]] || { echo "ERROR: no questions survived — check $STACK_LOG"; exit 1; }
