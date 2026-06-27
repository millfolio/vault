class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.31"
  url "https://github.com/millfolio/vault/releases/download/v0.4.31/mill-macos.tar.gz"
  sha256 "987ebed8a7910e8da08c88c300c4bdca464f55d5a928bf484bd16b9fa4551c46"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
