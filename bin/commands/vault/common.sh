# ldx-vault module: constants, key access, status probes, version cache.
# Sourced by bin/commands/ldx-vault; shared helpers live in
# bin/commands/vault/common.sh. Not executable on its own.
# (0.34.1 -> Vault 2.0.4). Never silently pull a newer chart; ldx vault
# upgrade handles version moves deliberately (snapshot + checks).
VAULT_CHART_VERSION="0.34.1"

source "${LDX_HOME}/bin/lib/common.sh"

# Vault operator init JSON (unseal keys + root token) lives in the host
# secret store as ldx/vault/init_json. Legacy installs kept it in
# ${VAULT_DIR}/keys.json; the whole file is imported on first read (blob,
# not KEY=VALUE) and removed after verification.
vault_keys_json() {
    ldx_secret_get_blob vault "${VAULT_DIR}/keys.json" init_json
}

# Helm values file that defines this rig's Vault deployment. Shared by setup
# and upgrade so an upgrade never relies on --reuse-values: chart 0.34.x added
# new value sections (server.httproute) whose templates blow up when the old
# release's values are reused without the new chart's defaults.
# See config/vault-values.yaml for the full values and rationale.
VAULT_HELM_VALUES="${CONFIG_DIR}/vault-values.yaml"

status_vault() {
    require_command "kubectl"
    require_command "jq"

    local namespace
    namespace="$(ldx_namespace vault)"

    # Check if pod exists
    local phase
    phase=$(kubectl get pods vault-0 -n "$namespace" -o 'jsonpath={..status.phase}' 2>/dev/null) || true

    if [ -z "$phase" ]; then
        log_info "Vault is not installed. Run 'install' to install it."
        return
    fi

    if [ "$phase" != "Running" ]; then
        log_warn "Vault pod is in '$phase' state (not Running)."
        return
    fi

    # Pod is running, check sealed status
    local sealed
    sealed=$(kubectl exec -n "$namespace" vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed 2>/dev/null) || true

    if [ "$sealed" = "true" ]; then
        log_warn "Vault is running but sealed. Run 'unseal' to unseal it."
    elif [ "$sealed" = "false" ]; then
        log_info "Vault is running and unsealed."
    else
        log_warn "Vault pod is Running but could not determine seal status."
    fi

    log_info "Access URL: https://vault.rd.localhost"
    log_info "In-cluster URL: http://vault.${namespace}.svc.cluster.local:8200"
}

# helm --wait names only the resource it gave up on. Say which pods are stuck and
# quote what the scheduler complained about, so a failed rollout needs no follow-up
# kubectl to understand. Informational: exit status stays with the caller.
report_unready_pods() {
    local namespace="$1"

    kubectl get pods -n "$namespace" --no-headers 2>/dev/null |
        awk '{split($2, r, "/"); if (r[1] + 0 < r[2] + 0) printf "  %s  %s (%s)\n", $1, $3, $2}' |
        { grep . || echo "  (nothing reports not-ready; check 'helm history' for a stale failure)"; }

    kubectl get events -n "$namespace" --sort-by=.lastTimestamp 2>/dev/null |
        awk '$1 == "Warning"' | tail -n 5 | sed 's/^/  /'
}

# Finds the Traefik Service ClusterIP so we can configure hostAliases in the
# Vault pod. This allows Vault to reach Authelia through Traefik (so the Host
# header matches the OIDC issuer) without relying on external DNS.
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


vault_cli() {
    VAULT_ADDR="$VAULT_API_URL" VAULT_TOKEN="$VAULT_ROOT_TOKEN" vault "$@"
}

# Loads the cached root token and requires a reachable, unsealed Vault.
# Reads `.sealed` as a raw boolean: jq's `//` treats `false` as absent, so
# `.sealed // empty` would report a healthy Vault as unreachable.
# Retries for up to 60 seconds to handle the case where Traefik isn't ready yet
# (e.g., during 'install' when the ingress is still being configured).
require_unsealed_vault() {
    local keys_json
    keys_json=$(vault_keys_json 2>/dev/null) \
        || fatal "Vault root token not found (ldx/vault/init_json). Run 'install' first."
    VAULT_ROOT_TOKEN=$(jq -r .root_token <<<"$keys_json")

    local sealed="" attempts=0
    while [ $attempts -lt 12 ]; do
        sealed=$(vault_cli status -format=json 2>/dev/null | jq -r '.sealed') || true
        case "$sealed" in
            false) return ;;
            true) fatal "Vault is sealed. Run 'unseal' first." ;;
        esac
        attempts=$((attempts + 1))
        if [ $attempts -lt 12 ]; then
            echo -n "."
            sleep 5
        fi
    done
    echo ""
    fatal "Cannot reach Vault at ${VAULT_API_URL} after 60s. Is 'ldx tls install' done and the cluster up?"
}


record_vault_version() {
    local chart="$1" app="$2" prev_chart="${3:-}" prev_app="${4:-}"
    init_dirs
    local file="${VAULT_DIR}/version.json" updated
    updated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ -f "$file" ] && jq -e . "$file" >/dev/null 2>&1; then
        [ -n "$prev_chart" ] || prev_chart=$(jq -r '.base_chart // empty' "$file")
        [ -n "$prev_app" ] || prev_app=$(jq -r '.base_app // empty' "$file")
    fi
    jq -n \
        --arg base_chart "$chart" --arg base_app "$app" \
        --arg chart "$chart" --arg app "$app" \
        --arg prev_chart "$prev_chart" --arg prev_app "$prev_app" \
        --arg updated "$updated" \
        '{base_chart: $base_chart, base_app: $base_app,
          chart: $chart, app: $app,
          previous_chart: (if $prev_chart == "" then null else $prev_chart end),
          previous_app: (if $prev_app == "" then null else $prev_app end),
          updated_at: $updated}' > "$file"
}

# Chart version of the installed helm release, e.g. "0.33.0" (empty if absent).
vault_release_chart() {
    helm list -n "$(ldx_namespace vault)" -o json 2>/dev/null \
        | jq -r '.[] | select(.name == "vault") | .chart' 2>/dev/null \
        | sed -n 's/^vault-//p'
}

# Status of the installed helm release ("deployed", "failed", ...).
vault_release_status() {
    helm list -n "$(ldx_namespace vault)" -o json 2>/dev/null \
        | jq -r '.[] | select(.name == "vault") | .status' 2>/dev/null
}

# Vault app version the running pod reports (empty if not running).
vault_live_app_version() {
    kubectl get pod vault-0 -n "$(ldx_namespace vault)" \
        -o jsonpath='{.spec.containers[?(@.name=="vault")].image}' 2>/dev/null \
        | sed -n 's/.*:\(.*\)$/\1/p'
}

# App version pinned by a given chart version (empty when unknown).
vault_app_version_for_chart() {
    helm show chart hashicorp/vault --version "$1" 2>/dev/null \
        | sed -n 's/^appVersion:[[:space:]]*//p' | tr -d '"' | head -1
}

# Storage backend declared in the generated Vault config: "raft" | "file".
vault_storage_type() {
    local type
    type=$(kubectl get configmap vault-config -n "$(ldx_namespace vault)" -o jsonpath='{.data.config}' 2>/dev/null \
        | sed -n 's/.*storage "\([a-z-]*\)".*/\1/p' | head -1)
    printf '%s' "${type:-file}"
}

