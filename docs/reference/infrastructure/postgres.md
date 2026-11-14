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
[Configuration](../../ldx.md#configuration)), sets the default password to
`changeit`, and runs initialization SQL scripts to enable the `vector` extension.

### `ldx postgres uninstall`

This command removes PostgreSQL from the platform release, including its persistent storage PVC, leaving the namespace
and the other services intact.

## Connecting to PostgreSQL

The PostgreSQL service is exposed in two ways to support different development workflows.

### From the Host Machine

A `LoadBalancer` service is created, which Rancher Desktop automatically exposes to your host. For applications running
directly on your host OS, use the following connection details:

- **Host:** `localhost`
- **Port:** `5432` (or via NodePort `30432`)
- **Username:** `postgres`
- **Password:** `changeit`
- **Database:** `postgres`
- **Connection URI:** `postgresql://postgres:changeit@localhost:5432/postgres`

### From Inside the Kubernetes Cluster

For applications running as pods inside the Kubernetes cluster (in any namespace), use the internal Kubernetes DNS name
to connect:

- **Host:** `postgresql.commons.svc.cluster.local`
- **Port:** `5432`
- **Username:** `postgres`
- **Password:** `changeit`
- **Database:** `postgres`
- **Connection URI:** `postgresql://postgres:changeit@postgresql.commons.svc.cluster.local:5432/postgres`

*Note: `commons` in the DNS name is the deployment namespace; substitute your custom namespace if one is configured.*
