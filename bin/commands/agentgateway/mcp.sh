# ldx-agentgateway module: mcp subcommand: Vault-backed MCP tool CRUD + admin API.
# Sourced by bin/commands/ldx-agentgateway; shared constants and helpers live in
# bin/commands/agentgateway/common.sh. Not executable on its own.

# ---------------------------------------------------------------------------
# mcp (MCP tool management with Vault-backed credentials)
# ---------------------------------------------------------------------------

# Helper: reach the gateway's admin API (no auth, bound to pod loopback)
# via kubectl port-forward. Returns the local URL.
gateway_admin_url() {
    local namespace="$NAMESPACE"
    local pod
    pod=$(kubectl get pods -n "$namespace" -l app=agentgateway -o 'jsonpath={.items[0].metadata.name}' 2>/dev/null) || true
    if [ -z "$pod" ]; then
        fatal "No agentgateway pod found in namespace '${namespace}'. Is it installed?"
    fi

    # Find a free local port for the port-forward.
    local port
    port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()')

    # Start port-forward in the background.
    kubectl port-forward -n "$namespace" "pod/${pod}" "${port}:15000" >/dev/null 2>&1 &
    local pf_pid=$!

    # Wait for the port-forward to be ready (up to 10s).
    local i=0
    while [ $i -lt 20 ]; do
        if curl -s "http://127.0.0.1:${port}/api/config/effective" >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
        i=$((i + 1))
    done

    echo "http://127.0.0.1:${port}"
    echo "$pf_pid"
}

# Cleanup function for the port-forward background process.
cleanup_port_forward() {
    if [ -n "${PORT_FORWARD_PID:-}" ]; then
        kill "$PORT_FORWARD_PID" 2>/dev/null || true
        wait "$PORT_FORWARD_PID" 2>/dev/null || true
    fi
}

# Creates or updates an MCP secret in Vault.
vault_write_mcp_secret() {
    local tool="$1"
    local token="$2"

    require_vault_unsealed

    local vault_namespace="$VAULT_NAMESPACE"
    local root_token
    root_token=$(vault_keys_json | jq -r .root_token)

    # Write the secret to Vault (KV v2).
    kubectl exec -i -n "$vault_namespace" vault-0 -- sh -s "$root_token" "$tool" "$token" <<'REMOTE_EOF' >/dev/null
root_token="$1"
tool="$2"
token="$3"
export VAULT_TOKEN="$root_token"

vault kv put "secret/mcp/${tool}" "token=${token}"
REMOTE_EOF
}

# Deletes an MCP secret from Vault.
vault_delete_mcp_secret() {
    local tool="$1"

    # Check if Vault is set up (root token exists). If not, there's nothing to delete.
    if ! vault_keys_json >/dev/null 2>&1; then
        return 0
    fi

    # Check if Vault is running and unsealed. If not, warn but don't fail
    # (the secret might not exist anyway, and we don't want to block uninstall).
    local vault_namespace="$VAULT_NAMESPACE"
    local phase
    phase=$(kubectl get pods vault-0 -n "$vault_namespace" -o 'jsonpath={..status.phase}' 2>/dev/null) || true
    if [ "$phase" != "Running" ]; then
        log_warn "Vault pod is not running; skipping secret deletion for '${tool}'."
        return 0
    fi

    local sealed
    sealed=$(kubectl exec -n "$vault_namespace" vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed 2>/dev/null) || true
    if [ "$sealed" != "false" ]; then
        log_warn "Vault is sealed; skipping secret deletion for '${tool}'."
        return 0
    fi

    local root_token
    root_token=$(vault_keys_json | jq -r .root_token)

    # Delete the secret metadata (which deletes all versions).
    kubectl exec -i -n "$vault_namespace" vault-0 -- sh -s "$root_token" "$tool" <<'REMOTE_EOF' >/dev/null
root_token="$1"
tool="$2"
export VAULT_TOKEN="$root_token"

vault kv metadata delete "secret/mcp/${tool}" 2>/dev/null || true
REMOTE_EOF
}

