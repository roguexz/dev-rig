# Authelia (`ldx authelia`)

This command deploys [Authelia](https://www.authelia.com) — an open-source Identity Provider — on the local Kubernetes
cluster. It serves as a single OIDC provider for all web UIs in the dev-rig: **Vault**, **agentgateway**, and
**Grafana**. After one-time Touch ID (WebAuthn) enrollment, every login becomes a biometric prompt — no more passwords
to remember.

## Architecture

```
Browser ──(HTTPS via Traefik)──▶ auth.rd.localhost ──▶ Authelia (OIDC provider)
                                    │                    ├── SQLite DB (PVC)
                                    │                    ├── File Notifier (PVC)
                                    │                    └── Secrets (JWT, JWKS)
                                    │
vault.rd.localhost ────────────────▶ Vault (OIDC client)
agentgateway.rd.localhost ─────────▶ agentgateway (OIDC client)
otel.rd.localhost ─────────────────▶ Grafana (OIDC client)
```

All three apps redirect unauthenticated users to `https://auth.rd.localhost`. Authelia presents Touch ID (WebAuthn)
after the initial password+enrollment setup.

## Commands

### `ldx authelia install`

Deploys Authelia into the `authelia` namespace:

1. **Secrets**: Generates JWT, storage, session, and OIDC HMAC secrets. Generates an RSA 2048-bit key for OIDC token
   signing. Generates and caches OIDC client secrets for Vault, agentgateway, and Grafana (mode `0600`, stored at
   `~/.cache/local-dev/authelia/client_secrets`).
2. **Bootstrap user**: Prompts for a bootstrap password (generated in non-interactive mode) and hashes it with
   Argon2id. Creates a `users_database.yml` ConfigMap with the `admin` user.
3. **Configuration**: Creates the main `configuration.yaml` ConfigMap with WebAuthn settings (`rp_id: rd.localhost`),
   session cookies for `rd.localhost`, access control rules for all three apps, and three OIDC clients (vault,
   agentgateway, grafana).
4. **Storage**: Creates a PersistentVolumeClaim (`authelia-data`, 1Gi) for the SQLite database.
5. **Deployment**: Single replica with `Recreate` strategy (SQLite lock safety), `enableServiceLinks: false`,
   readiness/liveness probes on `/api/health`.
6. **Ingress**: Traefik Ingress for `auth.rd.localhost` with TLS (uses the mkcert wildcard cert from `ldx tls`).

After installation, run `ldx authelia enroll` for the one-time Touch ID enrollment.

### `ldx authelia enroll`

Guides the one-time Touch ID / WebAuthn enrollment with a step-by-step interactive flow:

1. **Step 1**: Shows all browser instructions upfront (sign in, click "Register device", click "ADD" next to WebAuthn
   Credentials), then opens your browser.
2. **Step 2**: Waits for you to reach the "Identity Verification" dialog in the browser.
3. **Step 3**: Fetches the one-time code from the Authelia notifier and displays it. You paste it back in the browser,
   click VERIFY, and complete the WebAuthn wizard (enter description, choose passkey location, tap Touch ID).
4. **Step 4**: Checks the notification file to confirm the WebAuthn credential was registered successfully.
5. **Step 5**: Runs both an API test and a browser test to verify Touch ID login works end-to-end.

After completion, future logins to Authelia and all OIDC clients trigger the native macOS Passkey prompt directly.

### `ldx authelia status`

Shows the Authelia deployment status (pod phase, OIDC discovery endpoint reachability).

### `ldx authelia uninstall`

Removes Authelia and all its resources (namespace, deployment, service, PVC, ConfigMaps, Secret). Optionally removes
the local cached secrets and keys.

## Wiring up apps

After Authelia is deployed and Touch ID is enrolled, wire up each app:

### Vault

```bash
ldx vault sso
```

Configures Vault's OIDC auth method to point at Authelia's discovery URL. Userpass (`admin/changeit`) remains
available as a fallback.

### agentgateway

```bash
ldx agentgateway sso
```

Configures the agentgateway UI to use Authelia as its OIDC provider. The UI login flow becomes:
`https://agentgateway.rd.localhost/ui` → `auth.rd.localhost` login → Touch ID → back to agentgateway.

### Grafana

```bash
ldx otel install
```

If Authelia is already deployed, `ldx otel install` automatically detects it and adds OIDC environment variables to
the Grafana deployment. If Authelia is not deployed, Grafana uses the default admin password (`admin/changeit`).

## Accessing Authelia

- **URL:** `https://auth.rd.localhost`
- **In-cluster:** `http://authelia.authelia.svc.cluster.local:9091`

## OIDC endpoints

- **Discovery:** `https://auth.rd.localhost/.well-known/openid-configuration`
- **Authorization:** `https://auth.rd.localhost/api/oidc/authorization`
- **Token:** `https://auth.rd.localhost/api/oidc/token`
- **UserInfo:** `https://auth.rd.localhost/api/oidc/userinfo`
- **JWKS:** `https://auth.rd.localhost/.well-known/jwks.json`

## Registered OIDC clients

| Client ID      | App             | Redirect URI                                                  |
|----------------|-----------------|---------------------------------------------------------------|
| `vault`        | HashiCorp Vault | `https://vault.rd.localhost/ui/vault/auth/oidc/oidc/callback` |
| `agentgateway` | agentgateway    | `https://agentgateway.rd.localhost/oauth/callback`            |
| `grafana`      | Grafana         | `https://otel.rd.localhost/login/generic_oauth`               |

All clients use `two_factor` authorization policy and request `openid profile email groups` scopes.

## User management

Authelia uses a file-based users database (`users_database.yml`). To add a user:

1. Generate an Argon2id hash:
   ```bash
   docker run --rm authelia/authelia:latest authelia crypto hash generate argon2 --password '<password>'
   ```
2. Edit the `users_database.yml` ConfigMap:
   ```bash
   kubectl edit configmap authelia-users -n authelia
   ```
3. Add the user with their email (must match the email in the target app).

Note: Users also need to be created in the target app (Vault via `ldx vault create-user`, Grafana auto-signs up on
first login).

## Troubleshooting

**OIDC discovery not reachable:** Ensure Traefik is configured with TLS (`ldx tls install`) and the mkcert CA is
trusted by your browser.

**Touch ID not prompting:** Ensure the `rp_id` (`rd.localhost`) matches the base domain of `auth.rd.localhost`, and
that the browser supports WebAuthn.

**Pod not starting:** Check logs with `kubectl logs -n authelia deploy/authelia`. Common issues:

- SQLite lock errors (resolved by the `Recreate` strategy)
- Environment variable conflicts (resolved by `enableServiceLinks: false`)

**Lost Touch ID access:** Use the bootstrap password as a fallback. It was displayed during `ldx authelia install`
(non-interactive mode) or entered by you (interactive mode).
