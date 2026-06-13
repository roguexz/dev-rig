I have Rancher Desktop running on my local laptop. I need a set of scripts that will allow me to configure the
instance (each time I reset it). Here is what I want in it.

Script to generate certs using mkcert for the following domains,

- https://localhost
- https://localhost:8443
- https://localhost.rogue.io
- https://localhost.rogue.io:8443
-
- https://*.rancher.localhost
- https://*.rd.localhost

This script should store the root CA in the OS local cache folder under the folder name of "local-dev" (in the
appropriate location). I believe on a Mac that would be "~/.cache/local-dev/certs/" (localhost.pem & localhost-key.pem)

Something like, `tls install`

I need the ability to create a Java keystore (which is a copy of the current JDK's keystore) and import the root CA into
it. In the docs, make a note on how I can consume the keystore. Of course I also expect that all operations are
idempotent.

For the local Rancher Desktop, I need the ability to configure the Traefik instance with the generated certs. I believe
the approach is to,

- create a TLS secret in the kube-system namespace
- set it as the default in Traefik

See if you want to create a script with multiple sub commands or top level scripts

------

Next, I want the ability to install & configure the cert-manager on the local cluster. I believe that would be the
`cert-manager`, `cert-manager-webhook`, `cert-manager-cainject`. Give me two examples that demonstrate the following
patterns

- TLS termination at the edge
- End-to-End TLS (where the pod gets a cert issued by the cert-manager)

-----

Next, I need the ability to deploy and configure the OpenTelemetry LGTM stack. Something like `otel-lgtm install`
Give me examples on how I can use it, specifically with Quarkus based apps.

---

Next, I want the redis stack deployed to the cluster, including direct host access to Redis on the 6379 (IIRC) port.

---

Lastly, I want the vault setup deployed locally. Since vault needs the secrets for unsealing it on each start, include
the functionality of storing the secrets in a predictable location (under that local-dev cache folder) and give me a
script like `rd-vault setup / unseal / seal / ...`
Include examples on how an application can use the annotations for having secrets from one of the vaults injected into
the deployment.

---

All scripts must result in idempotent actions, like invoking install / setup twice should not cause it fail.
All scripts must provide the ability to uninstall & also expose useful commands (for that function)
Create this repository assuming that I will copy the "bin" folder as is to my $HOME/bin folder ... so include
configurations within that folder ... which also means any hardcodings must be configure