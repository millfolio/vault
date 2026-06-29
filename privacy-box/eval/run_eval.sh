#!/usr/bin/env bash
#
# run_eval.sh — pre-release PROMPT evaluation.
#
# Drives `privacy_box codegen` on a SYNTHETIC manifest (codegen only ever sees the
# aliased manifest, so no index / embedding server is needed) and lints the program
# the frontier model writes against shape rules in golden.tsv — must / must-not
# contain. This is the STABLE tier: it checks the model picks the right TOOLS and
# program SHAPE (transactions() not search, money() not String(x), no .alias), which
# is far less flaky than scoring the numeric answer. It directly guards the
# "$224,303 phone bill" class.
#
# NOT part of `moon :check` / pre-push — codegen is model-nondeterministic and needs
# the frontier key. Run it before cutting a release:  pixi run eval
#
# Needs ANTHROPIC_API_KEY (else codegen falls back to the local model, which is not
# what we're evaluating). Override the binary with PRIVACY_BOX_BIN=… (used to test
# this script itself with a mock). EVAL_VERBOSE=1 prints the program for each FAIL.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"                 # vault/
BIN="${PRIVACY_BOX_BIN:-$ROOT/privacy-box/build/privacy_box}"
GOLDEN="$DIR/golden.tsv"
MANIFESTS="$DIR/manifests"

if [ ! -x "$BIN" ]; then
  echo "privacy_box not built — run: (cd '$ROOT' && pixi run privacy-box)" >&2
  exit 2
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${PRIVACY_BOX_BIN:-}" ]; then
  echo "⚠️  ANTHROPIC_API_KEY is not set — codegen will use the LOCAL model, but this"
  echo "    eval is about the FRONTIER prompt. Set it for a meaningful run." >&2
fi
# Codegen with a zero remote budget falls back to local-only; give it room.
export PRIVACY_BOX_REMOTE_TOKEN_BUDGET="${PRIVACY_BOX_REMOTE_TOKEN_BUDGET:-200000}"

pass=0
fail=0
while IFS=$'\t' read -r q must mustnot manifest; do
  case "$q" in '' | \#*) continue ;; esac
  prog="$("$BIN" codegen "$q" --manifest "$MANIFESTS/$manifest" 2>/dev/null)"
  ok=1
  reasons=""
  IFS=',' read -ra need <<<"$must"
  for t in "${need[@]}"; do
    [ -z "$t" ] && continue
    if ! printf '%s' "$prog" | grep -qF -- "$t"; then
      ok=0
      reasons="$reasons missing:[$t]"
    fi
  done
  IFS=',' read -ra ban <<<"$mustnot"
  for t in "${ban[@]}"; do
    [ -z "$t" ] && continue
    if printf '%s' "$prog" | grep -qF -- "$t"; then
      ok=0
      reasons="$reasons present:[$t]"
    fi
  done
  if [ "$ok" = 1 ]; then
    echo "PASS  $q"
    pass=$((pass + 1))
  else
    echo "FAIL  $q  --$reasons"
    fail=$((fail + 1))
    if [ "${EVAL_VERBOSE:-0}" = 1 ]; then
      echo "------ generated program ------"
      printf '%s\n' "$prog"
      echo "-------------------------------"
    fi
  fi
done <"$GOLDEN"

echo
echo "prompt eval: $pass passed, $fail failed"
[ "$fail" = 0 ]
