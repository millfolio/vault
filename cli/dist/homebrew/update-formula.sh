#!/usr/bin/env bash
#
# Regenerate dist/homebrew/mill.rb for a published release tag — downloads the
# release's mill-macos.tar.gz, computes its sha256, and rewrites the formula's
# version/url/sha256. Run after the release workflow has attached the asset:
#
#   dist/homebrew/update-formula.sh v0.1.0
#
# Then copy the formula into the tap repo (Formula/mill.rb) — or let CI do it,
# see dist/homebrew/README.md.
#
set -euo pipefail

TAG="${1:?usage: update-formula.sh vX.Y.Z}"
REPO="${MILL_REPO:-millfolio/vault}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/mill.rb"

URL="https://github.com/$REPO/releases/download/$TAG/mill-macos.tar.gz"
VER="${TAG#v}"

echo "==> fetching $URL" >&2
TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT
curl -fsSL "$URL" -o "$TMP"
SHA="$(shasum -a 256 "$TMP" | awk '{print $1}')"
echo "==> sha256 $SHA" >&2

cat >"$OUT" <<EOF
class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/$REPO"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "$VER"
  url "$URL"
  sha256 "$SHA"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) \`mill\` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
EOF

echo "==> wrote $OUT (version $VER)" >&2
