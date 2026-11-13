# agentgateway (`ldx agentgateway`)

This command deploys [agentgateway](https://agentgateway.dev) - an HTTP/gRPC gateway for LLM, MCP, and A2A traffic - as
a pod in the Kubernetes cluster and exposes it via Traefik Ingress and an internal ClusterIP.

## Commands

### `ldx agentgateway install`

This command installs agentgateway into the configured namespace (default `commons`, see
[Configuration](../../docs/ldx.md#configuration)):

1. **Service account**: Creates a dedicated `agentgateway` ServiceAccount (replacing the `default` SA), which is bound
   to a Vault role that grants the Vault Agent sidecar permission to read MCP credentials.
2. **Vault role**: Creates the `agentgateway-mcp` Vault role (bound to the gateway's ServiceAccount) so the Vault
   Agent sidecar can authenticate to Vault via Kubernetes auth and read MCP secrets. Requires `ldx vault enable-secrets`
   to have been run first.
3. **Configuration**: Creates a ConfigMap (`agentgateway-config`) with a declarative configuration: a SQLite database at
   `/data/data.db` in `hybrid` storage mode, a `default` gateway on port 4000, and the built-in UI served on that
   gateway. Previously synced oMLX models and an already-configured Vault SSO policy are preserved across re-installs.
4. **Persistent data**: Creates a PersistentVolumeClaim (`agentgateway-data`, 1Gi) mounted at `/data` for the SQLite
   database (LLM analytics, logs, sessions, and runtime data).
5. **Runtime secrets**: The Deployment loads the `agentgateway-secrets` Secret (optional) into the pod environment; the
   config file references values such as `$OMLX_API_KEY` and `$UI_CLIENT_SECRET` and agentgateway expands them at load
   time, so no secret material is stored in the ConfigMap.
6. **Vault Agent sidecar**: Adds a `vault-agent` container (same image as the Vault server, runs as uid 1000) to the
   Deployment. It authenticates to Vault via Kubernetes auth, reads MCP secrets, and writes them to files in the shared
   `/etc/agentgateway/mcp-credentials` directory with `0400` permissions. The gateway reads these files via
   `backendAuth.key.value.file` - the credential never appears in the gateway's config, environment, or as a response
   to the harness.
7. **Deployment**: Deploys the pinned agentgateway image (`cr.agentgateway.dev/agentgateway:v1.7.0`) with the config
   mounted read-only at `/etc/agentgateway/config.yaml`.
8. **Client API key**: Ensures the gateway's virtual client API key exists (generated once as `agw-<48 hex>`, cached
   in the host secret store as `ldx/agentgateway/api_key`, stored in the Secret under `AGENTGATEWAY_API_KEY`)
   and wires the `llm.policies.apiKey` policy into the config so every LLM request must present it - see
   [`api-key`](#ldx-agentgateway-api-key).
9. **Service & Ingress Exposure**: Exposes the gateway via Traefik Ingress (`https://agentgateway.rd.localhost`) and
   an internal ClusterIP for in-cluster clients.

After installation, the gateway UI is available at `https://agentgateway.rd.localhost`. LLM endpoints are protected by
the client API key policy; the UI itself is authenticated separately (Vault SSO when configured, otherwise open).

> **Note:** The ConfigMap mount is read-only, so the gateway runs with `config.storage.mode: hybrid`: the ConfigMap is
> the baseline and resources managed through the UI or API are stored in the SQLite database on the PVC and merged over
> it, surviving pod restarts. Saving the *whole* config file from the UI's config editor is still not possible (the
> mounted file itself stays read-only). To change the baseline permanently, edit the manifest in `bin/commands/ldx-agentgateway`
> and re-run `ldx agentgateway install`, or use `sync-omlx` / `sso` below.

### `ldx agentgateway sync-omlx`

Syncs the models served by the local [omlx](https://github.com/jundot/omlx) server into the gateway's LLM routes:

1. Reads the omlx port and API key from `~/.omlx/settings.json`.
2. Fetches the model list from `http://localhost:<port>/v1/models` (helper models such as `MarkItDown` are excluded).
3. Writes an `llm.models` fragment to the `agentgateway-llm-models` ConfigMap and rolls the gateway, so each model is
   served at `https://agentgateway.rd.localhost/v1/...` and proxied to `http://host.docker.internal:<port>/v1`.
4. Stores the omlx API key in the `agentgateway-secrets` Secret (`OMLX_API_KEY`) unless key verification is disabled in
   omlx settings.
5. Ensures the virtual client API key and `llm.policies.apiKey` policy are present (same as `install`).

Use `--dry-run` to print the generated configuration without applying it.

> **When to run:** whenever models are added to or removed from oMLX. The `llm.models` fragment is rebuilt from the live
> `/v1/models` list, so a newly loaded model only gains a gateway route - and a removed model only stops being routed -
> once this command re-runs; the gateway pod restarts as part of it. Clients that cached the previous route list then
> need their own refresh, see [Refreshing after oMLX model changes](./opencode.md#refreshing-after-omlx-model-changes).

### `ldx agentgateway api-key`

Manages the gateway's virtual client API key - the credential clients must present to access both LLM and MCP routes:

- **Enforcement**: `apiKey` policies (mode `strict`) are configured on both the LLM routes (`llm.policies.apiKey`) and
  the `/mcp` route (`routes[].policies.apiKey`) by `install` and `sync-omlx`. Requests to `/v1/...` or `/mcp` without a
  valid key get `401`. The UI and its OIDC flow are not affected.
- **Generation**: On first use, a key `agw-<48 hex>` is generated, written to
  the host secret store as `ldx/agentgateway/api_key`, and stored in the `agentgateway-secrets` Secret under
  `AGENTGATEWAY_API_KEY`. The config references it as `$AGENTGATEWAY_API_KEY` (expanded by agentgateway at load time),
  so the Secret is the canonical copy.
- **Reuse and rotation**: Re-running the command is idempotent (reuses the cached key, repairs the Secret/config if
  they drifted). Delete the `ldx/agentgateway/api_key` secret first to generate a fresh key. `--dry-run` prints without applying.

Clients such as `ldx opencode sync` pick the key up from the cache file or the Secret automatically, and configure it
for both the LLM provider and the MCP endpoint.

### `ldx agentgateway sso`

Enables Authelia (deployed by `ldx authelia install`) as the OIDC identity provider for the agentgateway UI:

1. Checks that Authelia is running and its OIDC discovery endpoint responds.
2. Reads the agentgateway client secret from the Authelia secret store (`ldx/authelia/client_secrets/*`).
3. Stores the client secret and OIDC configuration in the `agentgateway-secrets` Secret.
4. Updates the gateway's `ui.policies.oidc` block to point at Authelia's endpoints.
5. Restarts the gateway.

The generated `ui.policies.oidc` block uses explicit provider mode: the `issuer` and `authorizationEndpoint` are the
browser-facing `auth.rd.localhost` URLs, while `tokenEndpoint` and `jwks` point at the in-cluster Authelia service
(`http://authelia.authelia.svc.cluster.local:9091`), because pods resolve `*.rd.localhost` to loopback and do not trust
the mkcert CA. It requests `scopes: [openid, profile, email, groups]`, so the UI shows each user's name and email.

Authelia must be running before running this command (`ldx authelia install`).

> **Note:** This replaces the previous Vault-based SSO. If you previously ran `ldx agentgateway sso` with the old
> Vault-based implementation, Vault-side OIDC resources (`identity/oidc/{key,client,assignment,provider}/agentgateway*`,
> `identity/group/name/agentgateway-ui-users`) may still exist; clean them up manually if desired.

### `ldx agentgateway mcp`

Manages MCP tools with Vault-backed credentials. This is the primary way to configure MCP servers for the gateway so
that harnesses (OpenCode, etc.) can use them without ever seeing the credentials:

```bash
# Add a new MCP tool (credential stored in Vault, target registered with the gateway)
ldx agentgateway mcp add <name> --url <url> --token <token>

# List all configured MCP tools
ldx agentgateway mcp list

# Remove an MCP tool and its Vault credential
ldx agentgateway mcp remove <name>

# Rotate a tool's credential (Vault Agent refreshes the file automatically)
ldx agentgateway mcp rotate <name> --token <new-token>
```

#### How it works

1. **`mcp add`**:
   - Stores the credential in Vault at `secret/mcp/<name>` (KV v2, `token` field).
   - Registers an `mcp.target` resource with the gateway via the admin API, with `backendAuth.key.value.file` pointing
     to `/etc/agentgateway/mcp-credentials/<name>.token`.
   - Regenerates the Vault Agent ConfigMap (adds a template block for the new tool).
   - Restarts the gateway pod to pick up the new config.

2. **`mcp list`**: Queries the gateway's admin API and displays all configured MCP targets (name, URL, resource ID).

3. **`mcp remove`**:
   - Deletes the Vault secret (all versions).
   - Deletes the `mcp.target` resource from the gateway's config.
   - Regenerates the Vault Agent ConfigMap (removes the template block).
   - Restarts the gateway pod.

4. **`mcp rotate`**: Updates the Vault secret in place. The Vault Agent detects the change and refreshes the file
   automatically - no gateway restart is needed because the gateway reads the file on each request.

#### Security model

- **Vault** stores the credential encrypted at rest. Access is controlled by the `mcp-secrets-read` policy, which only
  grants read/list on `secret/data/mcp/*`.
- The **Vault Agent sidecar** (in the gateway pod) authenticates to Vault via Kubernetes auth using the pod's service
  account token, gets a short-lived token (1h TTL), and templates the secret into a file with `0400` permissions, owned
  by uid 1000.
- The **gateway** reads the file via `backendAuth.key.value.file` and injects the credential into outbound MCP requests.
  The credential never appears in the gateway's config file, environment variables, or responses to the harness.
- The **harness** (OpenCode, etc.) sends MCP requests to the gateway with a virtual API key
  (`Authorization: Bearer <key>`). The gateway validates the key (same key used for LLM routes) and handles
  authentication to the upstream MCP server transparently. The `ldx-opencode sync` command configures the MCP endpoint
  with this key automatically.
- **Credential rotation** is seamless: `mcp rotate` updates Vault, the Vault Agent detects the change and refreshes
  the file, and the next request from the gateway uses the new credential.

#### Prerequisites

- Vault must be set up with `ldx vault setup` (or `ldx vault enable-secrets` on an existing install) so that the KV v2
  secrets engine, Kubernetes auth method, and `mcp-secrets-read` policy are in place.
- The gateway must be installed with `ldx agentgateway install` (which creates the dedicated ServiceAccount, Vault
  role, and Vault Agent sidecar).

#### Tool naming

Tool names are used as path components in Vault and as filenames on disk, so they must contain only alphanumeric
characters, hyphens, and underscores (e.g., `github`, `my-tool`, `my_tool`).

### `ldx agentgateway uninstall`

This command cleans up the agentgateway deployment, services, ingress, configuration, runtime secrets, the SQLite
PVC, the Vault Agent ConfigMap, the dedicated ServiceAccount, and the cached client API key file, leaving the
namespace intact. It also deletes all MCP secrets from Vault (if any exist).

## Accessing agentgateway

### From the Host Machine

- **HTTPS URL (Ingress):** `https://agentgateway.rd.localhost/ui`

Traefik also serves the same host in plaintext on port 80 (`http://agentgateway.rd.localhost/ui`) without forcing a
redirect, and the certificate from `ldx tls install` is trusted by the system keychain, so `curl` works without `-k`.

The UI is served on the gateway port. The admin interface (port 15000) binds to the pod's loopback interface and is
intentionally not reachable from outside the pod; the gateway-port UI is the supported, authenticatable path.

After `ldx agentgateway sso`, opening the UI redirects to `https://auth.rd.localhost` for login (Touch ID) and back
once the Authelia session is established.

### From Inside the Kubernetes Cluster

For applications running as pods inside the Kubernetes cluster (in any namespace), use the internal Kubernetes DNS name
to connect:

- **Endpoint:** `http://agentgateway.commons.svc.cluster.local:4000`

LLM clients can call `http://agentgateway.commons.svc.cluster.local:4000/v1/chat/completions` (and the rest of the
OpenAI-compatible surface) for models synced with `sync-omlx`, authenticating with the gateway client API key
(`AGENTGATEWAY_API_KEY`, see [`api-key`](#ldx-agentgateway-api-key)) - not the omlx key, which stays server-side in
the gateway.

*Note: `commons` in the DNS names is the deployment namespace; substitute your custom namespace if one is configured.*

## Upgrading

### `ldx agentgateway upgrade [version]`

Upgrades the running agentgateway to a new image version with a rolling restart. All runtime state - the SQLite
database on the PVC, the ConfigMap, and the Secrets (SSO config, API keys, oMLX key) - is preserved; only the pod
image changes.

```bash
ldx agentgateway upgrade            # jump to the pinned version (v1.7.0)
ldx agentgateway upgrade 1.7.0      # pin a specific version
ldx agentgateway upgrade --dry-run  # render only; touch nothing
```

What it does:

1. Detects the current running image tag from the deployment.
2. Resolves the target (the pinned `AGENTGATEWAY_IMAGE` if omitted; a bare version gets a `v` prefix).
3. Prints the plan ` vX.Y.Z -> vA.B.C` (a no-op when already at the target).
4. Runs `kubectl set image` and waits for the rollout to complete.
5. Verifies the new pod's image matches the target, and reminds you to check the UI (and SSO, if configured).

The pinned constant is the source of truth for fresh installs; re-run `ldx agentgateway install` after bumping it if
you want new workspaces to start at the newer version.
