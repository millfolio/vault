#!/usr/bin/env bash
#
# run-demo.sh — launch the PUBLIC demo: the replay proxy (replay mode) + the REAL
# millfolio app server, pointed at the synthetic fixture vault and at the proxy
# instead of the Anthropic API. The real code is unmodified — it's pure config:
#
#   ANTHROPIC_BASE_URL=http://127.0.0.1:$DEMO_PORT/v1   → codegen replays from cache
#   ANTHROPIC_API_KEY=demo                              → non-empty so codegen takes
#                                                          the "remote" path (→ proxy)
#   MILLFOLIO_VAULT=<fixtures vault>                    → the synthetic, public-safe data
#
# Curated questions hit the cache → cached program → REAL sandbox execution over the
# synthetic vault → answer. Misses get a friendly fallback (no paid API call, ever).
#
# Runs on macOS (the per-query sandbox is Seatbelt). Intended to run in a dedicated
# demo macOS account on the Mac mini. Generated programs may call the on-device model
# (ask_local()/search()); the demo points those at its OWN inference server on :8001
# (ENCLAVE_LOCAL_URL) so it never touches the production engine on :8000. That
# demo engine must be running (on a GUI/GPU-capable account) — see scripts/README.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEMO_PORT="${DEMO_PORT:-8788}"
# the millfolio/demo-vault repo's vault/ (sibling checkout by default; deploy.sh syncs it to ~/demo-vault)
DEMO_VAULT="${DEMO_VAULT:-$ROOT/../demo-vault/vault}"
# The real, BUILT millfolio runtime — the installed/synced bundle + Mojo toolchain.
SUPPORT="${MILLFOLIO_SUPPORT:-$HOME/Library/Application Support/Millfolio}"
BUNDLE="${MILLFOLIO_BUNDLE:-$SUPPORT/bundle}"
TOOLCHAIN="${MILLFOLIO_TOOLCHAIN:-$SUPPORT/mojo}"
APP_SERVER="${MILLFOLIO_SERVER:-$BUNDLE/app/build/millfolio-server}"

# Toolchain env — the app server shells `mojo build` to compile each generated
# program in the sandbox, so it needs CONDA_PREFIX/MODULAR_HOME/PATH + the codegen
# include dir (ENCLAVE_MILLFOLIO → <…>/pkgs). Normally the launchd agent sets
# these; we launch the server directly, so we set them here.
export CONDA_PREFIX="$TOOLCHAIN"
export MODULAR_HOME="$TOOLCHAIN/share/max"
export PATH="$TOOLCHAIN/bin:$PATH"
export ENCLAVE_MILLFOLIO="${ENCLAVE_MILLFOLIO:-$BUNDLE/millfolio/millfolio}"
# enclave resolves its resources/ (the codegen system prompt) + sandbox/*.sb.template
# by ABSOLUTE path under ENCLAVE_HOME — never cwd. Point it at the bundle's enclave
# dir; without this the app-server would fail to load the real prompt (it no longer falls
# back to a cwd-relative path or a stub).
export ENCLAVE_HOME="${ENCLAVE_HOME:-$BUNDLE/enclave/enclave}"
# flare's TLS (OpenSSL) needs a CA bundle to verify EXTERNAL HTTPS. Codegen goes to the
# local replay proxy over HTTP, so this only bites the Turnstile siteverify call —
# without it OpenSSL can't find a root store ("unable to get local issuer certificate").
# macOS ships the system roots at /etc/ssl/cert.pem; point OpenSSL there unless set.
export SSL_CERT_FILE="${SSL_CERT_FILE:-/etc/ssl/cert.pem}"

