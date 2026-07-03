class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.39-rc.18"
  url "https://github.com/millfolio/vault/releases/download/v0.4.39-rc.18/mill-macos.tar.gz"
  sha256 "58599ebd03260f2ab9c06c1f384b9e37baf5d4b2a26b047f6b898be96f81eaeb"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
