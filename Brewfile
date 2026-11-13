# Prerequisites for ldx (dev-rig). Install: brew bundle --file Brewfile
tap "hashicorp/tap"
tap "anchore/tap"

brew "anchore/tap/grype"          # cvescan vulnerability scanner
brew "helm"                       # k8s chart installs
brew "jq"                         # JSON glue
brew "kubectl"                    # k8s client (rancher-desktop context)
brew "mkcert"                     # local CA / TLS certificates
brew "hashicorp/tap/vault"        # Vault CLI (ldx vault create-user)
brew "terminal-notifier"          # cvescan desktop notifications

cask "rancher-desktop"            # local Kubernetes runtime

# Not installable via Homebrew:
#  - Xcode Command Line Tools (ldx touchid helper): xcode-select --install
#  - A JDK (ldx tls keystore)
