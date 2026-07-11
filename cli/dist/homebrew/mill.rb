class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.49"
  url "https://github.com/millfolio/vault/releases/download/v0.4.49/mill-macos.tar.gz"
  sha256 "2f9917ba2582c1b5d2538f4931c61e8db95956fde88bd73cb5935b668538cb3e"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill`.
    bin.install "mill" => "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
