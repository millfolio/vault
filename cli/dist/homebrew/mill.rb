class Mill < Formula
  desc "CLI for the millfolio personal data vault (millrace server + headgate)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.1.8"
  url "https://github.com/millfolio/vault/releases/download/v0.1.8/mill-macos.tar.gz"
  sha256 "d8ab30ffb48020a5c97d27c3609637c8aae819d981b3809dcc546304ae8ef67a"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
