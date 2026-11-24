# ldx-vault module: setup/unseal/seal/uninstall, user + secrets-engine setup.
# Sourced by bin/commands/ldx-vault; shared helpers live in
# bin/commands/vault/common.sh. Not executable on its own.
setup_vault() {
    require_command "helm"
    require_command "kubectl"
    require_command "jq"

    local namespace
    namespace="$(ldx_namespace k8s)"
    ldx_save_namespace vault "$namespace"

    # Cache the version before installing so it survives even if init is interrupted.
    record_vault_version "$VAULT_CHART_VERSION" "$(vault_app_version_for_chart "$VAULT_CHART_VERSION")"

    # Authelia is a hard dependency: userpass login is disabled, so users can
    # only sign in through OIDC. Fail early if Authelia is missing.
    local authelia_namespace
    authelia_namespace="$(ldx_namespace authelia)"
    local phase
    phase=$(kubectl get pods -n "$authelia_namespace" -l app.kubernetes.io/name=authelia -o 'jsonpath={..status.phase}' 2>/dev/null) || true
    if [ "$phase" != "Running" ]; then
        fatal "Authelia is required for Vault SSO (userpass login is disabled). Run 'ldx authelia install' first."
    fi

    # Read the Vault client secret from the host secret store (Keychain),
    # created by 'ldx authelia install'.
    local vault_client_secret
    vault_client_secret=$(ldx_secret_get "authelia/client_secrets" VAULT_CLIENT_SECRET 2>/dev/null) || true
    if [ -z "$vault_client_secret" ]; then
        fatal "VAULT_CLIENT_SECRET not found in the host secret store (ldx/authelia/client_secrets/*). Run 'ldx authelia install' first."
    fi

    # Deployment lives in the ldx-local-platform chart (release 'ldx', service
    # 'vault'): the chart is pinned there, values and the Traefik hostAlias are
    # supplied by 'ldx k8s', and a sealed vault is auto-unsealed afterwards.
    # Everything below is the one-time imperative initialization.
    "${LDX_HOME}/bin/ldx" k8s up --services vault

    log_info "Waiting for Vault pod to be created and running..."
    while [[ $(kubectl get pods vault-0 -n "$namespace" -o 'jsonpath={..status.phase}' 2>/dev/null) != "Running" ]]; do
        echo -n "."
        sleep 2
    done
    echo ""

    sleep 5

    log_info "Initializing Vault..."

    # Check the server's initialization state before deciding to skip init.
    # Stored keys can go stale when the cluster is recreated (PVCs wiped): the
    # keys on disk no longer match the fresh server, and skipping init would
    # leave unseal_vault failing with a bare 400 "Vault is not initialized".
    local initialized
    initialized=$(kubectl exec -n "$namespace" vault-0 -- vault status -format=json 2>/dev/null | jq -r .initialized 2>/dev/null) || true
    if [ "$initialized" != "true" ]; then
        if ldx_secret_has vault init_json || [ -f "${VAULT_DIR}/keys.json" ]; then
            log_warn "Stored Vault keys exist but the server is not initialized (.initialized=false)."
            log_warn "The stored keys are stale (from a previous, destroyed cluster). Re-initializing now."
        fi
        init_dirs
        local init_json
        init_json=$(kubectl exec -n "$namespace" vault-0 -- vault operator init -format=json)
        ldx_secret_put vault init_json "$init_json"
        # The legacy file holds the stale keys from the destroyed cluster;
        # remove it so it cannot be migrated back over the new keys.
        rm -f "${VAULT_DIR}/keys.json"
        log_info "Vault initialized. Unseal keys and root token stored in $(ldx_secret_backend) storage (ldx/vault/init_json)"
    else
        if ldx_secret_has vault init_json || [ -f "${VAULT_DIR}/keys.json" ]; then
            log_warn "Vault keys already exist (ldx/vault/init_json). Skipping initialization."
            log_info "If you need to re-initialize, delete the stored secret first (backend: $(ldx_secret_backend))."
        else
            fatal "Vault is initialized but no keys are stored (ldx/vault/init_json). Cannot unseal without the unseal keys."
        fi
    fi

    unseal_vault

    configure_default_user

    enable_secrets_vault

    log_info "Vault UI and API are accessible at: https://vault.rd.localhost"
    log_info "Login via Authelia SSO (userpass login is disabled)."
}

