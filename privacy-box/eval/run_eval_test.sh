#!/usr/bin/env bash
#
# run_eval_test.sh — unit tests for the eval HARNESS (run_eval.sh itself), so the
# lint logic can't silently rot. Fully mock-driven: a fake `privacy_box` emits a
# canned program per question, so this needs NO model, NO API key, NO network —
# it's wired into `moon run vault:check` (unlike the real eval, which is a manual,
# key-requiring, model-nondeterministic pre-release gate).
#
# It asserts the harness's CONTRACT: must_contain / must_not_contain detection,
# the pass→exit-0 / fail→exit-1 result, comment+blank skipping, and the
# unknown-model→exit-2 guard.
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Mock privacy_box. Invoked as: codegen "<question>" --manifest <path>. Emits a
# GOOD program (transactions()+money(), no search/raw-$) when the question contains
# "good", else a BAD one (search()+raw-float formatting) — enough to exercise both
# must_contain and must_not_contain paths.
cat >"$TMP/mockbin" <<'EOF'
#!/usr/bin/env bash
q="${2:-}"
if printf '%s' "$q" | grep -q relok; then
  # relative-date program: months_ago() cutoff, NO hardcoded date literal → clean.
  printf '%s\n' 'from vault import *' 'def main() raises:' \
    '    var cutoff = months_ago(3)' '    var t = transactions()' \
    '    if t[0].date >= cutoff:' '        print(money(t[0].amount))'
elif printf '%s' "$q" | grep -q reldate; then
  # relative-date program that WRONGLY hardcodes a YYYY-MM-DD literal → guard trips.
  printf '%s\n' 'from vault import *' 'def main() raises:' \
    '    var cutoff = months_ago(3)' '    var t = transactions()' \
    '    if t[0].date >= "2026-04-01":' '        print(money(t[0].amount))'
elif printf '%s' "$q" | grep -q overtag; then
  # EXTRACTION query that WRONGLY suggests a tag → over-tag guard (must_not) trips.
  printf '%s\n' 'from vault import *' 'def main() raises:' \
    '    # SUGGEST_TAG: insurance : Is this an insurance renewal?' \
    '    var hits = search("insurance", 8)' \
    '    print(ask_local("renewal date?", hits[0].text))'
elif printf '%s' "$q" | grep -q extract; then
  # clean EXTRACTION: inline ask_local, NO SUGGEST_TAG.
  printf '%s\n' 'from vault import *' 'def main() raises:' \
    '    var hits = search("insurance", 8)' \
    '    print(ask_local("renewal date?", hits[0].text))'
elif printf '%s' "$q" | grep -q good; then
  printf '%s\n' 'from vault import *' 'def main() raises:' \
    '    var t = transactions()' '    print(money(t[0].amount))'
else
  printf '%s\n' 'from vault import *' 'def main() raises:' \
    '    var hits = search("x")' '    print("$" + String(0.0))'
fi
EOF
chmod +x "$TMP/mockbin"

fails=0
assert_exit() { # desc expected actual
  if [ "$2" != "$3" ]; then
    echo "FAIL: $1 (want exit $2, got $3)"
    fails=$((fails + 1))
  else
    echo "ok:   $1"
  fi
}

run() { # golden_file [model] -> sets rc
  local golden="$1"
  shift
  PRIVACY_BOX_BIN="$TMP/mockbin" EVAL_GOLDEN="$golden" \
    bash "$DIR/run_eval.sh" "$@" >/dev/null 2>&1
  rc=$?
}

# 1) all must_contain present + must_not_contain absent → PASS → exit 0
printf 'good q\ttransactions(,money(\tsearch(,$" +\tstatements.txt\n' >"$TMP/g_pass.tsv"
run "$TMP/g_pass.tsv"
assert_exit "satisfied golden → exit 0" 0 "$rc"

# 2) must_contain missing AND banned present (the bad program) → FAIL → exit 1
printf 'bad q\ttransactions(,money(\tsearch(,$" +\tstatements.txt\n' >"$TMP/g_fail.tsv"
run "$TMP/g_fail.tsv"
assert_exit "missing must + present banned → exit 1" 1 "$rc"

# 3) a lone must_not_contain violation (good program but we ban money() ) → exit 1
printf 'good q\ttransactions(\tmoney(\tstatements.txt\n' >"$TMP/g_ban.tsv"
run "$TMP/g_ban.tsv"
assert_exit "banned substring present → exit 1" 1 "$rc"

# 4) comments + blank lines are skipped; the single real row passes → exit 0
printf '# header comment\n\ngood q\ttransactions(\t\tstatements.txt\n' >"$TMP/g_cmt.tsv"
run "$TMP/g_cmt.tsv"
assert_exit "comments/blanks skipped → exit 0" 0 "$rc"

# 4b) relative-date row satisfied (months_ago present, NO hardcoded date) → exit 0
printf 'relok q\ttransactions(,months_ago(\t\tstatements.txt\n' >"$TMP/g_relok.tsv"
run "$TMP/g_relok.tsv"
assert_exit "wall-clock row, no date literal → exit 0" 0 "$rc"

# 4c) relative-date row whose program hardcodes a YYYY-MM-DD literal → guard → exit 1
printf 'reldate q\ttransactions(,months_ago(\t\tstatements.txt\n' >"$TMP/g_reldate.tsv"
run "$TMP/g_reldate.tsv"
assert_exit "wall-clock row, hardcoded date literal → exit 1" 1 "$rc"

# 4d) extraction query, INLINE ask_local + NO SUGGEST_TAG → over-tag guard clean → exit 0
printf 'extract q\task_local\t# SUGGEST_TAG:\tstatements.txt\n' >"$TMP/g_extract.tsv"
run "$TMP/g_extract.tsv"
assert_exit "extraction row, no SUGGEST_TAG → exit 0" 0 "$rc"

# 4e) extraction query that WRONGLY emits a SUGGEST_TAG → banned → exit 1 (over-tag guard)
printf 'overtag q\task_local\t# SUGGEST_TAG:\tstatements.txt\n' >"$TMP/g_overtag.tsv"
run "$TMP/g_overtag.tsv"
assert_exit "extraction row, stray SUGGEST_TAG → exit 1" 1 "$rc"

# 5) unknown model (no golden.<model>.tsv, no EVAL_GOLDEN) → exit 2
PRIVACY_BOX_BIN="$TMP/mockbin" bash "$DIR/run_eval.sh" no-such-model >/dev/null 2>&1
assert_exit "unknown model → exit 2" 2 "$?"

# 6) the SHIPPED golden files parse (4 TAB-separated columns per data row)
for g in "$DIR"/golden.*.tsv; do
  bad="$(awk -F'\t' '!/^#/ && NF>0 && NF!=4 {print NR}' "$g")"
  if [ -n "$bad" ]; then
    echo "FAIL: $(basename "$g") has non-4-column data row(s): $bad"
    fails=$((fails + 1))
  else
    echo "ok:   $(basename "$g") is well-formed (4 columns)"
  fi
done

echo
if [ "$fails" = 0 ]; then
  echo "run_eval self-test: ALL PASSED"
else
  echo "run_eval self-test: $fails FAILED"
  exit 1
fi
