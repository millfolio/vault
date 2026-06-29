#!/usr/bin/env bash
#
# check_prompt_examples.sh — every ```mojo block in the codegen system prompt
# (privacy_box-system.md) is a REAL program the frontier model is told to imitate.
# Compile each one against the actual vault package, so a broken example — a wrong
# tool name, or a wrong field like the `.id` vs `.alias` regression that failed "how
# much did I pay for my phone bill" — can never reach a release. Deterministic; wired
# into `vault:check`. No FFI shims needed (the vault FFI is dlopen'd at RUN time, not
# linked at build time), so this just elaborates Mojo source.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"   # vault/
PROMPT="$ROOT/privacy-box/resources/privacy_box-system.md"
MOJO="${MOJO:-mojo}"
# The SAME include set the vault binary builds with (core/src + the sibling libs).
INC=(-I "$ROOT/core/src"
     -I "$ROOT/../flare" -I "$ROOT/../json" -I "$ROOT/../lancedb.mojo/src"
     -I "$ROOT/../pdftotext.mojo/src" -I "$ROOT/../zlib.mojo/src"
     -I "$ROOT/../csv.mojo/src" -I "$ROOT/../docx.mojo/src")

[ -f "$PROMPT" ] || { echo "prompt not found: $PROMPT" >&2; exit 1; }
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Split out each ```mojo … ``` block into its own file.
count="$(python3 - "$PROMPT" "$TMP" <<'PY'
import sys, re, os
text = open(sys.argv[1]).read()
blocks = re.findall(r"```mojo\n(.*?)```", text, re.S)
for i, b in enumerate(blocks, 1):
    open(os.path.join(sys.argv[2], f"ex_{i:02d}.mojo"), "w").write(b)
print(len(blocks))
PY
)"
[ "${count:-0}" -gt 0 ] || { echo "no \`\`\`mojo examples found in $PROMPT" >&2; exit 1; }

echo "==> compiling $count prompt example(s) against the vault package"
fail=0
for f in "$TMP"/ex_*.mojo; do
  if "$MOJO" build "$f" "${INC[@]}" -o /dev/null 2>"$TMP/err.txt"; then
    echo "  ✓ $(basename "$f")"
  else
    echo "  ✗ $(basename "$f") does NOT compile:"
    grep -E "error:" "$TMP/err.txt" | sed 's/^/      /' | head -6
    fail=1
  fi
done

if [ "$fail" = 0 ]; then
  echo "✓ all $count prompt examples compile"
else
  echo "✗ a prompt example failed to compile — fix privacy_box-system.md" >&2
  exit 1
fi
