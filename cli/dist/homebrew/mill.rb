class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.6"
  url "https://github.com/millfolio/vault/releases/download/v0.4.6/mill-macos.tar.gz"
  sha256 "c3756ea3bb986e452c549a4387dde220a597f9e1c2d1068eceb4f12fe161c971"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
