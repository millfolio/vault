class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.27"
  url "https://github.com/millfolio/vault/releases/download/v0.4.27/mill-macos.tar.gz"
  sha256 "f1500be251901008e1f81f81f11ea0ada3f7ff2f8cc3bc1a4598e2b4c5126c5d"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
