#!/bin/bash
# test_transfer.sh — hermetic integration test for `mill export` / `mill import`
# (cli/Sources/mill/VaultTransfer.swift). Run via `pixi run test-transfer` (in
# the `test` aggregate → vault:check) or directly: `bash cli/test_transfer.sh`.
#
# Everything runs under a mktemp dir with fake $HOMEs + MILLFOLIO_DATA_DIR
# overrides and the MILLFOLIO_EXPORT_PASSPHRASE env passphrase, so it never
# touches the real vault, home folder, or Keychain. Covers:
#   T1 modern roundtrip — data dir restored byte-identically (minus excludes),
#      documents (incl. nested + a TSV-escaped backslash name) restored under
#      the new home, existing files never clobbered, machine-local secrets
#      preserved, the transient work queue never travels.
#   T2 legacy import — /Users/<olduser>/ paths in manifest.tsv +
#      indexed-paths.json rewritten to ~/…; outside-home source docs skipped.
#   T3 wrong passphrase — the encrypted DMG refuses to open (non-zero exit).
#   T4 --no-documents — data-only archive.
#
# The Keychain paths (create-synchronizable / fallback / find) are deliberately
# NOT covered — host-state-dependent; the env passphrase is the test seam.
set -u

CLI_DIR="$(cd "$(dirname "$0")" && pwd)"

# macOS-only feature (hdiutil + Swift). Skip cleanly anywhere else.
if [[ "$(uname)" != "Darwin" ]] || ! command -v hdiutil >/dev/null; then
    echo "test_transfer: SKIP (needs macOS hdiutil)"
    exit 0
fi

echo "test_transfer: building mill…"
if ! swift build --package-path "$CLI_DIR" --product mill >/dev/null 2>&1; then
    echo "FAIL: swift build --product mill"
    exit 1
fi
MILL="$CLI_DIR/.build/debug/mill"

WORK="$(mktemp -d /tmp/mill-transfer-test.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
export MILLFOLIO_EXPORT_PASSPHRASE="transfer-test-pass"

FAILURES=0
CHECKS=0
fail() { echo "FAIL: $1"; FAILURES=$((FAILURES + 1)); CHECKS=$((CHECKS + 1)); }
ok()   { CHECKS=$((CHECKS + 1)); }
expect_content() {  # file, want, label
    if [[ "$(cat "$1" 2>/dev/null)" == "$2" ]]; then ok; else fail "$3 (got: $(cat "$1" 2>/dev/null || echo '<missing>'))"; fi
}
expect_absent() {   # file, label
    if [[ -e "$1" ]]; then fail "$2 (exists)"; else ok; fi
}
expect_grep() {     # pattern, file, label (-- so a leading-dash pattern isn't an option)
    if grep -q -- "$1" "$2"; then ok; else fail "$3 (no '$1' in output)"; fi
}

# ── fixtures: machine A (modern layout, ~/vault) ──────────────────────────────
HOME_A="$WORK/homeA"; DATA_A="$WORK/dataA"
mkdir -p "$HOME_A/vault/2026" "$DATA_A/index.db"
printf 'PDF-ONE'   > "$HOME_A/vault/st1.pdf"
printf 'CSV-TWO'   > "$HOME_A/vault/2026/st2.csv"
printf 'BACKSLASH' > "$HOME_A/vault/a\\b.pdf"       # on-disk name: a\b.pdf
printf '#meta\t5\t5\t~/vault\t7\n'                > "$DATA_A/manifest.tsv"
printf 'file_0\tst1.pdf\tpdf\t100\taaa\t0\t3\n'  >> "$DATA_A/manifest.tsv"
printf 'file_1\t2026/st2.csv\tcsv\t50\tbbb\t3\t2\n' >> "$DATA_A/manifest.tsv"
printf 'file_2\ta\\\\b.pdf\tpdf\t9\tccc\t5\t1\n' >> "$DATA_A/manifest.tsv"  # TSV cell: a\\b.pdf
printf 'file_0\t2026-01-05\t42.50\tdebit\tVERIZON\tphone\t1\t2026\n' > "$DATA_A/transactions.tsv"
printf 'phone = verizon\n' > "$DATA_A/categories.txt"
printf 'A-SECRET'   > "$DATA_A/.anthropic-key"      # machine-local: must not travel
printf 'queue-item' > "$DATA_A/work_queue.jsonl"    # transient: must not travel
printf 'lance'      > "$DATA_A/index.db/data.lance" # nested store dir must copy intact

# ── T1: modern roundtrip with documents ───────────────────────────────────────
OUT="$WORK/t1-export.log"
HOME="$HOME_A" MILLFOLIO_DATA_DIR="$DATA_A" "$MILL" export --out "$WORK/a.dmg" >"$OUT" 2>&1 \
    || fail "T1 export exited non-zero: $(cat "$OUT")"
expect_grep "3 document(s)" "$OUT" "T1 export stages all three documents"

