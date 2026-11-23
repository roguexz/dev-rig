# ldx-bifrost module: install/uninstall/upgrade + chart hooks (prepare-support, prepare-values).
# Sourced by bin/commands/ldx-bifrost; shared constants and helpers live in
# bin/commands/bifrost/common.sh. Not executable on its own.

# Internal: create/update the CLI-owned resources the chart's Deployment
# references by name (config ConfigMap, runtime Secret, extra CAs). Idempotent;
# run by 'ldx k8s' as the bifrost pre-apply hook and by 'install' before
# the chart apply.
prepare_support() {
    require_command "kubectl"
    ldx_save_namespace bifrost "$NAMESPACE"
    kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -
    ensure_encryption_key
    ensure_admin_credentials
    ensure_api_key
    apply_config
    create_extra_cas_configmap "$NAMESPACE"
}

# Internal: render the chart values (stdout). Logs go to stderr; the values
# file is consumed by 'ldx k8s'. The image follows the LIVE deployment when
# one exists, so 'ldx bifrost upgrade' (kubectl set image) survives
# later reconciles; the pinned constant is only the initial value.
prepare_values() {
    exec 3>&1 1>&2

    local live_image="" host_aliases=""
    live_image=$(bifrost_running_image 2>/dev/null) || true

    host_aliases=" []"

    # Checksum of the CLI-owned ConfigMap, rendered into pod annotations
    # (see chart): a config change rolls the pods.
    local config_sha
    config_sha=$(kubectl get configmap bifrost-config -n "$NAMESPACE" \
        -o jsonpath='{.data}' 2>/dev/null | shasum -a 256 | awk '{print $1}') || true

    cat >&3 <<EOF
bifrostStack:
  image: ${live_image:-$BIFROST_IMAGE}
  hostAliases:${host_aliases}
  podAnnotations:
    checksum/config: "${config_sha:-none}"
EOF
}

install_bifrost() {
    require_command "kubectl"

    ldx_save_namespace bifrost "$NAMESPACE"

    # CLI-owned config/secret, then the static deployment via
    # the ldx-local-platform chart (service 'bifrost'; prehook
    # bifrost re-runs prepare_support).
    prepare_support
    "${LDX_HOME}/bin/ldx" k8s up --services bifrost

    log_info "Bifrost installation complete."
    log_info "Bifrost UI is accessible at: https://${BIFROST_HOST}/"
    log_info "In-cluster DNS: http://bifrost.${NAMESPACE}.svc.cluster.local:8080"
    log_info "Admin credentials: username 'admin', password in keychain (run 'ldx bifrost admin-password')."
    if [ -n "$(get_providers_fragment)" ]; then
        log_info "Synced oMLX provider is configured (re-run 'sync-omlx' to refresh)."
    fi
    log_info "MCP servers are not configured; add them via the Bifrost UI at https://${BIFROST_HOST}/."
}

uninstall_bifrost() {
    require_command "kubectl"

    local namespace="$NAMESPACE"

    log_info "Uninstalling Bifrost..."
    # Chart teardown (Deployment, Service, Ingress, ServiceAccount, PVC).
    "${LDX_HOME}/bin/ldx" k8s down --services bifrost --purge-data

    # CLI-owned resources (not chart-managed by design: they carry dynamic
    # state assembled by sync-omlx).
    kubectl delete configmap bifrost-config -n "$namespace" --ignore-not-found
    kubectl delete configmap "$BIFROST_PROVIDERS_CM" -n "$namespace" --ignore-not-found
    kubectl delete secret "$BIFROST_SECRET" -n "$namespace" --ignore-not-found

    # The virtual client key died with the Secret; drop the local cache entries.
    ldx_secret_delete bifrost/credentials API_KEY
    ldx_secret_delete bifrost api_key
    rm -f "$BIFROST_KEY_CACHE"

    # Admin credentials and encryption key are in the keychain; remove them.
    ldx_secret_delete bifrost/credentials USERNAME
    ldx_secret_delete bifrost/credentials PASSWORD
    ldx_secret_delete bifrost/credentials ENCRYPTION_KEY
    ldx_secret_delete bifrost admin_username
    ldx_secret_delete bifrost admin_password
    ldx_secret_delete bifrost encryption_key

    log_info "Bifrost uninstall complete. The '${namespace}' namespace was not deleted."
}

# ---------------------------------------------------------------------------
# upgrade
# ---------------------------------------------------------------------------

# Image the running deployment specifies (empty if not installed).
bifrost_running_image() {
    kubectl get deployment bifrost -n "$NAMESPACE" \
        -o jsonpath='{.spec.template.spec.containers[?(@.name=="bifrost")].image}' 2>/dev/null || true
}

# Tag of the running image (e.g. 'v2.6.0'); empty when the deployment is absent.
bifrost_running_tag() {
    local image
    image=$(bifrost_running_image)
    [ -n "$image" ] || return 1
    printf '%s' "$image" | sed -n 's/.*:\(.*\)$/\1/p'
}

upgrade_bifrost() {
    require_command "kubectl"

    local namespace="$NAMESPACE"
    local target="" dry_run=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                dry_run=true
                shift
                ;;
            -*)
                log_error "Unknown option: $1"
                show_help
                exit 1
                ;;
            *)
                [ -z "$target" ] || { log_error "Unexpected argument: $1"; exit 1; }
                target="$1"
                shift
                ;;
        esac
    done

    local current_image current_tag
    current_image=$(bifrost_running_image)
    if [ -z "$current_image" ]; then
        fatal "Bifrost is not installed. Run 'install' first."
    fi
    current_tag=$(bifrost_running_tag)

    # Resolve the target image. A bare version gets a 'v' prefix; a fully
    # qualified image reference is used as-is. Omitting the version upgrades
    # to the pinned constant.
    local target_image
    if [ -z "$target" ]; then
        target_image="$BIFROST_IMAGE"
        log_info "No version given; upgrading to pinned ${target_image}."
    elif printf '%s' "$target" | grep -q ':'; then
        target_image="$target"
    else
        case "$target" in
            v*) target_image="${BIFROST_IMAGE_BASE}:${target}" ;;
            *)  target_image="${BIFROST_IMAGE_BASE}:v${target}" ;;
        esac
    fi
    local target_tag
    target_tag=$(printf '%s' "$target_image" | sed -n 's/.*:\(.*\)$/\1/p')

    # Already at the target: no-op.
    if [ "$target_image" = "$current_image" ]; then
        log_info "Bifrost already at ${current_tag}; nothing to do."
        return 0
    fi

    log_info "Upgrade plan: ${current_tag} -> ${target_tag}"

    if $dry_run; then
        log_info "--dry-run: would set image to ${target_image} and roll the deployment; no changes applied."
        return 0
    fi

    log_info "Updating Bifrost image to ${target_tag}..."
    kubectl set image deployment/bifrost bifrost="${target_image}" -n "$namespace"

    rollout_bifrost

    # Verify the rollout landed on the requested image.
    local new_image
    new_image=$(bifrost_running_image)
    log_info "Running image: $(bifrost_running_tag) (expected ${target_tag})"
    if [ "$new_image" != "$target_image" ]; then
        fatal "Upgrade did not complete: expected ${target_tag}, got $(bifrost_running_tag). Check 'kubectl get pods -n ${namespace}'."
    fi

    log_info "Upgrade complete: Bifrost ${target_tag}."
}
