# ldx-agentgateway module: sso: Authelia OIDC wiring for the gateway UI.
# Sourced by bin/commands/ldx-agentgateway; shared constants and helpers live in
# bin/commands/agentgateway/common.sh. Not executable on its own.

# ---------------------------------------------------------------------------
# sso (Authelia OIDC)
# ---------------------------------------------------------------------------

sso_agentgateway() {
    require_command "kubectl"
    require_command "jq"
    require_command "curl"

    # Read the agentgateway client secret from the Authelia secret store
    # (populated by 'ldx authelia install'; migrates the legacy cache file).
    local agentgateway_client_secret
    agentgateway_client_secret=$(
        ldx_secret_get_kv authelia/client_secrets "$AUTHELIA_SECRETS_FILE" \
            AGENTGATEWAY_CLIENT_SECRET 2>/dev/null
    ) || true
    if [ -z "$agentgateway_client_secret" ]; then
        fatal "AGENTGATEWAY_CLIENT_SECRET not found. Run 'ldx authelia install' first."
    fi

    # Check that Authelia is running and its OIDC discovery endpoint responds
    local phase
    phase=$(kubectl get pods -n "$AUTHELIA_NAMESPACE" -l app.kubernetes.io/name=authelia -o 'jsonpath={..status.phase}' 2>/dev/null) || phase="NotFound"
    if [ "$phase" != "Running" ]; then
        fatal "Authelia is not running (pod phase: ${phase}). Run 'ldx authelia install' first."
    fi

    local discovery_url="https://${AUTHELIA_HOST}/.well-known/openid-configuration"
    if ! curl -sf "${discovery_url}" > /dev/null 2>&1; then
        fatal "Cannot reach Authelia OIDC discovery at ${discovery_url}. Is Traefik configured with TLS?"
    fi

    local issuer="https://${AUTHELIA_HOST}"
    local client_id="agentgateway"

    # Persist the OIDC client details plus a stable cookie-signing secret
    # (agentgateway requires OIDC_COOKIE_SECRET whenever oidc is configured;
    # keep it across re-runs so sessions survive).
    local cookie_secret
    cookie_secret=$(kubectl get secret "$AGENTGATEWAY_SECRET" -n "$NAMESPACE" -o jsonpath='{.data.OIDC_COOKIE_SECRET}' 2>/dev/null | base64 -d 2>/dev/null) || true
    if [ -z "$cookie_secret" ]; then
        cookie_secret=$(openssl rand -hex 32)
    fi
    put_secret \
        "OIDC_COOKIE_SECRET=${cookie_secret}" \
        "UI_CLIENT_SECRET=${agentgateway_client_secret}" \
        "OIDC_ISSUER=${issuer}" \
        "OIDC_CLIENT_ID=${client_id}"

    # Reconcile through the ldx platform chart: the prehook resolves
    # Traefik's ClusterIP for hostAliases and re-applies the CLI-owned
    # config/secret, so no direct manifest apply here.
    "${LDX_HOME}/bin/ldx" k8s up --services agentgateway

    log_info "Restarting agentgateway to enable OIDC..."
    rollout_agentgateway

    log_info "Authelia SSO enabled."
    log_info "UI login flow: https://${AGENTGATEWAY_HOST}/ui -> ${AUTHELIA_HOST} login"
    log_info "Authelia OIDC discovery: ${discovery_url}"
    log_info "After the first login, you will be prompted by Touch ID."
}
