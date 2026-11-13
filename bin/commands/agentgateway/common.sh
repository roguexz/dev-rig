# ldx-agentgateway module: constants, config assembly, Vault role, Vault Agent templates.
# Sourced by bin/commands/ldx-agentgateway; shared constants and helpers live in
# bin/commands/agentgateway/common.sh. Not executable on its own.

# Namespace agentgateway deploys into, and the namespace Vault lives in (the
# SSO flow reaches into it). Both honour LDX_AGENTGATEWAY_NAMESPACE /
# LDX_VAULT_NAMESPACE / LDX_NAMESPACE env vars and the local config; see
# lib/common.sh.
NAMESPACE="$(ldx_namespace agentgateway)"
VAULT_NAMESPACE="$(ldx_namespace vault)"

# Pinned agentgateway image (standalone distribution).
AGENTGATEWAY_IMAGE="cr.agentgateway.dev/agentgateway:v1.7.0"
# Image reference without the tag (used by 'upgrade' to build target images).
AGENTGATEWAY_IMAGE_BASE="cr.agentgateway.dev/agentgateway"
# Hostname (Traefik Ingress) the gateway and its UI are served on.
AGENTGATEWAY_HOST="agentgateway.rd.localhost"
# Secret holding runtime credentials (OIDC client secret, oMLX key).
AGENTGATEWAY_SECRET="agentgateway-secrets"
# ConfigMap holding the synced oMLX model list (fragment of the gateway config).
AGENTGATEWAY_MODELS_CM="agentgateway-llm-models"
# Virtual client key the gateway validates on inbound LLM requests (stored in
# the runtime Secret, cached locally for harness configs like opencode).
AGENTGATEWAY_API_KEY_NAME="AGENTGATEWAY_API_KEY"
AGENTGATEWAY_KEY_CACHE="${CACHE_DIR}/agentgateway/api_key"

# Vault Agent sidecar (reads MCP credentials from Vault, writes to shared files).
VAULT_AGENT_IMAGE="hashicorp/vault:2.0.4"
VAULT_MCP_ROLE="agentgateway-mcp"
VAULT_MCP_POLICY="mcp-secrets-read"
MCP_CREDENTIALS_DIR="/etc/agentgateway/mcp-credentials"
VAULT_AGENT_CONFIG_CM="agentgateway-vault-agent-config"

# Gateway Service Account (dedicated, bound to the Vault role).
AGENTGATEWAY_SA="agentgateway"

# Vault operator init JSON (root token + unseal keys): host secret store
# (Keychain), imported from the legacy cache file on first read.
vault_keys_json() {
    ldx_secret_get_blob vault "${VAULT_DIR}/keys.json" init_json
}

# Authelia OIDC provider (deployed by 'ldx authelia install').
AUTHELIA_HOST="auth.rd.localhost"
AUTHELIA_NAMESPACE="$(ldx_namespace authelia)"
AUTHELIA_PORT=9091
AUTHELIA_SECRETS_DIR="${CACHE_DIR}/authelia"
AUTHELIA_SECRETS_FILE="${AUTHELIA_SECRETS_DIR}/client_secrets"


# ---------------------------------------------------------------------------
# Config assembly helpers
# ---------------------------------------------------------------------------

# In-cluster Vault URL is referenced directly in the Vault Agent sidecar config
# (see render_vault_agent_config).

