# Bifrost (`ldx bifrost`)

This command deploys [Bifrost](https://github.com/maximhq/bifrost) - a unified LLM and MCP gateway - as a Deployment in
the Kubernetes cluster and exposes it via Traefik Ingress and an internal ClusterIP. Bifrost replaces the old
agentgateway (LLM gateway) and also provides MCP gatewaying in the same deployment.

## Architecture

```
OpenCode ──(Bearer $BIFROST_VK_OPENCODE)──▶ https://bifrost.rd.localhost/openai   (LLM)
OpenCode ──(Bearer $BIFROST_VK_OPENCODE)──▶ https://bifrost.rd.localhost/mcp      (MCP)
                                                         │
                                                  Bifrost Gateway
                                                         │
                                                ┌────────┴────────┐
                                                │                 │
                                          oMLX (host)        MCP Servers
                                          (LLM inference)   (user-configured)
```

Bifrost sits between the harness and upstream providers. LLM requests are routed to the local oMLX server; MCP requests
are routed to user-configured MCP servers. A single virtual client key secures both endpoints.

## Commands

### `ldx bifrost install`

Installs Bifrost into the configured namespace (default `commons`) and wires it to the local oMLX server:

1. **Helm release**: Deploys the `bifrost` subchart via `ldx k8s up --services bifrost` (Deployment, PVC, Service,
   Ingress). The chart carries the static deployment; dynamic config stays CLI-owned.
2. **Admin credentials**: Generates a random admin password (username is `admin`) stored in the keychain at
   `ldx/bifrost/admin_password`. The admin UI uses these credentials for login.
3. **Encryption key**: Generates an AES encryption key (stored in the keychain at `ldx/bifrost/encryption_key`) for
   encrypting data at rest in the SQLite databases.
4. **Virtual client key**: Generates a virtual client key (`sk-bf-<48 hex>`) stored in the keychain at
   `ldx/bifrost/api_key` and in the K8s Secret `bifrost-secrets` under `BIFROST_VK_OPENCODE`. This key secures both
   the LLM and MCP endpoints.
5. **Configuration**: Creates the `bifrost-config` ConfigMap with SQLite storage (config and logs databases on the
   1Gi PVC), admin auth, virtual key policy, and the oMLX provider section (injected from the `bifrost-providers`
   ConfigMap, if synced).
6. **Service & Ingress**: Exposes the gateway via Traefik Ingress (`https://bifrost.rd.localhost`) and an internal
   ClusterIP. Endpoints: `/openai` (LLM), `/mcp` (MCP), `/health` (probes).

After installation, the gateway UI is available at `https://bifrost.rd.localhost`. Print the admin password with
`ldx bifrost admin-password`. MCP servers are not configured on install; add them through the Bifrost UI.

> **Note:** MCP servers are configured through the Bifrost UI after installation. Bifrost handles OAuth credential
> brokering for MCP servers that require it.

### `ldx bifrost sync-omlx`

Configures the local [omlx](https://github.com/jundot/omlx) server as the LLM provider:

1. Reads the omlx port and API key from `~/.omlx/settings.json`.
2. Fetches the model list from `http://localhost:<port>/v1/models` (helper models such as `MarkItDown` are excluded).
3. Writes the `omlx` provider configuration to the `bifrost-providers` ConfigMap. The provider uses the
   `openai` base type and points to `http://host.docker.internal:<port>` (Rancher Desktop resolves this to the
   macOS host for pods; Bifrost appends the API path itself).
4. Stores the omlx API key in the `bifrost-secrets` Secret (`OMLX_API_KEY`) unless key verification is disabled in
   omlx settings. Uses `["*"]` for the key's models so all omlx models are routed without listing each one.
5. Ensures the virtual client key exists, applies the full gateway config, and restarts the gateway.

Use `--dry-run` to print the generated provider configuration without applying it.

> **When to run:** on first use after install, and whenever the omlx server's port or API key changes. The provider
> uses `["*"]` for models, so new models appear automatically without re-syncing.

### `ldx bifrost api-key`

Manages the gateway's virtual client key - the single credential clients present to access both LLM and MCP routes:

- **Enforcement**: The virtual key policy (`is_vk_mandatory: true`) is always on. Requests to `/openai` and `/mcp`
  without a valid key get `401`.
- **Generation**: On first use, a key `sk-bf-<48 hex>` is generated, cached in the host secret store as
  `ldx/bifrost/api_key`, and stored in the `bifrost-secrets` Secret under `BIFROST_VK_OPENCODE`.
- **Reuse and rotation**: Re-running the command is idempotent (reuses the cached key, repairs the Secret/config if
  they drifted). Delete the `ldx/bifrost/api_key` secret first to generate a fresh key.
- **Print**: `ldx bifrost api-key print` prints the current key to stdout.

Clients such as `ldx opencode sync` pick the key up from the keychain automatically.

### `ldx bifrost admin-password`

Prints the admin password (stored in the keychain at `ldx/bifrost/admin_password`) to stdout. Use this to log in to
the Bifrost UI at `https://bifrost.rd.localhost`. The username is `admin`.

### `ldx bifrost status`

Shows the deployment state: pod status, admin auth, API key, encryption key, and synced providers.

### `ldx bifrost upgrade [version]`

Upgrades the running Bifrost to a new image version with a rolling restart. All runtime state - the SQLite databases
on the PVC, the ConfigMap, and the Secrets (admin credentials, API key, encryption key, oMLX key) - is preserved;
only the pod image changes.

```bash
ldx bifrost upgrade            # jump to the pinned version (v2.6.0)
ldx bifrost upgrade 1.4.11     # pin a specific version
ldx bifrost upgrade --dry-run  # render only; touch nothing
```

### `ldx bifrost uninstall`

Removes the Bifrost deployment, services, ingress, config, runtime secrets, and the 1Gi PVC. The namespace is
managed by the platform and is not deleted unless the whole platform is removed.

## Accessing Bifrost

### From the Host Machine

- **HTTPS URL (Ingress):** `https://bifrost.rd.localhost`
  - `/openai` - LLM endpoint (OpenAI-compatible API)
  - `/mcp` - MCP endpoint
  - `/health` - Health check (readiness/liveness probes)
  - `/` - Admin UI

The certificate from `ldx tls install` is trusted by the system keychain, so `curl` works without `-k`.

### From Inside the Kubernetes Cluster

For applications running as pods inside the Kubernetes cluster, use the internal Kubernetes DNS name:

- **LLM:** `http://bifrost.commons.svc.cluster.local:8080/openai`
- **MCP:** `http://bifrost.commons.svc.cluster.local:8080/mcp`

*Note: `commons` in the DNS names is the deployment namespace; substitute your custom namespace if one is configured.*

## Storage

Bifrost uses SQLite for both its configuration database and logs database, stored on a 1Gi PVC at `/data/bifrost.db`
and `/data/logs.db`. SQLite databases grow gradually as data accumulates - they do not pre-allocate the full size. The
config database stays small (kilobytes), and the logs database grows based on request volume and retention settings.
For a local dev rig, 1Gi is plenty. You can expand the PVC later if needed (`kubectl edit pvc bifrost-data`).

## Migrating from agentgateway

If you previously used agentgateway for LLMs:

1. Install Bifrost: `ldx bifrost install`
2. Sync oMLX: `ldx bifrost sync-omlx`
3. Sync the harness: `ldx opencode sync` (configures the Bifrost LLM and MCP endpoints)
4. Add your MCP servers through the Bifrost UI (`https://bifrost.rd.localhost`)
5. Uninstall the old gateway: `ldx k8s down agentgateway` (if not already removed)

Bifrost handles both LLM routing and MCP credential brokering in a single deployment, so the separate agentgateway
is no longer needed.

## Configuration

Bifrost is configured via a JSON config file (`bifrost-config.json.tpl`) merged with synced provider fragments:

- **Encryption key**: `BIFROST_ENCRYPTION_KEY` (from the runtime Secret)
- **Admin credentials**: `BIFROST_ADMIN_USERNAME`, `BIFROST_ADMIN_PASSWORD` (from the runtime Secret)
- **Virtual client key**: `BIFROST_VK_OPENCODE` (from the runtime Secret)
- **oMLX API key**: `OMLX_API_KEY` (from the runtime Secret, set by `sync-omlx`)
- **Storage**: SQLite databases at `/data/bifrost.db` (config) and `/data/logs.db` (logs)
- **Providers**: Injected from the `bifrost-providers` ConfigMap (written by `sync-omlx`)

The config is mounted at `/app/data/config.json` (Bifrost looks for it in its app data directory). The SQLite
    databases on the PVC hold runtime state
(managed through the UI or API), surviving pod restarts.
