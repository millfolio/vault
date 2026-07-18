#!/usr/bin/env bash
#
# Coordinated release for the millfolio stack. Tags each repo so its CI builds and
# attaches the release asset, in dependency order:
#
#   1. millfolio   (this repo)  -> millfolio-zip.yml  attaches millfolio.zip
#   2. enclave               -> enclave-zip.yml attaches enclave.zip
#   3. cli                    -> release.yml      attaches millfolio-macos.tar.gz
#   4. homebrew-tap           -> formula bumped to the cli asset's url + sha256
#
# The engine + enclave are the assets the CLI's Bootstrapper fetches at runtime
# (millfolio.zip + enclave.zip from releases/latest); they have no build-time tie
# to cli, so they just go first. The tap MUST come after cli: update-formula.sh
# downloads the cli release asset to compute its sha256, so the asset has to
# exist first. This script waits for each asset to appear before moving on.
#
# VERSION is figured out automatically: the highest vX.Y.Z tag across the three
# release repos, patch-bumped (--minor / --major to bump elsewhere). With no tags
# yet, the cli Homebrew formula's version seeds the first release. Pass an
# explicit vX.Y.Z to override. The run is non-interactive (no prompts); use
# --dry-run to print the resolved version + plan and exit.
#
# Layout: the repos are siblings under one umbrella dir (enclave/, cli/,
# homebrew-tap/ next to this millfolio/ checkout). Override with ENCLAVE_DIR /
# CLI_DIR / TAP_DIR if yours differ.
#
#   Usage: scripts/release.sh [vX.Y.Z] [--major|--minor|--patch]
#                  [--skip-engine] [--skip-enclave] [--skip-app] [--skip-tap] [--dry-run]
#
set -euo pipefail

# -- locations ----------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENGINE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"          # the millfolio repo
UMBRELLA="$(cd "$ENGINE_DIR/.." && pwd)"
ENCLAVE_DIR="${ENCLAVE_DIR:-$UMBRELLA/enclave}"
APP_DIR="${APP_DIR:-$UMBRELLA/app}"
CLI_DIR="${CLI_DIR:-$UMBRELLA/cli}"
TAP_DIR="${TAP_DIR:-$UMBRELLA/homebrew-tap}"

ENGINE_REPO="${ENGINE_REPO:-millfolio/millfolio}"
ENCLAVE_REPO="${ENCLAVE_REPO:-millfolio/enclave}"
APP_REPO="${APP_REPO:-millfolio/app}"
CLI_REPO="${CLI_REPO:-millfolio/cli}"

ENGINE_ASSET="millfolio.zip"
ENCLAVE_ASSET="enclave.zip"
APP_ASSET="millfolio-app.zip"
CLI_ASSET="millfolio-macos.tar.gz"
TAP_FORMULA="millfolio.rb"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-2400}"   # seconds to wait for a CI asset (engine build ~20m+)
POLL_INTERVAL="${POLL_INTERVAL:-20}"

# -- args ---------------------------------------------------------------------
VERSION="" BUMP="patch" SKIP_ENGINE=0 SKIP_ENCLAVE=0 SKIP_APP=0 SKIP_TAP=0 DRY_RUN=0
for a in "$@"; do
  case "$a" in
    --major)         BUMP="major" ;;
    --minor)         BUMP="minor" ;;
    --patch)         BUMP="patch" ;;
    --skip-engine)   SKIP_ENGINE=1 ;;
    --skip-enclave) SKIP_ENCLAVE=1 ;;
    --skip-app)      SKIP_APP=1 ;;
    --skip-tap)      SKIP_TAP=1 ;;
    --dry-run)       DRY_RUN=1 ;;
    -h|--help)       sed -n '2,33p' "$0"; exit 0 ;;
    -*)              echo "unknown option: $a" >&2; exit 2 ;;
    *)               [ -z "$VERSION" ] && VERSION="$a" || { echo "unexpected argument: $a" >&2; exit 2; } ;;
  esac
done

# -- helpers ------------------------------------------------------------------
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Every vX.Y.Z tag across the release repos, one per line (deduped, sorted).
all_release_tags() {
  local dir
  for dir in "$ENGINE_DIR" "$ENCLAVE_DIR" "$APP_DIR" "$CLI_DIR"; do
    git -C "$dir" ls-remote --tags origin 2>/dev/null \
      | sed -E 's#.*refs/tags/##; s#\^\{\}$##' \
      | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true
  done | sort -u -V
}

