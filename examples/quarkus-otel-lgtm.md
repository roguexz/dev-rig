# Configuring Quarkus with the OpenTelemetry Stack

To get your Quarkus application to send all its telemetry data (traces, logs, and metrics) to the deployed OTel stack, you need to add the OpenTelemetry extension and configure a single endpoint.

## 1. Add Quarkus OpenTelemetry Extension

Add the following dependency to your `pom.xml`:

```xml
<dependency>
    <groupId>io.quarkus</groupId>
    <artifactId>quarkus-opentelemetry</artifactId>
</dependency>
```

## 2. Configure `application.properties`

You need to tell your Quarkus application where to send the telemetry data. The configuration depends on whether you are running your application on your host machine or inside the Kubernetes cluster.

### For Local Development (on Host Machine)

When running your app directly on your host (e.g., via `./gradlew quarkus:dev`), use `localhost` to connect to the OpenTelemetry Collector.

```properties
# Enable OpenTelemetry
quarkus.opentelemetry.enabled=true

# --- OTLP Endpoint (gRPC) ---
# Send everything (traces, metrics, logs) to the collector
quarkus.opentelemetry.tracer.exporter.otlp.endpoint=http://localhost:4317
quarkus.opentelemetry.metric.exporter.otlp.endpoint=http://localhost:4317
quarkus.opentelemetry.log.exporter.otlp.endpoint=http://localhost:4317

# --- LOGS ---
# Ensure logs are also sent via OTLP
quarkus.log.handler.opentelemetry.enabled=true
```

### For Kubernetes Deployment (In-Cluster)

When running your app as a pod inside the cluster, use the Kubernetes service DNS name.

```properties
# Enable OpenTelemetry
quarkus.opentelemetry.enabled=true

# --- OTLP Endpoint (gRPC) ---
# Send everything (traces, metrics, logs) to the collector
quarkus.opentelemetry.tracer.exporter.otlp.endpoint=http://otel-collector.commons.svc.cluster.local:4317
quarkus.opentelemetry.metric.exporter.otlp.endpoint=http://otel-collector.commons.svc.cluster.local:4317
quarkus.opentelemetry.log.exporter.otlp.endpoint=http://otel-collector.commons.svc.cluster.local:4317

# --- LOGS ---
# Ensure logs are also sent via OTLP
quarkus.log.handler.opentelemetry.enabled=true
```

This unified push-based approach simplifies configuration, as you no longer need to worry about exposing a separate `/metrics` endpoint for scraping.
