class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.26"
  url "https://github.com/millfolio/vault/releases/download/v0.4.26/mill-macos.tar.gz"
  sha256 "83a50e86ac2576b0cb15fdf3b5492de443aab9b4b8e72f558194351c33b5871d"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