# bump_semver vX.Y.Z {major|minor|patch} -> vX'.Y'.Z'
bump_semver() {
  local v="${1#v}" part="$2" M m p
  IFS=. read -r M m p <<< "$v"
  case "$part" in
    major) M=$((M + 1)); m=0; p=0 ;;
    minor) m=$((m + 1)); p=0 ;;
    *)     p=$((p + 1)) ;;
  esac
  printf 'v%s.%s.%s\n' "$M" "$m" "$p"
}

# Formula version (e.g. 0.1.1) -> seed for the very first release.
formula_version() {
  grep -E '^[[:space:]]*version' "$CLI_DIR/dist/homebrew/$TAP_FORMULA" 2>/dev/null \
    | head -1 | sed -E 's/.*"([^"]+)".*/\1/'
}

# Resolve VERSION: explicit arg wins; else bump the highest existing tag; else
# seed from the formula version. Then ensure it collides with no existing tag.
resolve_version() {
  local tags latest fv
  tags="$(all_release_tags)"
  latest="$(printf '%s\n' "$tags" | grep -E '^v' | tail -1 || true)"

  if [ -n "$VERSION" ]; then
    [[ "$VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "explicit version must look like vX.Y.Z (got '$VERSION')"
  elif [ -n "$latest" ]; then
    VERSION="$(bump_semver "$latest" "$BUMP")"
    log "latest released tag is $latest -> $BUMP-bumped to $VERSION"
  else
    fv="$(formula_version)"
    VERSION="v${fv:-0.1.0}"
    log "no existing release tags -> seeding first release from formula: $VERSION"
  fi

  while printf '%s\n' "$tags" | grep -qx "$VERSION"; do
    local nxt; nxt="$(bump_semver "$VERSION" patch)"
    warn "tag $VERSION already exists -> bumping to $nxt"
    VERSION="$nxt"
  done
}

# Tag the repo at $1 with $VERSION and push it, so CI fires. Refuses if the
# working tree is dirty or the local branch is ahead of its remote (CI would
# build a commit GitHub hasn't seen).
tag_and_push() {
  local dir="$1" repo="$2"
  [ -d "$dir/.git" ] || die "$dir is not a git repo (set ENCLAVE_DIR/CLI_DIR/TAP_DIR?)"
  ( cd "$dir"
    [ -z "$(git status --porcelain)" ] || die "$repo working tree is dirty -- commit or stash first"
    local branch; branch="$(git symbolic-ref --quiet --short HEAD || true)"
    [ -n "$branch" ] || die "$repo is in detached HEAD"
    git fetch -q origin
    if git rev-parse -q --verify "refs/remotes/origin/$branch" >/dev/null; then
      [ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$branch")" ] \
        || die "$repo: local $branch differs from origin/$branch -- push (or pull) first"
    fi
    if git ls-remote --tags --exit-code origin "refs/tags/$VERSION" >/dev/null 2>&1; then
      warn "$repo: tag $VERSION already on origin -- skipping tag/push (will still wait for its asset)"
      return 0
    fi
    log "$repo: tagging $VERSION at $(git rev-parse --short HEAD) and pushing"
    git tag -a "$VERSION" -m "$repo $VERSION"
    git push -q origin "$VERSION"
  )
  log "$repo: tag pushed -- CI: https://github.com/$repo/actions"
}

# Poll the GitHub Release for $VERSION until the named asset shows up.
wait_for_asset() {
  local repo="$1" asset="$2" elapsed=0
  log "waiting for $repo $VERSION/$asset (timeout ${WAIT_TIMEOUT}s)..."
  while true; do
    if gh release view "$VERSION" --repo "$repo" --json assets \
         --jq '.assets[].name' 2>/dev/null | grep -qx "$asset"; then
      log "$repo: $asset is published"
      return 0
    fi
    (( elapsed >= WAIT_TIMEOUT )) && die "timed out waiting for $repo $VERSION/$asset (check the Actions tab)"
    sleep "$POLL_INTERVAL"; elapsed=$((elapsed + POLL_INTERVAL))
    printf '    ...%ss elapsed\n' "$elapsed" >&2
  done
}

# -- preflight ----------------------------------------------------------------
command -v gh  >/dev/null || die "gh CLI not found"
command -v curl >/dev/null || die "curl not found"
gh auth status >/dev/null 2>&1 || die "gh not authenticated (run: gh auth login)"
[ -x "$CLI_DIR/dist/homebrew/update-formula.sh" ] || die "missing $CLI_DIR/dist/homebrew/update-formula.sh"
[ -d "$TAP_DIR/.git" ] || die "tap repo not found at $TAP_DIR (set TAP_DIR)"

resolve_version

echo
log "Release plan for $VERSION"
[ "$SKIP_ENGINE" = 0 ]   && echo "    1. engine    $ENGINE_REPO  -> $ENGINE_ASSET"     || echo "    1. engine    (skipped)"
[ "$SKIP_ENCLAVE" = 0 ] && echo "    2. enclave  $ENCLAVE_REPO  -> $ENCLAVE_ASSET" || echo "    2. enclave  (skipped)"
[ "$SKIP_APP" = 0 ]      && echo "    3. app       $APP_REPO  -> $APP_ASSET"           || echo "    3. app       (skipped)"
echo                         "    4. cli       $CLI_REPO  -> $CLI_ASSET"
[ "$SKIP_TAP" = 0 ]      && echo "    5. tap       formula bump -> $TAP_DIR/Formula/$TAP_FORMULA" || echo "    5. tap       (skipped)"
echo
if [ "$DRY_RUN" = 1 ]; then
  log "dry run -- no tags pushed."
  exit 0
fi

# -- 1. engine (millfolio.zip) --------------------------------------------------
if [ "$SKIP_ENGINE" = 0 ]; then
  tag_and_push "$ENGINE_DIR" "$ENGINE_REPO"
  wait_for_asset "$ENGINE_REPO" "$ENGINE_ASSET"
fi

# -- 2. enclave (enclave.zip) -----------------------------------------------
if [ "$SKIP_ENCLAVE" = 0 ]; then
  tag_and_push "$ENCLAVE_DIR" "$ENCLAVE_REPO"
  wait_for_asset "$ENCLAVE_REPO" "$ENCLAVE_ASSET"
fi

# -- 3. app (millfolio-app.zip: ws_server source + web/dist) --------------------
# Independent of cli (the CLI builds it on-device against enclave at install).
if [ "$SKIP_APP" = 0 ]; then
  tag_and_push "$APP_DIR" "$APP_REPO"
  wait_for_asset "$APP_REPO" "$APP_ASSET"
fi

# -- 4. cli (millfolio-macos.tar.gz) -- must finish before the tap --------------
tag_and_push "$CLI_DIR" "$CLI_REPO"
wait_for_asset "$CLI_REPO" "$CLI_ASSET"

# -- 5. tap (formula -> cli's published asset) --------------------------------
if [ "$SKIP_TAP" = 0 ]; then
  log "tap: regenerating formula from $CLI_REPO $VERSION asset"
  ( cd "$CLI_DIR" && MILL_REPO="$CLI_REPO" dist/homebrew/update-formula.sh "$VERSION" )

  cp "$CLI_DIR/dist/homebrew/$TAP_FORMULA" "$TAP_DIR/Formula/$TAP_FORMULA"

  # Keep the cli repo's source-of-truth formula in sync too (best effort).
  ( cd "$CLI_DIR"
    if [ -n "$(git status --porcelain "dist/homebrew/$TAP_FORMULA")" ]; then
      git add "dist/homebrew/$TAP_FORMULA"
      git commit -q -m "homebrew: bump formula to $VERSION"
      git push -q origin HEAD && log "cli: formula sync committed"
    fi )

  ( cd "$TAP_DIR"
    if [ -z "$(git status --porcelain "Formula/$TAP_FORMULA")" ]; then
      warn "tap: Formula/$TAP_FORMULA unchanged for $VERSION -- nothing to publish"
    else
      git add "Formula/$TAP_FORMULA"
      git commit -q -m "millfolio ${VERSION#v}"
      git push -q origin HEAD
      log "tap: published Formula/$TAP_FORMULA for $VERSION"
    fi )
fi

echo
log "Done ($VERSION). Install with:  brew install millfolio/tap/mill"
