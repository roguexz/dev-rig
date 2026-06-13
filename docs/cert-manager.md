# Cert-Manager (`rd-setup certmanager`)

This command automates the installation and configuration of `cert-manager`, a powerful tool for managing TLS
certificates within Kubernetes.

This setup configures `cert-manager` with a `ClusterIssuer` that can sign new certificate requests using the locally
trusted `mkcert` root CA. This is ideal for a development environment, as it allows you to issue valid certificates for
your applications that are automatically trusted by your browser.

## Commands

### `rd-setup certmanager install`

This command performs the following actions:

1. **Adds Helm Repo:** Adds the official `jetstack` Helm repository.
2. **Installs `cert-manager`:** Deploys `cert-manager` and its Custom Resource Definitions (CRDs) into the
   `cert-manager` namespace using its official Helm chart.
3. **Creates CA Secret:** Creates a Kubernetes `Secret` in the `cert-manager` namespace containing the `mkcert` root CA
   certificate and key.
4. **Creates `ClusterIssuer`:** Deploys a `ClusterIssuer` resource named `mkcert-issuer`. This issuer uses the CA secret
   to sign new certificate requests, effectively allowing `cert-manager` to issue locally trusted certificates.

After installation, you can request certificates by referencing `mkcert-issuer` in your `Ingress` or `Certificate`
resources.

> **See:** The [`examples/`](../examples/) directory for detailed manifests demonstrating both edge and end-to-end TLS
> patterns.
> - [`cert-manager-edge.yaml`](../examples/cert-manager-edge.yaml)
> - [`cert-manager-e2e.yaml`](../examples/cert-manager-e2e.yaml)

### `rd-setup certmanager uninstall`

This command cleanly removes all `cert-manager` components:

1. Deletes the `mkcert-issuer` `ClusterIssuer`.
2. Uninstalls the `cert-manager` Helm release.
3. Deletes the `cert-manager` namespace and all resources within it.
