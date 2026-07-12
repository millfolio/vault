class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.50-rc.4"
  url "https://github.com/millfolio/vault/releases/download/v0.4.50-rc.4/mill-macos.tar.gz"
  sha256 "3c75e454b07179f78b137344e5e64975d6fee3ad7d8c78ae35ce4d1c0246aaa6"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
