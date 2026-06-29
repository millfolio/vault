class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.35"
  url "https://github.com/millfolio/vault/releases/download/v0.4.35/mill-macos.tar.gz"
  sha256 "1073c8e7fd75a0e9fa5c673f7a082ad2d859f417112ba5b23f2f63c62f9bdf87"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
