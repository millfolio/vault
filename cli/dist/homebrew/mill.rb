class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.52"
  url "https://github.com/millfolio/vault/releases/download/v0.4.52/mill-macos.tar.gz"
  sha256 "2d83792a8d9e9df5f1beaa63edaf18ee83f29b46c9db4a2c4b6c9f3c56d2c1bd"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill`.
    bin.install "mill" => "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