# Creates or updates an MCP target resource via the config resources API.
api_upsert_mcp_target() {
    local admin_url="$1"
    local tool="$2"
    local url="$3"
    local header_name="${4:-}"

    local json
    if [ -n "$header_name" ]; then
        # Custom header: use location to specify the header name with no prefix.
        # MCP targets use mcp.host (not http.url) and policies at the target level.
        json=$(jq -n \
            --arg id "$tool" \
            --arg name "$tool" \
            --arg url "$url" \
            --arg file "${MCP_CREDENTIALS_DIR}/${tool}.token" \
            --arg header "$header_name" \
            '{
              kind: "mcp.target",
              id: $id,
              value: {
                name: $name,
                mcp: { host: $url },
                policies: {
                  backendAuth: {
                    key: {
                      value: { file: $file },
                      location: {
                        header: {
                          name: $header,
                          prefix: ""
                        }
                      }
                    }
                  }
                }
              }
            }')
    else
        # Default: Authorization: Bearer <token> (location defaults to Authorization header)
        json=$(jq -n \
            --arg id "$tool" \
            --arg name "$tool" \
            --arg url "$url" \
            --arg file "${MCP_CREDENTIALS_DIR}/${tool}.token" \
            '{
              kind: "mcp.target",
              id: $id,
              value: {
                name: $name,
                mcp: { host: $url },
                policies: {
                  backendAuth: {
                    key: {
                      value: { file: $file }
                    }
                  }
                }
              }
            }')
    fi

    local http_code response_body
    response_body=$(curl -s -w '\n%{http_code}' -X PUT "${admin_url}/api/config/resources/mcp.target" \
        -H 'Content-Type: application/json' \
        -d "{\"resources\":[${json}]}")
    http_code=$(echo "$response_body" | tail -1)
    response_body=$(echo "$response_body" | sed '$d')

    if [ "$http_code" -ge 400 ] 2>/dev/null; then
        echo "$response_body"
        return 1
    fi
    echo "$response_body"
}

# Deletes an MCP target resource via the config resources API.
api_delete_mcp_target() {
    local admin_url="$1"
    local tool="$2"

    # First, get the resource ID for this tool.
    local response id
    response=$(curl -s "${admin_url}/api/config/resources/mcp.target")
    id=$(echo "$response" | jq -r --arg name "$tool" '.resources[] | select(.value.name == $name) | .id')

    if [ -z "$id" ] || [ "$id" = "null" ]; then
        return 0  # Not found; nothing to delete.
    fi

    curl -s -X DELETE "${admin_url}/api/config/resources/mcp.target/${id}"
}

# Lists MCP targets via the config resources API.
api_list_mcp_targets() {
    local admin_url="$1"

    curl -s "${admin_url}/api/config/resources/mcp.target"
}

