class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.39-rc.10"
  url "https://github.com/millfolio/vault/releases/download/v0.4.39-rc.10/mill-macos.tar.gz"
  sha256 "a787f48957c2e6e64d626410c5bf76e13520ff32d6c3d7d161d5cc0dbf3eb662"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
