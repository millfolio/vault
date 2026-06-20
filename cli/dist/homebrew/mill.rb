class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.3.0"
  url "https://github.com/millfolio/vault/releases/download/v0.3.0/mill-macos.tar.gz"
  sha256 "7cff5019746b0c0785e47985f94beb60ac6146f61a380550e54cf6e33eb5d303"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
