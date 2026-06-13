# Using the Custom Java Keystore

The `rd-setup tls keystore` command creates a custom Java keystore at `~/.cache/local-dev/certs/cacerts`. This keystore is a copy of your system's default `cacerts` file, with the addition of the `mkcert` root CA. This allows Java applications to trust the locally generated TLS certificates.

## For Quarkus Applications

You can configure your Quarkus application to use this keystore by setting the following properties in your `application.properties` file:

```properties
# Path to the custom keystore
quarkus.http.ssl.certificate.key-store-file=${user.home}/.cache/local-dev/certs/cacerts
# Password for the keystore
quarkus.http.ssl.certificate.key-store-password=changeit
```

## For Other Java Applications

For other Java applications, you can use the following system properties when running your application:

```bash
java -Djavax.net.ssl.trustStore=${HOME}/.cache/local-dev/certs/cacerts \
     -Djavax.net.ssl.trustStorePassword=changeit \
     -jar your-application.jar
```
