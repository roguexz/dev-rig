#!/usr/bin/env bash
set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }
log_error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; }

log_info "Running pre-install hook for skill '${SKILL_NAME:-docling}'..."

if command -v docling &>/dev/null; then
    log_info "Docling CLI is already installed: $(command -v docling)"
else
    log_info "Docling CLI is not installed. Installing via uv tool..."

    if ! command -v uv &>/dev/null; then
        log_warn "'uv' CLI is not found."
        if command -v brew &>/dev/null; then
            log_info "Installing 'uv' via Homebrew..."
            brew install uv
        else
            log_info "Installing 'uv' via standalone installer..."
            curl -LsSf https://astral.sh/uv/install.sh | sh
            # Ensure ~/.cargo/bin or ~/.local/bin is in PATH for current session
            export PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:${PATH}"
        fi
    fi

    log_info "Running 'uv tool install docling'..."
    uv tool install docling
fi

log_info "Pre-install check completed successfully for '${SKILL_NAME:-docling}'."
