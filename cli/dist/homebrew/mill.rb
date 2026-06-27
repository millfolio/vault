class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.30"
  url "https://github.com/millfolio/vault/releases/download/v0.4.30/mill-macos.tar.gz"
  sha256 "43bf7d707dc8e913bd2df99c31642e57e28029016fe87d9b2d3b1188b05e7f01"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
