# agentgateway (`ldx agentgateway`)

This command deploys [agentgateway](https://agentgateway.dev) — an HTTP/gRPC gateway for LLM, MCP, and A2A traffic — as
a
pod in the Kubernetes cluster and exposes it via Traefik Ingress and an internal ClusterIP.

## Commands

### `ldx agentgateway install`

This command installs agentgateway into the `commons` namespace:

1. **Configuration**: Creates a ConfigMap (`agentgateway-config`) with a declarative configuration: a SQLite database at
   `/data/data.db`, a `default` gateway on port 4000, and the built-in UI served on that gateway. Previously synced
   oMLX models and an already-configured Vault SSO policy are preserved across re-installs.
2. **Persistent data**: Creates a PersistentVolumeClaim (`agentgateway-data`, 1Gi) mounted at `/data` for the SQLite
   database (LLM analytics, logs, sessions, and runtime data).
3. **Runtime secrets**: The Deployment loads the `agentgateway-secrets` Secret (optional) into the pod environment; the
   config file references values such as `$OMLX_API_KEY` and `$UI_CLIENT_SECRET` and agentgateway expands them at load
   time, so no secret material is stored in the ConfigMap.
4. **Deployment**: Deploys the pinned agentgateway image (`cr.agentgateway.dev/agentgateway:v1.6.0`) with the config
   mounted read-only at `/etc/agentgateway/config.yaml`.
5. **Service & Ingress Exposure**: Exposes the gateway via Traefik Ingress (`https://agentgateway.rd.localhost`) and
   an internal ClusterIP for in-cluster clients.

> **Note:** Configuration is declarative. Because the ConfigMap mount is read-only, changes made in the agentgateway UI
> do not survive a pod restart. To change the configuration permanently, edit the manifest in `bin/ldx-agentgateway`
> and re-run `ldx agentgateway install`, or use `sync-omlx` / `sso` below.

### `ldx agentgateway sync-omlx`

Syncs the models served by the local [omlx](https://github.com/jundot/omlx) server into the gateway's LLM routes:

1. Reads the omlx port and API key from `~/.omlx/settings.json`.
2. Fetches the model list from `http://localhost:<port>/v1/models` (helper models such as `MarkItDown` are excluded).
3. Writes an `llm.models` fragment to the `agentgateway-llm-models` ConfigMap and rolls the gateway, so each model is
   served at `https://agentgateway.rd.localhost/v1/...` and proxied to `http://host.docker.internal:<port>/v1`.
4. Stores the omlx API key in the `agentgateway-secrets` Secret (`OMLX_API_KEY`) unless key verification is disabled in
   omlx settings.

Use `--dry-run` to print the generated configuration without applying it. Re-run the command whenever the local model
list changes.

### `ldx agentgateway sso`

Enables Vault (deployed by `ldx vault setup`) as the OIDC identity provider for the agentgateway UI:

1. Creates a Traefik Ingress for `vault.rd.localhost` so the browser can reach Vault with a trusted certificate.
2. Inside the Vault pod, provisions the OIDC resources: signing key (`agentgateway-ui`), OIDC client (`agentgateway-ui`,
   redirect URI `https://agentgateway.rd.localhost/oauth/callback`), group (`agentgateway-ui-users`), assignment, and
   provider (`agentgateway`). The provider advertises
   `scopes_supported=profile` (the shared scope created by `ldx vault setup` / `create-user`).
3. Logs in with the Vault userpass backend (default `admin`/`changeit`, overridable with `--vault-username` /
   `--vault-password`) to discover the user's entity id and adds it to the group, then restarts the gateway.

The generated `ui.policies.oidc` block uses explicit provider mode: the `issuer` and `authorizationEndpoint` are the
browser-facing `vault.rd.localhost` URLs, while `tokenEndpoint` and `jwks` point at the in-cluster Vault service
(`http://vault.commons.svc.cluster.local:8200`), because pods resolve `*.rd.localhost` to loopback and do not trust the
mkcert CA. It also requests `scopes: [profile]`, so the UI shows each user's name and email (from Vault entity
metadata) instead of the raw entity UUID. Provision or update that metadata with `ldx vault create-user`.

Vault must be unsealed before running this command (`ldx vault unseal`).

> **Note:** Vault-side resources (`identity/oidc/{key,client,assignment,provider}/agentgateway*`,
> `identity/group/name/agentgateway-ui-users`) and the `vault-rd` Ingress are left in place by `uninstall`; clean them
> up manually if desired.

### `ldx agentgateway uninstall`

This command cleans up the agentgateway deployment, services, ingress, configuration, runtime secrets, and the SQLite
PVC, leaving the `commons` namespace intact.

## Accessing agentgateway

### From the Host Machine

- **HTTPS URL (Ingress):** `https://agentgateway.rd.localhost/ui`

Traefik also serves the same host in plaintext on port 80 (`http://agentgateway.rd.localhost/ui`) without forcing a
redirect, and the certificate from `ldx tls install` is trusted by the system keychain, so `curl` works without `-k`.

The UI is served on the gateway port. The admin interface (port 15000) binds to the pod's loopback interface and is
intentionally not reachable from outside the pod; the gateway-port UI is the supported, authenticatable path.

After `ldx agentgateway sso`, opening the UI redirects to `https://vault.rd.localhost` for login and back once the
Vault session is established.

### From Inside the Kubernetes Cluster

For applications running as pods inside the Kubernetes cluster (in any namespace), use the internal Kubernetes DNS name
to connect:

- **Endpoint:** `http://agentgateway.commons.svc.cluster.local:4000`

LLM clients can call `http://agentgateway.commons.svc.cluster.local:4000/v1/chat/completions` (and the rest of the
OpenAI-compatible surface) for models synced with `sync-omlx`, authenticating with the omlx API key.

## Upgrading

Bump the pinned image tag (`AGENTGATEWAY_IMAGE`) at the top of `bin/ldx-agentgateway` and re-run
`ldx agentgateway install`. The SQLite database persists in the PVC across upgrades; `uninstall` deletes it.
