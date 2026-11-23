# PostgreSQL with pgvector (`ldx postgres`)

This command deploys a standalone PostgreSQL instance in the Kubernetes cluster with the `pgvector` extension enabled
and exposes it so that it is accessible directly from your host machine.

`ldx postgres` is a thin alias for the declarative platform stack: it runs `ldx k8s up/down --services postgres
--purge-data` (uninstall). PostgreSQL is a subchart of the `ldx-local-platform` umbrella chart - see
[the platform stack reference](./k8s.md).

Before installing, `ldx k8s` builds the `local/bitnami-postgresql-pgvector:18` image in the Rancher Desktop Docker
context if it is not present: the pgvector extension is grafted onto the Bitnami PostgreSQL base image, which is why
the chart pins an image built on the host rather than pulling one.

## Commands

### `ldx postgres install`

This command installs a standalone PostgreSQL instance into the configured namespace (default `commons`, see
[Configuration](../../ldx.md#configuration)), and runs initialization SQL scripts to enable the `vector` extension.

Fresh installs get a random per-installation password for the `postgres` superuser. It is generated once and stored in
two places: the host secret store (macOS Keychain item `ldx/postgresql/credentials/PASSWORD`, or a file under the
cache directory on other hosts) and the Kubernetes Secret `postgresql`, which the chart consumes via
`auth.existingSecret`. A leaked password is therefore valid only for that machine's cluster. Run `ldx postgres
print-password` to print it (raw value on stdout, composable as `$(ldx postgres print-password)`); to force a new one,
delete the keychain item and redeploy with `--purge-data`.

Installs that predate this feature keep the chart default password `changeit`; nothing is rotated in place. To move an
old install to a random password, run `ldx k8s down --services postgres --purge-data` and install again.

### `ldx postgres uninstall`

This command removes PostgreSQL from the platform release, including its persistent storage PVC, leaving the namespace
and the other services intact.

### `ldx postgres print-password`

This command prints the PostgreSQL password as a raw value on stdout, for composition:
`PGPASSWORD="$(ldx postgres print-password)" psql -h localhost -U postgres`. On a legacy install without a host secret
store entry it prints the password from the chart's Kubernetes Secret.

## Connecting to PostgreSQL

The PostgreSQL service is exposed in two ways to support different development workflows.

### From the Host Machine

A `LoadBalancer` service is created, which Rancher Desktop automatically exposes to your host. For applications running
directly on your host OS, use the following connection details:

- **Host:** `localhost`
- **Port:** `5432` (or via NodePort `30432`)
- **Username:** `postgres`
- **Password:** printed by `ldx postgres print-password` (fresh installs); `changeit` on pre-random-password installs
- **Database:** `postgres`
- **Connection URI:** `postgresql://postgres:<password>@localhost:5432/postgres`

### From Inside the Kubernetes Cluster

For applications running as pods inside the Kubernetes cluster (in any namespace), use the internal Kubernetes DNS name
to connect:

- **Host:** `postgresql.commons.svc.cluster.local`
- **Port:** `5432`
- **Username:** `postgres`
- **Password:** printed by `ldx postgres print-password` (fresh installs); `changeit` on pre-random-password installs
- **Database:** `postgres`
- **Connection URI:** `postgresql://postgres:<password>@postgresql.commons.svc.cluster.local:5432/postgres`

In-cluster apps can read the password from the Kubernetes Secret `postgresql` in the deployment namespace (key
`postgres-password`) instead of embedding it.

*Note: `commons` in the DNS name is the deployment namespace; substitute your custom namespace if one is configured.*
