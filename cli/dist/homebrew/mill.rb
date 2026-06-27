class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.32"
  url "https://github.com/millfolio/vault/releases/download/v0.4.32/mill-macos.tar.gz"
  sha256 "48fedd18e731d215588dd4088afccb0fb2c4b9b442251f51d59f6c92a914b3ab"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
