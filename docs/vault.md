# HashiCorp Vault (`ldx vault`)

This command manages the deployment and lifecycle of a local HashiCorp Vault instance. It is deployed in "standalone"
mode (not "dev" mode), which more closely mirrors a production environment by requiring an explicit initialization and
unseal process.

## Commands

### `ldx vault setup`

This command installs Vault, creates a default admin user, and exposes the UI via a Traefik Ingress.

### `ldx vault status`

This command shows the current status of the Vault installation, including whether the pod is running,
whether Vault is sealed or unsealed, and the URLs to access it.

### `ldx vault unseal` (or `ldx-vault unseal`)

This command unseals the Vault after a restart. You can run this directly from any directory once `ldx` binaries are
installed in your local PATH (`ldx install`).

### `ldx vault seal`

This command manually seals the Vault.

### `ldx vault create-user <username>`

Creates (or updates) a userpass user with identity metadata, so OIDC clients can show a real name/email instead of a
raw entity UUID.

```bash
ldx vault create-user alice --full-name "Alice Example" --email alice@example.com
# password is prompted (leave empty to keep an existing user's password)
ldx vault create-user alice --email alice-new@example.com   # update email only
```

- `--password <pass>` — password (prompted when omitted; an empty response keeps the existing password)
- `--full-name <name>` / `--email <email>` — stored as entity metadata; omitted values keep their previous value
- `--policies <list>` — Vault policies for the user (default: `default`)

The command materializes the user's Vault identity entity and writes the metadata onto it. The shared OIDC
`profile` scope (see below) renders these values into `name`/`email` claims for any client that requests it.
`setup` does the same for the built-in `admin` user (`Administrator` / `admin@rd.localhost`).

### OIDC profile scope

`setup` and `create-user` ensure a shared OIDC scope exists at `identity/oidc/scope/profile`:

```
{"name": {{identity.entity.metadata.full_name}}, "email": {{identity.entity.metadata.email}}}
```

OIDC providers list it via `scopes_supported=profile` (Vault adds `openid` implicitly — passing it explicitly is an
error), and clients request it at authorize time. Users without metadata simply get empty `name`/`email` claims;
token issuance never fails. Services such as `ldx agentgateway sso` reference this scope rather than creating it.

### `ldx vault uninstall`

This command completely removes Vault, its persistent data, and its related configurations.

## Connecting to Vault

### From the Host Machine (or for UI Access)

The Vault UI and API are exposed via a Traefik Ingress. For applications running directly on your host OS or for
accessing the UI in your browser, use the following address:

- **Vault Address:** `https://vault.rogue.io` (or `https://vault.rd.localhost`)
- **UI Username:** `admin`
- **UI Password:** `changeit`

### From Inside the Kubernetes Cluster

For applications running as pods inside the Kubernetes cluster, it is best practice to use the internal Kubernetes
service DNS name. This avoids a round-trip through the external ingress.

- **Vault Address:** `http://vault.commons.svc.cluster.local:8200`

*Note: The connection is `http` (not `https`) for in-cluster communication because you are connecting directly to the
service port, bypassing the TLS termination at the Traefik ingress.*

> **See:** The [`examples/vault-agent-injection.yaml`](../examples/vault-agent-injection.yaml) file for the recommended
> approach to inject secrets into pods using Kubernetes Service Account authentication, which does not require sharing
> tokens or credentials in your application's configuration.
