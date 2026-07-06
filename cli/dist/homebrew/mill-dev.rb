class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.46-rc.1"
  url "https://github.com/millfolio/vault/releases/download/v0.4.46-rc.1/mill-macos.tar.gz"
  sha256 "085a8e25311a2f24d6e2390ff8634fe678cfdda46a0e41df3d14841fdcbf50dc"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
