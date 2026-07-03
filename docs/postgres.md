# PostgreSQL with pgvector (`rd-setup postgres`)

This command deploys a standalone PostgreSQL instance in the Kubernetes cluster with the `pgvector` extension enabled
and exposes it so that it is accessible directly from your host machine.

## Commands

### `rd-setup postgres install`

This command installs a standalone PostgreSQL instance into the `commons` namespace, sets the default password to
`changeit`, and runs initialization SQL scripts to enable the `vector` extension.

### `rd-setup postgres uninstall`

This command cleans up the PostgreSQL deployment, including the persistent storage PVC, leaving the `commons` namespace
intact.

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
