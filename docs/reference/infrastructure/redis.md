# Redis Stack (`ldx redis`)

This command deploys a standalone Redis instance in the Kubernetes cluster and exposes it so that it is accessible
directly from your host machine.

`ldx redis` is a thin alias for the declarative platform stack: it runs `ldx k8s up/down --services redis`. Redis is a
subchart of the `ldx-local-platform` umbrella chart, so its lifecycle, values and diffs are shared with the other
services - see [the platform stack reference](./k8s.md).

## Commands

### `ldx redis install`

This command installs a standalone Redis instance into the configured namespace (default `commons`, see
[Configuration](../../ldx.md#configuration)).

Fresh installs get a random per-installation password. It is generated once and stored in two places: the host secret
store (macOS Keychain item `ldx/redis/credentials/PASSWORD`, or a file under the cache directory on other hosts) and
the Kubernetes Secret `redis`, which the chart consumes via `auth.existingSecret`. A leaked password is therefore valid
only for that machine's cluster. Run `ldx redis print-password` to print it.

Installs that predate this feature run unauthenticated; nothing is rotated in place. To move an old install behind a
random password, run `ldx k8s down --services redis` and install again.

### `ldx redis status`

This command shows the Redis pod status and the host/cluster endpoints. It does not print the password.

### `ldx redis print-password`

This command prints the Redis password as a raw value on stdout, for composition:
`REDISCLI_AUTH="$(ldx redis print-password)" redis-cli ping`.

### `ldx redis uninstall`

This command removes Redis from the platform release, leaving the namespace and the other services intact. Redis keeps
no persistent volume, so nothing survives; PostgreSQL's PVC is unaffected.

## Connecting to Redis

The Redis service is exposed in two ways to support different development workflows.

### From the Host Machine

A `LoadBalancer` service is created, which Rancher Desktop automatically exposes to your host. For applications running
directly on your host OS (e.g., via a local Gradle or Maven command), use the following connection string (the
password is printed by `ldx redis print-password`; on pre-random-password installs the instance is unauthenticated, so the URI
is `redis://localhost:6379`):

- **Redis URI:** `redis://:<password>@localhost:6379`

With `redis-cli`, pass `-a '<password>'` (or set `REDISCLI_AUTH`).

### From Inside the Kubernetes Cluster

For applications running as pods inside the Kubernetes cluster (in any namespace), use the internal Kubernetes DNS name
to connect:

- **Redis URI:** `redis://:<password>@redis-master.commons.svc.cluster.local:6379`

In-cluster apps can read the password from the Kubernetes Secret `redis` in the deployment namespace (key
`redis-password`) instead of embedding it.

*Note: The service is named `redis-master` by the Bitnami Helm chart. `commons` in the DNS name is the deployment
namespace; substitute your custom namespace if one is configured.*
