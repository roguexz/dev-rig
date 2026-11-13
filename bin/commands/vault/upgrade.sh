# ldx-vault module: upgrade: chart-version guarded upgrade (needs snapshot.sh).
# Sourced by bin/commands/ldx-vault; shared helpers live in
# bin/commands/vault/common.sh. Not executable on its own.
source "${LDX_HOME}/bin/commands/vault/snapshot.sh"

upgrade_vault() {
    require_command "helm"
    require_command "kubectl"
    require_command "jq"

    # Guard: post-chart-workspace upgrades go through the umbrella chart.
    local k8s_ns
    k8s_ns="$(ldx_namespace k8s)"
    if helm status "ldx" -n "$k8s_ns" &>/dev/null &&
       helm get values "ldx" -n "$k8s_ns" -a -o json 2>/dev/null \
           | jq -e '.vaultStack.enabled == true' &>/dev/null; then
        fatal "Vault is managed by the ldx-local-platform chart (pinned in charts/ldx-local-platform/Chart.yaml). Upgrade flow: 'ldx vault snapshot', bump the vault dependency version in Chart.yaml, run 'helm dependency update .' in that chart, then 'ldx k8s up --services vault' and 'ldx vault status'."
    fi

    local namespace
    namespace="$(ldx_namespace vault)"
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

    helm repo add hashicorp https://helm.releases.hashicorp.com --force-update >/dev/null 2>&1 || true
    helm repo update hashicorp >/dev/null 2>&1 || helm repo update >/dev/null

    local current status
    current=$(vault_release_chart)
    status=$(vault_release_status)
    [ -n "$current" ] || fatal "Vault is not installed. Run 'setup' first."

    if [ -z "$target" ]; then
        target=$(helm search repo hashicorp/vault -l 2>/dev/null | awk 'NR==2 {print $2}')
        [ -n "$target" ] || fatal "Could not determine the latest chart version."
        log_info "No version given; latest chart is ${target} (Vault $(vault_app_version_for_chart "$target"))."
    fi

    # A release already at the target and healthy is a no-op. A release stuck
    # at the target but 'failed' (a prior interrupted upgrade) is re-driven.
    if [ "$target" = "$current" ] && [ "$status" = "deployed" ]; then
        log_info "Vault already at chart ${target}; nothing to do."
        record_vault_version "$target" "$(vault_live_app_version)"
        return
    fi

    local target_app current_app
    target_app=$(vault_app_version_for_chart "$target")
    current_app=$(vault_live_app_version)
    log_info "Upgrade plan: chart ${current} (Vault ${current_app:-unknown}) -> chart ${target} (Vault ${target_app:-unknown})"

    if $dry_run; then
        helm upgrade vault hashicorp/vault \
            --version "$target" \
            --namespace "$namespace" \
            --values "$VAULT_HELM_VALUES" \
            --dry-run=client >/dev/null
        log_info "--dry-run: manifest rendered successfully; no changes applied."
        return
    fi

    # Pre-flight: Vault must be healthy and unsealed, and we must hold a
    # snapshot. Vault refuses to start against storage written by a newer
    # version, so the snapshot (or the PVC contents) is the rollback path.
    local sealed
    sealed=$(kubectl exec -n "$namespace" vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed 2>/dev/null) || true
    [ "$sealed" = "false" ] || fatal "Vault is sealed (or not running). Run 'unseal' first."

    snapshot_vault
    local snap
    snap=$(ls -t "${VAULT_DIR}/snapshots/"*.snap | head -1)

    log_info "Upgrading Vault Helm release to chart ${target}..."
    # --force-conflicts: the injector controller re-writes the webhook caBundle
    # outside helm; helm 4's server-side apply otherwise refuses the field.
    # No --wait: this chart rolls out OnDelete and its readiness probe fails
    # while sealed, so helm can never observe the new pod ready on its own.
    if ! helm upgrade vault hashicorp/vault \
        --version "$target" \
        --namespace "$namespace" \
        --values "$VAULT_HELM_VALUES" \
        --force-conflicts; then
        log_error "helm upgrade failed. Pods that are not ready:"
        report_unready_pods "$namespace"
        fatal "Snapshot: ${snap}. Fix and re-run, or consult docs/vault.md."
    fi

    # Drive the OnDelete rollout ourselves: recreate the pod so it picks up the
    # new image, then unseal (a fresh pod starts sealed).
    if [ "$(vault_live_app_version)" != "${target_app:-$current_app}" ]; then
        log_info "Recreating vault-0 to load the new image..."
        kubectl delete pod vault-0 -n "$namespace" --wait=true
    fi
    log_info "Waiting for the vault container to start..."
    kubectl wait --for=condition=ContainersReady pod/vault-0 -n "$namespace" --timeout=180s \
        || log_warn "vault-0 not ContainersReady yet; attempting unseal anyway."

    log_info "Re-unsealing (new pod starts sealed)..."
    unseal_vault

    # Wait for readiness now that it is unsealed (readiness = `vault status`).
    if ! kubectl wait --for=condition=Ready pod/vault-0 -n "$namespace" --timeout=120s; then
        fatal "vault-0 did not become Ready after unseal. Snapshot for rollback: ${snap}. See docs/vault.md."
    fi

    # Post checks: app version and that the OIDC issuer config survived the
    # version move. The provider discovery endpoint needs no token, so a 200
    # proves the identity backend read the (persisted) OIDC configuration.
    local new_app ok=true
    new_app=$(vault_live_app_version)
    log_info "Running pod image tag: ${new_app:-unknown} (expected ${target_app:-unknown})"

    if kubectl exec -n "$namespace" vault-0 -- sh -c \
        'wget -qO- http://127.0.0.1:8200/v1/identity/oidc/provider/agentgateway/.well-known/openid-configuration 2>/dev/null || curl -s http://127.0.0.1:8200/v1/identity/oidc/provider/agentgateway/.well-known/openid-configuration' \
        | grep -q '"issuer"'; then
        log_info "OIDC issuer responds: identity data intact."
    else
        log_warn "OIDC issuer did not respond after upgrade."
        ok=false
    fi

    record_vault_version "$target" "${new_app:-$target_app}" "$current" "$current_app"

    if $ok; then
        log_info "Upgrade complete: chart ${target}, Vault ${new_app:-$target_app}."
        log_info "Log in at https://agentgateway.rd.localhost/ui and confirm SSO still works."
    else
        fatal "Upgrade applied but a smoke check failed. Snapshot for rollback: ${snap}. See docs/vault.md."
    fi
}

