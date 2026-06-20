class Mill < Formula
  desc "CLI for the millfolio personal data vault (millrace server + headgate)"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.2.0"
  url "https://github.com/millfolio/vault/releases/download/v0.2.0/mill-macos.tar.gz"
  sha256 "b9a20b751cd725c37c770af35dcd3cf43d4fee0f28e27894ddf099350c415449"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) `mill` binary.
    bin.install "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
