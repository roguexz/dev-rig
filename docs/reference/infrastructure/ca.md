# Extra CAs (`ldx ca`)

`ldx ca` manages user-supplied CA certificates for the local platform. It adds corporate or internal CAs to the
`extra-cas` ConfigMap, which the bifrost and otel deployments mount at `/etc/ssl/extra-cas` and expose via
`SSL_CERT_DIR`. The container image's public CAs are untouched; the ConfigMap only adds local CAs.

The mkcert root CA (from `ldx tls install`) is always included alongside user-supplied CAs.

## Commands

### `ldx ca install --dir <path> [--split]`

Validates every `*.pem`, `*.crt` and `*.cer` file in `<path>` and installs the valid ones into
`~/.cache/local-dev/ca/`. Validation uses `openssl x509` to confirm the file is a parseable certificate.

After a successful install it re-creates the `extra-cas` ConfigMap and restarts any running bifrost/otel
deployments so the new CAs take effect. Files that fail validation are skipped and reported; if no valid
certificates are found, the command exits non-zero.

A file that contains more than one certificate (a concatenated bundle) is treated as a single file: only
the first certificate is used and a warning is printed. Pass `--split` to split the bundle into individual
certificates and install each one:

```bash
ldx ca install --dir ~/Downloads/corp-ca/ --split
```

With `--split`, each certificate in the bundle is written to a temp directory as `<name>.<N>.pem`,
validated and installed individually. Leading and trailing content around the PEM blocks is ignored.

## Deduplication and naming

Certificates are identified by their SHA-256 fingerprint, not by file name. Installing the same certificate
under a different file name — or in a bundle alongside its individual copy — installs it once and reports
the duplicates as already installed. The mkcert root CA is always installed alongside user CAs, so a user CA
identical to it is skipped as already installed. Cache files are named `<subject-slug>-<short-fingerprint>.pem`
(e.g. `corp-ca-973690360633.pem`), so the name is derived from the certificate itself, not from the
source file name. Re-running an install that finds everything already installed is a no-op.

**Example — corporate CA:**

```bash
# Copy the corporate CA certificate(s) into a directory, then install them
ldx ca install --dir ~/Downloads/corp-ca/
```

### `ldx ca status`

Shows the mkcert CA, the installed user-supplied CAs (with their subjects), and the state of the
`extra-cas` ConfigMap (file count).

### `ldx ca clear`

Removes the user-supplied CAs from `~/.cache/local-dev/ca/` (the mkcert CA is left in place) and re-creates
the `extra-cas` ConfigMap, restarting bifrost/otel if they are running.

## Notes

- User CAs are stored as PEM files in `~/.cache/local-dev/ca/`. The ConfigMap is re-created on `install`
  and `clear`; editing files in the cache directory does not refresh the ConfigMap. To apply a change,
  re-run `ldx ca clear` and `ldx ca install --dir <path>`.
- The `extra-cas` ConfigMap lives in the otel namespace (default `commons`, honours `LDX_OTEL_NAMESPACE` /
  `LDX_NAMESPACE`). Both bifrost and otel reference it by name.
- A restart of the bifrost/otel deployments is required for new CAs to take effect; `ldx ca install` and
  `ldx ca clear` do this automatically when the deployments exist.
