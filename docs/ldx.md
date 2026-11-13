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

Infrastructure tools (`otel`, `redis`, `postgres`, `vault`, `authelia`, `agentgateway`) deploy into the `commons` namespace by
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
LDX_VAULT_NAMESPACE=secrets ldx vault setup  # Vault into 'secrets', other tools unaffected
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

## Commands Overview

| Command            | Category                | Description                                                           | Documentation                        |
|:-------------------|:------------------------|:----------------------------------------------------------------------|:-------------------------------------|
| `ldx install`      | Management              | Symlink `ldx` into local bin (`--dir` to choose target)              | [README.md](../README.md)            |
| `ldx skill`        | Agent Skills            | Manage agent skills (install, uninstall, list, info)                  | [skill.md](./reference/ai/skill.md)               |
| `ldx cvescan`      | Host Security           | System-wide automated Grype vulnerability scanner daemon              | [cvescan.md](./reference/security/cvescan.md)           |
| `ldx touchid`      | Host Security           | Touch ID (biometric) authentication for `git push` via pre-push hook  | [touchid.md](./reference/security/touchid.md)           |
| `ldx tls`          | Dev Infrastructure      | Local TLS certificates & Traefik configuration                        | [tls.md](./reference/infrastructure/tls.md)                   |
| `ldx certmanager`  | Kubernetes Dev          | In-cluster `cert-manager` setup                                       | [cert-manager.md](./reference/infrastructure/cert-manager.md) |
| `ldx otel`         | Observability           | Grafana LGTM stack (Loki, Grafana, Tempo, Mimir)                      | [otel.md](./reference/observability/otel.md)                 |
| `ldx k8s`          | Dev Infrastructure      | Declarative platform stack (Helm umbrella chart)                      | [k8s.md](./reference/infrastructure/k8s.md)                |
| `ldx redis`        | Dev Infrastructure      | Redis stack deployment                                                | [redis.md](./reference/infrastructure/redis.md)                 |
| `ldx postgres`     | Dev Infrastructure      | PostgreSQL with `pgvector` extension                                  | [postgres.md](./reference/infrastructure/postgres.md)         |
| `ldx vault`        | Security / Secrets      | Local HashiCorp Vault deployment                                      | [vault.md](./reference/security/vault.md)               |
| `ldx authelia`     | Identity / SSO          | Authelia (OIDC provider with WebAuthn/Touch ID) for SSO               | [authelia.md](./reference/identity/authelia.md)             |
| `ldx agentgateway` | AI / LLM Infrastructure | agentgateway (LLM/MCP/A2A gateway) with UI, Authelia SSO, oMLX sync   | [agentgateway.md](./reference/ai/agentgateway.md) |
| `ldx opencode`     | AI / LLM Infrastructure | Configure the local opencode harness from agentgateway models         | [opencode.md](./reference/ai/opencode.md)               |

---

## Installation to User PATH

Install `ldx` into your user's bin directory (`$HOME/.local/bin` or `$HOME/bin`) by executing:

```bash
ldx install
```

This symlinks the `ldx` dispatcher into the target directory; commands and assets resolve through the checkout, so
`git pull` in the repository is the upgrade. Use `--dir <path>` to choose a different target.

Ensure `$HOME/.local/bin` (or your installation target) is in your shell's configuration (`~/.zshrc` or `~/.bashrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```
