class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.37"
  url "https://github.com/millfolio/vault/releases/download/v0.4.37/mill-macos.tar.gz"
  sha256 "d4631be2fe3644b9397fa28ac66088ffc7e309d1a17cf76f01a02c3c9faf947c"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill`.
    bin.install "mill" => "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
