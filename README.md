# Local Development Experience CLI (`ldx`)

**`ldx` (Local Development Experience)** is a lightweight CLI toolkit designed to streamline local infrastructure and
system security workflows on macOS. Powered by modular scripts (`ldx-*`), it provides a unified command line to spin up
local Kubernetes environments, manage developer services (PostgreSQL, Vault), and execute security checks effortlessly.
Direct usage of individual binaries (`ldx-vault`, `ldx-postgres`, etc.) is also fully supported.

> [!NOTE]
> This repository reflects my personal development preferences and opinions, built to maintain a consistent workflow
when working across multiple laptops.

## Prerequisites

Before using these scripts, ensure you have the following command-line tools installed:

- [Grype](https://github.com/anchore/grype) (for `cvescan` vulnerability scanner)
- [terminal-notifier](https://formulae.brew.sh/formula/terminal-notifier) (optional, for `cvescan` desktop
  notifications)
- [Rancher Desktop](https://rancherdesktop.io/) (for local k8s infrastructure)
- [mkcert](https://github.com/FiloSottile/mkcert)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- [helm](https://helm.sh/docs/intro/install/)
- [jq](https://stedolan.github.io/jq/download/)
- [Vault CLI](https://developer.hashicorp.com/vault/install) (for `ldx vault create-user`, which drives Vault over
  its HTTPS API)

  ```bash
  brew tap hashicorp/tap
  brew install hashicorp/tap/vault
  ```

- A Java Development Kit (JDK) for the `ldx tls keystore` command.

## Quick Start & Installation

### Option 1: Remote One-Liner Installation (Recommended)

Install directly via `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/roguexz/dev-rig/main/install.sh | bash
```

Or via GitHub CLI (`gh`):

```bash
gh api repos/roguexz/dev-rig/contents/install.sh --jq '.content' | base64 -d | bash
```

This downloads the latest release tarball to a temporary directory, executes `ldx install` (copying executables into
`$HOME/.local/bin`), and automatically cleans up temporary files.

---

### Option 2: Local Repository Installation

1. **Clone the repository:**
   ```bash
   git clone https://github.com/roguexz/dev-rig.git
   cd dev-rig
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

Ensure `$HOME/.local/bin` (or your chosen install directory) is present in your shell configuration (`~/.zshrc` or
`~/.bashrc`):

```bash
export PATH="$HOME/.local/bin:$PATH"
```

After reloading your shell (`source ~/.zshrc`), `ldx` commands will be accessible from anywhere (e.g.,
`ldx-vault unseal`, `ldx postgres install`).

## Available Commands

The `ldx` CLI is modular, with each command managing a specific capability.

| Command                         | Description                                                                                 | Direct Binary      |
|---------------------------------|---------------------------------------------------------------------------------------------|--------------------|
| `ldx install [flags]`           | Installs `ldx` commands into `$HOME/.local/bin` (`--copy` default, `--link` flag).          | `ldx install`      |
| `ldx cvescan <subcommand>`      | System-wide automated Grype vulnerability scanner LaunchDaemon.                             | `ldx-cvescan`      |
| `ldx tls <subcommand>`          | Manages local TLS certificates and Java keystores.                                          | `ldx-tls`          |
| `ldx certmanager <subcommand>`  | Installs and configures `cert-manager` for in-cluster certificates.                         | `ldx-certmanager`  |
| `ldx otel <subcommand>`         | Deploys the Grafana LGTM stack (Loki, Grafana, Tempo, Mimir).                               | `ldx-otel`         |
| `ldx redis <subcommand>`        | Deploys a Redis instance accessible from the host.                                          | `ldx-redis`        |
| `ldx postgres <subcommand>`     | Deploys a PostgreSQL instance with pgvector extension.                                      | `ldx-postgres`     |
| `ldx vault <subcommand>`        | Manages a local HashiCorp Vault deployment for secrets management.                          | `ldx-vault`        |
| `ldx agentgateway <subcommand>` | Deploys agentgateway (LLM/MCP/A2A gateway) with built-in UI, Vault SSO and oMLX model sync. | `ldx-agentgateway` |
| `ldx opencode <subcommand>`     | Configures the local opencode harness from agentgateway models.                             | `ldx-opencode`     |

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
- [**agentgateway (`agentgateway`)**](./docs/agentgateway.md)

All scripts are designed to be idempotent, meaning you can run them multiple times without causing errors. Each
capability also includes an `uninstall` command to cleanly remove all resources.

## Recommended: AI-Assisted Development Toolkit

The prerequisites above cover the `ldx` scripts themselves. For the AI-assisted side of my local workflow, these are
the tools I keep installed on every machine — and most of them are just a `brew` command away:

```bash
brew install opencode ripgrep imagemagick gitleaks
brew install --cask openchamber bruno ghidra
```

- **[OpenCode](https://opencode.ai)** — an AI coding agent for the terminal; the engine behind most of my agentic
  workflows.
- **[OpenChamber](https://openchamber.dev)** — a polished desktop and web interface for OpenCode, with a built-in
  terminal, file browser, notes, and reusable actions right next to the chat.
- **[ripgrep](https://github.com/BurntSushi/ripgrep)** — extremely fast code search; the backbone of how agents explore
  a codebase.
- **[ImageMagick](https://imagemagick.org)** — quick image conversion, resizing, and annotation from the command line;
  handy when agents generate or compare screenshots.
- **[Bruno](https://www.usebruno.com)** — a lightweight, Git-friendly API client for testing and documenting local
  services; a nice companion to the `ldx` stacks.
- **Reverse engineering with AI** — [REA](https://github.com/morluto/rea) gives your coding agent structured,
  evidence-backed access to native binaries, powered by [Hopper](https://hopperapp.com/)
  and [Ghidra](https://ghidra-sre.org/). REA installs via a `curl` script and Ghidra via `brew install --cask ghidra`(it
  runs on the same JDK you already installed for `ldx tls keystore`); Hopper is a paid app.
- **Secure your `git push` with hooks** — [gitleaks](https://github.com/gitleaks/gitleaks) catches secrets before they
  leave your machine. Wire it into a `pre-push` hook — directly or through a hook manager
  like [lefthook](https://github.com/evilmartians/lefthook) — so credentials never reach a remote.
