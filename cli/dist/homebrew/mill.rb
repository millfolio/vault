class Mill < Formula
  desc "CLI for the millfolio personal data vault"
  homepage "https://github.com/millfolio/vault"
  # version / url / sha256 are bumped per release by dist/homebrew/update-formula.sh
  # (downloads the mill-macos.tar.gz release asset and fills in its checksum).
  version "0.4.43"
  url "https://github.com/millfolio/vault/releases/download/v0.4.43/mill-macos.tar.gz"
  sha256 "650f32ec9d17e6688bfc650d8232530489069a99c5b755447b575f034dbe4255"

  depends_on :macos

  def install
    # The tarball is a single universal (arm64 + x86_64) binary, installed as `mill`.
    bin.install "mill" => "mill"
  end

  test do
    assert_match "mill", shell_output("#{bin}/mill --help")
  end
end
