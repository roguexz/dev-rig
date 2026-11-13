#!/usr/bin/env bash
#
# install.sh - Installer for ldx (Local Development Experience)
#
# Prefers Homebrew (self-hosted tap in this repo: brew tap roguexz/dev-rig).
# Falls back to a git clone into a stable location (~/.local/share/ldx)
# followed by 'ldx install', which symlinks bin/ldx into ~/.local/bin.
# ldx installs by symlink only, so the checkout must persist:
# upgrades are 'git pull' (fallback path) or 'brew upgrade' (brew path).
#

set -euo pipefail

REPO="roguexz/dev-rig"
INSTALL_DIR="${HOME}/.local/share/ldx"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
fatal() { log_error "$1"; exit 1; }

if command -v brew &>/dev/null; then
  if brew list --formula roguexz/dev-rig/ldx &>/dev/null; then
    log_info "Upgrading ldx via Homebrew..."
    brew upgrade roguexz/dev-rig/ldx
  else
    log_info "Tapping ${REPO} and installing ldx via Homebrew..."
    brew tap "${REPO}"
    brew install "${REPO}/ldx"
  fi
  # Extra arguments (e.g. --dir) apply to the post-install symlink step.
  if [ $# -gt 0 ]; then
    ldx install "$@"
  fi
  log_info "Installation complete. Run 'ldx help' to get started."
  exit 0
fi

log_warn "Homebrew not found; falling back to a git clone (requires git)."

command -v git &>/dev/null || fatal "git is required for the non-Homebrew install path."

if [ -d "${INSTALL_DIR}/.git" ]; then
  log_info "Updating existing checkout at ${INSTALL_DIR}..."
  git -C "${INSTALL_DIR}" pull --ff-only
else
  log_info "Cloning ${REPO} into ${INSTALL_DIR}..."
  mkdir -p "$(dirname "${INSTALL_DIR}")"
  git clone --depth 1 "https://github.com/${REPO}.git" "${INSTALL_DIR}"
fi

log_info "Invoking installer..."
"${INSTALL_DIR}/bin/ldx" install "$@"

log_info "Installation complete! Upgrades later: git -C ${INSTALL_DIR} pull"
