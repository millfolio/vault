class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.53"
  url "https://github.com/millfolio/vault/releases/download/v0.4.53/mill-macos.tar.gz"
  sha256 "aed564c16313be785ee8b8a8d835f293b659be2eafd717acd795e55d9d530214"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill`.
    bin.install "mill" => "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
