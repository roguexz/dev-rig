# Local Development Experience CLI (`ldx`)

This repository contains a set of modular scripts (`ldx-*`) to automate local development infrastructure (Rancher Desktop) and host system security tools on macOS.

The primary entrypoint CLI is `ldx`, acting as a unified dispatcher for sub-commands managing specific tools, security utilities, and local infrastructure services. Direct usage of individual binaries (`ldx-vault`, `ldx-postgres`, etc.) is also fully supported.

## Prerequisites

Before using these scripts, ensure you have the following command-line tools installed:

- [Grype](https://github.com/anchore/grype) (for `cvescan` vulnerability scanner)
- [terminal-notifier](https://formulae.brew.sh/formula/terminal-notifier) (optional, for `cvescan` desktop notifications)
- [Rancher Desktop](https://rancherdesktop.io/) (for local k8s infrastructure)
- [mkcert](https://github.com/FiloSottile/mkcert)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- [helm](https://helm.sh/docs/intro/install/)
- [jq](https://stedolan.github.io/jq/download/)
- A Java Development Kit (JDK) for the `ldx tls keystore` command.

## Quick Start & Installation

### Option 1: Remote One-Liner Installation (Recommended)

Because this is a private GitHub repository, `raw.githubusercontent.com` requires authentication. You can install directly via the `gh` CLI:

```bash
gh api repos/roguexz/dev-setup/contents/install.sh --jq '.content' | base64 -d | bash
```

Or using `curl` with a GitHub access token:

```bash
curl -fsSL -H "Authorization: token $GITHUB_TOKEN" https://raw.githubusercontent.com/roguexz/dev-setup/main/install.sh | bash
```

This downloads the latest release tarball to a temporary directory, executes `ldx install` (copying executables into `$HOME/.local/bin`), and automatically cleans up temporary files.

---

### Option 2: Local Repository Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/roguexz/dev-setup.git
   cd dev-setup
   ```

2. **Make the scripts executable:**
   ```bash
   chmod +x bin/* install.sh cvescan/*.sh
   ```

3. **Install `ldx` binaries to your local PATH:**
   ```bash
   ./bin/ldx install
   ```
   By default, this copies `ldx` and all `ldx-*` binaries to `$HOME/.local/bin` (or `$HOME/bin`).

   - **Symlink option**: To keep installed binaries in sync with `git pull`, pass `--link`:
     ```bash
     ./bin/ldx install --link
     ```
   - **Custom target directory**:
     ```bash
     ./bin/ldx install --dir /custom/path/bin
     ```

---

### Shell PATH Configuration

Ensure `$HOME/.local/bin` (or your chosen install directory) is present in your shell configuration (`~/.zshrc` or `~/.bashrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

After reloading your shell (`source ~/.zshrc`), `ldx` commands will be accessible from anywhere (e.g., `ldx-vault unseal`, `ldx postgres install`).

## Available Commands

The `ldx` CLI is modular, with each command managing a specific capability.

| Command                            | Description                                                              | Direct Binary    |
| ---------------------------------- | ------------------------------------------------------------------------ | ---------------- |
| `ldx install [flags]`              | Installs `ldx` commands into `$HOME/.local/bin` (`--copy` default, `--link` flag). | `ldx install` |
| `ldx cvescan <subcommand>`         | System-wide automated Grype vulnerability scanner LaunchDaemon.          | `ldx-cvescan`    |
| `ldx tls <subcommand>`             | Manages local TLS certificates and Java keystores.                       | `ldx-tls`        |
| `ldx certmanager <subcommand>`     | Installs and configures `cert-manager` for in-cluster certificates.      | `ldx-certmanager` |
| `ldx otel <subcommand>`            | Deploys the Grafana LGTM stack (Loki, Grafana, Tempo, Mimir).            | `ldx-otel`       |
| `ldx redis <subcommand>`           | Deploys a Redis instance accessible from the host.                       | `ldx-redis`      |
| `ldx postgres <subcommand>`        | Deploys a PostgreSQL instance with pgvector extension.                   | `ldx-postgres`   |
| `ldx vault <subcommand>`           | Manages a local HashiCorp Vault deployment for secrets management.       | `ldx-vault`      |
| `ldx litellm <subcommand>`         | Deploys a LiteLLM proxy instance backed by PostgreSQL.                   | `ldx-litellm`    |

For detailed usage of each command, see the documentation below.

## Documentation

- [**CLI Reference (`ldx`)**](./docs/ldx.md)
- [**System CVE Scanner (`cvescan`)**](./docs/cvescan.md)
- [**TLS & Traefik (`tls`)**](./docs/tls.md)
- [**Cert-Manager (`certmanager`)**](./docs/cert-manager.md)
- [**OpenTelemetry LGTM Stack (`otel`)**](./docs/otel.md)
- [**Redis (`redis`)**](./docs/redis.md)
- [**PostgreSQL (`postgres`)**](./docs/postgres.md)
- [**Vault (`vault`)**](./docs/vault.md)
- [**LiteLLM Proxy (`litellm`)**](./docs/litellm.md)

All scripts are designed to be idempotent, meaning you can run them multiple times without causing errors. Each capability also includes an `uninstall` command to cleanly remove all resources.
