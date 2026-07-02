class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.39-rc.11"
  url "https://github.com/millfolio/vault/releases/download/v0.4.39-rc.11/mill-macos.tar.gz"
  sha256 "2f4d046c42f631d50a3522695eb9f640704f2eb91b3b55e488ee7d5c5b52cc26"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
