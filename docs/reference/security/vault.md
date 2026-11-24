# HashiCorp Vault (`ldx vault`)

This command manages the deployment and lifecycle of a local HashiCorp Vault instance. It is deployed in "standalone"
mode (not "dev" mode), which more closely mirrors a production environment by requiring an explicit initialization and
unseal process.

## Commands

### `ldx vault install`

This command installs Vault, configures Authelia SSO (userpass login is disabled), enables the KV v2 secrets engine and
Kubernetes auth method, and exposes the UI via a Traefik Ingress. The secrets engine and auth method are also enabled
by `enable-secrets`, which can be run separately on existing installs.

Requires:
- Authelia deployed (`ldx authelia install`)
- Vault's pod resolves `auth.rd.localhost` to Traefik's ClusterIP (configured automatically by `ldx k8s`)

### `ldx vault status`

This command shows the current status of the Vault installation, including whether the pod is running,
whether Vault is sealed or unsealed, and the URLs to access it.

### Stale keys and re-initialization

Vault keys are stored in the host secret store (`ldx/vault/init_json`, macOS Keychain; legacy
`~/.cache/local-dev/vault/keys.json` is imported on first read). When the cluster is recreated (PVCs wiped), the
stored keys no longer match the fresh server. `ldx vault install` detects this: if the server reports
`.initialized=false` while keys exist in the store, it warns and re-initializes the server, storing the new keys
(the stale legacy `keys.json` is removed). `ldx vault unseal` fails fast with a clear message in the same situation instead of a bare
400. To re-initialize manually, delete the stored secret first (`ldx/vault/init_json`) and re-run `install`.

### `ldx vault unseal` (or `ldx-vault unseal`)

This command unseals the Vault after a restart. Run it from any directory once `ldx` is installed
(`brew install roguexz/ldx/ldx`), or invoke `bin/ldx` from a checkout.

### `ldx vault seal`

This command manually seals the Vault.

### `ldx vault create-user <username>`

Creates (or updates) a userpass user with identity metadata, so OIDC clients can show a real name/email instead of a
raw entity UUID. This command re-enables userpass if it was disabled by the default SSO configuration.

```bash
ldx vault create-user alice --full-name "Alice Example" --email alice@example.com
# password is prompted (leave empty to keep an existing user's password)
ldx vault create-user alice --email alice-new@example.com   # update email only
```

- `--password <pass>` - password (prompted when omitted; an empty response keeps the existing password)
- `--full-name <name>` / `--email <email>` - stored as entity metadata; omitted values keep their previous value
- `--policies <list>` - Vault policies for the user (default: `default`)

The command materializes the user's Vault identity entity and writes the metadata onto it. The shared OIDC
`profile` scope (see below) renders these values into `name`/`email` claims for any client that requests it.

> **Note:** Userpass login is disabled by default (SSO is the only login method). Creating a userpass user re-enables
> the userpass auth method. For most users, Authelia SSO is the preferred login path.

It drives Vault with the `vault` CLI over the ingress (`https://vault.rd.localhost`), authenticating with the root token
stored in the host secret store as `ldx/vault/init_json` (macOS Keychain; legacy
`~/.cache/local-dev/vault/keys.json` is imported on first read); that host is on the mkcert wildcard `ldx tls` issues (`*.rd.localhost`) and
installs into the system trust store, so the CLI verifies it without `-k`. If the user has no identity entity yet (they never
logged in), the command creates one and binds its `userpass` alias, so the first login maps onto that entity. Existing
metadata keys and the entity name Vault assigned are preserved.

### `ldx vault sso`

Re-configures Vault's OIDC auth method to use Authelia (deployed by `ldx authelia install`) as its identity provider.
SSO is configured automatically by `install`; this command re-applies the wiring without a full reinstall, for example
after changing the Authelia client secret.

After this, Vault logins redirect to Authelia, which presents Touch ID (WebAuthn) after the initial
password+enrollment setup.

Requires:
- Authelia deployed (`ldx authelia install`)
- Vault running and unsealed (`ldx vault install`, `ldx vault unseal`)

Userpass login is disabled (SSO is the only login method).

### `ldx vault enable-secrets`

Enables the KV v2 secrets engine and Kubernetes auth method for applications that need to store and retrieve secrets
from Vault:

1. **KV v2 secrets engine** at path `secret` - the standard path for application secrets.
2. **Kubernetes auth method** - configured with `kubernetes_host=https://kubernetes.default.svc:443` (the in-cluster
   API server URL) and `skip_tls_verify=true` (Rancher Desktop's self-signed cert is not in Vault's trust store). This
   allows pods to authenticate to Vault using their service account tokens, getting short-lived Vault tokens.

This command is idempotent: it is safe to re-run, and it skips steps that are already in place. It requires Vault to
be running and unsealed (`ldx vault unseal` first if sealed).

For new installs, `setup` runs this automatically.

> **Note:** MCP credential management is handled by [Bifrost](../ai/bifrost.md). Vault remains available for other
> use cases.

### OIDC profile scope

`install` and `create-user` ensure a shared OIDC scope exists at `identity/oidc/scope/profile`:

```
{"name": {{identity.entity.metadata.full_name}}, "email": {{identity.entity.metadata.email}}}
```

OIDC providers list it via `scopes_supported=profile` (Vault adds `openid` implicitly - passing it explicitly is an
error), and clients request it at authorize time. Users without metadata simply get empty `name`/`email` claims;
token issuance never fails.

The Authelia admin user (configured by `ldx authelia install`) has entity metadata `Administrator` /
`admin@rd.localhost`, so it renders correctly in the profile scope.

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
4. Recreates `vault-0` to load the new image - this chart uses an `OnDelete`
   rollout - then unseals it and waits for readiness.
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

Login is through Authelia SSO (userpass login is disabled). Open the UI and choose 'Authelia' (or 'OIDC') as the
login method; after the first login, Touch ID (WebAuthn) is used.

`vault.rd.localhost` resolves to loopback on its own and is covered by the certificate `ldx tls` issues, so the UI and the
CLI work without an `/etc/hosts` entry or `-k`. An install made before this host was used still publishes
`vault.rogue.io` on the ingress; `ldx vault install` moves it.

With the `vault` CLI (see Prerequisites in the README), you can log in through the OIDC flow:

```bash
export VAULT_ADDR=https://vault.rd.localhost
vault login -method=oidc   # opens a browser for the Authelia login
```

`ldx vault create-user` uses this same address, with the cached root token instead of a login. It re-enables userpass
for that user if it was disabled.

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
