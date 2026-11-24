# `ldx` CLI Reference

`ldx` (Local Development Experience) is the primary top-level command-line dispatcher for local development environment
automation and host security utilities.

---

## Usage Syntax

```bash
ldx <command> [subcommand] [flags]
```

You can also run individual command scripts directly from the repository, such as `bin/commands/ldx-vault unseal`,
`bin/commands/ldx-postgres install`, etc. Commands are auto-discovered as `bin/commands/ldx-<command>` executables.

---

## Configuration

### Kubernetes namespaces

Infrastructure tools (`otel`, `redis`, `postgres`, `vault`, `authelia`, `bifrost`) deploy into the `commons` namespace by
default. You can deploy them into a custom namespace instead. (`tls` and `certmanager` keep their fixed namespaces -
`kube-system` and `cert-manager` - because Rancher Desktop and upstream conventions require them.)

The namespace for a tool is resolved in this order, first match wins:

1. `LDX_<TOOL>_NAMESPACE` environment variable - e.g. `LDX_VAULT_NAMESPACE`, `LDX_POSTGRES_NAMESPACE`
2. `LDX_NAMESPACE` environment variable - applies to every tool
3. `LDX_<TOOL>_NAMESPACE` in the local config file
4. `LDX_NAMESPACE` in the local config file
5. `commons` (default)

One-off override:

```bash
LDX_NAMESPACE=devtools ldx redis install     # Redis into 'devtools'
LDX_VAULT_NAMESPACE=secrets ldx vault install  # Vault into 'secrets', other tools unaffected
```

### Local config file

Config lives at `~/.config/ldx/config` (honours `$XDG_CONFIG_HOME`) as plain `KEY=value` lines:

```ini
# ldx configuration
LDX_NAMESPACE=devtools
LDX_VAULT_NAMESPACE=secrets
```

You can edit this file by hand, but you rarely need to: every `install`/`setup` run records the namespace it actually
used, so later commands (`uninstall`, `status`, `unseal`, …) find the deployment without re-specifying it. Environment
variables always beat the file.

Namespace names must be valid Kubernetes names (RFC 1123 label: lowercase letters, digits and `-`, starting and ending
alphanumeric, at most 63 characters).

---

## Image versions

All container image versions are defined in a single file: `config/images.yaml`. This is the source of truth for the images deployed by the CLI. The file uses a simple `service: image` format:

```yaml
redis: docker.io/bitnami/redis:8.10.3-debian-12-r1
postgres: local/bitnami-postgresql-pgvector:18
otel: grafana/otel-lgtm:0.41.0
vault: hashicorp/vault:2.0.4
authelia: docker.io/authelia/authelia:latest
bifrost: maximhq/bifrost:v2.6.0
certmanager: quay.io/jetstack/cert-manager-controller:v1.21.3
```

The CLI reads this file at deploy time (`ldx k8s up`, `ldx upgrade`) and passes the images to Helm via `--set` flags. Chart values.yaml files carry the same values as fallbacks for standalone chart deployment, but the CLI always overrides them with the central file.

To change an image version, edit `config/images.yaml` and run `ldx upgrade`.

---

## Commands Overview

