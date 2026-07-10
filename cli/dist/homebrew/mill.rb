class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.48"
  url "https://github.com/millfolio/vault/releases/download/v0.4.48/mill-macos.tar.gz"
  sha256 "ce06494351530b65438b9729ae1a38804f3ec6c0ec9bdd2c6d4bfdc03fcb0b40"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill`.
    bin.install "mill" => "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
