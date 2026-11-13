# Platform Stack (`ldx k8s`)

One Helm release, `ldx`, deploys the local development services into a single namespace from the
`charts/ldx-local-platform` umbrella chart. Services are opt-in and recorded per namespace, so `ldx k8s up` is a
plain idempotent reconcile: it applies the recorded set without being told it again.

Per-service commands (`ldx redis`, `ldx postgres`) are thin aliases over this command.

## Commands

### `ldx k8s up [services] [options]`

Reconciles the release toward the recorded service set, adding any services named on the command line. Creates the
namespace, builds images the chart cannot build for itself, and adopts releases from before the umbrella chart.

```bash
ldx k8s up redis              # add redis, keep everything else
ldx k8s up                    # apply the recorded set (idempotent)
ldx k8s up redis postgres -f tuning.yaml
```

`-f, --values <file>` copies the file into `~/.config/ldx/k8s-values/` keyed by namespace, so later plain `up` runs
keep applying it.

### `ldx k8s down [services] [options]`

Disables the named services and reconciles the release to what remains. With no services - or when the set becomes
empty - the whole release is removed, namespace untouched.

```bash
ldx k8s down redis            # drop redis, keep postgres
ldx k8s down                  # remove the platform
ldx k8s down --purge-data     # ... and delete the PVCs
```

### `ldx k8s status`, `ldx k8s services`, `ldx k8s diff`

`status` shows the release, the recorded set, the enabled set in the release, and the pods. `services` prints just the
recorded names (one per line, for scripting). `diff` previews the next `up` (needs the
[helm-diff](https://github.com/databus23/helm-diff) plugin).

## Services

| Name          | Chart subchart                  | Host access        |
|---------------|---------------------------------|--------------------|
| `redis`       | Bitnami Redis                   | `localhost:6379`, NodePort 30379 |
| `postgres`    | Bitnami PostgreSQL + pgvector   | `localhost:5432`, NodePort 30432 |
| `otel`        | Grafana OTel LGTM (all-in-one)  | `https://otel.rd.localhost` (Grafana), OTLP `localhost:4317/4318` |
| `vault` | hashicorp vault 0.34.1 (Vault 2.0.4): single-node + agent injector, auto-unseal post-apply | `https://vault.rd.localhost` |
| `authelia` | Authelia OIDC provider (own subchart, keeps its namespace) | `https://auth.rd.localhost` (OIDC, WebAuthn) |
| `certmanager` | cert-manager + mkcert CA (own release) | ClusterIssuer `mkcert-issuer` |

`certmanager` runs as its own release (`ldx-cert-manager`, namespace `cert-manager`, chart
`charts/ldx-cert-manager`) because it spans namespaces and owns cluster-scoped resources.

## Configuration

- **Namespace**: `--namespace`, then `LDX_K8S_NAMESPACE`, `LDX_NAMESPACE`, then the value recorded by the previous run
  (default `commons`). See [Configuration](../../ldx.md#configuration).
- **Service set**: `~/.config/ldx/k8s-services`, one `<namespace>=<svc> <svc>` line per namespace.
- **Extra values**: `~/.config/ldx/k8s-values/<namespace>-<file>.values`.

## Chart layout

```
charts/ldx-local-platform/          # main release: 'ldx'
├── Chart.yaml              # umbrella; one opt-in dependency per service
├── values.yaml             # .enabled switches (CLI-owned) + tunable defaults
└── charts/
    ├── redis/              # vendored Bitnami Redis + host-access services
    ├── postgresql/         # vendored Bitnami PostgreSQL + host-access services
    └── otel/               # Grafana OTel LGTM + Grafana ingress/secret

charts/ldx-cert-manager/            # separate release: 'ldx-cert-manager'
└── vendored jetstack cert-manager + mkcert ClusterIssuer, trust bundles,
    and the Traefik ServersTransport (spans cert-manager + kube-system)
```

Each subchart vendors its upstream Bitnami chart, pinned to a specific chart version, and pins the resource names via
`fullnameOverride` to the names the pre-chart scripts used (`redis`, `postgresql`). Those two facts are what make the
migration safe: the chart recreates resources under the names Kubernetes already knows, so StatefulSets rebind to
existing PVCs instead of starting empty.

### Adopting a pre-chart install

`ldx k8s up` detects the per-tool releases the older scripts created (`redis`, `postgresql`) in the target namespace
and uninstalls them immediately before applying the umbrella release. Because the names match, the PVCs survive and are
rebound: an adopt-and-upgrade is not a data-losing reinstall. A legacy release in a *different* namespace is reported
and left alone.

### What stays in the CLI

Anything the chart cannot express:

- **Local image builds** - the pgvector image is built in the Rancher Desktop Docker context.
- **Secret handoffs** - Authelia's OIDC client secrets, Vault's unseal keys and the agentgateway API key live in the
  host secret store (see [securing your workflow](../../guides/securing-workflow.md)); Helm renders manifests that
  reference them, the CLI supplies them.
- **Dynamic state** - oMLX model sync, Vault unseal, MCP tool registration, port-forward helpers.

The remaining services (agentgateway) are still driven imperatively, and `tls` is a host-side tool; `ldx <service> install` keeps
working for them in the meantime.