export MILLFOLIO_PORT="${MILLFOLIO_PORT:-10010}"   # demo listens here (10000 is the real instance)
# Public demo: run several flare workers so concurrent visitors don't block each other
# at codegen/approval. The sandboxed RUN still serializes (the server's flock run-queue),
# so this is safe — it just keeps the front end responsive under a few simultaneous users.
export MILLFOLIO_WORKERS="${MILLFOLIO_WORKERS:-8}"
export ANTHROPIC_BASE_URL="http://127.0.0.1:${DEMO_PORT}/v1"
export ANTHROPIC_API_KEY="demo"                 # non-empty → codegen uses the (proxied) remote
export ENCLAVE_REMOTE_TOKEN_BUDGET="1000000000"   # never deplete → never fall back to local
# Codegen model for the demo. Pinned to claude-sonnet-4-6: the shipping default
# (claude-sonnet-5) currently writes programs that don't compile / open raw files for
# these questions (the eval flags this), which breaks the replayed answers. The demo is
# a replay of the codegen, so it must be primed with a model that produces WORKING
# programs. Revisit once the sonnet-5 codegen prompt is fixed.
export ENCLAVE_MODEL="${ENCLAVE_MODEL:-claude-sonnet-4-6}"
export MILLFOLIO_VAULT="$DEMO_VAULT"
# Data dir: deploy.sh stages the synthetic index into ~/.config/millfolio, but the
# rc.8 default moved to ~/Library/.../data. Without this, the app-server reads the wrong
# (empty) config_dir AND the run-sandbox only re-allows the new dir, so generated
# programs hit "Failed to open file …/.config/millfolio/…". Pin config_dir to where the
# demo data actually lives so the app-server, the sandbox allow-list, and the programs agree.
export MILLFOLIO_DATA_DIR="${MILLFOLIO_DATA_DIR:-$HOME/.config/millfolio}"
export MILLFOLIO_WEB_DIR="${MILLFOLIO_WEB_DIR:-$BUNDLE/app/web/dist}"
# Local, NON-REPO secrets file (Turnstile keys, etc.) — the analogue of
# ~/.config/enclave/config.json for enclave. The launchd daemon's plist only
# exports HOME/PATH, so put real secrets HERE (never in this repo). It's sourced, so
# use `export KEY=value` lines. Override the path with $MILLFOLIO_DEMO_ENV.
DEMO_ENV_FILE="${MILLFOLIO_DEMO_ENV:-$HOME/.config/millfolio/demo.env}"
# shellcheck disable=SC1090
[[ -f "$DEMO_ENV_FILE" ]] && source "$DEMO_ENV_FILE"
# Cloudflare Turnstile — the demo's human/bot gate (DEMO ONLY; the real product never
# sets these). The intro modal renders the widget for MILLFOLIO_TURNSTILE_SITEKEY and
# gates chat on a server-verified token. Empty = gate OFF (widget hidden, chat open),
# so the demo runs without it until you wire real keys. To ENABLE: create a Turnstile
# widget at dash.cloudflare.com (add the demo hostnames), then put BOTH keys in
# $DEMO_ENV_FILE. Cloudflare test keys for a quick local trial: sitekey
# 1x00000000000000000000AA + secret 1x0000000000000000000000000000000AA (ALWAYS PASS).
export MILLFOLIO_TURNSTILE_SITEKEY="${MILLFOLIO_TURNSTILE_SITEKEY:-}"
export MILLFOLIO_TURNSTILE_SECRET="${MILLFOLIO_TURNSTILE_SECRET:-}"
# Publish the curated questions to the served web root so the UI fetches them
# (/questions.json) instead of hardcoding the list — one source of truth (the primed
# cache). Best-effort; the dropdown falls back to a built-in list if it's absent.
if [[ -f "$ROOT/replay/cache/questions.json" && -d "$MILLFOLIO_WEB_DIR" ]]; then
  cp "$ROOT/replay/cache/questions.json" "$MILLFOLIO_WEB_DIR/questions.json" 2>/dev/null || true
fi
# ask_local()/search() in generated programs hit the on-device inference server. Point
# the demo at its OWN engine (:8001) — production stays on :8000 (hard isolation). The
# demo engine loads the shared weights (/Users/Shared/millfolio/hf) and runs on a
# GUI/GPU-capable account; the bgent app reaches it over loopback.
DEMO_ENGINE_PORT="${DEMO_ENGINE_PORT:-8001}"
export ENCLAVE_LOCAL_URL="${ENCLAVE_LOCAL_URL:-http://127.0.0.1:${DEMO_ENGINE_PORT}/v1}"
# The orchestrator reads ENCLAVE_LOCAL_URL, but the GENERATED program's vault tools
# (ask_local/search) read MILLFOLIO_LOCAL_URL / MILLFOLIO_EMBED_URL (default :8000).
# Point those at the demo engine too, else document questions hit the dead prod :8000
# (ConnectionRefused). The sandboxed program inherits these via the server's env.
export MILLFOLIO_LOCAL_URL="${MILLFOLIO_LOCAL_URL:-http://127.0.0.1:${DEMO_ENGINE_PORT}/v1}"
export MILLFOLIO_EMBED_URL="${MILLFOLIO_EMBED_URL:-http://127.0.0.1:${DEMO_ENGINE_PORT}/v1}"

