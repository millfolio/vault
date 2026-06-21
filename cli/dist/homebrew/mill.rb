class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.15"
  url "https://github.com/millfolio/vault/releases/download/v0.4.15/mill-macos.tar.gz"
  sha256 "7da24ff6c788aaf46ee1998f0bdae30f8d7006a4ac467e6a81ccbc19279f766e"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
