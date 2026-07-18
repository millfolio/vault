#!/usr/bin/env bash
#
# finalize-cache.sh — replace each curated question's CODEGEN cache entry with the
# FINAL (fixed, cleanly-compiling) program. The frontier model's first program often
# needs a compile-fix; at replay that means TWO compiles (the broken one that fails +
# the fixed one) plus a fix round-trip. After finalizing, the codegen replay returns a
# program that compiles on the first try → ONE compile, no fix.
#
# Run on the SERVING machine against the LIVE replay stack, when idle (it keys off the
# log's first replay HIT per request, so concurrent traffic would confuse it):
#   bash ~/demo/scripts/finalize-cache.sh
# Then pull replay/cache back to the repo and commit.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CACHE="${REPLAY_CACHE_DIR:-$ROOT/replay/cache}"
LOG="${MILLFOLIO_LOG:-$HOME/Library/Logs/millfolio-demo.log}"
SCRATCH="${ENCLAVE_SCRATCH:-$HOME/.config/enclave/scratch}/gen.mojo"
PORT="${MILLFOLIO_PORT:-10010}"

[[ -f "$LOG" ]] || { echo "error: log not found at $LOG"; exit 1; }
n=0
while IFS= read -r q; do
  mark=$(wc -l < "$LOG")
  curl -fs --max-time 120 -H 'Content-Type: application/json' \
    -d "{\"message\": \"$q\"}" "http://127.0.0.1:$PORT/chat" >/dev/null 2>&1 || true
  # The harness's FIRST replay call per question is the codegen (manifest is not a
  # replay call); fixes come after. So the first HIT key after our request is codegen.
  key="$(tail -n +$((mark+1)) "$LOG" | grep -aoE '\[replay\] HIT  [0-9a-f]{12}' | head -1 | awk '{print $3}')"
  f="$(ls "$CACHE/$key"*.mojo 2>/dev/null | head -1)"
  if [[ -n "$key" && -f "$f" && -f "$SCRATCH" ]] && [[ "$(wc -l <"$SCRATCH")" -ge 5 ]]; then
    if grep -q "from vault import" "$SCRATCH"; then
      cp "$SCRATCH" "$f"; n=$((n+1))
      echo "  finalized: $q → ${f##*/} ($(wc -l <"$f") lines)"
    else
      echo "  skip (scratch not a vault program): $q"
    fi
  else
    echo "  skip (no codegen key / scratch): $q  [key=$key]"
  fi
done < <(python3 -c "import json;[print(x) for x in json.load(open('$CACHE/questions.json'))]")
echo "==> finalized $n codegen entries. Re-ask a question to confirm there's no fix round-trip."
