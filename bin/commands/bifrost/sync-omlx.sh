# ldx-bifrost module: sync-omlx: oMLX model/provider discovery and merge.
# Sourced by bin/commands/ldx-bifrost; shared constants and helpers live in
# bin/commands/bifrost/common.sh. Not executable on its own.

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

    if ! get_providers_fragment >/dev/null && ! kubectl get deployment bifrost -n "$namespace" >/dev/null 2>&1; then
        fatal "Bifrost is not installed. Run 'install' first."
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

    # --- Generate the providers.omlx fragment ---
    # The gateway reaches omlx on the host via host.docker.internal (Rancher
    # Desktop resolves it to the macOS host for pods). omlx is OpenAI-compatible
    # so we configure it as a custom provider with base_provider_type: "openai".
    #
    # In Bifrost, models are referenced as "provider/model" (e.g. "omlx/qwen-blend")
    # for routing. The OpenCode harness configures them with the "bifrost-" config
    # key prefix (e.g. "bifrost/bifrost-qwen-blend") to distinguish them from
    # direct omlx models, while the wire id sent to Bifrost stays "omlx/<model-id>".
    # base_url must not include /v1; Bifrost appends the path itself.
    local omlx_upstream="http://host.docker.internal:${omlx_port}"

    # Build the models array from the discovered models. We use ["*"] to allow
    # all models, which is simpler than listing each one, and lets new models
    # appear without re-syncing. The key's models field is ["*"].
    local providers_fragment
    if [ "$omlx_skip_verify" = "true" ] || [ -z "$omlx_api_key" ]; then
        # No API key needed.
        providers_fragment=$(jq -n \
            --arg base_url "$omlx_upstream" \
            '{
              "omlx": {
                "custom_provider_config": {
                  "base_provider_type": "openai",
                  "allowed_requests": {
                    "chat_completion": true,
                    "chat_completion_stream": true,
                    "list_models": true
                  }
                },
                "network_config": {
                  "base_url": $base_url,
                  "insecure_skip_verify": false,
                  "allow_private_network": true,
                  "retry_backoff_initial": 500,
                  "retry_backoff_max": 5000
                },
                "keys": [
                  {
                    "name": "omlx-primary",
                    "value": "",
                    "models": ["*"],
                    "weight": 1.0
                  }
                ]
              }
            }')
    else
        # API key needed; reference it from the runtime Secret.
        providers_fragment=$(jq -n \
            --arg base_url "$omlx_upstream" \
            '{
              "omlx": {
                "custom_provider_config": {
                  "base_provider_type": "openai",
                  "allowed_requests": {
                    "chat_completion": true,
                    "chat_completion_stream": true,
                    "list_models": true
                  }
                },
                "network_config": {
                  "base_url": $base_url,
                  "insecure_skip_verify": false,
                  "allow_private_network": true,
                  "retry_backoff_initial": 500,
                  "retry_backoff_max": 5000
                },
                "keys": [
                  {
                    "name": "omlx-primary",
                    "value": "env.OMLX_API_KEY",
                    "models": ["*"],
                    "weight": 1.0
                  }
                ]
              }
            }')
    fi

    if [ "$dry_run" = true ]; then
        log_info "Dry run - generated config would be:"
        printf '%s\n' "$providers_fragment" | jq .
        return 0
    fi

    # --- Store the oMLX API key (if any) in the shared runtime Secret ---
    if [ "$omlx_skip_verify" != "true" ] && [ -n "$omlx_api_key" ]; then
        put_secret "OMLX_API_KEY=${omlx_api_key}"
    fi

    # LLM routes always enforce virtual client keys; make sure one exists so
    # the rendered config carries the vk.
    ensure_api_key

    log_info "Writing oMLX provider config to ConfigMap ${BIFROST_PROVIDERS_CM}..."
    kubectl create configmap "$BIFROST_PROVIDERS_CM" -n "$namespace" \
        --from-literal=providers.json="$providers_fragment" \
        --dry-run=client -o yaml | kubectl apply -f -

    apply_config

    log_info "Restarting Bifrost to pick up the new provider config..."
    rollout_bifrost

    log_info "Sync complete. oMLX is now configured as provider 'omlx' (models referenced as 'omlx/<model-id>')."
}