# Reads OIDC state (issuer + clientId) from the runtime Secret. Returns non-zero
# when SSO has not been configured.
get_oidc_state() {
    local issuer client_id
    issuer=$(kubectl get secret "$AGENTGATEWAY_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.OIDC_ISSUER}' 2>/dev/null | base64 -d 2>/dev/null) || true
    client_id=$(kubectl get secret "$AGENTGATEWAY_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.OIDC_CLIENT_ID}' 2>/dev/null | base64 -d 2>/dev/null) || true
    if [ -n "$issuer" ] && [ -n "$client_id" ]; then
        OIDC_ISSUER="$issuer"
        OIDC_CLIENT_ID="$client_id"
        return 0
    fi
    return 1
}

# Reads the virtual client API key from the runtime Secret. Returns non-zero
# when API-key enforcement has not been enabled.
get_api_key_state() {
    AGENTGATEWAY_API_KEY=$(kubectl get secret "$AGENTGATEWAY_SECRET" -n "$NAMESPACE" \
        -o jsonpath="{.data.${AGENTGATEWAY_API_KEY_NAME}}" 2>/dev/null | base64 -d 2>/dev/null) || true
    [ -n "$AGENTGATEWAY_API_KEY" ]
}

# Reads the synced oMLX models fragment (the `models:` list) from its ConfigMap.
get_models_fragment() {
    kubectl get configmap "$AGENTGATEWAY_MODELS_CM" -n "$NAMESPACE" -o jsonpath='{.data.models\.yaml}' 2>/dev/null || true
}

# Reads the synced oMLX provider fragment (the `providers:` map) from its ConfigMap.
get_providers_fragment() {
    kubectl get configmap "$AGENTGATEWAY_MODELS_CM" -n "$NAMESPACE" -o jsonpath='{.data.providers\.yaml}' 2>/dev/null || true
}

# Finds the Traefik Service ClusterIP so we can configure hostAliases in the
# gateway pod. This allows the gateway to reach Authelia through Traefik (so
# the Host header matches the OIDC issuer) without relying on external DNS.
get_traefik_cluster_ip() {
    local traefik_ns="" traefik_svc="" ip=""

    # Try common namespaces where Traefik might be deployed
    for ns in kube-system traefik ingress; do
        traefik_svc=$(kubectl get svc -n "$ns" -l app.kubernetes.io/name=traefik -o 'jsonpath={.items[0].metadata.name}' 2>/dev/null) || true
        if [ -n "$traefik_svc" ]; then
            traefik_ns="$ns"
            break
        fi
    done

    # If not found by label, try by name
    if [ -z "$traefik_svc" ]; then
        for ns in kube-system traefik ingress; do
            if kubectl get svc -n "$ns" traefik 2>/dev/null >/dev/null; then
                traefik_ns="$ns"
                traefik_svc="traefik"
                break
            fi
        done
    fi

    if [ -n "$traefik_ns" ] && [ -n "$traefik_svc" ]; then
        ip=$(kubectl get svc -n "$traefik_ns" "$traefik_svc" -o 'jsonpath={.spec.clusterIP}' 2>/dev/null) || true
    fi

    if [ -z "$ip" ] || [ "$ip" = "None" ]; then
        # Last resort: look for any Service with Type=LoadBalancer or the default TLS secret
        ip=$(kubectl get svc -A -o json 2>/dev/null | jq -r '.items[] | select(.spec.clusterIP != "None") | select(.metadata.name == "traefik" or .metadata.labels."app.kubernetes.io/name" == "traefik") | .spec.clusterIP' 2>/dev/null | head -1) || true
    fi

    printf '%s' "$ip"
}

# Lists registered MCP tool names from Vault (secret/mcp/<tool>). Returns one
# name per line. Used to populate the route's backend targets in hybrid mode,
# where file-owned routes and database-owned targets are not automatically merged.
list_mcp_tools_from_vault() {
    if ! vault_keys_json >/dev/null 2>&1; then
        return 0
    fi
    local vault_namespace="$VAULT_NAMESPACE"
    local root_token
    root_token=$(vault_keys_json 2>/dev/null | jq -r .root_token 2>/dev/null) || true
    if [ -z "$root_token" ]; then
        return 0
    fi
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/mcp-tools.XXXXXX")
    kubectl exec -i -n "$vault_namespace" vault-0 -- sh -s "$root_token" >"$tmpfile" 2>/dev/null <<'REMOTE_EOF'
root_token="$1"
export VAULT_TOKEN="$root_token"
vault kv list secret/mcp/ 2>/dev/null || true
REMOTE_EOF
    local rc=$?
    if [ $rc -ne 0 ]; then
        rm -f "$tmpfile"
        return 0
    fi
    if [ -s "$tmpfile" ]; then
        # vault kv list output: "Keys\n----\nname1\nname2\n" - extract lines after the separator.
        awk 'begin{skip=1} /^[^-]/ && NR>1 && $0 !~ /^Keys$/ {if(!skip) print; next} /^----$/ {skip=0}' "$tmpfile" | sort -u
    fi
    rm -f "$tmpfile"
}

# Generates YAML for the /mcp route's backend targets by querying the gateway's
# admin API for all registered mcp.target resources. In hybrid storage mode,
# file-owned routes and database-owned targets are not automatically merged, so
# the route must explicitly list the targets it should serve. Returns YAML list
# items (indented with 6 spaces) or an empty string if no targets are found.
get_mcp_targets_yaml() {
    local admin_url pf_pid
    read -r admin_url pf_pid < <(gateway_admin_url)
    PORT_FORWARD_PID="$pf_pid"
    trap cleanup_port_forward EXIT

    local api_key
    api_key=$(kubectl get secret "$AGENTGATEWAY_SECRET" -n "$NAMESPACE" \
        -o jsonpath="{.data.${AGENTGATEWAY_API_KEY_NAME}}" 2>/dev/null | base64 -d 2>/dev/null) || true
    if [ -z "$api_key" ]; then
        cleanup_port_forward
        return 0
    fi

    local response
    response=$(curl -s "${admin_url}/api/config/resources/mcp.target" \
        -H "Authorization: Bearer ${api_key}" 2>/dev/null) || true

    cleanup_port_forward

    # Parse the response and generate YAML for each target.
    echo "$response" | jq -r '
        .resources // []
        | .[]
        | .value
        | "      - name: \(.name)"
          + "\n        mcp:\n          host: \(.mcp.host)"
          + (if .policies and .policies.backendAuth then
                "\n        policies:\n          backendAuth:\n            key:\n              value:\n                file: \(.policies.backendAuth.key.value.file)"
                + (if .policies.backendAuth.key.location and .policies.backendAuth.key.location.header then
                      "\n              location:\n                header:\n                  name: \(.policies.backendAuth.key.location.header.name)"
                      + (if .policies.backendAuth.key.location.header.prefix != null then
                            "\n                  prefix: \"\(.policies.backendAuth.key.location.header.prefix)\""
                        else "" end)
                  else "" end)
            else "" end)
    ' 2>/dev/null || true
}

# Renders the full gateway config.yaml to stdout, preserving optional features
# that are already configured (Vault SSO, synced oMLX models).
#
# Uses the config template file for static structure and injects dynamic
# sections (OIDC policy, LLM routes, MCP targets) at marker positions.
#
# Note: literal agentgateway env-var references ($UI_CLIENT_SECRET, etc.) in
# the template are passed through as-is for agentgateway to expand from the
# pod environment.
render_config() {
    local oidc_section="" llm_section="" models_fragment=""
    if get_oidc_state; then
        oidc_section=$(cat <<EOF
  policies:
    oidc:
      issuer: https://${AUTHELIA_HOST}
      authorizationEndpoint: https://${AUTHELIA_HOST}/api/oidc/authorization
      tokenEndpoint: https://${AUTHELIA_HOST}/api/oidc/token
      jwks:
        url: https://${AUTHELIA_HOST}/jwks.json
      clientId: ${OIDC_CLIENT_ID}
      clientSecret: \$UI_CLIENT_SECRET
      redirectURI: https://${AGENTGATEWAY_HOST}/oauth/callback
      # Ask Authelia for standard scopes so the UI shows name/email.
      scopes:
      - openid
      - profile
      - email
      - groups
EOF
)
    fi

    models_fragment=$(get_models_fragment)
    providers_fragment=$(get_providers_fragment)
    # LLM routes are always authenticated with virtual client keys, even when
    # no models are synced. This makes the auth model consistent with MCP
    # routes and gives harnesses a clear 401 instead of a 404 when hitting
    # /v1 before models are available.
    if ! get_api_key_state; then
        fatal "No ${AGENTGATEWAY_API_KEY_NAME} in Secret '${AGENTGATEWAY_SECRET}'. Run 'ldx agentgateway api-key' (install does this automatically)."
    fi
    # Build the models line: use the synced fragment, or an empty list.
    local models_line
    if [ -n "$models_fragment" ]; then
        models_line="$models_fragment"
    else
        models_line="  models: []"
    fi
    # Build the providers line: use the synced fragment, or an empty list.
    local providers_line
    if [ -n "$providers_fragment" ]; then
        providers_line="$providers_fragment"
    else
        providers_line="  providers: []"
    fi
    # Virtual client keys: inbound requests must carry one of these in
    # 'Authorization: Bearer <key>'; the gateway swaps in the provider
    # key ($OMLX_API_KEY) before forwarding. The raw key stays in the
    # Secret; the config references it for env expansion.
    llm_section=$(cat <<EOF
llm:
  gateways:
  - default
${providers_line}
  policies:
    apiKey:
      mode: strict
      keys:
      - key: \$${AGENTGATEWAY_API_KEY_NAME}
        metadata:
          user: local
          name: Local Access
${models_line}
EOF
)

    # MCP endpoint is always secured with the same virtual client key as LLM
    # routes. We use the routing-based mode (not the simplified 'mcp' section)
    # so that the apiKey policy can be attached to the /mcp route. In hybrid
    # storage mode, file-owned routes and database-owned targets are not
    # automatically merged, so we explicitly list registered targets in the
    # route's backend by querying the gateway's admin API.
    if ! get_api_key_state; then
        fatal "No ${AGENTGATEWAY_API_KEY_NAME} in Secret '${AGENTGATEWAY_SECRET}'. Run 'ldx agentgateway api-key' (install/sync-omlx do this automatically)."
    fi
    local targets_yaml
    targets_yaml=$(get_mcp_targets_yaml)
    if [ -z "$targets_yaml" ]; then
        targets_yaml="      targets: []"
    else
        targets_yaml=$'      targets:\n'"${targets_yaml}"
    fi

    local rendered
    rendered=$(render_template "${CONFIG_DIR}/agentgateway-config.yaml.tpl" \
        API_KEY_NAME="$AGENTGATEWAY_API_KEY_NAME")
    rendered=$(inject_block "$rendered" "{{OIDC_SECTION}}" "$oidc_section")
    rendered=$(inject_block "$rendered" "{{LLM_SECTION}}" "$llm_section")
    inject_block "$rendered" "{{MCP_TARGETS}}" "$targets_yaml"
}

apply_config() {
    local config
    config=$(render_config)
    kubectl create configmap agentgateway-config -n "$NAMESPACE" \
        --from-literal=config.yaml="$config" \
        --dry-run=client -o yaml | kubectl apply -f -
}

# Restarts the deployment and waits for readiness.
rollout_agentgateway() {
    kubectl rollout restart deployment/agentgateway -n "$NAMESPACE"
    kubectl rollout status deployment/agentgateway -n "$NAMESPACE" --timeout=120s
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
    if ! kubectl patch secret "$AGENTGATEWAY_SECRET" -n "$NAMESPACE" \
        --type merge -p "{\"stringData\":${json}}" >/dev/null 2>&1; then
        local flags=()
        for kv in "${args[@]}"; do
            flags+=("--from-literal=$kv")
        done
        kubectl create secret generic "$AGENTGATEWAY_SECRET" -n "$NAMESPACE" "${flags[@]}"
    fi
}

# ---------------------------------------------------------------------------
# Vault role setup
# ---------------------------------------------------------------------------

# Check that Vault is running and unsealed. Fails with a helpful message if not.
require_vault_unsealed() {
    require_command "kubectl"
    require_command "jq"

    local vault_namespace="$VAULT_NAMESPACE"

    local phase
    phase=$(kubectl get pods vault-0 -n "$vault_namespace" -o 'jsonpath={..status.phase}' 2>/dev/null) || true
    [ "$phase" = "Running" ] || fatal "Vault pod is not running in namespace '${vault_namespace}'. Run 'ldx vault setup' first."

    local sealed
    sealed=$(kubectl exec -n "$vault_namespace" vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed 2>/dev/null) || true
    [ "$sealed" = "false" ] || fatal "Vault is sealed. Run 'ldx vault unseal' first."

    if ! vault_keys_json >/dev/null 2>&1; then
        fatal "Vault init keys not found (ldx/vault/init_json). Run 'ldx vault setup' first."
    fi
}

# Creates (or updates) the Vault role that allows the gateway's service account
# to authenticate to Vault and read MCP secrets. Runs inside the Vault pod
# using the root token (same pattern as the SSO setup).
ensure_vault_role() {
    require_vault_unsealed

    local vault_namespace="$VAULT_NAMESPACE"
    local gateway_namespace="$NAMESPACE"
    local root_token
    root_token=$(vault_keys_json | jq -r .root_token)

    # Check if the policy exists (created by 'ldx vault enable-secrets').
    local policy_check
    policy_check=$(kubectl exec -n "$vault_namespace" vault-0 -- sh -c \
        "VAULT_TOKEN='${root_token}' vault policy read ${VAULT_MCP_POLICY}" 2>/dev/null) || true
    if [ -z "$policy_check" ]; then
        fatal "Vault policy '${VAULT_MCP_POLICY}' not found. Run 'ldx vault enable-secrets' first."
    fi

    # Create/update the role. Binds the gateway's service account to the MCP
    # secrets policy. Token TTL is short-lived; the Vault Agent refreshes it.
    log_info "Configuring Vault role '${VAULT_MCP_ROLE}' for service account '${AGENTGATEWAY_SA}' in namespace '${gateway_namespace}'..."
    kubectl exec -i -n "$vault_namespace" vault-0 -- sh -s "$root_token" "$gateway_namespace" <<'REMOTE_EOF' >/dev/null
root_token="$1"
gateway_ns="$2"
export VAULT_TOKEN="$root_token"

vault write auth/kubernetes/role/agentgateway-mcp \
    bound_service_account_names="agentgateway" \
    bound_service_account_namespaces="$gateway_ns" \
    policies="mcp-secrets-read" \
    ttl="1h" \
    max_ttl="24h"
REMOTE_EOF

    log_info "Vault role '${VAULT_MCP_ROLE}' configured."
}

# ---------------------------------------------------------------------------
# Vault Agent sidecar
# ---------------------------------------------------------------------------

# Lists the MCP tool names stored in Vault (secret/data/mcp/<name>).
# Returns nothing if Vault is not running or sealed (graceful handling).
list_mcp_tools_in_vault() {
    # Check if the root token exists. If not, there are no tools.
    if ! vault_keys_json >/dev/null 2>&1; then
        return 0
    fi

    local vault_namespace="$VAULT_NAMESPACE"

    # Check if Vault is running. If not, return nothing.
    local phase
    phase=$(kubectl get pods vault-0 -n "$vault_namespace" -o 'jsonpath={..status.phase}' 2>/dev/null) || true
    if [ "$phase" != "Running" ]; then
        return 0
    fi

    # Check if Vault is unsealed. If not, return nothing.
    local sealed
    sealed=$(kubectl exec -n "$vault_namespace" vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed 2>/dev/null) || true
    if [ "$sealed" != "false" ]; then
        return 0
    fi

    local root_token
    root_token=$(vault_keys_json | jq -r .root_token)

    # List the metadata under secret/metadata/mcp/ to get tool names.
    # The response is a list of paths like "secret/metadata/mcp/<name>".
    # Append `|| true` so an empty list doesn't trigger `set -e`.
    kubectl exec -n "$vault_namespace" vault-0 -- sh -c \
        "VAULT_TOKEN='${root_token}' vault list secret/metadata/mcp/" 2>/dev/null |
        grep -v '^Keys$' | grep -v '^----$' | sed 's/[[:space:]]*$//' | sort || true
}

# Renders the Vault Agent config to stdout. The config authenticates via
# Kubernetes auth (using the pod's SA JWT) and creates one template block
# per MCP tool, each writing that tool's token to a separate file.
render_vault_agent_config() {
    local tools
    tools=$(list_mcp_tools_in_vault)

    cat <<EOF
# Vault Agent auto-auth + template config
vault {
  address = "http://vault.${VAULT_NAMESPACE}.svc.cluster.local:8200"
}

auto_auth {
  method "kubernetes" {
    config {
      role = "${VAULT_MCP_ROLE}"
      kubernetes_host = "https://kubernetes.default.svc:443"
    }
  }
  sink "file" {
    config {
      path = "/vault-agent/token"
    }
  }
}
EOF

    if [ -n "$tools" ]; then
        # One template block per tool.
        while IFS= read -r tool; do
            [ -n "$tool" ] || continue
            cat <<EOF

template {
  source = "/etc/vault-agent/config/template-${tool}.go.tpl"
  destination = "${MCP_CREDENTIALS_DIR}/${tool}.token"
  perms = "0400"
}
EOF
        done <<< "$tools"
    fi
}

# Renders the Go template for a single MCP tool.
render_mcp_tool_template() {
    local tool="$1"
    # Output just the token value without any trailing newline.
    # In KV v2, the secret response has data.data.token.
    printf '{{- with secret "secret/data/mcp/%s" }}{{ .Data.data.token }}{{- end }}\n' "$tool"
}

# Applies the Vault Agent ConfigMap (config.hcl + one Go template per tool).
# Uses temporary files for robust handling of multi-line content.
apply_vault_agent_config() {
    local config
    config=$(render_vault_agent_config)

    # Create a temporary directory for the config files.
    local tmpdir
    tmpdir=$(mktemp -d)

    # Clean up on exit (normal or error).
    local saved_trap
    saved_trap=$(trap -p EXIT)
    trap "rm -rf '${tmpdir}'; ${saved_trap:-true}" EXIT

    # Write the main config to a file.
    printf '%s\n' "$config" > "${tmpdir}/config.hcl"

    # Build the kubectl flags for creating the ConfigMap.
    local flags=(
        "--from-file=config.hcl=${tmpdir}/config.hcl"
    )

    # Write one template file per tool.
    local tools
    tools=$(list_mcp_tools_in_vault)
    if [ -n "$tools" ]; then
        local tool template
        while IFS= read -r tool; do
            [ -n "$tool" ] || continue
            template=$(render_mcp_tool_template "$tool")
            printf '%s\n' "$template" > "${tmpdir}/template-${tool}.go.tpl"
            flags+=("--from-file=template-${tool}.go.tpl=${tmpdir}/template-${tool}.go.tpl")
        done <<< "$tools"
    fi

    # Create the ConfigMap from the files.
    kubectl create configmap "$VAULT_AGENT_CONFIG_CM" -n "$NAMESPACE" \
        "${flags[@]}" \
        --dry-run=client -o yaml | kubectl apply -f -

    # Clean up the temporary directory.
    rm -rf "$tmpdir"

    # Restore the original EXIT trap.
    if [ -n "$saved_trap" ]; then
        eval "$saved_trap"
    else
        trap - EXIT
    fi
}



# Ensures a virtual client API key exists: reuses the stored key or generates
# and stores a fresh one, and keeps the local cache in sync. Does NOT apply the
# config or restart the gateway; callers decide when that happens.
ensure_api_key() {
    local key
    if get_api_key_state; then
        key="$AGENTGATEWAY_API_KEY"
    else
        key="agw-$(openssl rand -hex 24)"
        put_secret "${AGENTGATEWAY_API_KEY_NAME}=${key}"
        log_info "Generated a new virtual API key (stored in Secret '${AGENTGATEWAY_SECRET}')."
    fi

    # Cache for local harnesses (opencode) in the host secret store. The
    # legacy cache file is removed on migration; it's a bearer token.
    ldx_secret_put agentgateway api_key "$key"
    rm -f "$AGENTGATEWAY_KEY_CACHE"

    AGENTGATEWAY_API_KEY="$key"
}

# Prints the virtual client API key to stdout.
