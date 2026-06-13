#!/usr/bin/env bash

set -euo pipefail

# Global Configuration
export CACHE_DIR="${HOME}/.cache/local-dev"
export CERTS_DIR="${CACHE_DIR}/certs"
export VAULT_DIR="${CACHE_DIR}/vault"
export RD_KUBE_CONTEXT="rancher-desktop"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

fatal() {
    log_error "$1"
    exit 1
}

require_command() {
    local cmd="$1"
    # Use 'command -v' to check for the existence of the command binary in the PATH.
    # This correctly ignores shell functions or aliases with the same name.
    if ! command -v "$cmd" &> /dev/null; then
        fatal "Required command '$cmd' is not installed or not in PATH."
    fi
}

init_dirs() {
    mkdir -p "${CERTS_DIR}"
    mkdir -p "${VAULT_DIR}"
}

# --- Wrapper Functions ---
# By defining these as functions, they will intercept calls to 'kubectl' and 'helm'
# within the scripts that source this file, automatically applying the context.

kubectl() {
    # Verify the context exists before running the command to provide a clear error.
    # We use 'command kubectl' to ensure we call the binary, not this function.
    if ! command kubectl config get-contexts "$RD_KUBE_CONTEXT" &> /dev/null; then
        fatal "Kubernetes context '$RD_KUBE_CONTEXT' not found. Is Rancher Desktop running?"
    fi
    command kubectl --context="$RD_KUBE_CONTEXT" "$@"
}

helm() {
    # We use 'command helm' to ensure we call the binary, not this function.
    # Helm uses the KUBECONFIG context, so we can pass it using --kube-context
    if ! command kubectl config get-contexts "$RD_KUBE_CONTEXT" &> /dev/null; then
        fatal "Kubernetes context '$RD_KUBE_CONTEXT' not found. Is Rancher Desktop running?"
    fi
    command helm --kube-context="$RD_KUBE_CONTEXT" "$@"
}
