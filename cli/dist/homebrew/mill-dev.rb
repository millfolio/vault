class MillDev < Formula
  desc "CLI for the millfolio personal data vault (dev channel)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.38-rc.3"
  url "https://github.com/millfolio/vault/releases/download/v0.4.38-rc.3/mill-macos.tar.gz"
  sha256 "db5a979cb225aaf77a8e8bdd3a53c2aa34b20c191c11d86daa1a7700db34be3f"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill-dev`.
    bin.install "mill" => "mill-dev"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill-dev --help")
  end
end
