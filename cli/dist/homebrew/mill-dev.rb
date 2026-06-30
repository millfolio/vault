class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.38-rc.5"
  url "https://github.com/millfolio/vault/releases/download/v0.4.38-rc.5/mill-macos.tar.gz"
  sha256 "6d374b03db7c7d2e4232dc7cc7f8abeef33097573857ea4c97dfe6c57b77974d"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
