# ldx-agentgateway module: sync-omlx: oMLX model/provider discovery and merge.
# Sourced by bin/commands/ldx-agentgateway; shared constants and helpers live in
# bin/commands/agentgateway/common.sh. Not executable on its own.

# ---------------------------------------------------------------------------
# sync-omlx
# ---------------------------------------------------------------------------

sync_omlx_models() {
    require_command "kubectl"
    require_command "jq"

    local dry_run=false
    for arg in "$@"; do
        case "$arg" in
            --dry-run) dry_run=true ;;
            *) fatal "Unknown option for sync-omlx: $arg" ;;
        esac
    done

    local namespace="$NAMESPACE"
    local settings_file="${HOME}/.omlx/settings.json"

    if [ ! -f "$settings_file" ]; then
        fatal "omlx settings file not found at: $settings_file"
    fi

    if ! get_models_fragment >/dev/null && ! kubectl get deployment agentgateway -n "$namespace" >/dev/null 2>&1; then
        fatal "agentgateway is not installed. Run 'install' first."
    fi

    local omlx_port omlx_api_key omlx_skip_verify
    omlx_port=$(jq -r '.server.port // 5033' "$settings_file")
    omlx_api_key=$(jq -r '.auth.api_key // ""' "$settings_file")
    omlx_skip_verify=$(jq -r '.auth.skip_api_key_verification // false' "$settings_file")

    local omlx_base="http://localhost:${omlx_port}"
    log_info "omlx server: ${omlx_base} (skip_api_key_verification=${omlx_skip_verify})"

    # --- Fetch omlx models ---
    log_info "Fetching models from omlx..."
    local omlx_models_raw
    if [ "$omlx_skip_verify" = "true" ]; then
        omlx_models_raw=$(curl -sS "${omlx_base}/v1/models" 2>&1) || fatal "Failed to fetch models from omlx at ${omlx_base}/v1/models: ${omlx_models_raw}"
    else
        omlx_models_raw=$(curl -sS -H "Authorization: Bearer ${omlx_api_key}" "${omlx_base}/v1/models" 2>&1) || fatal "Failed to fetch models from omlx at ${omlx_base}/v1/models: ${omlx_models_raw}"
    fi

    if [ -z "$omlx_models_raw" ]; then
        fatal "Failed to fetch models from omlx at ${omlx_base}/v1/models (empty response)"
    fi

    # Extract model IDs (exclude helper/non-LLM models)
    local omlx_models=()
    while IFS= read -r model_id; do
        case "$model_id" in
            MarkItDown|nomicai-modernbert) continue ;;
        esac
        [ -n "$model_id" ] && omlx_models+=("$model_id")
    done < <(echo "$omlx_models_raw" | jq -r '.data[].id')

    if [ ${#omlx_models[@]} -eq 0 ]; then
        fatal "No omlx models found at ${omlx_base}/v1/models"
    fi
    log_info "Found ${#omlx_models[@]} omlx models"

    # --- Generate the llm.providers and llm.models fragments ---
    # The gateway reaches omlx on the host via host.docker.internal (Rancher
    # Desktop resolves it to the macOS host for pods). Model names carry the
    # 'agw-' prefix so the harness (ldx-opencode sync) can reference them
    # without collision with other providers.
    #
    # The provider (baseUrl, apiKey, formats) is defined once under
    # llm.providers; each model references it by name via provider.reference.
    # This keeps credentials in a single location instead of duplicating them
    # per model.
    local omlx_upstream="http://host.docker.internal:${omlx_port}/v1"
    local providers_fragment="  providers:"
    providers_fragment+=$'\n'"  - name: omlx"
    providers_fragment+=$'\n'"    provider:"
    providers_fragment+=$'\n'"      custom:"
    providers_fragment+=$'\n'"        formats:"
    providers_fragment+=$'\n'"        - type: completions"
    providers_fragment+=$'\n'"    params:"
    providers_fragment+=$'\n'"      baseUrl: ${omlx_upstream}"
    if [ "$omlx_skip_verify" != "true" ] && [ -n "$omlx_api_key" ]; then
        providers_fragment+=$'\n'"      apiKey: \$OMLX_API_KEY"
    fi

    local models_fragment="  models:"
    local model_id
    for model_id in "${omlx_models[@]}"; do
        # YAML-escape double quotes in model ids (rare but legal).
        local escaped_id="${model_id//\"/\\\"}"
        # Add 'agw-' prefix to the gateway-facing name; keep the raw id for the upstream model param.
        local gw_name="${model_id}"
        if [[ "$gw_name" != agw-* ]]; then
            gw_name="agw-${gw_name}"
        fi
        local escaped_gw_name="${gw_name//\"/\\\"}"
        models_fragment+=$'\n'"  - name: \"${escaped_gw_name}\""
        models_fragment+=$'\n'"    provider:"
        models_fragment+=$'\n'"      reference: omlx"
        models_fragment+=$'\n'"    params:"
        models_fragment+=$'\n'"      model: \"${escaped_id}\""
    done

    if [ "$dry_run" = true ]; then
        log_info "Dry run - generated config would be:"
        printf 'llm:\n  gateways:\n  - default\n%s\n%s\n' "$providers_fragment" "$models_fragment"
        return 0
    fi

    # --- Store the oMLX API key (if any) in the shared runtime Secret ---
    if [ "$omlx_skip_verify" != "true" ] && [ -n "$omlx_api_key" ]; then
        put_secret "OMLX_API_KEY=${omlx_api_key}"
    fi

    # LLM routes always enforce virtual client keys; make sure one exists so
    # the rendered config carries the apiKey policy.
    ensure_api_key

    log_info "Writing oMLX provider and ${#omlx_models[@]} model routes to ConfigMap ${AGENTGATEWAY_MODELS_CM}..."
    kubectl create configmap "$AGENTGATEWAY_MODELS_CM" -n "$namespace" \
        --from-literal=providers.yaml="$providers_fragment" \
        --from-literal=models.yaml="$models_fragment" \
        --dry-run=client -o yaml | kubectl apply -f -

    apply_config

    log_info "Restarting agentgateway to pick up the new model routes..."
    rollout_agentgateway

    log_info "Sync complete. ${#omlx_models[@]} oMLX models are now served at https://${AGENTGATEWAY_HOST}/v1"
}
