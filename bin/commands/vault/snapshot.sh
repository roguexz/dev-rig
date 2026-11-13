# ldx-vault module: snapshot: Raft snapshot to the cache dir.
# Sourced by bin/commands/ldx-vault; shared helpers live in
# bin/commands/vault/common.sh. Not executable on its own.
snapshot_vault() {
    require_command "kubectl"
    require_command "jq"

    local namespace
    namespace="$(ldx_namespace vault)"
    local sealed
    sealed=$(kubectl exec -n "$namespace" vault-0 -- vault status -format=json 2>/dev/null | jq -r .sealed 2>/dev/null) || true
    [ "$sealed" = "false" ] || fatal "Vault is sealed (or not running). Run 'unseal' first."

    init_dirs
    local chart storage snap
    chart=$(vault_release_chart)
    storage=$(vault_storage_type)
    snap="${VAULT_DIR}/snapshots/$(date +%Y%m%d-%H%M%S)-vault${chart:+-${chart}}-${storage}.snap"

    case "$storage" in
        raft)
            log_info "Saving Raft snapshot..."
            kubectl exec -n "$namespace" vault-0 -- vault operator raft snapshot save /tmp/raft.snap >/dev/null
            kubectl cp "${namespace}/vault-0:/tmp/raft.snap" "$snap" >/dev/null
            kubectl exec -n "$namespace" vault-0 -- rm -f /tmp/raft.snap 2>/dev/null || true
            ;;
        file)
            # File backend (chart default for standalone): the data dir on the
            # PVC *is* the database. Tar it out of the pod. Writes during the
            # tar are rare on a dev box; for a hard-consistent copy seal first.
            log_info "Backing up file storage (/vault/data)..."
            kubectl exec -n "$namespace" vault-0 -- tar czf /tmp/filedb.tgz -C /vault data >/dev/null
            kubectl cp "${namespace}/vault-0:/tmp/filedb.tgz" "$snap" >/dev/null
            kubectl exec -n "$namespace" vault-0 -- rm -f /tmp/filedb.tgz 2>/dev/null || true
            ;;
        *)
            fatal "Unsupported storage backend '${storage}'. Snapshot manually."
            ;;
    esac

    if [ ! -s "$snap" ]; then
        rm -f "$snap"
        fatal "Snapshot is empty; the file was not written."
    fi
    log_info "Snapshot saved (${storage}): ${snap} ($(wc -c < "$snap" | tr -d ' ') bytes)"
}

