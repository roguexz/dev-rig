# ldx-agentgateway module: status subcommand (read-only overview).
# Sourced by bin/commands/ldx-agentgateway; shared constants and helpers live
# in bin/commands/agentgateway/common.sh. Not executable on its own.

# Masks a secret for display: shows a short prefix so a cached value can be
# recognized, never the whole key.
mask_key() {
    local k="$1"
    [ -n "$k" ] || { printf '(empty)'; return; }
    printf '%s…(%d chars)' "${k:0:8}" "${#k}"
}

status_agentgateway() {
    require_command "kubectl"
    require_command "jq"

    local deploy
    deploy=$(kubectl get deployment agentgateway -n "$NAMESPACE" -o json 2>/dev/null) || deploy=""
    if [ -z "$deploy" ]; then
        log_warn "agentgateway is not deployed in namespace '${NAMESPACE}'. Run 'install' first."
        return 1
    fi

    log_info "Namespace: ${NAMESPACE}"
    log_info "URL:       https://${AGENTGATEWAY_HOST} (UI /ui, LLM /v1, MCP /mcp)"

    # Deployment: replicas, image (the live tag - 'upgrade' moves it without
    # touching the chart pin), per-container readiness (gateway + sidecar).
    local ready total image
    ready=$(jq -r '.status.readyReplicas // 0' <<<"$deploy")
    total=$(jq -r '.spec.replicas // 1' <<<"$deploy")
    image=$(jq -r '.spec.template.spec.containers[0].image' <<<"$deploy")
    log_info "Deployment: ${ready}/${total} ready, image ${image}"

    local containers
    containers=$(kubectl get pods -n "$NAMESPACE" -l app=agentgateway \
        -o jsonpath='{.items[0].status.containerStatuses[*].name}' 2>/dev/null) || true
    local cstates
    cstates=$(kubectl get pods -n "$NAMESPACE" -l app=agentgateway \
        -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null) || true
    if [ -n "$containers" ]; then
        local -a cnames creads
        read -r -a cnames <<<"$containers"
        read -r -a creads <<<"$cstates"
        local line="" i
        for i in "${!cnames[@]}"; do
            line+="${cnames[$i]}=${creads[$i]:-unknown} "
        done
        log_info "Containers: ${line% }"
    fi

    # SSO: the OIDC wiring lives in the runtime Secret (set by 'sso').
    if get_oidc_state; then
        log_info "SSO:     enabled (issuer ${OIDC_ISSUER}, client '${OIDC_CLIENT_ID}')"
    else
        log_info "SSO:     not configured (run 'sso' to wire Authelia login)"
    fi

    # Virtual client key the gateway enforces on inbound LLM/MCP requests.
    if get_api_key_state; then
        log_info "API key: set $(mask_key "$AGENTGATEWAY_API_KEY")"
    else
        log_warn "API key: missing in the cluster Secret (run 'api-key')"
    fi

    # Models synced from oMLX (the merged config fragment).
    local models count
    models=$(get_models_fragment)
    count=$(printf '%s\n' "$models" | grep -c '^[[:space:]]*- name:' || true)
    if [ "${count:-0}" -gt 0 ]; then
        log_info "Models:  ${count} synced from oMLX (run 'sync-omlx' to refresh)"
    else
        log_info "Models:  none synced (run 'sync-omlx')"
    fi

    # MCP tools registered in Vault (graceful when Vault is sealed/absent).
    local tools tcount
    tools=$(list_mcp_tools_in_vault)
    tcount=$(printf '%s\n' "$tools" | grep -c . || true)
    if [ "${tcount:-0}" -gt 0 ]; then
        log_info "MCP:     ${tcount} tool(s): $(printf '%s' "$tools" | tr '\n' ' ' | sed 's/ $//')"
    else
        log_info "MCP:     no tools registered (run 'mcp add <name> --url <url>')"
    fi
}
