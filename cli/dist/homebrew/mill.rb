class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.21"
  url "https://github.com/millfolio/vault/releases/download/v0.4.21/mill-macos.tar.gz"
  sha256 "0b04ed8496272077b0ab99e3f9fe0e9c00f7718ba981141657137e8f67d49c57"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
