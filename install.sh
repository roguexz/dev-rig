#!/usr/bin/env bash
#
# install.sh - Remote installer for ldx (Local Development Experience)
# Downloads the latest release tarball (or main branch source), unpacks to a temporary directory,
# executes 'ldx install', and cleans up.
#

set -euo pipefail

REPO="roguexz/dev-setup"

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }
fatal() { log_error "$1"; exit 1; }

TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'ldx-install')"
cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

log_info "Downloading latest source tarball for ${REPO}..."

# Determine download method (gh CLI if authenticated, else curl)
if command -v gh &>/dev/null && gh auth status &>/dev/null; then
  RELEASE_TAG="$(gh api "repos/${REPO}/releases/latest" --jq '.tag_name' 2>/dev/null || true)"
  if [ -n "$RELEASE_TAG" ] && [ "$RELEASE_TAG" != "null" ] && [[ "$RELEASE_TAG" != *"Not Found"* ]]; then
    log_info "Found release: ${RELEASE_TAG}"
    gh api "repos/${REPO}/tarball/${RELEASE_TAG}" | tar -xz -C "$TMP_DIR"
  else
    log_info "No published release found. Downloading latest 'main' branch..."
    gh api "repos/${REPO}/tarball/main" | tar -xz -C "$TMP_DIR"
  fi
else
  AUTH_HEADER=()
  [ -n "${GITHUB_TOKEN:-}" ] && AUTH_HEADER=(-H "Authorization: token ${GITHUB_TOKEN}")

  RELEASE_TARBALL="$(curl -fsSL "${AUTH_HEADER[@]}" "https://api.github.com/repos/${REPO}/releases/latest" 2>/dev/null | grep '"tarball_url"' | cut -d '"' -f 4 || true)"
  if [ -n "$RELEASE_TARBALL" ]; then
    curl -fsSL "${AUTH_HEADER[@]}" -L "$RELEASE_TARBALL" | tar -xz -C "$TMP_DIR"
  else
    log_info "No published release found. Downloading latest 'main' branch..."
    curl -fsSL "${AUTH_HEADER[@]}" -L "https://api.github.com/repos/${REPO}/tarball/main" | tar -xz -C "$TMP_DIR"
  fi
fi

# Locate unpacked executable
INSTALL_CMD="$(find "$TMP_DIR" -type f \( -name "ldx" -o -name "dev-setup" \) 2>/dev/null | head -n 1 || true)"

if [ -z "$INSTALL_CMD" ]; then
  fatal "Could not locate 'ldx' binary in extracted source files."
fi

UNPACKED_BIN_DIR="$(dirname "$INSTALL_CMD")"
chmod +x "$UNPACKED_BIN_DIR"/*

log_info "Invoking installer..."
"$INSTALL_CMD" install "$@"

log_info "Installation complete! Cleaned up temporary directory."
