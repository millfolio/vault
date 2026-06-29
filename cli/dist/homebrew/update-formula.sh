#!/usr/bin/env bash
#
# Regenerate a Homebrew formula for a published release tag — downloads the
# release's mill-macos.tar.gz, computes its sha256, and writes version/url/sha256.
# Run after the asset is attached (CI for a -rc tag; release:promote for prod).
#
#   dist/homebrew/update-formula.sh v0.4.37            # PROD  → mill.rb     (class Mill,    bin `mill`)
#   dist/homebrew/update-formula.sh v0.4.37-rc.1 --dev # DEV   → mill-dev.rb (class MillDev, bin `mill-dev`)
#
# The two channels install DIFFERENT binary names (`mill` vs `mill-dev`) so they can
# coexist in Homebrew; the CLI reads its own channel back via `brew list --versions`
# to fetch the matching bundle. Then copy the formula into the tap repo (Formula/).
#
set -euo pipefail

TAG="${1:?usage: update-formula.sh vX.Y.Z[-rc.N] [--dev]}"
CHANNEL="prod"
[ "${2:-}" = "--dev" ] && CHANNEL="dev"
REPO="${MILL_REPO:-millfolio/vault}"
HERE="$(cd "$(dirname "$0")" && pwd)"

if [ "$CHANNEL" = dev ]; then
  OUT="$HERE/mill-dev.rb"
  CLASS="MillDev"
  BIN="mill-dev"
  DESC="CLI for the millfolio personal data vault (dev channel)"
else
  OUT="$HERE/mill.rb"
  CLASS="Mill"
  BIN="mill"
  DESC="CLI for the millfolio personal data vault"
fi

URL="https://github.com/$REPO/releases/download/$TAG/mill-macos.tar.gz"
VER="${TAG#v}"

echo "==> fetching $URL" >&2
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP"
SHA="$(shasum -a 256 "$TMP" | awk '{print $1}')"
echo "==> sha256 $SHA" >&2

cat >"$OUT" <<EOF
class $CLASS < Formula
  desc "$DESC"
  homepage "https://github.com/$REPO"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "$VER"
  url "$URL"
  sha256 "$SHA"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as \`$BIN\`.
    bin.install "mill" => "$BIN"
  end

  test do
    assert_match "mill", shell_output("#{bin}/$BIN --help")
  end
end
EOF

echo "==> wrote $OUT (version $VER, channel $CHANNEL)" >&2