unseal_vault() {
    require_command "kubectl"
    require_command "jq"

    local namespace
    namespace="$(ldx_namespace vault)"

    local keys_json
    keys_json=$(vault_keys_json 2>/dev/null) \
        || fatal "Vault keys not found (ldx/vault/init_json). Run 'install' first."

    local status_json
    status_json=$(kubectl exec -n "$namespace" vault-0 -- vault status -format=json 2>/dev/null) || true

    local initialized
    initialized=$(jq -r .initialized <<<"$status_json" 2>/dev/null) || true
    if [ "$initialized" != "true" ]; then
        fatal "Vault is not initialized (.initialized=${initialized:-unknown}) but keys exist in the host secret store (ldx/vault/init_json).
The stored keys are stale (from a previous, destroyed cluster). Run 'ldx vault install' to re-initialize, or delete the stored keys first (backend: $(ldx_secret_backend))."
    fi

    local sealed
    sealed=$(jq -r .sealed <<<"$status_json" 2>/dev/null) || true
    if [ "$sealed" = "false" ]; then
        log_info "Vault is already unsealed."
        return
    fi

    log_info "Unsealing Vault..."

    jq -r .unseal_keys_b64[] <<<"$keys_json" | while read -r key; do
        kubectl exec -n "$namespace" vault-0 -- vault operator unseal "$key"
    done

    log_info "Vault unseal process complete."
}

configure_default_user() {
    require_command "kubectl"
    require_command "jq"
    require_command "curl"

    local namespace
    namespace="$(ldx_namespace vault)"
    log_info "Configuring Vault authentication (Authelia SSO only, userpass disabled)..."

    local keys_json root_token
    keys_json=$(vault_keys_json 2>/dev/null) || {
        log_warn "Root token not found. Skipping user configuration."
        return
    }
    root_token=$(jq -r .root_token <<<"$keys_json")

    # Read the Vault client secret from the host secret store (Keychain),
    # created by 'ldx authelia install'.
    local vault_client_secret
    vault_client_secret=$(ldx_secret_get "authelia/client_secrets" VAULT_CLIENT_SECRET 2>/dev/null) || true
    if [ -z "$vault_client_secret" ]; then
        fatal "VAULT_CLIENT_SECRET not found in the host secret store (ldx/authelia/client_secrets/*). Run 'ldx authelia install' first."
    fi

    local authelia_host="auth.rd.localhost"
    local authelia_external_url="https://${authelia_host}"

    # Check that Authelia is running and its OIDC discovery endpoint responds
    local authelia_namespace
    authelia_namespace="$(ldx_namespace authelia)"
    local phase
    phase=$(kubectl get pods -n "$authelia_namespace" -l app.kubernetes.io/name=authelia -o 'jsonpath={..status.phase}' 2>/dev/null) || phase="NotFound"
    if [ "$phase" != "Running" ]; then
        fatal "Authelia is not running (pod phase: ${phase}). Run 'ldx authelia install' first."
    fi

    local discovery_url="https://${authelia_host}/.well-known/openid-configuration"
    if ! check_oidc_discovery "${discovery_url}"; then
        fatal "Cannot reach Authelia OIDC discovery at ${discovery_url}. Is Traefik configured with TLS?"
    fi

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

    # We use a temporary shell script executed inside the pod to keep things clean
    cat <<EOF | kubectl exec -i -n "$namespace" vault-0 -- sh
        export VAULT_TOKEN="${root_token}"

        # Create an admin policy that has full permissions
        vault policy write admin - <<POLICY
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
POLICY

        # Disable userpass authentication. Users must sign in through OIDC
        # (Authelia), so a local password login is not offered.
        if vault auth list | grep -q "userpass/"; then
            vault auth disable userpass || true
        fi

        # Enable OIDC auth method pointing at Authelia
        if ! vault auth list | grep -q "oidc/"; then
            vault auth enable oidc
        fi

        # Use the external URL (base URL, without the discovery path) for the discovery
        # endpoint. Vault appends /.well-known/openid-configuration automatically.
        # All other endpoints use the full URL.
        #
        # The Vault pod resolves auth.rd.localhost to Traefik's ClusterIP via
        # hostAliases (set by 'ldx k8s'). This ensures the Host header matches
        # the OIDC issuer (Authelia validates it), and the request goes through
        # Traefik for proper TLS termination.
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
        # 'ldx authelia install'), which matches the Authelia admin user's email.
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

        # Shared OIDC profile scope: OIDC clients (e.g. Vault, Grafana)
        # request scope=profile and Vault renders name/email from entity
        # metadata. Missing metadata renders as an empty claim, never an error.
        vault write identity/oidc/scope/profile \\
            description="Profile information (name, email)" \\
            template='{"name": {{identity.entity.metadata.full_name}}, "email": {{identity.entity.metadata.email}}}' >/dev/null
EOF

    log_info "Vault configured successfully with Authelia SSO (userpass login disabled)."
}

