# `dev-setup` CLI Reference

`dev-setup` is the primary top-level command-line dispatcher for development environment automation and host security utilities.

---

## Usage Syntax

```bash
dev-setup <command> [subcommand] [flags]
```

---

## Commands Overview

| Command | Category | Description | Documentation |
| :--- | :--- | :--- | :--- |
| `dev-setup cvescan` | Host Security | System-wide automated Grype vulnerability scanner daemon | [cvescan.md](./cvescan.md) |
| `dev-setup tls` | Dev Infrastructure | Local TLS certificates & Traefik configuration | [tls.md](./tls.md) |
| `dev-setup certmanager` | Kubernetes Dev | In-cluster `cert-manager` setup | [cert-manager.md](./cert-manager.md) |
| `dev-setup otel` | Observability | Grafana LGTM stack (Loki, Grafana, Tempo, Mimir) | [otel.md](./otel.md) |
| `dev-setup redis` | Dev Infrastructure | Redis stack deployment | [redis.md](./redis.md) |
| `dev-setup postgres` | Dev Infrastructure | PostgreSQL with `pgvector` extension | [postgres.md](./postgres.md) |
| `dev-setup vault` | Security / Secrets | Local HashiCorp Vault deployment | [vault.md](./vault.md) |
| `dev-setup litellm` | AI / LLM Infrastructure | LiteLLM proxy instance backed by PostgreSQL | [litellm.md](./litellm.md) |

---

## Installation to User PATH

Add the `bin` directory of this repository to your shell's configuration (`~/.zshrc` or `~/.bash_profile`):

```bash
export PATH="/path/to/dev-setup/bin:$PATH"
```

After reloading your shell, `dev-setup` will be accessible globally.
