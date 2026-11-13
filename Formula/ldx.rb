class Ldx < Formula
  desc "Local Development Experience CLI: local k8s stacks, TLS, secrets and security tools"
  homepage "https://github.com/roguexz/dev-rig"
  # Self-hosted tap: this repo is the tap. Tag a release, then update
  # url/sha256 here (sha: `shasum -a 256` on the tarball URL):
  #   git tag v0.1.0 && git push origin v0.1.0
  url "https://github.com/roguexz/dev-rig/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_TARBALL_SHA256"
  head "https://github.com/roguexz/dev-rig.git", branch: "main"

  depends_on "helm"
  depends_on "jq"
  depends_on "kubectl"
  depends_on "mkcert"
  depends_on "anchore/tap/grype"
  depends_on "hashicorp/tap/vault"
  depends_on "terminal-notifier"

  def install
    # GitHub archive tarballs unpack under a dev-rig-<version>/ prefix.
    root = Dir["dev-rig-*"].first
    raise "unexpected archive layout" if root.nil?

    # Install the whole tree (bin/, bin/lib/, config/, cvescan/, lib/,
    # skills/, VERSION) under the prefix. bin/ldx resolves LDX_HOME from its
    # realpath, so commands and assets are found under the prefix at runtime.
    prefix.install Dir["#{root}/*"]
    bin.install_symlink prefix/"bin/ldx"
  end

  def post_install
    # Symlink ldx into ~/.local/bin (or ~/bin) so `ldx <command>` works.
    system bin/"ldx", "install"
  end

  def caveats
    <<~EOS
      Run `ldx install` if you skipped post-install symlink creation, and make
      sure your shell PATH includes ~/.local/bin.

      Not installed by Homebrew (install manually):
        * Rancher Desktop (cask: brew install --cask rancher-desktop) - the
          local k8s context used by ldx infra commands
        * Xcode Command Line Tools (xcode-select --install) - needed by
          `ldx touchid` to compile the Touch ID helper
        * A JDK - needed by `ldx tls keystore`
    EOS
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/ldx --version")
  end
end
