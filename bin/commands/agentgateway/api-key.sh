# ldx-agentgateway module: api-key subcommand (ensure_api_key lives in common.sh).
# Sourced by bin/commands/ldx-agentgateway; shared constants and helpers live in
# bin/commands/agentgateway/common.sh. Not executable on its own.
print_api_key() {
    require_command "kubectl"

    if ! get_api_key_state; then
        fatal "No ${AGENTGATEWAY_API_KEY_NAME} in Secret '${AGENTGATEWAY_SECRET}'. Run 'ldx agentgateway api-key' first."
    fi

    printf '%s\n' "$AGENTGATEWAY_API_KEY"
}

# api-key (top-level dispatcher)
api_key_command() {
    local subcommand="${1:-}"
    if [ $# -gt 0 ]; then
        shift
    fi

    case "$subcommand" in
        print)
            print_api_key "$@"
            ;;
        "")
            enable_api_key "$@"
            ;;
        *)
            log_error "Unknown api-key subcommand: $subcommand"
            log_error "Usage: ldx agentgateway api-key [print]"
            exit 1
            ;;
    esac
}

# Generates (or reuses) the virtual client API key, stores it in the runtime
# Secret, caches it locally for harness configs, and applies the apiKey policy.
enable_api_key() {
    require_command "kubectl"

    local existed=true
    get_api_key_state || existed=false
    ensure_api_key
    if [ "$existed" = true ]; then
        log_info "Reusing existing virtual API key."
    fi
    log_info "Cached key in $(ldx_secret_backend) storage as ldx/agentgateway/api_key."

    apply_config
    rollout_agentgateway

    log_info "API key is enforced on LLM routes (llm.policies.apiKey.mode=strict)."
    log_info "Virtual key stored in Secret '${AGENTGATEWAY_SECRET}' (${AGENTGATEWAY_API_KEY_NAME})"
    log_info "and cached as ldx/agentgateway/api_key; clients send it as"
    log_info "'Authorization: Bearer \$(ldx agentgateway api-key print)'."
    log_info "Sync it into opencode with: ldx opencode sync"
}
