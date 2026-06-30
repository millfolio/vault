class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.38-rc.4"
  url "https://github.com/millfolio/vault/releases/download/v0.4.38-rc.4/mill-macos.tar.gz"
  sha256 "78b3d5aab5bb88ee28a0903f646ec45a32a10b78693ad7fdb154422d56110512"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
