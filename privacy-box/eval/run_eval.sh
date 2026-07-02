#!/usr/bin/env bash
#
# run_eval.sh [MODEL] — pre-release PROMPT evaluation (per-model).
#
# Drives `privacy_box codegen` on a SYNTHETIC manifest (codegen only ever sees the
# aliased manifest, so no index / embedding server is needed) and lints the program
# the frontier model writes against shape rules in golden.<MODEL>.tsv — must /
# must-not contain. This is the STABLE tier: it checks the model picks the right
# TOOLS and program SHAPE (transactions() not search, money() not String(x), no
# .alias), which is far less flaky than scoring the numeric answer. It directly
# guards the "$224,303 phone bill" class.
#
# MODEL-DEPENDENT: codegen quality is a property of the (prompt, MODEL) pair, so the
# golden set is per-model — `golden.<MODEL>.tsv`. Pick the model with $1 or
# $EVAL_MODEL; it defaults to the shipping default (claude-sonnet-5) and is passed
# to codegen via PRIVACY_BOX_MODEL. Re-run the eval after ANY model change and after
# major prompt edits — see CONTRIBUTING.md.
#
# TAGS: codegen is shown the tag registry (readiness-gated). To keep the eval
# deterministic and independent of the developer's real categories, we copy
# eval/fixtures/data → a temp MILLFOLIO_DATA_DIR so the eval's tags are FIXED here,
# never the production tags.
#
# NOT part of `moon :check` / pre-push — codegen is model-nondeterministic and needs
# the frontier key. Run it before cutting a release:  moon run vault:eval
# (the harness itself IS unit-tested, mock-driven, in run_eval_test.sh → :check).
#
# Needs ANTHROPIC_API_KEY (else codegen falls back to the local model, which is not
# what we're evaluating). Override the binary with PRIVACY_BOX_BIN=… (used by
# run_eval_test.sh to drive this script with a mock). EVAL_VERBOSE=1 prints the
# program for each FAIL.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$DIR/../.." && pwd)"                 # vault/
MODEL="${1:-${EVAL_MODEL:-claude-sonnet-5}}"
BIN="${PRIVACY_BOX_BIN:-$ROOT/build/privacy_box}"
# EVAL_GOLDEN overrides the per-model golden path (run_eval_test.sh drives the
# harness with a controlled golden this way).
GOLDEN="${EVAL_GOLDEN:-$DIR/golden.$MODEL.tsv}"
MANIFESTS="$DIR/manifests"

if [ ! -f "$GOLDEN" ]; then
  echo "no golden set for model '$MODEL' ($GOLDEN)." >&2
  echo "  available:" >&2
  for g in "$DIR"/golden.*.tsv; do
    [ -f "$g" ] && echo "    $(basename "$g" .tsv | sed 's/^golden\.//')" >&2
  done
  echo "  create one (copy the closest) when introducing a new model." >&2
  exit 2
fi
if [ ! -x "$BIN" ]; then
  echo "privacy_box not built — run: (cd '$ROOT' && pixi run privacy-box)" >&2
  exit 2
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ] && [ -z "${PRIVACY_BOX_BIN:-}" ]; then
  echo "⚠️  ANTHROPIC_API_KEY is not set — codegen will use the LOCAL model, but this"
  echo "    eval is about the FRONTIER prompt. Set it for a meaningful run." >&2
fi

# The model under evaluation (codegen reads PRIVACY_BOX_MODEL). Skip when a mock
# binary is driving the harness self-test (it ignores the model).
if [ -z "${PRIVACY_BOX_BIN:-}" ]; then
  export PRIVACY_BOX_MODEL="$MODEL"
fi
# Codegen with a zero remote budget falls back to local-only; give it room.
export PRIVACY_BOX_REMOTE_TOKEN_BUDGET="${PRIVACY_BOX_REMOTE_TOKEN_BUDGET:-200000}"

# FIXTURE TAGS: copy the fixture data dir to a temp MILLFOLIO_DATA_DIR so codegen's
# tag context is the fixed set in eval/fixtures/data — never the real categories,
# and the eval never writes to a tracked file. A mock run (self-test) skips this.
CLEANUP_DIR=""
if [ -z "${PRIVACY_BOX_BIN:-}" ] && [ -d "$DIR/fixtures/data" ]; then
  CLEANUP_DIR="$(mktemp -d)"
  cp -R "$DIR/fixtures/data/." "$CLEANUP_DIR/"
  export MILLFOLIO_DATA_DIR="$CLEANUP_DIR"
fi
cleanup() { [ -n "$CLEANUP_DIR" ] && rm -rf "$CLEANUP_DIR"; }
trap cleanup EXIT

# privacy_box's codegen HTTPS call dlopens flare's FFI libs by the RELATIVE path
# `build/<lib>.so`, so it must run with cwd = the vault root, and those libs must be
# in `build/`. Under a plain `pixi run` they land in `.pixi/envs/default/lib` — stage
# them into `build/` so the eval works from `moon run vault:eval` too. (A mock run
# skips this — it needs no TLS.) Harmless if already present.
if [ -z "${PRIVACY_BOX_BIN:-}" ]; then
  cd "$ROOT" || { echo "cannot cd to vault root $ROOT" >&2; exit 2; }
  mkdir -p build
  for lib in libflare_tls libflare_zlib libflare_brotli libflare_fs; do
    if [ ! -f "build/$lib.so" ] && [ -f ".pixi/envs/default/lib/$lib.so" ]; then
      cp -f ".pixi/envs/default/lib/$lib.so" "build/$lib.so" 2>/dev/null || true
    fi
  done
fi

echo "eval model: $MODEL   golden: $(basename "$GOLDEN")"
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
echo "prompt eval ($MODEL): $pass passed, $fail failed"
[ "$fail" = 0 ]
