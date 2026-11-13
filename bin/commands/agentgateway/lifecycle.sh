# ldx-agentgateway module: install/uninstall/upgrade + chart hooks (prepare-support, prepare-values).
# Sourced by bin/commands/ldx-agentgateway; shared constants and helpers live in
# bin/commands/agentgateway/common.sh. Not executable on its own.
# Internal: create/update the CLI-owned resources the chart's Deployment
# references by name (config ConfigMap, Vault Agent ConfigMap, runtime
# Secret, extra CAs). Idempotent; run by 'ldx k8s' as the agentgateway
# pre-apply hook and by 'install' before the chart apply.
prepare_support() {
    require_command "kubectl"
    ldx_save_namespace agentgateway "$NAMESPACE"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    ensure_api_key
    apply_config
    apply_vault_agent_config
    create_extra_cas_configmap "$NAMESPACE"
}

# Internal: render the chart values (stdout). Logs go to stderr; the values
# file is consumed by 'ldx k8s'. The image follows the LIVE deployment when
# one exists, so 'ldx agentgateway upgrade' (kubectl set image) survives
# later reconciles; the pinned constant is only the initial value.
prepare_values() {
    exec 3>&1 1>&2

    local live_image="" host_aliases=""
    live_image=$(agentgateway_running_image 2>/dev/null) || true

    # Resolve auth.rd.localhost to Traefik's ClusterIP so the gateway reaches
    # Authelia through Traefik (Host header matches the OIDC issuer) without
    # relying on external DNS.
    local traefik_ip
    traefik_ip=$(get_traefik_cluster_ip)
    if [ -n "$traefik_ip" ]; then
        host_aliases="    - ip: \"${traefik_ip}\"
      hostnames: [\"auth.rd.localhost\"]"
        log_info "Configuring agentgateway to resolve auth.rd.localhost to Traefik (${traefik_ip})..."
    else
        log_warn "Could not determine Traefik ClusterIP; the gateway may not reach Authelia for OIDC."
    fi

    # Checksums of the CLI-owned ConfigMaps, rendered into pod annotations
    # (see chart): a config/models/templates change rolls the pods.
    local config_sha agent_sha
    config_sha=$(kubectl get configmap agentgateway-config -n "$NAMESPACE" \
        -o jsonpath='{.data}' 2>/dev/null | shasum -a 256 | awk '{print $1}') || true
    agent_sha=$(kubectl get configmap "$VAULT_AGENT_CONFIG_CM" -n "$NAMESPACE" \
        -o jsonpath='{.data}' 2>/dev/null | shasum -a 256 | awk '{print $1}') || true

    cat >&3 <<EOF
agentgatewayStack:
  image: ${live_image:-$AGENTGATEWAY_IMAGE}
  hostAliases:
${host_aliases:-"  []"}
  podAnnotations:
    checksum/config: "${config_sha:-none}"
    checksum/vault-agent-config: "${agent_sha:-none}"
EOF
}

install_agentgateway() {
    require_command "kubectl"

    ldx_save_namespace agentgateway "$NAMESPACE"

    # Vault role binding (SA -> MCP secrets policy); needs an unsealed Vault.
    ensure_vault_role

    # CLI-owned config/secret/agent-templates, then the static deployment via
    # the ldx-local-platform chart (service 'agentgateway'; prehook
    # agentgateway re-runs prepare_support and supplies hostAliases).
    prepare_support
    "${LDX_HOME}/bin/ldx" k8s up --services agentgateway

    log_info "agentgateway installation complete."
    log_info "agentgateway UI is accessible at: https://${AGENTGATEWAY_HOST}/ui"
    log_info "In-cluster DNS: http://agentgateway.${namespace}.svc.cluster.local:4000"
    if get_oidc_state; then
        log_info "Vault SSO is enabled for the UI (issuer: ${OIDC_ISSUER})."
    fi
    if [ -n "$(get_models_fragment)" ]; then
        log_info "Synced oMLX models are served on /v1 (re-run 'sync-omlx' to refresh)."
    fi
    log_info "MCP credentials are managed via Vault (add tools with 'ldx agentgateway mcp add')."
}

uninstall_agentgateway() {
    require_command "kubectl"

    local namespace="$NAMESPACE"

    log_info "Uninstalling agentgateway..."
    # Chart teardown (Deployment, Service, Ingress, ServiceAccount, PVC).
    "${LDX_HOME}/bin/ldx" k8s down --services agentgateway --purge-data

    # CLI-owned resources (not chart-managed by design: they carry dynamic
    # state assembled by sync-omlx / sso / mcp).
    kubectl delete configmap agentgateway-config -n "$namespace" --ignore-not-found
    kubectl delete configmap "$AGENTGATEWAY_MODELS_CM" -n "$namespace" --ignore-not-found
    kubectl delete configmap "$VAULT_AGENT_CONFIG_CM" -n "$namespace" --ignore-not-found
    kubectl delete secret "$AGENTGATEWAY_SECRET" -n "$namespace" --ignore-not-found

    # Delete MCP secrets from Vault.
    local tools
    tools=$(list_mcp_tools_in_vault)
    if [ -n "$tools" ]; then
        while IFS= read -r tool; do
            [ -n "$tool" ] || continue
            log_info "Deleting Vault secret for MCP tool '${tool}'..."
            vault_delete_mcp_secret "$tool"
        done <<< "$tools"
    fi

    # The virtual client key died with the Secret; drop the local cache entry.
    ldx_secret_delete agentgateway api_key
    rm -f "$AGENTGATEWAY_KEY_CACHE"

    log_info "agentgateway uninstall complete. The '${namespace}' namespace was not deleted."
}

# ---------------------------------------------------------------------------
# upgrade
# ---------------------------------------------------------------------------

# Image the running deployment specifies (empty if not installed).
agentgateway_running_image() {
    kubectl get deployment agentgateway -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[?(@.name=="agentgateway")].image}' 2>/dev/null || true
}

