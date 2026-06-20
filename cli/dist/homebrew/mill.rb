class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.2"
  url "https://github.com/millfolio/vault/releases/download/v0.4.2/mill-macos.tar.gz"
  sha256 "b1cd6dd1a4fd397a664d2ff299e2af686d29c6b3887464eafb586ab996e36af4"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
