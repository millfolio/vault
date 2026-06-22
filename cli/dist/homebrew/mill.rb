class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.20"
  url "https://github.com/millfolio/vault/releases/download/v0.4.20/mill-macos.tar.gz"
  sha256 "3ca92147ce4b215ed91a00c67e6faa8b5c72027267485d7c1453b123fa5821b0"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
