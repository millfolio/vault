#!/usr/bin/env bash
# enclave sandbox spike — prove the code-runner containment boundary on macOS.
#
# Renders sandbox/enclave.sb.template against a throwaway demo layout and runs
# six checks. The generated code's *language* is irrelevant to this boundary
# (Seatbelt enforces at the syscall level), so we use stock tools (/bin/cat,
# touch, curl) as a stand-in for the compiled Mojo binary the real runner wraps.
#
# Exit 0 iff all six pass. See SPIKE.md for the meaning of each check.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd -P)"
TEMPLATE="$HERE/enclave.sb.template"

# ── --compile: prove the COMPILE profile (compile.sb.template) still builds a
# real `from vault import *` program WITHOUT granting write to the toolchain
# prefix (the Issue-#1 hardening). Unlike the stock-tool run-profile checks below,
# this needs the pixi env (CONDA_PREFIX + the mojo toolchain) and the precompiled
# `pkgs/` set, so run it via `pixi run bash sandbox/spike.sh --compile` from the
# vault root. It renders compile.sb.template exactly as src/sandbox.mojo does and
# runs a COLD sandboxed build, asserting: the profile grants NO prefix write, the
# build succeeds, the binary is produced, and the Mojo cache still persists.
if [ "${1:-}" = "--compile" ]; then
  CTMPL="$HERE/compile.sb.template"
  : "${CONDA_PREFIX:?run under pixi: pixi run bash sandbox/spike.sh --compile}"
  PKGS="${PKGS:-$HERE/../../build/pkgs}"
  [ -f "$PKGS/vault.mojoc" ] || { echo "no pkgs at $PKGS (run: pixi run precompile)"; exit 1; }
  CROOT="${TMPDIR:-/tmp}/enclave_compile_spike.$$"
  mkdir -p "$CROOT/scratch"
  CSCRATCH="$(cd "$CROOT/scratch" && pwd -P)"
  cat > "$CSCRATCH/gen.mojo" <<'PROG'
from vault import transactions, money
def main() raises:
    var txns = transactions("all")
    var total = 0.0
    for i in range(len(txns)):
        total += txns[i].amount
    print("count:", len(txns), "total:", money(total))
PROG
  CHOME="$(cd "$HOME" && pwd -P)"
  CTMP="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
  CRUNTIME="$(cd "$CONDA_PREFIX" && pwd -P)"
  CMH="$(cd "${MODULAR_HOME:-$CRUNTIME/share/max}" && pwd -P)"
  CCACHE="$CMH/cache/.mojo_cache"
  CPROFILE="$CROOT/compile.sb"
  sed -e "s#@SCRATCH_DIR@#$CSCRATCH#g" -e "s#@HOME@#$CHOME#g" \
      -e "s#@TMPDIR@#$CTMP#g" -e "s#@RUNTIME_PREFIX@#$CRUNTIME#g" \
      -e "s#@MOJO_CACHE_DIR@#$CCACHE#g" "$CTMPL" > "$CPROFILE"
  cfails=0
  # SECURITY assertion: no write grant for the bare toolchain prefix.
  if grep -Eq "allow file-write\* \(subpath \"$CRUNTIME\"\)" "$CPROFILE"; then
    echo "  [FAIL] compile profile grants write to the toolchain prefix"; cfails=1
  else echo "  [PASS] compile profile does NOT grant prefix write"; fi
  rm -rf "$CCACHE"   # force a COLD build (the stringent case for prefix writes)
  echo "  building (cold, sandboxed) …"
  if sandbox-exec -f "$CPROFILE" "$CONDA_PREFIX/bin/mojo" build \
        "$CSCRATCH/gen.mojo" -I "$PKGS" -o "$CSCRATCH/gen" >"$CROOT/b.out" 2>&1 \
     && [ -x "$CSCRATCH/gen" ]; then
    echo "  [PASS] cold sandboxed build succeeded + binary produced"
  else
    echo "  [FAIL] cold sandboxed build FAILED"; tail -15 "$CROOT/b.out"; cfails=1
  fi
  if [ -n "$(find "$CCACHE" -type f 2>/dev/null | head -1)" ]; then
    echo "  [PASS] Mojo build cache persisted (warm reuse intact)"
  else echo "  [FAIL] build cache empty — @MOJO_CACHE_DIR@ write denied"; cfails=1; fi
  rm -rf "$CROOT"
  if [ "$cfails" -eq 0 ]; then echo "COMPILE SPIKE PASSED"; exit 0
  else echo "COMPILE SPIKE FAILED"; exit 1; fi
fi

ROOT="${TMPDIR:-/tmp}/enclave_spike.$$"

# Demo layout: in-scope private data, out-of-scope secrets, scratch.
mkdir -p "$ROOT/data" "$ROOT/scratch" "$ROOT/private"
echo "PRIVATE-ROW: ssn=123-45-6789" > "$ROOT/data/records.csv"
echo "OUT-OF-SCOPE SECRET" > "$ROOT/private/keys.txt"

# Canonical (symlink-resolved) paths — Seatbelt matches the real path, and on
# macOS /tmp -> /private/tmp, so this resolution is mandatory.
DATA="$(cd "$ROOT/data" && pwd -P)"
SCRATCH="$(cd "$ROOT/scratch" && pwd -P)"
PRIVATE="$(cd "$ROOT/private" && pwd -P)"
HOME_P="$(cd "$HOME" && pwd -P)"

PROFILE="$ROOT/enclave.sb"
# @RUNTIME_PREFIX@ is the language runtime (pixi env); irrelevant to this shell
# spike's stock-tool tests, so point it at a harmless existing path.
RUNTIME_P="${CONDA_PREFIX:-/usr/lib}"
sed -e "s#@DATA_DIR@#$DATA#g" \
    -e "s#@SCRATCH_DIR@#$SCRATCH#g" \
    -e "s#@HOME@#$HOME_P#g" \
    -e "s#@RUNTIME_PREFIX@#$RUNTIME_P#g" \
    "$TEMPLATE" > "$PROFILE"

run() { sandbox-exec -f "$PROFILE" "$@"; }
fails=0
check() { # name  expected(allow|deny)  cmd...
  local name="$1" expect="$2"; shift 2
  if "$@" >/dev/null 2>&1; then got=allow; else got=deny; fi
  if [ "$got" = "$expect" ]; then printf '  [PASS] %s\n' "$name"
  else printf '  [FAIL] %s (expected %s, got %s)\n' "$name" "$expect" "$got"; fails=$((fails+1)); fi
}

echo "enclave sandbox spike  (profile: $PROFILE)"
check "in-scope data read"        allow run /bin/cat       "$DATA/records.csv"
check "out-of-scope read"         deny  run /bin/cat       "$PRIVATE/keys.txt"
check "home read (~/.zshrc)"      deny  run /bin/cat       "$HOME_P/.zshrc"
check "scratch write"             allow run /usr/bin/touch "$SCRATCH/out.txt"
check "out-of-scope write"        deny  run /usr/bin/touch "$DATA/evil.txt"
check "network egress (curl)"     deny  run /usr/bin/curl -s --max-time 5 http://example.com

rm -rf "$ROOT"
if [ "$fails" -eq 0 ]; then echo "ALL CHECKS PASSED"; exit 0
else echo "$fails CHECK(S) FAILED"; exit 1; fi
