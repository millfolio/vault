class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.53-rc.2"
  url "https://github.com/millfolio/vault/releases/download/v0.4.53-rc.2/mill-macos.tar.gz"
  sha256 "1c8d1184a9cdc3f55b721e0a59109462a1c11b08d099d6fe38c4c908fe5f437b"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
