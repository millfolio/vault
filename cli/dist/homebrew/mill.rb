class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.8"
  url "https://github.com/millfolio/vault/releases/download/v0.4.8/mill-macos.tar.gz"
  sha256 "0492d6dca9ae82e52130cf764b4f166a05742c7231f2800a340ddd82eb4d4e93"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
