# OpenTelemetry Stack (`ldx otel`)

`ldx otel` is a thin alias for the declarative platform stack: it runs `ldx k8s up/down --services otel`. The LGTM
stack is a subchart of the `ldx-local-platform` umbrella chart - see
[the platform stack reference](../infrastructure/k8s.md).

**Prerequisite:** Authelia must be installed before OTel. Grafana's basic
username/password login is disabled; users can only sign in through Authelia
OIDC. Run `ldx authelia install` first.

This command deploys a complete, push-based observability stack based on the `docker-otel-lgtm` model. It allows you to
send logs, traces, and metrics from your applications to a single endpoint and visualize them in Grafana.

The core of this stack is the **OpenTelemetry Collector**, which receives all your data and routes it to the correct
backend:

- **Logs** are sent to **Loki**.
- **Traces** are sent to **Tempo**.
- **Metrics** are sent to **Prometheus**.

All components are deployed into the shared `commons` namespace by default; a custom namespace can be configured, see
[Configuration](../../ldx.md#configuration).

## Commands

### `ldx otel install`

This command installs and configures the entire stack. It requires Authelia to
be running; otherwise it fails with instructions to install Authelia first.

### `ldx otel uninstall`

This command removes all components related to the OTel stack, but leaves the namespace intact.

### `ldx otel status`

This command shows the current deployment state: pod status, OTLP endpoints,
Grafana URL, and OIDC configuration.

### `ldx otel sso enable`

This command enables Authelia OIDC SSO for Grafana without a full reinstall.
It updates the Helm release with the current OIDC configuration and triggers a
rollout of the LGTM pod. Use this if you reinstall Authelia or change its
configuration.

`ldx otel sso disable` is not available: Grafana's basic login is disabled, so
removing OIDC would lock out all users.

## Sending Telemetry Data

The OpenTelemetry Collector is exposed to your machine, allowing you to send data from applications running both locally
on your host and inside the cluster.

### From the Host Machine

For applications running directly on your host OS (e.g., via a local Gradle or Maven command), send all OTLP telemetry
to:

- **gRPC Endpoint:** `localhost:4317`
- **HTTP Endpoint:** `localhost:4318`

### From Inside the Kubernetes Cluster

For applications running as pods inside the Kubernetes cluster (in any namespace), use the internal Kubernetes DNS name
to send all OTLP telemetry to:

- **gRPC Endpoint:** `otel-collector.commons.svc.cluster.local:4317`
- **HTTP Endpoint:** `otel-collector.commons.svc.cluster.local:4318`

*Note: `commons` in the DNS names is the deployment namespace; substitute your custom namespace if one is configured.*

## Accessing Grafana

Once installed, you can access the Grafana dashboard to view your logs, traces, and metrics.

- **URL:** `https://otel.rd.localhost`

### Authentication

Grafana uses OIDC SSO through Authelia. Basic username/password login is
disabled. When you open Grafana, the login page shows only the "Sign in with
Authelia" button, which redirects to `auth.rd.localhost` and prompts Touch ID.

If Authelia is unavailable, you cannot log in to Grafana. This is intentional:
there is no password fallback.

The service is exposed via a Traefik Ingress and uses the locally trusted TLS certificate, so you can access it
directly without needing to use `kubectl port-forward`.

> **See:** [`examples/quarkus-otel-lgtm.md`](../examples/quarkus-otel-lgtm.md) for detailed instructions on configuring
> a Quarkus application to send telemetry data to this stack.
