# Local Development Environment & Host Utilities Setup (`dev-setup`)

This repository contains a set of modular scripts to automate local development infrastructure (Rancher Desktop) and host system security tools on macOS.

The primary entrypoint CLI is `dev-setup`, acting as a unified dispatcher for sub-commands managing specific tools, security utilities, and local infrastructure services.

## Prerequisites

Before using these scripts, ensure you have the following command-line tools installed:

- [Grype](https://github.com/anchore/grype) (for `cvescan` vulnerability scanner)
- [terminal-notifier](https://github.com/julien Blanchard/terminal-notifier) (optional, for `cvescan` desktop notifications)
- [Rancher Desktop](https://rancherdesktop.io/) (for local k8s infrastructure)
- [mkcert](https://github.com/FiloSottile/mkcert)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- [helm](https://helm.sh/docs/intro/install/)
- [jq](https://stedolan.github.io/jq/download/)
- A Java Development Kit (JDK) for the `tls keystore` command.

## Installation

1. **Clone the repository:**
   ```bash
   git clone <repo-url> dev-setup
   cd dev-setup
   ```

2. **Make the scripts executable:**
   ```bash
   chmod +x bin/* cvescan/*.sh
   ```

3. **Add the `bin` directory to your shell's `PATH`:**
   Add the following line to your `~/.zshrc`, `~/.bash_profile`, or equivalent shell configuration file:

   ```bash
   export PATH="/path/to/your/dev-setup/bin:$PATH"
   ```
   Reload your shell for the changes to take effect. You can now run `dev-setup` from any directory.

## Available Commands

The `dev-setup` tool is modular, with each command managing a specific capability.

| Command                                | Description                                                              |
| -------------------------------------- | ------------------------------------------------------------------------ |
| `dev-setup cvescan <subcommand>`       | System-wide automated Grype vulnerability scanner LaunchDaemon.          |
| `dev-setup tls <subcommand>`           | Manages local TLS certificates and Java keystores.                       |
| `dev-setup certmanager <subcommand>`   | Installs and configures `cert-manager` for in-cluster certificates.      |
| `dev-setup otel <subcommand>`          | Deploys the Grafana LGTM stack (Loki, Grafana, Tempo, Mimir).            |
| `dev-setup redis <subcommand>`         | Deploys a Redis instance accessible from the host.                       |
| `dev-setup postgres <subcommand>`      | Deploys a PostgreSQL instance with pgvector extension.                   |
| `dev-setup vault <subcommand>`         | Manages a local HashiCorp Vault deployment for secrets management.       |
| `dev-setup litellm <subcommand>`       | Deploys a LiteLLM proxy instance backed by PostgreSQL.                   |

For detailed usage of each command, see the documentation below.

## Documentation

- [**System CVE Scanner (`cvescan`)**](./docs/cvescan.md)
- [**CLI Reference (`dev-setup`)**](./docs/dev-setup.md)
- [**TLS & Traefik (`tls`)**](./docs/tls.md)
- [**Cert-Manager (`certmanager`)**](./docs/cert-manager.md)
- [**OpenTelemetry LGTM Stack (`otel`)**](./docs/otel.md)
- [**Redis (`redis`)**](./docs/redis.md)
- [**PostgreSQL (`postgres`)**](./docs/postgres.md)
- [**Vault (`vault`)**](./docs/vault.md)
- [**LiteLLM Proxy (`litellm`)**](./docs/litellm.md)

All scripts are designed to be idempotent, meaning you can run them multiple times without causing errors. Each capability also includes an `uninstall` command to cleanly remove all resources.