| Command            | Category                | Description                                                           | Documentation                        |
|:-------------------|:------------------------|:----------------------------------------------------------------------|:-------------------------------------|
| `ldx skill`        | Agent Skills            | Manage agent skills (install, uninstall, list, info)                  | [skill.md](./reference/ai/skill.md)               |
| `ldx cvescan`      | Host Security           | System-wide automated Grype vulnerability scanner daemon              | [cvescan.md](./reference/security/cvescan.md)           |
| `ldx touchid`      | Host Security           | Touch ID (biometric) authentication for `git push` via pre-push hook  | [touchid.md](./reference/security/touchid.md)           |
| `ldx tls`          | Dev Infrastructure      | Local TLS certificates & Traefik configuration                        | [tls.md](./reference/infrastructure/tls.md)                   |
| `ldx certmanager`  | Kubernetes Dev          | In-cluster `cert-manager` setup                                       | [cert-manager.md](./reference/infrastructure/cert-manager.md) |
| `ldx ca`           | Dev Infrastructure      | User-supplied CA certificates for the platform (`extra-cas` ConfigMap) | [ca.md](./reference/infrastructure/ca.md)                        |
| `ldx otel`         | Observability           | Grafana LGTM stack (Loki, Grafana, Tempo, Mimir)                      | [otel.md](./reference/observability/otel.md)                 |
| `ldx k8s`          | Dev Infrastructure      | Declarative platform stack (Helm umbrella chart)                      | [k8s.md](./reference/infrastructure/k8s.md)                |
| `ldx redis`        | Dev Infrastructure      | Redis stack deployment                                                | [redis.md](./reference/infrastructure/redis.md)                 |
| `ldx postgres`     | Dev Infrastructure      | PostgreSQL with `pgvector` extension                                  | [postgres.md](./reference/infrastructure/postgres.md)         |
| `ldx vault`        | Security / Secrets      | Local HashiCorp Vault deployment                                      | [vault.md](./reference/security/vault.md)               |
| `ldx authelia`     | Identity / SSO          | Authelia (OIDC provider with WebAuthn/Touch ID) for SSO               | [authelia.md](./reference/identity/authelia.md)             |
| `ldx bifrost`      | AI / LLM Infrastructure | Bifrost (LLM + MCP gateway) with admin UI, oMLX provider sync          | [bifrost.md](./reference/ai/bifrost.md)               |
| `ldx opencode`     | AI / LLM Infrastructure | Configure the local opencode harness from Bifrost                       | [opencode.md](./reference/ai/opencode.md)               |
| `ldx upgrade`      | Dev Infrastructure      | Upgrade installed services to match the repository state                | (built-in --help)                                     |

---

## `ldx upgrade`

Upgrades all currently-installed shipped components to match the repository state. This is the primary way to keep
local cluster images current after pinned versions are updated in the repository.

Services are grouped by their upgrade mechanism:

| Mechanism              | Services                                          | How it works                                         |
|:-----------------------|:--------------------------------------------------|:-----------------------------------------------------|
| Umbrella Helm chart    | redis, postgres, otel, vault, authelia, certmanager | One `helm upgrade --install` of `ldx-local-platform` |
| Dedicated (kubectl)    | bifrost                                            | `kubectl set image` + rollout                        |
| Local image rebuild    | postgres (pgvector)                                | Force-rebuilds the locally-built pgvector image      |

The command upgrades to the versions pinned in `config/images.yaml`, the single source of truth for all container images. This file is read by the CLI at deploy time and passed to Helm, so editing it and running `ldx upgrade` propagates the changes to the cluster.

### Usage

```bash
ldx upgrade                    # Upgrade all installed services
ldx upgrade --check            # Dry-run: report what would change without upgrading
ldx upgrade --services a,b     # Limit the upgrade to specific services
```

### Options

| Flag                  | Description                                                     |
|:----------------------|:----------------------------------------------------------------|
| `--check`             | Dry-run mode. Compares deployed image tags with the repo-pinned tags and reports what would change, without making any changes. |
| `--services <a,b>`    | Comma-separated list of services to upgrade. Without this flag, all installed services are upgraded. |
| `--namespace <ns>`    | Namespace of the release. Defaults to the namespace recorded by `ldx k8s`. |

### Behavior

- Detects installed services from the state file (`~/.config/ldx/k8s-services`).
- For umbrella-managed services, runs `ldx k8s up --services <list> --force-rebuild` once.
- For bifrost, runs `ldx bifrost upgrade`.
- Continues processing remaining services if one fails.
- Exit code 0 if all services were upgraded or were already up-to-date; 1 if any service failed.

---

## Installation

Installation is through the Homebrew tap:

```bash
brew tap hashicorp/tap   # vault dependency (not in homebrew-core)
brew tap roguexz/ldx
brew install roguexz/ldx/ldx
```

See the [README](../README.md). The commands resolve their assets through
`LDX_HOME`, derived at runtime from the dispatcher's real path, so running
`bin/ldx` directly from a checkout works without any install step.
