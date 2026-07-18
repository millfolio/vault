#!/usr/bin/env bash
#
# check_mojo_version.sh — guard against the mojo-nightly drift that broke v0.4.34.
#
# Two places pin the Mojo nightly and they MUST agree:
#   • pixi.toml          — the nightly CI precompiles the bundle's vault.mojoc with.
#   • the `mill` CLI     — Bootstrapper.{mojoVersion,enclaveMojoVersion}, the
#                          toolchain the installer provisions on the user's machine.
# A `.mojoc` is version-locked: a compiler older/newer than the one that built it
# REFUSES to load it ("Mojo precompiled file is incompatible…"), so a drift breaks the
# whole vault tool surface at install time (`from vault import *` → unknown symbols).
#
# `pixi.toml` is the source of truth; this asserts the CLI constants match it. Wired
# into `vault:check` so a drift fails at `moon run :check` / pre-push, never at a
# user's `mill install`. When you bump the nightly, update BOTH and this stays green.
set -euo pipefail
DIR="$(cd "$(dirname "$0")/.." && pwd)"   # vault/
BS="$DIR/cli/Sources/MillfolioCore/Bootstrapper.swift"

pin="$(grep -oE '1\.0\.0b3\.dev[0-9]+' "$DIR/pixi.toml" | head -1)"
[ -n "$pin" ] || { echo "check-mojo-version: no mojo pin found in $DIR/pixi.toml" >&2; exit 1; }

fail=0
for name in mojoVersion enclaveMojoVersion; do
    v="$(grep -oE "${name} = \"1\.0\.0b3\.dev[0-9]+" "$BS" | grep -oE '1\.0\.0b3\.dev[0-9]+' | head -1)"
    if [ "$v" != "$pin" ]; then
        echo "✗ Bootstrapper.$name = '${v:-<missing>}' but pixi.toml pins '$pin'." >&2
        echo "  Update the CLI constant to match — a version-locked vault.mojoc" >&2
        echo "  cannot load under a mismatched compiler (the v0.4.34 install break)." >&2
        fail=1
    fi
done
[ "$fail" = 0 ] && echo "✓ mojo nightly: mill CLI matches the pixi pin ($pin)"
exit "$fail"
