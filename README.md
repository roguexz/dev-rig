# Local Development Environment Setup for Rancher Desktop

This repository contains a set of scripts to automate the setup and configuration of a local development environment
using Rancher Desktop on macOS.

The primary script is `rd-setup`, which acts as a dispatcher for various sub-commands, each managing a specific piece of
the infrastructure.

## Prerequisites

Before using these scripts, ensure you have the following command-line tools installed:

- [Rancher Desktop](https://rancherdesktop.io/)
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
   chmod +x bin/*
   ```

3. **Add the `bin` directory to your shell's `PATH`:**
   Add the following line to your `~/.zshrc`, `~/.bash_profile`, or equivalent shell configuration file:

   ```bash
   export PATH="/path/to/your/dev-setup/bin:$PATH"
   ```
   Reload your shell for the changes to take effect. You can now run `rd-setup` from any directory.

## Available Commands

The `rd-setup` tool is modular, with each command handling a specific capability.

| Command                               | Description                                                              |
| ------------------------------------- | ------------------------------------------------------------------------ |
| `rd-setup tls <subcommand>`           | Manages local TLS certificates and Java keystores.                       |
| `rd-setup certmanager <subcommand>`   | Installs and configures `cert-manager` for in-cluster certificates.      |
| `rd-setup otel <subcommand>`          | Deploys the Grafana LGTM stack (Loki, Grafana, Tempo, Mimir).            |
| `rd-setup redis <subcommand>`         | Deploys a Redis instance accessible from the host.                       |
| `rd-setup postgres <subcommand>`      | Deploys a PostgreSQL instance with pgvector extension.                   |
| `rd-setup vault <subcommand>`         | Manages a local HashiCorp Vault deployment for secrets management.       |

For detailed usage of each command, see the documentation below.

## Documentation

- [**TLS & Traefik (`tls`)**](./docs/tls.md)
- [**Cert-Manager (`certmanager`)**](./docs/cert-manager.md)
- [**OpenTelemetry LGTM Stack (`otel`)**](./docs/otel.md)
- [**Redis (`redis`)**](./docs/redis.md)
- [**PostgreSQL (`postgres`)**](./docs/postgres.md)
- [**Vault (`vault`)**](./docs/vault.md)

All scripts are designed to be idempotent, meaning you can run them multiple times without causing errors. Each
capability also includes an `uninstall` command to cleanly remove all resources.
