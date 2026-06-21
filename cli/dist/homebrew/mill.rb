class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.16"
  url "https://github.com/millfolio/vault/releases/download/v0.4.16/mill-macos.tar.gz"
  sha256 "a1aaff1d64555e7db1820f64526d4c88dec1ace88ed8ec433d3666e9189b8909"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
