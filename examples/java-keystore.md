# Using the Custom Java Keystore

The `ldx tls keystore` command creates a custom Java keystore at `~/.cache/local-dev/certs/cacerts`. This keystore is a copy of your system's default `cacerts` file, with the addition of the `mkcert` root CA. This allows Java applications to trust the locally generated TLS certificates.

## For Quarkus Applications

### Serving Content over TLS

Configure the server to use the generated certificates for serving content over TLS. Add the
following entries to your `application.properties` file:

```properties
# Configure HTTPS for all locally run Quarkus apps
quarkus.tls.key-store.pem.0.cert=$HOME/.cache/local-dev/certs/localhost.pem
quarkus.tls.key-store.pem.0.key=$HOME/.cache/local-dev/certs/localhost-key.pem
# Reject HTTP requests
quarkus.http.insecure-requests=disabled
```

Alternatively, add the following configuration to your shell profile (`~/.zshrc`, `~/.bashrc`, etc):

```bash
# Configure HTTPS for Quarkus apps running locally
export QUARKUS_HTTP_INSECURE_REQUESTS=disabled
export QUARKUS_TLS_KEY_STORE_PEM__0__CERT=$HOME/.cache/local-dev/certs/localhost.pem
export QUARKUS_TLS_KEY_STORE_PEM__0__KEY=$HOME/.cache/local-dev/certs/localhost-key.pem
```

### Configure Client Truststore

When you need to consume HTTPS endpoints that use locally generated certificates, you need to
configure the client truststore. Add the following entries to your
`application.properties` file:

```properties
# Configure client truststore for local development
quarkus.tls.trust-store.pem.certs=${HOME}/.cache/local-dev/certs/localhost.pem

# Create an additional "named" truststore for use with Quarkiverse extensions, e.g., Langchain4j
quarkus.tls.local-dev.trust-store.pem.certs=${HOME}/.cache/local-dev/certs/localhost.pem
quarkus.langchain4j.openai.tls-configuration-name=local-dev
```

## For Other Java Applications

For other Java applications, you can use the following system properties when running your application:

```bash
java -Djavax.net.ssl.trustStore=${HOME}/.cache/local-dev/certs/cacerts \
     -Djavax.net.ssl.trustStorePassword=changeit \
     -jar your-application.jar
```