# --- Vault API access ---------------------------------------------------------
# Pods reach Vault at http://vault.<namespace>.svc; host-side CLI calls go
# through the Traefik ingress instead. The certificate for it comes from
# 'ldx tls setup', whose wildcard covers *.rd.localhost, so the Go binary
# verifies it without -k.

# Address and token are passed explicitly, so an ambient VAULT_ADDR/VAULT_TOKEN
# in the caller's shell can never point these commands at another server.
create_user_vault() {
    require_command "jq"
    require_command "vault"

    local username="" password="" full_name="" email="" policies="default"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --password)
                password="$2"
                shift 2
                ;;
            --full-name)
                full_name="$2"
                shift 2
                ;;
            --email)
                email="$2"
                shift 2
                ;;
            --policies)
                policies="$2"
                shift 2
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                if [ -z "$username" ]; then
                    username="$1"
                    shift
                else
                    log_error "Unexpected argument: $1"
                    show_help
                    exit 1
                fi
                ;;
        esac
    done

    if [ -z "$username" ]; then
        fatal "Usage: ldx vault create-user <username> [--password <pass>] [--full-name <name>] [--email <email>] [--policies <list>]"
    fi

    if [ -z "$password" ]; then
        # `|| true`: with no TTY (CI, a pipe) read hits EOF and fails, and set -e
        # would drop out here without a word. An empty password is meaningful below.
        read -rsp "Password for '${username}' (unchanged if left empty): " password || true
        echo ""
    fi

    require_unsealed_vault

    log_info "Creating user '${username}' in Vault..."

    # Ensure userpass auth is enabled.
    if ! vault_cli read -format=json sys/auth | jq -e '.data | has("userpass/")' >/dev/null 2>&1; then
        vault_cli auth enable userpass >/dev/null
    fi

    # Ensure the shared OIDC `profile` scope exists (canonical owner: 'install';
    # this also repairs installs that predate it). Idempotent.
    vault_cli write identity/oidc/scope/profile \
        description="Profile information (name, email)" \
        template='{"name": {{identity.entity.metadata.full_name}}, "email": {{identity.entity.metadata.email}}}' >/dev/null

    # Create the user, or update it without touching the password when blank.
    if [ -n "$password" ]; then
        vault_cli write "auth/userpass/users/${username}" password="$password" policies="$policies" >/dev/null
    elif vault_cli read "auth/userpass/users/${username}" >/dev/null 2>&1; then
        vault_cli write "auth/userpass/users/${username}" policies="$policies" >/dev/null
    else
        fatal "user '${username}' does not exist and no --password was given."
    fi

    # A successful login both checks the password and makes Vault materialize the
    # entity and its userpass alias. -no-store keeps the caller's own token file.
    if [ -n "$password" ] &&
        ! vault_cli login -no-store -method=userpass username="$username" password="$password" >/dev/null 2>&1; then
        log_warn "Could not log in with the given password."
    fi

    local accessor entity_id
    accessor=$(vault_cli read -format=json sys/auth | jq -r '.data["userpass/"].accessor // empty')

    # Find the entity by its userpass alias. identity/lookup/entity is documented
    # as POST-only, but Vault answers the CLI's PUT as well, so the CLI covers
    # every identity call this command needs.
    entity_id=""
    if [ -n "$accessor" ]; then
        entity_id=$(vault_cli write -format=json -field=id identity/lookup/entity \
            alias_name="$username" alias_mount_accessor="$accessor" 2>/dev/null | tr -d '"') || true
    fi

    # Read-modify-write the entity so unrelated metadata keys survive (a PUT
    # replaces the whole map) and the entity name Vault assigned is kept.
    local entity_name="$username" current_meta='{}' metadata entity_json
    if [ -n "$entity_id" ]; then
        entity_json=$(vault_cli read -format=json "identity/entity/id/${entity_id}" 2>/dev/null) || true
        if [ -n "$entity_json" ]; then
            current_meta=$(jq -c '.data.metadata // {}' <<<"$entity_json")
            [ -n "$current_meta" ] || current_meta='{}'
            entity_name=$(jq -r '.data.name // empty' <<<"$entity_json")
            [ -n "$entity_name" ] || entity_name="$username"
        fi
    fi
    metadata=$(jq -cn \
        --argjson current "$current_meta" --arg full_name "$full_name" --arg email "$email" \
        '$current
         + (if $full_name == "" then {} else {full_name: $full_name} end)
         + (if $email == "" then {} else {email: $email} end)')

    if [ -n "$entity_id" ]; then
        # The id comes from the path, so it stays out of the body.
        jq -n --arg name "$entity_name" --argjson metadata "$metadata" \
            '{name: $name, metadata: $metadata}' \
            | vault_cli write "identity/entity/id/${entity_id}" - >/dev/null
    elif [ -n "$accessor" ] && [ "$metadata" != "{}" ]; then
        # Entity does not exist yet (user never logged in): create it with the
        # metadata and bind the userpass alias so the first login maps onto it.
        entity_id=$(jq -n --arg name "$username" --argjson metadata "$metadata" \
            '{name: $name, metadata: $metadata}' \
            | vault_cli write -format=json -field=id identity/entity - 2>/dev/null | tr -d '"') || true
        if [ -n "$entity_id" ]; then
            vault_cli write identity/entity-alias \
                name="$username" canonical_id="$entity_id" mount_accessor="$accessor" >/dev/null
        fi
    fi

    log_info "User '${username}' ready (policies: ${policies})."
    if [ -z "$entity_id" ]; then
        log_warn "No entity for '${username}' and nothing to store; metadata was left unchanged."
    elif [ -n "$full_name" ] || [ -n "$email" ]; then
        log_info "Entity: ${entity_id} (full_name: ${full_name:-unchanged}, email: ${email:-unchanged})"
        log_info "OIDC clients requesting the 'profile' scope will receive these as name/email claims."
    else
        log_info "Entity: ${entity_id}"
    fi
}

