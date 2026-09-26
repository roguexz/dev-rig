# Redis Stack (`ldx redis`)

This command deploys a standalone Redis instance in the Kubernetes cluster and exposes it so that it is accessible
directly from your host machine.

## Commands

### `ldx redis install`

This command installs a standalone, unauthenticated Redis instance into the `commons` namespace.

### `ldx redis uninstall`

This command cleans up the Redis deployment, leaving the `commons` namespace intact.

## Connecting to Redis

The Redis service is exposed in two ways to support different development workflows.

### From the Host Machine

A `LoadBalancer` service is created, which Rancher Desktop automatically exposes to your host. For applications running
directly on your host OS (e.g., via a local Gradle or Maven command), use the following connection string:

- **Redis URI:** `redis://localhost:6379`

### From Inside the Kubernetes Cluster

For applications running as pods inside the Kubernetes cluster (in any namespace), use the internal Kubernetes DNS name
to connect:

- **Redis URI:** `redis://redis-master.commons.svc.cluster.local:6379`

*Note: The service is named `redis-master` by the Bitnami Helm chart.*
