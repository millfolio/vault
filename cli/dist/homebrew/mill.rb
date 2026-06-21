class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.18"
  url "https://github.com/millfolio/vault/releases/download/v0.4.18/mill-macos.tar.gz"
  sha256 "ede67b76f38006db4cbe4cd6b3fb6880da415ab982d7f5dbad97c2e1a0602642"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