# --- Secrets engine and auth method setup -----------------------------------
# Enables the KV v2 secrets engine (path: secret) and the Kubernetes auth
# method. Idempotent: safe to re-run. Called by 'enable-secrets' and by
# 'install' for new installs.
enable_secrets_vault() {
    require_command "kubectl"
    require_command "jq"

    require_unsealed_vault

    local namespace
    namespace="$(ldx_namespace vault)"

    # --- Enable KV v2 secrets engine at 'secret' path ---
    # Check if it's already enabled (idempotent).
    if vault_cli secrets list -format=json 2>/dev/null | jq -e '.["secret/"]' >/dev/null 2>&1; then
        log_info "KV v2 secrets engine already enabled at 'secret'."
    else
        log_info "Enabling KV v2 secrets engine at 'secret'..."
        vault_cli secrets enable -path=secret -version=2 kv >/dev/null
        log_info "KV v2 secrets engine enabled at 'secret'."
    fi

    # --- Enable Kubernetes auth method ---
    # The Vault pod is in the cluster and can reach the API server at the
    # in-cluster DNS name. Skip TLS verification: Rancher Desktop uses a
    # self-signed cert that Vault does not trust.
    if vault_cli auth list -format=json 2>/dev/null | jq -e '.["kubernetes/"]' >/dev/null 2>&1; then
        log_info "Kubernetes auth method already enabled."
    else
        log_info "Enabling Kubernetes auth method..."
        vault_cli auth enable kubernetes >/dev/null
        vault_cli write auth/kubernetes/config \
            kubernetes_host="https://kubernetes.default.svc:443" \
            skip_tls_verify=true >/dev/null
        log_info "Kubernetes auth method enabled (host: https://kubernetes.default.svc:443)."
    fi

    log_info "Vault secrets engine and auth method setup complete."
    log_info "  - KV v2 at 'secret'"
    log_info "  - Kubernetes auth (pods authenticate with their SA JWT)"
}

# --- Authelia SSO ---------------------------------------------------------------
# Configures Vault's OIDC auth method to point at Authelia (deployed by 'ldx
# authelia install'). After this, Vault logins redirect to Authelia, which
# presents Touch ID (WebAuthn) after the initial password+enrollment setup.
# Userpass stays enabled as a fallback.

seal_vault() {
    require_command "kubectl"

    local namespace
    namespace="$(ldx_namespace vault)"
    log_info "Sealing Vault..."
    kubectl exec -n "$namespace" vault-0 -- vault operator seal
    log_info "Vault is now sealed."
}

uninstall_vault() {
    require_command "kubectl"

    # Deployment teardown via the platform release (removes the webhook
    # config and, with --purge-data, the PVC); keys are host-side.
    "${LDX_HOME}/bin/ldx" k8s down --services vault --purge-data

    log_info "Removing local Vault keys..."
    rm -rf "${VAULT_DIR}"
    ldx_secret_delete vault init_json

    log_info "Vault uninstall complete. The namespace was not deleted."
}

