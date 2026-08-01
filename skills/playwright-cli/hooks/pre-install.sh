#!/usr/bin/env bash
set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

log_info "Running pre-install hook for skill '${SKILL_NAME:-playwright-cli}'..."

# 1. Install playwright-cli via Homebrew if missing
if command -v playwright-cli &>/dev/null; then
    log_info "playwright-cli is already installed: $(command -v playwright-cli)"
else
    log_info "playwright-cli is not installed. Installing via Homebrew..."
    if command -v brew &>/dev/null; then
        brew install playwright-cli
    else
        fatal "Homebrew is required to install playwright-cli."
    fi
fi

# 2. Check for Microsoft Edge installation in /Applications/ or ~/Applications/
EDGE_SYS_APP="/Applications/Microsoft Edge.app"
EDGE_USER_APP="${HOME}/Applications/Microsoft Edge.app"

if [ -d "$EDGE_SYS_APP" ]; then
    log_info "Microsoft Edge browser is installed at '${EDGE_SYS_APP}'."
elif [ -d "$EDGE_USER_APP" ]; then
    log_info "Microsoft Edge browser is installed at '${EDGE_USER_APP}'."
elif command -v msedge &>/dev/null; then
    log_info "Microsoft Edge browser binary found in PATH: $(command -v msedge)"
else
    log_warn "Microsoft Edge browser was not detected in /Applications or ~/Applications."
    if command -v brew &>/dev/null; then
        log_info "Attempting to install Microsoft Edge via Homebrew Cask..."
        if brew install --cask microsoft-edge; then
            log_info "Successfully installed Microsoft Edge!"
        else
            log_warn "Failed to install Microsoft Edge via Homebrew Cask."
            log_warn "You can manually install it via: brew install --cask microsoft-edge"
            log_warn "Or download from: https://www.microsoft.com/edge"
        fi
    else
        log_warn "Homebrew not found. Please install Microsoft Edge manually from https://www.microsoft.com/edge"
    fi
fi

log_info "Pre-install hook completed for '${SKILL_NAME:-playwright-cli}'."
