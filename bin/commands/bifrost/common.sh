# ldx-bifrost module: constants, config assembly.
# Sourced by bin/commands/ldx-bifrost; shared constants and helpers live in
# bin/commands/bifrost/common.sh. Not executable on its own.

# Namespace bifrost deploys into. Honours LDX_BIFROST_NAMESPACE /
# LDX_NAMESPACE env vars and the local config; see lib/common.sh.
NAMESPACE="$(ldx_namespace bifrost)"

# Pinned bifrost image.
BIFROST_IMAGE="maximhq/bifrost:v2.6.0"
# Image reference without the tag (used by 'upgrade' to build target images).
BIFROST_IMAGE_BASE="maximhq/bifrost"
# Hostname (Traefik Ingress) the gateway and its UI are served on.
BIFROST_HOST="bifrost.rd.localhost"
# Secret holding runtime credentials (admin username/password, oMLX key,
# virtual client key, encryption key).
BIFROST_SECRET="bifrost-secrets"
# ConfigMap holding the synced oMLX provider config (fragment of the gateway
# config).
BIFROST_PROVIDERS_CM="bifrost-providers"
# Virtual client key the gateway validates on inbound LLM requests (stored in
# the runtime Secret, cached locally for harness configs like opencode).
BIFROST_VK_NAME="BIFROST_VK_OPENCODE"
BIFROST_KEY_CACHE="${CACHE_DIR}/bifrost/api_key"

# Gateway Service Account (dedicated).
BIFROST_SA="bifrost"

# ---------------------------------------------------------------------------
# Config assembly helpers
# ---------------------------------------------------------------------------

# Reads the synced oMLX providers fragment from its ConfigMap.
get_providers_fragment() {
    kubectl get configmap "$BIFROST_PROVIDERS_CM" -n "$NAMESPACE" -o jsonpath='{.data.providers\.json}' 2>/dev/null || true
}

# Reads the virtual client API key from the runtime Secret. Returns non-zero
# when API-key enforcement has not been enabled.
get_api_key_state() {
    BIFROST_API_KEY=$(kubectl get secret "$BIFROST_SECRET" -n "$NAMESPACE" \
        -o jsonpath="{.data.${BIFROST_VK_NAME}}" 2>/dev/null | base64 -d 2>/dev/null) || true
    [ -n "$BIFROST_API_KEY" ]
}

# Assembles the gateway config. Raw materials are collected here with
# kubectl; the text assembly (sections, template markers) is done with jq.
render_config() {
    # LLM routes always require a virtual client key; enforcement is strict.
    if ! get_api_key_state; then
        fatal "No ${BIFROST_VK_NAME} in Secret '${BIFROST_SECRET}'. Run 'ldx bifrost api-key' (install does this automatically)."
    fi

    require_command "jq"

    local providers_fragment
    providers_fragment=$(get_providers_fragment)
    if [ -z "$providers_fragment" ]; then
        # No providers synced yet; use an empty object.
        providers_fragment="{}"
    fi

    require_command "python3"

    # Inject the providers section at the {{PROVIDERS_SECTION}} marker using
    # Python for reliable multi-line string substitution.
    TEMPLATE_PATH="${CONFIG_DIR}/bifrost-config.json.tpl" \
    PROVIDERS_FRAGMENT="$providers_fragment" \
    python3 -c '
import sys, os
template_path = os.environ["TEMPLATE_PATH"]
fragment = os.environ["PROVIDERS_FRAGMENT"]
with open(template_path) as f:
    template = f.read()
template = template.replace("{{PROVIDERS_SECTION}}", fragment)
sys.stdout.write(template)
'
}

apply_config() {
    local config
    config=$(render_config)
    kubectl create configmap bifrost-config -n "$NAMESPACE" \
        --from-literal=config.json="$config" \
        --dry-run=client -o yaml | kubectl apply -f -
}

