class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.24"
  url "https://github.com/millfolio/vault/releases/download/v0.4.24/mill-macos.tar.gz"
  sha256 "346c189cea93c3077cf35bd3220ab2d07a83f26bc777e6591e6ea63d8c0e3280"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
