# ldx-vault module: setup/unseal/seal/uninstall, user + secrets-engine setup.
# Sourced by bin/commands/ldx-vault; shared helpers live in
# bin/commands/vault/common.sh. Not executable on its own.
setup_vault() {
    require_command "helm"
    require_command "kubectl"

    local namespace
    namespace="$(ldx_namespace k8s)"
    ldx_save_namespace vault "$namespace"

    # Cache the version before installing so it survives even if init is interrupted.
    record_vault_version "$VAULT_CHART_VERSION" "$(vault_app_version_for_chart "$VAULT_CHART_VERSION")"

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
    if ldx_secret_has vault init_json || [ -f "${VAULT_DIR}/keys.json" ]; then
        log_warn "Vault keys already exist (ldx/vault/init_json). Skipping initialization."
        log_info "If you need to re-initialize, delete the stored secret first (backend: $(ldx_secret_backend))."
    else
        init_dirs
        local init_json
        init_json=$(kubectl exec -n "$namespace" vault-0 -- vault operator init -format=json)
        ldx_secret_put vault init_json "$init_json"
        log_info "Vault initialized. Unseal keys and root token stored in $(ldx_secret_backend) storage (ldx/vault/init_json)"
    fi

    unseal_vault

    configure_default_user

    enable_secrets_vault

    log_info "Vault UI and API are accessible at: https://vault.rd.localhost"
    if [ "${DISABLE_USERPASS:-false}" != "true" ]; then
        log_info "You can login with Username: admin, Password: changeit"
    fi
    if [ -n "${OIDC_CLIENT_ID:-}" ] && [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
        log_info "OIDC authentication is enabled. You can log in via your Identity Provider (e.g. Google)."
    fi
}

unseal_vault() {
    require_command "kubectl"
    require_command "jq"

    local namespace
    namespace="$(ldx_namespace vault)"

    local keys_json
    keys_json=$(vault_keys_json 2>/dev/null) \
        || fatal "Vault keys not found (ldx/vault/init_json). Run 'install' first."

    local sealed
    sealed=$(kubectl exec -n "$namespace" vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed 2>/dev/null) || true
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

    local namespace
    namespace="$(ldx_namespace vault)"
    log_info "Configuring admin user and authentication methods..."

    local keys_json root_token
    keys_json=$(vault_keys_json 2>/dev/null) || {
        log_warn "Root token not found. Skipping user configuration."
        return
    }
    root_token=$(jq -r .root_token <<<"$keys_json")

    # We use a temporary shell script executed inside the pod to keep things clean
    cat <<EOF | kubectl exec -i -n "$namespace" vault-0 -- sh
        export VAULT_TOKEN="${root_token}"

        # Create an admin policy that has full permissions
        vault policy write admin - <<POLICY
path "*" {
  capabilities = ["create", "read", "update", "delete", "list", "sudo"]
}
POLICY

        # Always configure userpass unless DISABLE_USERPASS is true
        if [ "${DISABLE_USERPASS:-false}" != "true" ]; then
            if ! vault auth list | grep -q "userpass/"; then
                vault auth enable userpass
            fi
            # Create or update the admin user with the password 'changeit' and assign the admin policy
            vault write auth/userpass/users/admin password=changeit policies=admin

            # Give the admin entity profile metadata (full_name/email) so OIDC
            # providers that request the profile scope can render claims for
            # it. The login materializes the entity and its userpass alias;
            # VAULT_TOKEN must be unset for the login response to carry the
            # auth block, and the image has no jq, so parse with sed.
            unset VAULT_TOKEN
            admin_entity_id=\$(vault login -format=json -method=userpass username=admin password=changeit 2>/dev/null | sed -n 's/.*"entity_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
            export VAULT_TOKEN="${root_token}"
            # No "id" in the body: the path already carries it, and Vault warns when a
            # body repeats a parameter it takes from the URL.
            if [ -n "\$admin_entity_id" ]; then
                printf '{"name":"admin","metadata":{"full_name":"Administrator","email":"admin@rd.localhost"}}' | vault write identity/entity/id/\$admin_entity_id - >/dev/null
            fi

            # Shared OIDC profile scope: OIDC clients (e.g. agentgateway)
            # request scope=profile and Vault renders name/email from entity
            # metadata set above (or by 'create-user'). Missing metadata
            # renders as an empty claim, never an error.
            vault write identity/oidc/scope/profile \
                description="Profile information (name, email)" \
                template='{"name": {{identity.entity.metadata.full_name}}, "email": {{identity.entity.metadata.email}}}' >/dev/null
        else
            # If someone explicitly disables it later, we could optionally disable the auth path,
            # but for a dev script, it's safer to just skip creating/updating it.
            if vault auth list | grep -q "userpass/"; then
                vault auth disable userpass || true
            fi
        fi

        # Configure OIDC if credentials are provided
        if [ -n "${OIDC_CLIENT_ID:-}" ] && [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
            if ! vault auth list | grep -q "oidc/"; then
                vault auth enable oidc
            fi

            vault write auth/oidc/config \\
                oidc_discovery_url="https://accounts.google.com" \\
                oidc_client_id="${OIDC_CLIENT_ID:-}" \\
                oidc_client_secret="${OIDC_CLIENT_SECRET:-}" \\
                default_role="admin"

            vault write auth/oidc/role/admin \\
                bound_audiences="${OIDC_CLIENT_ID:-}" \\
                allowed_redirect_uris="https://vault.rd.localhost/ui/vault/auth/oidc/oidc/callback" \\
                allowed_redirect_uris="http://localhost:8250/oidc/callback" \\
                user_claim="sub" \\
                policies="admin"
        fi
EOF

    local auth_methods=""
    if [ "${DISABLE_USERPASS:-false}" != "true" ]; then
        auth_methods="Username/Password"
    fi
    if [ -n "${OIDC_CLIENT_ID:-}" ] && [ -n "${OIDC_CLIENT_SECRET:-}" ]; then
        if [ -n "$auth_methods" ]; then
            auth_methods="$auth_methods and OIDC"
        else
            auth_methods="OIDC"
        fi
    fi

    log_info "Vault configured successfully with ${auth_methods:-No} authentication."
}

# --- Vault API access ---------------------------------------------------------
# Pods reach Vault at http://vault.<namespace>.svc; host-side CLI calls go
# through the Traefik ingress instead. The certificate for it comes from
# 'ldx tls setup', whose wildcard covers *.rd.localhost, so the Go binary
# verifies it without -k.
VAULT_API_URL="https://vault.rd.localhost"
VAULT_ROOT_TOKEN=""

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
# Enables the KV v2 secrets engine (path: secret), the Kubernetes auth method,
# and the mcp-secrets-read policy. Idempotent: safe to re-run. Called by
# 'enable-secrets' and by 'install' for new installs.
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

    # --- Create the mcp-secrets-read policy ---
    # Grants read/list on the MCP secrets subtree. This is the minimal policy
    # the Vault Agent sidecar needs to read MCP credentials.
    cat <<POLICY | vault_cli policy write mcp-secrets-read - >/dev/null
path "secret/data/mcp/*" {
  capabilities = ["read", "list"]
}
path "secret/metadata/mcp/*" {
  capabilities = ["read", "list"]
}
POLICY
    log_info "Policy 'mcp-secrets-read' created."

    log_info "Vault secrets engine and auth method setup complete."
    log_info "  - KV v2 at 'secret' (MCP credentials go to secret/data/mcp/<name>/token)"
    log_info "  - Kubernetes auth (Vault Agent sidecars authenticate with their SA JWT)"
    log_info "  - Policy 'mcp-secrets-read' (minimal read access for the Vault Agent)"
}

# --- Authelia SSO ---------------------------------------------------------------
# Configures Vault's OIDC auth method to point at Authelia (deployed by 'ldx
# authelia install'). After this, Vault logins redirect to Authelia, which
# presents Touch ID (WebAuthn) after the initial password+enrollment setup.
# Userpass stays enabled as a fallback.
AUTHELIA_SECRETS_DIR="${CACHE_DIR}/authelia"
AUTHELIA_SECRETS_FILE="${AUTHELIA_SECRETS_DIR}/client_secrets"
AUTHELIA_HOST="auth.rd.localhost"

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

