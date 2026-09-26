# HashiCorp Vault (`ldx vault`)

This command manages the deployment and lifecycle of a local HashiCorp Vault instance. It is deployed in "standalone"
mode (not "dev" mode), which more closely mirrors a production environment by requiring an explicit initialization and
unseal process.

## Commands

### `ldx vault setup`

This command installs Vault, creates a default admin user, and exposes the UI via a Traefik Ingress.

### `ldx vault unseal` (or `ldx-vault unseal`)

This command unseals the Vault after a restart. You can run this directly from any directory once `ldx` binaries are
installed in your local PATH (`ldx install`).

### `ldx vault seal`

This command manually seals the Vault.

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
