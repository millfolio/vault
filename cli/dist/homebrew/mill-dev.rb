class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.39-rc.2"
  url "https://github.com/millfolio/vault/releases/download/v0.4.39-rc.2/mill-macos.tar.gz"
  sha256 "1d4a7498a7f7b99a53cd6726009dd7dd568caae9a317f19184ce3e8fc4d678dc"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
