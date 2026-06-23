class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.25"
  url "https://github.com/millfolio/vault/releases/download/v0.4.25/mill-macos.tar.gz"
  sha256 "57079a0f2f0e4dfc31d266170be9c69e0d01627f125ce8ec8e2b069893b365df"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
