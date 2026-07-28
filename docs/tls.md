# TLS & Traefik (`ldx tls`)

This command manages the creation of locally trusted TLS certificates using `mkcert` and configures Rancher Desktop's
built-in Traefik Ingress Controller to use them for HTTPS traffic.

## Commands

### `ldx tls install`

This is the main setup command. It performs the following actions idempotently:

1. **Installs the `mkcert` Root CA:** Runs `mkcert -install` to ensure the local root Certificate Authority is trusted
   by your operating system and browsers.
2. **Generates Certificates:** Creates a TLS certificate valid for the following domains and stores it in
   `~/.cache/local-dev/certs/`:
    - `localhost`
    - `*.rancher.localhost`
    - `*.rd.localhost`
    - `localhost.rogue.io`
    - `*.localhost.rogue.io`
3. **Creates a Kubernetes Secret:** Creates a `Secret` named `default-tls-secret` in the `kube-system` namespace
   containing the generated certificate and key.
4. **Configures Traefik:** Deploys a Traefik `TLSStore` resource that configures Traefik to use the `default-tls-secret`
   as the default certificate for any TLS-enabled Ingress that does not specify its own.

### `ldx tls keystore`

This command creates a custom Java keystore for use in Java-based applications (like Quarkus).

1. **Locates System Keystore:** Finds the `cacerts` file from the JDK specified by `$JAVA_HOME` (or the default macOS
   path).
2. **Copies Keystore:** Copies the system `cacerts` to `~/.cache/local-dev/certs/cacerts`.
3. **Imports Root CA:** Imports the `mkcert` root CA certificate into the new local keystore.

This allows Java applications configured to use this keystore to trust the locally generated certificates.

> **See:** [`examples/java-keystore.md`](../examples/java-keystore.md) for instructions on how to use this keystore in
> your application.

### `ldx tls uninstall`

This command cleans up all resources created by `install`:

1. Deletes the Traefik `TLSStore`.
2. Deletes the `default-tls-secret` from `kube-system`.
3. Deletes the generated certificate and key files from `~/.cache/local-dev/certs/`.

It does **not** uninstall the `mkcert` root CA from the system trust store. You can do this manually by running
`mkcert -uninstall`.
