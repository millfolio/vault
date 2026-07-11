class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.50-rc.1"
  url "https://github.com/millfolio/vault/releases/download/v0.4.50-rc.1/mill-macos.tar.gz"
  sha256 "3baae6ebd60b9f52d11464de7a44b7707edb9a0804a9acc76b6d00d7f02f190b"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