# Tag of the running image (e.g. 'v1.7.0'); empty when the deployment is absent.
agentgateway_running_tag() {
    local image
    image=$(agentgateway_running_image)
    [ -n "$image" ] || return 1
    printf '%s' "$image" | sed -n 's/.*:\(.*\)$/\1/p'
}

upgrade_agentgateway() {
    require_command "kubectl"

    local namespace="$NAMESPACE"
    local target="" dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                [ -z "$target" ] || { log_error "Unexpected argument: $1"; exit 1; }
                target="$1"
                shift
                ;;
        esac
    done

    local current_image current_tag
    current_image=$(agentgateway_running_image)
    if [ -z "$current_image" ]; then
        fatal "agentgateway is not installed. Run 'install' first."
    fi
    current_tag=$(agentgateway_running_tag)

    # Resolve the target image. A bare version gets a 'v' prefix; a fully
    # qualified image reference is used as-is. Omitting the version upgrades
    # to the pinned constant.
    local target_image
    if [ -z "$target" ]; then
        target_image="$AGENTGATEWAY_IMAGE"
        log_info "No version given; upgrading to pinned ${target_image}."
    elif printf '%s' "$target" | grep -q ':'; then
        target_image="$target"
    else
        case "$target" in
            v*) target_image="${AGENTGATEWAY_IMAGE_BASE}:${target}" ;;
            *)  target_image="${AGENTGATEWAY_IMAGE_BASE}:v${target}" ;;
        esac
    fi
    local target_tag
    target_tag=$(printf '%s' "$target_image" | sed -n 's/.*:\(.*\)$/\1/p')

    # Already at the target: no-op.
    if [ "$target_image" = "$current_image" ]; then
        log_info "agentgateway already at ${current_tag}; nothing to do."
        return 0
    fi

    log_info "Upgrade plan: ${current_tag} -> ${target_tag}"

    if $dry_run; then
        log_info "--dry-run: would set image to ${target_image} and roll the deployment; no changes applied."
        return 0
    fi

    log_info "Updating agentgateway image to ${target_tag}..."
    kubectl set image deployment/agentgateway agentgateway="${target_image}" -n "$namespace"

    rollout_agentgateway

    # Verify the rollout landed on the requested image.
    local new_image
    new_image=$(agentgateway_running_image)
    log_info "Running image: $(agentgateway_running_tag) (expected ${target_tag})"
    if [ "$new_image" != "$target_image" ]; then
        fatal "Upgrade did not complete: expected ${target_tag}, got $(agentgateway_running_tag). Check 'kubectl get pods -n ${namespace}'."
    fi

    log_info "Upgrade complete: agentgateway ${target_tag}."
    if get_oidc_state; then
        log_info "Vault SSO is enabled; log in at https://${AGENTGATEWAY_HOST}/ui and confirm it still works."
    fi
}
