# ldx-vault module: sso: Authelia OIDC login for Vault.
# Sourced by bin/commands/ldx-vault; shared helpers live in
# bin/commands/vault/common.sh. Not executable on its own.
sso_vault() {
    require_command "kubectl"
    require_command "jq"
    require_command "curl"

    # Read the Vault client secret from the Authelia cache (created by 'ldx authelia install')
    local vault_client_secret
    # Host secret store (Keychain); the pre-Keychain file (KEY=VALUE lines)
    # is imported on first read.
    vault_client_secret=$(ldx_secret_get_kv "authelia/client_secrets" "$AUTHELIA_SECRETS_FILE" VAULT_CLIENT_SECRET 2>/dev/null) || true
    if [ -z "$vault_client_secret" ]; then
        fatal "VAULT_CLIENT_SECRET not found in ${AUTHELIA_SECRETS_FILE}."
    fi

    # Check that Authelia is running and its OIDC discovery endpoint responds
    local authelia_namespace
    authelia_namespace="$(ldx_namespace authelia)"
    local phase
    phase=$(kubectl get pods -n "$authelia_namespace" -l app.kubernetes.io/name=authelia -o 'jsonpath={..status.phase}' 2>/dev/null) || phase="NotFound"
    if [ "$phase" != "Running" ]; then
        fatal "Authelia is not running (pod phase: ${phase}). Run 'ldx authelia install' first."
    fi

    local discovery_url="https://${AUTHELIA_HOST}/.well-known/openid-configuration"
    if ! curl -sf "${discovery_url}" > /dev/null 2>&1; then
        fatal "Cannot reach Authelia OIDC discovery at ${discovery_url}. Is Traefik configured with TLS?"
    fi

    require_unsealed_vault

    local namespace
    namespace="$(ldx_namespace vault)"

    log_info "Configuring Vault OIDC auth method to use Authelia..."

    local authelia_external_url="https://${AUTHELIA_HOST}"

    # Read the CA from the ClusterTrustBundle (created by 'ldx certmanager install').
    # The PEM content is safe to embed in the heredoc (only base64 chars and newlines).
    local ca_pem=""
    ca_pem=$(kubectl get clustertrustbundle mkcert-ca -o jsonpath='{.spec.trustBundle}' 2>/dev/null || true)
    if [ -n "$ca_pem" ]; then
        log_info "Using mkcert root CA from ClusterTrustBundle for TLS verification."
    else
        log_warn "ClusterTrustBundle 'mkcert-ca' not found or empty. Vault may fail to verify Authelia's TLS certificate."
        log_warn "Run 'ldx certmanager install' first."
    fi

    # Run the Vault API calls inside the pod (same pattern as configure_default_user).
    # The image has no jq, so we avoid relying on it.
    cat <<EOF | kubectl exec -i -n "$namespace" vault-0 -- sh
        export VAULT_TOKEN="${VAULT_ROOT_TOKEN}"

        # Enable OIDC auth method if not already enabled
        if ! vault auth list | grep -q "oidc/"; then
            vault auth enable oidc
        fi

        # Use the external URL (base URL, without the discovery path) for the discovery
        # endpoint. Vault appends /.well-known/openid-configuration automatically.
        # All other endpoints use the full URL.
        #
        # The Vault pod resolves auth.rd.localhost to Traefik's ClusterIP via CoreDNS
        # (glibc queries DNS for .localhost, unlike musl which follows RFC 6761 strictly).
        # This ensures the Host header matches the OIDC issuer (Authelia validates it),
        # and the request goes through Traefik for proper TLS termination.
        #
        # CA certificates are passed as PEM content using the correct parameter names:
        # oidc_discovery_ca_pem for the discovery URL and jwks_ca_pem for the JWKS URL.
        if [ -n "${ca_pem}" ]; then
            vault write auth/oidc/config \\
                oidc_discovery_url="${authelia_external_url}" \\
                oidc_discovery_ca_pem="${ca_pem}" \\
                oidc_authorization_url="${authelia_external_url}/api/oidc/authorization" \\
                oidc_token_url="${authelia_external_url}/api/oidc/token" \\
                oidc_jwks_url="${authelia_external_url}/.well-known/jwks.json" \\
                jwks_ca_pem="${ca_pem}" \\
                oidc_client_id="vault" \\
                oidc_client_secret="${vault_client_secret}" \\
                default_role="admin"
        else
            vault write auth/oidc/config \\
                oidc_discovery_url="${authelia_external_url}" \\
                oidc_authorization_url="${authelia_external_url}/api/oidc/authorization" \\
                oidc_token_url="${authelia_external_url}/api/oidc/token" \\
                oidc_jwks_url="${authelia_external_url}/.well-known/jwks.json" \\
                oidc_client_id="vault" \\
                oidc_client_secret="${vault_client_secret}" \\
                default_role="admin"
        fi

        # Create role for Authelia logins. The email claim from Authelia maps to
        # the Vault entity. The admin entity has email admin@rd.localhost (set by
        # 'install'), which matches the Authelia admin user's email.
        #
        # oidc_scopes requests the email and profile scopes so Authelia includes
        # the email claim in the token (required by user_claim="email").
        vault write auth/oidc/role/admin \\
            bound_audiences="vault" \\
            allowed_redirect_uris="https://vault.rd.localhost/ui/vault/auth/oidc/oidc/callback" \\
            allowed_redirect_uris="http://localhost:8250/oidc/callback" \\
            user_claim="email" \\
            oidc_scopes="openid,email,profile" \\
            policies="admin"
EOF

    log_info "Vault OIDC login is now wired to Authelia."
    log_info "Open https://vault.rd.localhost and choose 'Authelia' (or 'OIDC') as the login method."
    log_info "After the first login, you will be prompted by Touch ID."
    log_info "Userpass (admin/changeit) remains available as a fallback."
}

# --- Version tracking ---------------------------------------------------------
# ${VAULT_DIR}/version.json records the chart/app version this workspace's
# setup pins and what the cluster actually runs, so later upgrades (or a
# downgrade) know the base. Written by setup and upgrade.
