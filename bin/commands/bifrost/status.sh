# ldx-bifrost module: status: deployment state.
# Sourced by bin/commands/ldx-bifrost; shared constants and helpers live in
# bin/commands/bifrost/common.sh. Not executable on its own.

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

status_bifrost() {
    require_command "kubectl"

    local namespace="$NAMESPACE"

    # Check if the deployment exists.
    local deployment_exists=false
    if kubectl get deployment bifrost -n "$namespace" >/dev/null 2>&1; then
        deployment_exists=true
    fi

    echo "Bifrost status (namespace: ${namespace})"
    echo "----------------------------------------"

    if [ "$deployment_exists" = true ]; then
        echo "Deployment:  installed"
        local ready
        ready=$(kubectl get deployment bifrost -n "$namespace" -o jsonpath='{.status.readyReplicas}' 2>/dev/null) || true
        local desired
        desired=$(kubectl get deployment bifrost -n "$namespace" -o jsonpath='{.spec.replicas}' 2>/dev/null) || true
        echo "Replicas:    ${ready:-0}/${desired:-0} ready"

        local image
        image=$(bifrost_running_image)
        echo "Image:       ${image:-unknown}"
    else
        echo "Deployment:  not installed (run 'ldx bifrost install')"
    fi

    echo ""
    # Admin auth
    local admin_user
    admin_user=$(bifrost_credential_get USERNAME 2>/dev/null) || true
    if [ -n "$admin_user" ]; then
        echo "Credentials:   ${admin_user} : 'ldx bifrost admin-password'"
    else
        echo "Credentials:   not configured"
    fi

    # API key
    if get_api_key_state; then
        echo "API key:       configured (run 'ldx bifrost api-key print' to see it)"
    else
        echo "API key:       not configured"
    fi

    echo ""
    echo "Models:"
    local providers_fragment
    providers_fragment=$(get_providers_fragment)
    if [ -n "$providers_fragment" ]; then
        echo "  omlx provider: configured"
        # Count models from the omlx endpoint if reachable.
        local settings_file="${HOME}/.omlx/settings.json"
        if [ -f "$settings_file" ]; then
            local omlx_port omlx_api_key omlx_skip_verify
            omlx_port=$(jq -r '.server.port // 5033' "$settings_file")
            omlx_api_key=$(jq -r '.auth.api_key // ""' "$settings_file")
            omlx_skip_verify=$(jq -r '.auth.skip_api_key_verification // false' "$settings_file")
            local omlx_base="http://localhost:${omlx_port}"
            local models_count=0
            if [ "$omlx_skip_verify" = "true" ]; then
                models_count=$(curl -sS "${omlx_base}/v1/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null | grep -cv 'MarkItDown\|nomicai-modernbert' || echo 0)
            else
                models_count=$(curl -sS -H "Authorization: Bearer ${omlx_api_key}" "${omlx_base}/v1/models" 2>/dev/null | jq -r '.data[].id' 2>/dev/null | grep -cv 'MarkItDown\|nomicai-modernbert' || echo 0)
            fi
            echo "  omlx models: ${models_count} available locally"
        else
            echo "  omlx models: settings file not found (~/.omlx/settings.json)"
        fi
    else
        echo "  omlx provider: not configured (run 'ldx bifrost sync-omlx')"
    fi

    echo ""
    echo "Access:"
    echo "  UI:          https://${BIFROST_HOST}/"
    echo "  LLM endpoint: https://${BIFROST_HOST}/openai"
    echo "  MCP endpoint: https://${BIFROST_HOST}/mcp"
    echo "  In-cluster:  http://bifrost.${namespace}.svc.cluster.local:8080"
}
