# Dev bootstrap for ldx (dev-rig): run ./bin/ldx straight from a checkout.
# Users who install the formula (brew install roguexz/ldx/ldx) do not need
# this file - the formula declares the same dependencies.
# Install: brew bundle --file Brewfile
tap "hashicorp/tap"               # vault is not in homebrew-core

brew "grype"                      # cvescan vulnerability scanner (homebrew-core)
brew "helm"                       # k8s chart installs (Rancher Desktop also ships one)
brew "jq"                         # JSON glue
brew "mkcert"                     # local CA / TLS certificates
brew "hashicorp/tap/vault"        # Vault CLI (ldx vault create-user)
brew "terminal-notifier"          # cvescan desktop notifications

# Not installable via Homebrew:
#  - Rancher Desktop (local Kubernetes; ships its own kubectl):
#      https://rancherdesktop.io/
#  - Xcode Command Line Tools (ldx touchid helper): xcode-select --install
#  - A JDK (ldx tls keystore)
