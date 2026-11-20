# ldx-bifrost module: api-key: virtual client key management.
# Sourced by bin/commands/ldx-bifrost; shared constants and helpers live in
# bin/commands/bifrost/common.sh. Not executable on its own.

# ---------------------------------------------------------------------------
# api-key
# ---------------------------------------------------------------------------

api_key_command() {
    require_command "kubectl"

    local subcommand="${1:-}"
    shift || true

    case "$subcommand" in
        print)
            print_api_key
            ;;
        "")
            # Ensure the key exists, apply config and restart.
            ensure_api_key
            apply_config
            log_info "Restarting Bifrost to pick up the API key..."
            rollout_bifrost
            log_info "Virtual client key updated. Run 'ldx bifrost api-key print' to see it."
            ;;
        *)
            fatal "Unknown api-key subcommand: $subcommand"
            ;;
    esac
}
