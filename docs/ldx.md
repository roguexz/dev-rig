# `ldx` CLI Reference

`ldx` (Local Development Experience) is the primary top-level command-line dispatcher for local development environment
automation and host security utilities.

---

## Usage Syntax

```bash
ldx <command> [subcommand] [flags]
```

You can also run individual capability binaries directly, such as `ldx-vault unseal`, `ldx-postgres install`, etc.

---

## Commands Overview

| Command           | Category                | Description                                                           | Documentation                        |
|:------------------|:------------------------|:----------------------------------------------------------------------|:-------------------------------------|
| `ldx install`     | Management              | Install `ldx` commands to local bin (`--copy` default, `--link` flag) | [README.md](../README.md)            |
| `ldx skill`       | Agent Skills            | Manage agent skills (install, uninstall, list, info)                  | [skill.md](./skill.md)               |
| `ldx cvescan`     | Host Security           | System-wide automated Grype vulnerability scanner daemon              | [cvescan.md](./cvescan.md)           |
| `ldx tls`         | Dev Infrastructure      | Local TLS certificates & Traefik configuration                        | [tls.md](./tls.md)                   |
| `ldx certmanager` | Kubernetes Dev          | In-cluster `cert-manager` setup                                       | [cert-manager.md](./cert-manager.md) |
| `ldx otel`        | Observability           | Grafana LGTM stack (Loki, Grafana, Tempo, Mimir)                      | [otel.md](./otel.md)                 |
| `ldx redis`       | Dev Infrastructure      | Redis stack deployment                                                | [redis.md](./redis.md)               |
| `ldx postgres`    | Dev Infrastructure      | PostgreSQL with `pgvector` extension                                  | [postgres.md](./postgres.md)         |
| `ldx vault`       | Security / Secrets      | Local HashiCorp Vault deployment                                      | [vault.md](./vault.md)               |
| `ldx litellm`     | AI / LLM Infrastructure | LiteLLM proxy instance backed by PostgreSQL                           | [litellm.md](./litellm.md)           |

---

## Installation to User PATH

You can install all `ldx` tools to your user's bin directory (`$HOME/.local/bin` or `$HOME/bin`) by executing:

```bash
ldx install
```

To create symlinks back to this git repository instead of copying files:

```bash
ldx install --link
```

Ensure `$HOME/.local/bin` (or your installation target) is in your shell's configuration (`~/.zshrc` or `~/.bashrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```