# Restarts the deployment and waits for readiness.
rollout_bifrost() {
    kubectl rollout restart deployment/bifrost -n "$NAMESPACE"
    kubectl rollout status deployment/bifrost -n "$NAMESPACE" --timeout=120s
}

# Upserts the shared runtime Secret with the given key=value pairs, preserving
# existing keys and creating the Secret if needed. Uses a merge patch so keys
# set by other subcommands survive.
put_secret() {
    local args=("$@")
    local json="{}"
    local kv
    for kv in "$@"; do
        json=$(jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + {($k): $v}' <<<"$json")
    done
    if ! kubectl patch secret "$BIFROST_SECRET" -n "$NAMESPACE" \
        --type merge -p "{\"stringData\":${json}}" >/dev/null 2>&1; then
        local flags=()
        for kv in "${args[@]}"; do
            flags+=("--from-literal=$kv")
        done
        kubectl create secret generic "$BIFROST_SECRET" -n "$NAMESPACE" "${flags[@]}"
    fi
}

# Ensures an encryption key exists: reuses the stored key or generates
# and stores a fresh one. Does NOT apply the config or restart the gateway;
# callers decide when that happens.
ensure_encryption_key() {
    local key
    key=$(ldx_secret_get bifrost encryption_key 2>/dev/null) || true
    if [ -z "$key" ]; then
        key=$(openssl rand -base64 32)
        ldx_secret_put bifrost encryption_key "$key"
        log_info "Generated a new encryption key (stored in keychain: ldx/bifrost/encryption_key)."
    fi
    put_secret "BIFROST_ENCRYPTION_KEY=${key}"
}

# Ensures admin credentials exist: generates a random username/password on
# first install, stores them in the keychain and the runtime Secret.
ensure_admin_credentials() {
    local username password
    username=$(ldx_secret_get bifrost admin_username 2>/dev/null) || true
    password=$(ldx_secret_get bifrost admin_password 2>/dev/null) || true

    if [ -z "$username" ] || [ -z "$password" ]; then
        username="admin"
        password=$(openssl rand -base64 24)
        ldx_secret_put bifrost admin_username "$username"
        ldx_secret_put bifrost admin_password "$password"
        log_info "Generated admin credentials (stored in keychain: ldx/bifrost/admin_*)."
        log_info "Run 'ldx bifrost admin-password' to print the password."
    fi

    put_secret "BIFROST_ADMIN_USERNAME=${username}"
    put_secret "BIFROST_ADMIN_PASSWORD=${password}"
}

# Ensures a virtual client API key exists: reuses the stored key or generates
# and stores a fresh one, and keeps the local cache in sync. Does NOT apply the
# config or restart the gateway; callers decide when that happens.
ensure_api_key() {
    local key
    if get_api_key_state; then
        key="$BIFROST_API_KEY"
    else
        key="sk-bf-$(openssl rand -hex 24)"
        put_secret "${BIFROST_VK_NAME}=${key}"
        log_info "Generated a new virtual API key (stored in Secret '${BIFROST_SECRET}')."
    fi

    # Cache for local harnesses (opencode) in the host secret store. The
    # legacy cache file is removed on migration; it's a bearer token.
    ldx_secret_put bifrost api_key "$key"
    rm -f "$BIFROST_KEY_CACHE"

    BIFROST_API_KEY="$key"
}

# Prints the virtual client API key to stdout.
print_api_key() {
    get_api_key_state || fatal "No ${BIFROST_VK_NAME} in Secret '${BIFROST_SECRET}'. Run 'ldx bifrost api-key' first."
    echo "$BIFROST_API_KEY"
}

# Prints the admin password to stdout (read from the keychain).
print_admin_password() {
    local password
    password=$(ldx_secret_get bifrost admin_password 2>/dev/null) || true
    if [ -z "$password" ]; then
        fatal "No admin password in keychain (ldx/bifrost/admin_password). Run 'ldx bifrost install' first."
    fi
    echo "$password"
}
