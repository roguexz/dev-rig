# Cert-Manager (`ldx certmanager`)

This command automates the installation and configuration of `cert-manager`, a powerful tool for managing TLS
certificates within Kubernetes.

This setup configures `cert-manager` with a `ClusterIssuer` that can sign new certificate requests using the locally
trusted `mkcert` root CA. This is ideal for a development environment, as it allows you to issue valid certificates for
your applications that are automatically trusted by your browser.

## Commands

### `ldx certmanager install`

This command performs the following actions:

1. **Adds Helm Repo:** Adds the official `jetstack` Helm repository.
2. **Installs `cert-manager`:** Deploys `cert-manager` and its Custom Resource Definitions (CRDs) into the
   `cert-manager` namespace using its official Helm chart.
3. **Creates CA Secret:** Creates a Kubernetes `Secret` in the `cert-manager` namespace containing the `mkcert` root CA
   certificate and key.
4. **Creates `ClusterIssuer`:** Deploys a `ClusterIssuer` resource named `mkcert-issuer`. This issuer uses the CA secret
   to sign new certificate requests, effectively allowing `cert-manager` to issue locally trusted certificates.
5. **Creates CA Secret:** Creates a `Secret` (`mkcert-ca-bundle`) in `kube-system` with the mkcert CA. This is
   used by Traefik for backend pod connections (see Traefik ServersTransport below).
6. **Creates Traefik ServersTransport:** If the `ServersTransport` CRD is available, creates a `ServersTransport`
   resource (`mkcert-ca`) in `kube-system` that references the CA Secret. This configures Traefik's backend
   TLS transport for re-encryption setups.

After installation, you can request certificates by referencing `mkcert-issuer` in your `Ingress` or `Certificate`
resources.

## Traefik ServersTransport (backend TLS transport)

For services that terminate their own TLS (like Authelia), Traefik connects to the pod via HTTPS (TLS
re-encryption). The `ServersTransport` resource configures how Traefik connects to backends.

The `mkcert-ca` `ServersTransport` is created in `kube-system` with:
- `rootCAsSecrets: [mkcert-ca-bundle]` — references the mkcert CA Secret
- `insecureSkipVerify: true` — required because the `rootCAsSecrets` field does not enable verification
  in this Traefik version. Connections are still encrypted (HTTPS), just not verified.

Services that use TLS re-encryption add these annotations to their Service:

```yaml
annotations:
  traefik.ingress.kubernetes.io/service.passhostheader: "true"
  traefik.ingress.kubernetes.io/service.serverstransport: kube-system-mkcert-ca@kubernetescrd
```

The `serverstransport` annotation tells Traefik to use the `ServersTransport` resource when connecting to the
backend. The `ServersTransport` implicitly configures HTTPS.

If the `ServersTransport` CRD is not available (e.g. older Traefik versions), use `serversslVerify: "false"`
instead to skip backend verification:

```yaml
annotations:
  traefik.ingress.kubernetes.io/service.passhostheader: "true"
  traefik.ingress.kubernetes.io/service.serversslVerify: "false"
```

## Examples

The [`examples/`](../examples/) directory contains two manifests demonstrating the TLS patterns supported by this setup.

### Edge Termination (`tls-edge-termination.yaml`)

Traefik terminates TLS at the ingress; the pod receives plain HTTP. This is the simplest pattern and works for
most services.

```bash
kubectl apply -f examples/tls-edge-termination.yaml
curl -k https://whoami-edge.rd.localhost
```

cert-manager automatically creates the certificate (via the `cert-manager.io/cluster-issuer` annotation on the
Ingress) and Traefik uses it to terminate TLS.

### Pod Termination (`tls-pod-termination.yaml`)

The pod terminates its own TLS. Traefik terminates the client's TLS, then initiates a **new** TLS connection to
the pod (TLS re-encryption), verifying the pod's certificate with the mkcert CA.

Use this pattern for services that require end-to-end encryption or manage their own certificates (like Authelia
with WebAuthn).

```bash
kubectl apply -f examples/tls-pod-termination.yaml
curl -k https://whoami-e2e.rd.localhost
```

The example deploys `stefanprodan/podinfo` configured to listen on HTTPS with a certificate issued by
`mkcert-issuer`. The Service annotations tell Traefik to connect via HTTPS and verify the pod's certificate.

> **Note:** Both examples use `*.rd.localhost` hostnames, which are covered by the wildcard certificate created
> by `ldx tls install`. If you've run `mkcert -install` on your host, you can drop the `-k` flag from `curl`
> since your browser/OS trusts the mkcert CA.

To clean up:
```bash
kubectl delete -f examples/tls-edge-termination.yaml
kubectl delete -f examples/tls-pod-termination.yaml
```

### `ldx certmanager uninstall`

This command cleanly removes all `cert-manager` components:

1. Deletes the `mkcert-ca-bundle` `Secret` from `kube-system`.
2. Deletes the `mkcert-ca` `ServersTransport` from `kube-system` (if the CRD is available).
3. Deletes the `mkcert-issuer` `ClusterIssuer`.
4. Deletes the `mkcert-ca` `ClusterTrustBundle` (or `TrustBundle`).
5. Uninstalls the `cert-manager` Helm release.
6. Deletes the `cert-manager` namespace and all resources within it.

## ClusterTrustBundle (CA distribution to pods)

In addition to creating the `ClusterIssuer`, `ldx certmanager install` creates a **ClusterTrustBundle**
(named `mkcert-ca`) that distributes the mkcert root CA to pods. This allows services inside the cluster
(Vault, Grafana, agentgateway) to verify TLS certificates signed by the mkcert CA (e.g., Authelia's cert).

Deployment scripts reference the ClusterTrustBundle via **volume projection** in their pod specs:

```yaml
volumes:
  - name: trust-bundle
    projected:
      sources:
        - clusterTrustBundle:
            name: mkcert-ca
            path: ca-bundle.pem
            optional: true
```

The CA is then available at the mount path (e.g., `/etc/ssl/trust/ca-bundle.pem`), and services set
`SSL_CERT_FILE` / `CURL_CA_BUNDLE` to point there.

### Rancher Desktop / K3s Configuration

K3s (used by Rancher Desktop) requires the `ClusterTrustBundle` feature gates to be explicitly enabled.
Without this, the ClusterTrustBundle API is not available and pods cannot reference it.

To enable it, create or edit the Rancher Desktop Lima override file:

```
~/Library/Application Support/rancher-desktop/lima/_config/override.yaml
```

Add the following content:

```yaml
provision:
  - mode: system
    script: |
      #!/bin/sh
      mkdir -p /etc/rancher/k3s/config.yaml.d
      cat <<'EOF' > /etc/rancher/k3s/config.yaml.d/90-clustertrustbundle.yaml
      kube-apiserver-arg:
        - "feature-gates=ClusterTrustBundle=true,ClusterTrustBundleProjection=true"
        - "runtime-config=certificates.k8s.io/v1beta1=true"
      EOF
```

Then **restart Rancher Desktop** for the changes to take effect.

Verify the feature is enabled:

```bash
kubectl api-resources --api-group=certificates.k8s.io --namespaced=false
```

You should see `clustertrustbundles` listed.

> **Note:** If `ldx certmanager install` warns that the ClusterTrustBundle API is not available,
> it's likely because these feature gates are not enabled. Apply the configuration above and restart
> Rancher Desktop before re-running the install.
