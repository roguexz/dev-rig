#!/usr/bin/env bash

set -euo pipefail

# Global Configuration
export CACHE_DIR="${HOME}/.cache/local-dev"
export CERTS_DIR="${CACHE_DIR}/certs"
export VAULT_DIR="${CACHE_DIR}/vault"
export RD_KUBE_CONTEXT="rancher-desktop"
export LDX_CONFIG_DIR="${XDG_CONFIG_HOME:-${HOME}/.config}/ldx"
export LDX_CONFIG_FILE="${LDX_CONFIG_DIR}/config"

# Namespace tools deploy into unless overridden (see ldx_namespace).
LDX_DEFAULT_NAMESPACE="commons"

# --- Custom namespaces --------------------------------------------------------
# Tools resolve their namespace through ldx_namespace(), which honours, in
# order: the LDX_<TOOL>_NAMESPACE environment variable, the LDX_NAMESPACE
# environment variable, the same two keys in the local config file
# (~/.config/ldx/config), and finally the 'commons' default. Install paths
# call ldx_save_namespace() so later commands (uninstall, status, unseal, ...)
# find the deployment without re-specifying the namespace.

# Loads the local config file into shadow LDX_CFG_* variables. Lines are
# KEY=value; '#' starts a comment. Only LDX namespace keys are honoured. The
# values land in separate variables (not the LDX_* names themselves) so the
# resolver can keep environment variables above config, at every level.
ldx_load_config() {
    [ -f "$LDX_CONFIG_FILE" ] || return 0
    local line key value
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"   # namespaces contain no whitespace; simplifies parsing
        [ -n "$line" ] || continue
        key="${line%%=*}"
        [ "$key" != "$line" ] || continue   # line without '=', ignore
        value="${line#*=}"
        [ -n "$value" ] || continue
        case "$key" in
            LDX_NAMESPACE)
                export LDX_CFG_NAMESPACE="$value"
                ;;
            LDX_[A-Z]*_NAMESPACE)
                export "LDX_CFG_${key#LDX_}"="$value"
                ;;
        esac
    done < "$LDX_CONFIG_FILE"
}

# Rejects anything Kubernetes would refuse as a namespace (RFC 1123 label).
ldx_validate_namespace() {
    local ns="$1"
    if [ "${#ns}" -gt 63 ] || ! [[ "$ns" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        fatal "Invalid namespace '${ns}': use lowercase letters, digits and '-', start/end alphanumeric, max 63 chars."
    fi
}

# Echoes the namespace the given tool (e.g. 'vault', 'agentgateway') should
# use. Precedence: LDX_<TOOL>_NAMESPACE env, LDX_NAMESPACE env,
# LDX_<TOOL>_NAMESPACE config, LDX_NAMESPACE config, 'commons'.
ldx_namespace() {
    local tool_upper
    tool_upper="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    local var="LDX_${tool_upper}_NAMESPACE"
    local cfgvar="LDX_CFG_${tool_upper}_NAMESPACE"
    local ns="${!var:-${LDX_NAMESPACE:-${!cfgvar:-${LDX_CFG_NAMESPACE:-$LDX_DEFAULT_NAMESPACE}}}}"
    ldx_validate_namespace "$ns"
    printf '%s\n' "$ns"
}

# Records the tool's effective namespace in the config file (upserts the key,
# preserving comments and other entries) and exports it for this run.
ldx_save_namespace() {
    local tool_upper
    tool_upper="$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')"
    local key="LDX_${tool_upper}_NAMESPACE"
    local ns="$2"
    ldx_validate_namespace "$ns"

    mkdir -p "$LDX_CONFIG_DIR"
    local tmp="${LDX_CONFIG_FILE}.tmp.$$"
    if [ -f "$LDX_CONFIG_FILE" ]; then
        grep -v "^[[:space:]]*${key}=" "$LDX_CONFIG_FILE" > "$tmp" || true
    else
        : > "$tmp"
    fi
    printf '%s=%s\n' "$key" "$ns" >> "$tmp"
    mv "$tmp" "$LDX_CONFIG_FILE"
    export "$key=$ns"
}

ldx_load_config

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
