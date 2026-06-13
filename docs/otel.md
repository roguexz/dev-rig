# OpenTelemetry Stack (`rd-setup otel`)

This command deploys a complete, push-based observability stack based on the `docker-otel-lgtm` model. It allows you to send logs, traces, and metrics from your applications to a single endpoint and visualize them in Grafana.

The core of this stack is the **OpenTelemetry Collector**, which receives all your data and routes it to the correct backend:

-   **Logs** are sent to **Loki**.
-   **Traces** are sent to **Tempo**.
-   **Metrics** are sent to **Prometheus**.

All components are deployed into the shared `commons` namespace.

## Commands

### `rd-setup otel install`

This command installs and configures the entire stack.

### `rd-setup otel uninstall`

This command removes all components related to the OTel stack, but leaves the `commons` namespace intact.

## Sending Telemetry Data

The OpenTelemetry Collector is exposed to your machine, allowing you to send data from applications running both locally on your host and inside the cluster.

### From the Host Machine

For applications running directly on your host OS (e.g., via a local Gradle or Maven command), send all OTLP telemetry to:

-   **gRPC Endpoint:** `localhost:4317`
-   **HTTP Endpoint:** `localhost:4318`

### From Inside the Kubernetes Cluster

For applications running as pods inside the Kubernetes cluster (in any namespace), use the internal Kubernetes DNS name to send all OTLP telemetry to:

-   **gRPC Endpoint:** `otel-collector.commons.svc.cluster.local:4317`
-   **HTTP Endpoint:** `otel-collector.commons.svc.cluster.local:4318`

## Accessing Grafana

Once installed, you can access the Grafana dashboard to view your logs, traces, and metrics.

-   **URL:** `https://otel.rd.localhost`
-   **Username:** `admin`
-   **Password:** `changeit`

The service is exposed via a Traefik Ingress and uses the locally trusted TLS certificate, so you can access it directly without needing to use `kubectl port-forward`.

> **See:** [`examples/quarkus-otel-lgtm.md`](../examples/quarkus-otel-lgtm.md) for detailed instructions on configuring a Quarkus application to send telemetry data to this stack.
