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

It drives Vault with the `vault` CLI over the ingress (`https://vault.rd.localhost`), authenticating with the root token
cached in `~/.cache/local-dev/vault/keys.json`; that host is on the mkcert wildcard `ldx tls` issues (`*.rd.localhost`) and
installs into the system trust store, so the CLI verifies it without `-k`. If the user has no identity entity yet (they never
logged in), the command creates one and binds its `userpass` alias, so the first login maps onto that entity. Existing
metadata keys and the entity name Vault assigned are preserved.

### OIDC profile scope

`setup` and `create-user` ensure a shared OIDC scope exists at `identity/oidc/scope/profile`:

```
{"name": {{identity.entity.metadata.full_name}}, "email": {{identity.entity.metadata.email}}}
```

OIDC providers list it via `scopes_supported=profile` (Vault adds `openid` implicitly — passing it explicitly is an
error), and clients request it at authorize time. Users without metadata simply get empty `name`/`email` claims;
token issuance never fails. Services such as `ldx agentgateway sso` reference this scope rather than creating it.

### `ldx vault upgrade [chart-version]`

Upgrades Vault to a Helm chart version, with a pre-upgrade snapshot and post-upgrade checks.

```bash
ldx vault upgrade            # jump to the latest chart
ldx vault upgrade 0.34.1     # pin a specific chart version
ldx vault upgrade --dry-run  # render only; touch nothing
```

What it does:

1. Resolves the target (latest chart if omitted) and prints the plan
   `chart X (Vault a) -> chart Y (Vault b)`.
2. Requires an unsealed, running Vault, then saves a storage snapshot
   (Raft snapshot, or a tar of `/vault/data` for the standalone file backend)
   into `~/.cache/local-dev/vault/snapshots/`.
3. Runs `helm upgrade` with the rig's own `--set` values (not `--reuse-values`,
   which breaks across chart majors that add new value sections) and
   `--force-conflicts` (the injector controller owns the webhook `caBundle`).
4. Recreates `vault-0` to load the new image — this chart uses an `OnDelete`
   rollout — then unseals it and waits for readiness.
5. Smoke-tests the OIDC issuer discovery endpoint (no token needed) to confirm
   identity data survived, and records the new version in the cache.

Vault refuses to start against storage written by a **newer** version, so the
snapshot is the only downgrade path: redeploy the older chart and restore the
snapshot into the PVC if you must roll back.

### `ldx vault snapshot`

Saves a storage snapshot (Raft or file backend, auto-detected) to
`~/.cache/local-dev/vault/snapshots/`. The Vault must be unsealed. `upgrade`
calls this for you before it changes anything.

### Version cache

`setup` and `upgrade` write `~/.cache/local-dev/vault/version.json` recording
the chart/app version installed, the base version, and the previous one, so a
later downgrade or audit can see what this workspace was built against.

### `ldx vault uninstall`

This command completely removes Vault, its persistent data, and its related configurations.

## Connecting to Vault

### From the Host Machine (or for UI Access)

The Vault UI and API are exposed via a Traefik Ingress. For applications running directly on your host OS or for
accessing the UI in your browser, use the following address:

- **Vault Address:** `https://vault.rd.localhost`
- **UI Username:** `admin`
- **UI Password:** `changeit`

`vault.rd.localhost` resolves to loopback on its own and is covered by the certificate `ldx tls` issues, so the UI and the
CLI work without an `/etc/hosts` entry or `-k`. An install made before this host was used still publishes
`vault.rogue.io` on the ingress; `ldx vault setup` moves it.

With the `vault` CLI (see Prerequisites in the README):

```bash
export VAULT_ADDR=https://vault.rd.localhost
vault login -method=userpass username=admin        # writes ~/.vault-token
vault login -no-store -method=userpass username=admin   # ...without touching it
```

`ldx vault create-user` uses this same address, with the cached root token instead of a login.

### From Inside the Kubernetes Cluster

For applications running as pods inside the Kubernetes cluster, it is best practice to use the internal Kubernetes
service DNS name. This avoids a round-trip through the external ingress.

- **Vault Address:** `http://vault.commons.svc.cluster.local:8200`

*Note: `commons` in the DNS name is the deployment namespace; substitute your custom namespace if one is configured.
The connection is `http` (not `https`) for in-cluster communication because you are connecting directly to the
service port, bypassing the TLS termination at the Traefik ingress.*

> **See:** The [`examples/vault-agent-injection.yaml`](../examples/vault-agent-injection.yaml) file for the recommended
> approach to inject secrets into pods using Kubernetes Service Account authentication, which does not require sharing
> tokens or credentials in your application's configuration.