HOME_B="$WORK/homeB"; DATA_B="$WORK/dataB"
mkdir -p "$HOME_B/vault" "$DATA_B"
printf 'B-LOCAL'  > "$HOME_B/vault/st1.pdf"         # pre-existing doc: must be kept
printf 'B-SECRET' > "$DATA_B/.anthropic-key"        # B's own secret: must be kept
OUT="$WORK/t1-import.log"
HOME="$HOME_B" MILLFOLIO_DATA_DIR="$DATA_B" "$MILL" import --force "$WORK/a.dmg" >"$OUT" 2>&1 \
    || fail "T1 import exited non-zero: $(cat "$OUT")"

if cmp -s "$DATA_A/manifest.tsv" "$DATA_B/manifest.tsv"; then ok; else fail "T1 manifest not byte-identical"; fi
expect_content "$DATA_B/categories.txt" 'phone = verizon' "T1 categories restored"
expect_content "$DATA_B/index.db/data.lance" 'lance' "T1 nested index.db restored"
expect_content "$DATA_B/.anthropic-key" 'B-SECRET' "T1 local secret preserved"
expect_absent  "$DATA_B/work_queue.jsonl" "T1 work queue must not travel"
expect_content "$HOME_B/vault/st1.pdf" 'B-LOCAL' "T1 existing document never clobbered"
expect_content "$HOME_B/vault/2026/st2.csv" 'CSV-TWO' "T1 nested document restored"
expect_content "$HOME_B/vault/a\\b.pdf" 'BACKSLASH' "T1 TSV-escaped name roundtrips"
expect_grep "2 document(s) restored" "$OUT" "T1 import reports actually-copied count"

# ── T2: legacy absolute paths rewritten on import ─────────────────────────────
DATA_L="$WORK/dataL"; DATA_L2="$WORK/dataL2"
mkdir -p "$DATA_L" "$DATA_L2"
printf '#meta\t5\t5\t/Users/olduser/vault\t7\nfile_0\tst1.pdf\tpdf\t100\taaa\t0\t3\n' > "$DATA_L/manifest.tsv"
printf '{"folders":[{"path":"/Users/olduser/vault","lastIndexed":"123"}]}' > "$DATA_L/indexed-paths.json"
OUT="$WORK/t2-export.log"
HOME="$HOME_A" MILLFOLIO_DATA_DIR="$DATA_L" "$MILL" export --out "$WORK/l.dmg" >"$OUT" 2>&1 \
    || fail "T2 export exited non-zero: $(cat "$OUT")"
expect_grep "outside your home folder" "$OUT" "T2 outside-home source docs skipped with a warning"
OUT="$WORK/t2-import.log"
HOME="$HOME_B" MILLFOLIO_DATA_DIR="$DATA_L2" "$MILL" import --force "$WORK/l.dmg" >"$OUT" 2>&1 \
    || fail "T2 import exited non-zero: $(cat "$OUT")"
expect_grep "normalized 2 legacy absolute path" "$OUT" "T2 reports both rewrites"
expect_grep '^#meta	5	5	~/vault	7$' "$DATA_L2/manifest.tsv" "T2 manifest source_dir rewritten to ~"
expect_grep '"path":"~/vault"' "$DATA_L2/indexed-paths.json" "T2 indexed-paths rewritten (no \\/ escapes)"
if grep -q "olduser" "$DATA_L2/indexed-paths.json"; then fail "T2 old username survives in indexed-paths"; else ok; fi

# ── T3: wrong passphrase refuses to open ──────────────────────────────────────
OUT="$WORK/t3-import.log"
if HOME="$HOME_B" MILLFOLIO_DATA_DIR="$WORK/dataT3" MILLFOLIO_EXPORT_PASSPHRASE="wrong-pass" \
    "$MILL" import --force "$WORK/a.dmg" >"$OUT" 2>&1; then
    fail "T3 import succeeded with a wrong passphrase"
else
    ok
fi
expect_grep "wrong passphrase" "$OUT" "T3 error names the passphrase"

# ── T4: --no-documents = data-only archive ────────────────────────────────────
OUT="$WORK/t4-export.log"
HOME="$HOME_A" MILLFOLIO_DATA_DIR="$DATA_A" "$MILL" export --no-documents --out "$WORK/nd.dmg" >"$OUT" 2>&1 \
    || fail "T4 export exited non-zero: $(cat "$OUT")"
expect_grep "no documents (--no-documents)" "$OUT" "T4 export says data-only"
DATA_ND="$WORK/dataND"; HOME_ND="$WORK/homeND"
mkdir -p "$DATA_ND" "$HOME_ND"
OUT="$WORK/t4-import.log"
HOME="$HOME_ND" MILLFOLIO_DATA_DIR="$DATA_ND" "$MILL" import --force "$WORK/nd.dmg" >"$OUT" 2>&1 \
    || fail "T4 import exited non-zero: $(cat "$OUT")"
expect_grep "no documents in the archive" "$OUT" "T4 import says no documents"
if [[ -d "$HOME_ND/vault" ]]; then fail "T4 documents appeared despite --no-documents"; else ok; fi

# ── summary ───────────────────────────────────────────────────────────────────
if [[ $FAILURES -gt 0 ]]; then
    echo "test_transfer: $FAILURES of $CHECKS checks FAILED"
    exit 1
fi
echo "test_transfer: all $CHECKS checks passed"