echo "==> starting replay proxy (REPLAY mode) on :$DEMO_PORT"
DEMO_PORT="$DEMO_PORT" python3 "$ROOT/replay/proxy.py" &
PROXY_PID=$!
trap 'kill $PROXY_PID 2>/dev/null || true' EXIT
sleep 1
curl -fs "http://127.0.0.1:${DEMO_PORT}/health" && echo

# The demo's inference engine must be up — generated programs that call ask_local()/
# search() will hang/fail otherwise. We don't start it here (it needs the GPU + a GUI
# session); just warn loudly if it isn't answering on ENCLAVE_LOCAL_URL.
if curl -fs -o /dev/null --max-time 3 "http://127.0.0.1:${DEMO_ENGINE_PORT}/v1/models" 2>/dev/null; then
  echo "==> demo inference engine: up on :$DEMO_ENGINE_PORT"
else
  echo "warning: demo inference engine NOT reachable on :$DEMO_ENGINE_PORT — ask_local()/search()"
  echo "         questions will fail. Start it (shared weights, GUI/GPU account): MILLFOLIO_PORT=$DEMO_ENGINE_PORT"
  echo "         HF_HOME=/Users/Shared/millfolio/hf <inference-server>"
fi

# The UI's bottom bar + each stats record stamp the on-device model name. Derive it
# from the engine's /v1/models (first non-embedding model) so the label is the model
# actually serving — fall back to the Qwen the demo ships if the engine isn't up yet.
MODEL_ID="$(curl -fs --max-time 3 "http://127.0.0.1:${DEMO_ENGINE_PORT}/v1/models" 2>/dev/null \
  | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    ids = [m.get("id", "") for m in d.get("data", [])]
    print(next((i for i in ids if "embed" not in i.lower()), ""))
except Exception:
    print("")' 2>/dev/null || true)"
MODEL_ID="${MODEL_ID##*/}"   # "Qwen/Qwen2.5-3B-Instruct" → "Qwen2.5-3B-Instruct"
export MILLFOLIO_MODEL_LABEL="${MILLFOLIO_MODEL_LABEL:-${MODEL_ID:-Qwen2.5-3B-Instruct}}"
echo "==> model label (bottom bar / stats): $MILLFOLIO_MODEL_LABEL"

# Stamp each stats record with the deployed build label (matches the UI bottom-bar
# stamp "<sha> · <date>") so the Stats page can average per deployed version.
# deploy.sh writes .deploy-version into the demo dir; fall back to "dev" locally.
export MILLFOLIO_VERSION="${MILLFOLIO_VERSION:-$(cat "$ROOT/.deploy-version" 2>/dev/null || echo dev)}"
echo "==> build version (stats): $MILLFOLIO_VERSION"

# Wire the Vault-page search (/api/search). The app server keeps LanceDB/embeddings
# OUT of process — it shells MILLFOLIO_RUN_SCRIPT, which runs the precompiled vault
# `millfolio` binary's `search` subcommand (reads MILLFOLIO_EMBED_URL → :8001 + the
# index in ~/.config/millfolio). Mirror the CLI's run-millfolio.sh (Bootstrapper.swift).
MILLFOLIO_PKG_DIR="$BUNDLE/millfolio/millfolio"
if [[ -x "$MILLFOLIO_PKG_DIR/build/millfolio" ]]; then
  RUN_SCRIPT="$SUPPORT/run-millfolio.sh"
  cat > "$RUN_SCRIPT" <<EOS
#!/bin/bash
cd '$MILLFOLIO_PKG_DIR'
export CONDA_PREFIX='$TOOLCHAIN'
export MODULAR_HOME='$TOOLCHAIN/share/max'
export PATH='$TOOLCHAIN/bin':"\$PATH"
exec ./build/millfolio "\$@"
EOS
  chmod +x "$RUN_SCRIPT"
  export MILLFOLIO_RUN_SCRIPT="$RUN_SCRIPT"
  echo "==> vault search runner: $RUN_SCRIPT"
else
  echo "warning: vault binary not at $MILLFOLIO_PKG_DIR/build/millfolio — Vault search disabled"
fi

echo "==> app server: $APP_SERVER"
[[ -x "$APP_SERVER" ]] || { echo "error: app server not found/built at $APP_SERVER (set MILLFOLIO_SERVER)"; exit 1; }
echo "==> serving the demo at http://localhost:10010  (vault: $DEMO_VAULT)"

# enclave's sandbox templates resolve relative to cwd; run from its dir.
cd "$BUNDLE/enclave/enclave" 2>/dev/null || true
exec "$APP_SERVER"
