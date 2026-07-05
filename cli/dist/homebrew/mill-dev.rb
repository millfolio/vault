class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.44-rc.6"
  url "https://github.com/millfolio/vault/releases/download/v0.4.44-rc.6/mill-macos.tar.gz"
  sha256 "bf479dd0f939abe464d3e58caf4d51a20f3a6e4c58f3429f1bf9e041873d48df"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
