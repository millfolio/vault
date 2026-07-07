class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.47-rc.1"
  url "https://github.com/millfolio/vault/releases/download/v0.4.47-rc.1/mill-macos.tar.gz"
  sha256 "818be51b838ce6143ad3b7e2422ac6bf0cc0ff0b52e1a9459047aea679f16095"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