# mcp add <name> --url <url> --token <token> [--header <header-name>]
mcp_add() {
    require_command "curl"
    require_command "jq"

    local tool="" url="" token="" header_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)
                url="$2"
                shift 2
                ;;
            --token)
                if [ "$2" = "-" ]; then
                    # Read token from stdin (avoids shell history).
                    token=$(cat)
                    shift 2
                else
                    token="$2"
                    shift 2
                fi
                ;;
            --header)
                header_name="$2"
                shift 2
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                if [ -z "$tool" ]; then
                    tool="$1"
                    shift
                else
                    log_error "Unexpected argument: $1"
                    show_help
                    exit 1
                fi
                ;;
        esac
    done

    if [ -z "$tool" ]; then
        fatal "Usage: ldx agentgateway mcp add <name> --url <url> [--token <token|->] [--header <name>]"
    fi
    if [ -z "$url" ]; then
        fatal "--url is required (the MCP server endpoint)."
    fi
    if [ -z "$token" ]; then
        read -rsp "Token for '${tool}' (credential value): " token || true
        echo ""
        [ -n "$token" ] || fatal "A token is required."
    fi

    # Validate the tool name (use as a path component and filename).
    if ! [[ "$tool" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        fatal "Tool name must contain only alphanumeric characters, hyphens, and underscores."
    fi

    # Validate the header name if provided.
    if [ -n "$header_name" ] && ! [[ "$header_name" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        fatal "Header name must contain only alphanumeric characters, hyphens, and underscores."
    fi

    log_info "Adding MCP tool '${tool}' (url: ${url})..."
    if [ -n "$header_name" ]; then
        log_info "  Using custom header: ${header_name}"
    else
        log_info "  Using default Authorization: Bearer header"
    fi

    # 1. Store the credential in Vault.
    log_info "Storing credential in Vault (secret/mcp/${tool})..."
    vault_write_mcp_secret "$tool" "$token"

    # 2. Regenerate the Vault Agent config (adds the template for this tool).
    #    This must happen before the restart so the Vault Agent sidecar creates
    #    the credential file when it starts.
    log_info "Updating Vault Agent configuration..."
    apply_vault_agent_config

    # 3. Restart the gateway so the Vault Agent sidecar creates the credential
    #    file. The gateway validates target policies on API writes, so the file
    #    must exist before we register the target.
    log_info "Restarting agentgateway (to create credential file)..."
    rollout_agentgateway

    # 4. Wait for the Vault Agent to create the credential file. The gateway
    #    container is distroless (no shell), so we can't check the file directly.
    #    The Vault Agent creates it on startup; give it a few seconds.
    log_info "Waiting for credential file to be created..."
    sleep 5

    # 5. Create the MCP target resource via the API (file now exists).
    log_info "Registering MCP target with the gateway..."
    local admin_url pf_pid
    read -r admin_url pf_pid < <(gateway_admin_url)
    PORT_FORWARD_PID="$pf_pid"
    trap cleanup_port_forward EXIT

    local response
    if ! response=$(api_upsert_mcp_target "$admin_url" "$tool" "$url" "$header_name"); then
        fatal "Failed to register MCP target (HTTP error): ${response}"
    fi
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        fatal "Failed to register MCP target: $(echo "$response" | jq -r '.error')"
    fi

    cleanup_port_forward
    trap - EXIT

    # 6. Re-apply the main config to update the route's targets list.
    #    In hybrid mode, file-owned routes and database-owned targets are not
    #    automatically merged, so the route must explicitly list its targets.
    log_info "Updating gateway route configuration..."
    apply_config

    # 7. Restart the gateway to pick up the new route config.
    log_info "Restarting agentgateway (to apply route config)..."
    rollout_agentgateway

    log_info "MCP tool '${tool}' added successfully."
    log_info "  - Credential stored in Vault (secret/mcp/${tool})"
    log_info "  - Target registered with the gateway (file: ${MCP_CREDENTIALS_DIR}/${tool}.token)"
    if [ -n "$header_name" ]; then
        log_info "  - Sent in header: ${header_name}"
    else
        log_info "  - Sent in Authorization: Bearer header"
    fi
    log_info "  - Harnesses can now use it via the gateway; they never see the credential."
}

# mcp list
mcp_list() {
    require_command "curl"
    require_command "jq"

    log_info "Listing MCP tools..."

    local admin_url pf_pid
    read -r admin_url pf_pid < <(gateway_admin_url)
    PORT_FORWARD_PID="$pf_pid"
    trap cleanup_port_forward EXIT

    local response
    response=$(api_list_mcp_targets "$admin_url")

    local count
    count=$(echo "$response" | jq '.resources | length')

    if [ "$count" = "0" ]; then
        echo "  (no MCP tools configured)"
    else
        printf "  %-30s %-50s %-10s\n" "NAME" "URL" "ID"
        printf "  %-30s %-50s %-10s\n" "----" "---" "--"
        echo "$response" | jq -r '.resources[] | "\(.value.name)\t\(.value.mcp.host // "\(.value.stdio.cmd // "stdio")")\t\(.id)"' |
            while IFS=$'\t' read -r name url id; do
                printf "  %-30s %-50s %-10s\n" "$name" "$url" "$id"
            done
    fi

    cleanup_port_forward
    trap - EXIT

    log_info "${count} MCP tool(s) configured."
}

# mcp remove <name>
mcp_remove() {
    require_command "curl"
    require_command "jq"

    local tool="$1"
    if [ -z "$tool" ]; then
        fatal "Usage: ldx agentgateway mcp remove <name>"
    fi

    log_info "Removing MCP tool '${tool}'..."

    # 1. Delete the credential from Vault.
    log_info "Deleting credential from Vault (secret/mcp/${tool})..."
    vault_delete_mcp_secret "$tool"

    # 2. Delete the MCP target resource via the API.
    log_info "Removing MCP target from the gateway..."
    local admin_url pf_pid
    read -r admin_url pf_pid < <(gateway_admin_url)
    PORT_FORWARD_PID="$pf_pid"
    trap cleanup_port_forward EXIT

    local response
    response=$(api_delete_mcp_target "$admin_url" "$tool")
    if echo "$response" | jq -e '.error' >/dev/null 2>&1; then
        log_warn "API error (target may not exist): $(echo "$response" | jq -r '.error')"
    fi

    # 3. Regenerate the Vault Agent config (removes the template for this tool).
    log_info "Updating Vault Agent configuration..."
    apply_vault_agent_config

    # 4. Re-apply the main config to update the route's targets list.
    log_info "Updating gateway route configuration..."
    apply_config

    # 5. Restart the gateway to pick up the new config.
    log_info "Restarting agentgateway..."
    rollout_agentgateway

    cleanup_port_forward
    trap - EXIT

    log_info "MCP tool '${tool}' removed."
}

# mcp rotate <name> --token <new-token>
mcp_rotate() {
    require_command "jq"

    local tool="" token=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token)
                if [ "$2" = "-" ]; then
                    # Read token from stdin (avoids shell history).
                    token=$(cat)
                    shift 2
                else
                    token="$2"
                    shift 2
                fi
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                if [ -z "$tool" ]; then
                    tool="$1"
                    shift
                else
                    log_error "Unexpected argument: $1"
                    show_help
                    exit 1
                fi
                ;;
        esac
    done

    if [ -z "$tool" ]; then
        fatal "Usage: ldx agentgateway mcp rotate <name> --token <new-token>"
    fi
    if [ -z "$token" ]; then
        read -rsp "New token for '${tool}': " token || true
        echo ""
        [ -n "$token" ] || fatal "A new token is required."
    fi

    log_info "Rotating credential for MCP tool '${tool}'..."

    # Update the secret in Vault. The Vault Agent detects the change and
    # refreshes the file automatically (no gateway restart needed).
    log_info "Updating credential in Vault (secret/mcp/${tool})..."
    vault_write_mcp_secret "$tool" "$token"

    log_info "Credential rotated. The Vault Agent will refresh the file automatically."
    log_info "(The gateway reads the file on each request, so the new credential takes effect immediately.)"
}

# mcp (top-level dispatcher)
mcp_command() {
    local subcommand="${1:-}"
    if [ $# -gt 0 ]; then
        shift
    fi

    case "$subcommand" in
        add)
            mcp_add "$@"
            ;;
        list)
            mcp_list "$@"
            ;;
        remove)
            mcp_remove "$@"
            ;;
        rotate)
            mcp_rotate "$@"
            ;;
        "")
            log_error "Usage: ldx agentgateway mcp <add|list|remove|rotate>"
            exit 1
            ;;
        *)
            log_error "Unknown mcp subcommand: $subcommand"
            log_error "Usage: ldx agentgateway mcp <add|list|remove|rotate>"
            exit 1
            ;;
    esac
}
