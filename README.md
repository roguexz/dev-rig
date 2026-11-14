# Local Development Experience CLI (`ldx`)

**`ldx` (Local Development Experience)** is a lightweight CLI toolkit designed to streamline local infrastructure and
system security workflows on macOS. Powered by modular command scripts (`bin/commands/ldx-*`), it provides a unified
command line to spin up local Kubernetes environments, manage developer services (PostgreSQL, Vault), and execute
security checks effortlessly. The individual command scripts can also be run directly from the repository.

> [!NOTE]
> This repository reflects my personal development preferences and opinions, built to maintain a consistent workflow
when working across multiple laptops.

## Prerequisites

All command-line prerequisites are pinned in the [Brewfile](./Brewfile):

```bash
brew bundle --file Brewfile
```

The same tools, if you prefer installing them by hand:

- [Grype](https://github.com/anchore/grype) (for `cvescan` vulnerability scanner)
- [terminal-notifier](https://formulae.brew.sh/formula/terminal-notifier) (optional, for `cvescan` desktop
  notifications)
- [Rancher Desktop](https://rancherdesktop.io/) (for local k8s infrastructure; ships `kubectl` — expose it by
  adding `~/.rd/bin` to your PATH)
- [mkcert](https://github.com/FiloSottile/mkcert)
- [helm](https://helm.sh/docs/intro/install/)
- [jq](https://stedolan.github.io/jq/download/)
- [Vault CLI](https://developer.hashicorp.com/vault/install) (for `ldx vault create-user`, which drives Vault over
  its HTTPS API)

  ```bash
  brew tap hashicorp/tap
  brew install hashicorp/tap/vault
  ```

- A Java Development Kit (JDK) for the `ldx tls keystore` command.
- Xcode Command Line Tools for the `ldx touchid` command (compiles the Touch ID helper):

  ```bash
  xcode-select --install
  ```

## Installation

`ldx` installs through Homebrew, from this organization's tap:

```bash
brew tap hashicorp/tap   # vault dependency (not in homebrew-core)
brew tap roguexz/ldx
brew install roguexz/ldx/ldx
```

Homebrew does not tap third-party taps automatically, so `hashicorp/tap`
(for `vault`) must be tapped explicitly before installing.

The formula installs the whole toolkit under Homebrew's prefix and links `ldx`
into `/opt/homebrew/bin`, which is already on the PATH of any shell configured
for Homebrew. Upgrades are `brew upgrade roguexz/ldx/ldx`.

### Development use

Working on `ldx` itself means running the dispatcher straight from a checkout
- there is no install step for the code in this repository:

```bash
git clone https://github.com/roguexz/dev-rig.git
cd dev-rig
./bin/ldx --version   # LDX_HOME resolves to the checkout
```

---

## Available Commands

The `ldx` CLI is modular: each command is a script in `bin/commands/ldx-*`, auto-discovered by the dispatcher.
The scripts can also be run directly from the repository (`bin/commands/ldx-vault unseal`).

| Command                         | Description                                                                                 | Command script         |
|---------------------------------|---------------------------------------------------------------------------------------------|------------------------|
| `ldx cvescan <subcommand>`      | System-wide automated Grype vulnerability scanner LaunchDaemon.                             | `bin/commands/ldx-cvescan` |
| `ldx touchid <subcommand>`      | Touch ID (biometric) authentication for `git push` via a global pre-push hook.              | `bin/commands/ldx-touchid` |
| `ldx tls <subcommand>`          | Manages local TLS certificates and Java keystores.                                          | `bin/commands/ldx-tls` |
| `ldx certmanager <subcommand>`  | Installs and configures `cert-manager` for in-cluster certificates.                         | `bin/commands/ldx-certmanager` |
| `ldx otel <subcommand>`         | Deploys the Grafana LGTM stack (Loki, Grafana, Tempo, Mimir).                               | `bin/commands/ldx-otel` |
| `ldx k8s <subcommand>`          | Declarative lifecycle for the platform stack (Helm umbrella chart).                   | `bin/commands/ldx-k8s` |
| `ldx redis <subcommand>`        | Deploys a Redis instance accessible from the host.                                    | `bin/commands/ldx-redis` |
| `ldx postgres <subcommand>`     | Deploys a PostgreSQL instance with pgvector extension.                                      | `bin/commands/ldx-postgres` |
| `ldx vault <subcommand>`        | Manages a local HashiCorp Vault deployment for secrets management.                          | `bin/commands/ldx-vault` |
| `ldx authelia <subcommand>`     | Deploys Authelia (OIDC provider with WebAuthn/Touch ID support) for SSO.                    | `bin/commands/ldx-authelia` |
| `ldx agentgateway <subcommand>` | Deploys agentgateway (LLM/MCP/A2A gateway) with built-in UI, Authelia SSO and oMLX model sync. | `bin/commands/ldx-agentgateway` |
| `ldx opencode <subcommand>`     | Configures the local opencode harness from agentgateway models.                             | `bin/commands/ldx-opencode` |

For detailed usage of each command, see the documentation below.

### Custom namespaces

The infrastructure commands (`otel`, `redis`, `postgres`, `vault`, `agentgateway`) deploy into the `commons` namespace by
default. Set `LDX_NAMESPACE` (or a tool-specific `LDX_<TOOL>_NAMESPACE`) in the environment or in
`~/.config/ldx/config` to deploy elsewhere; installs record the namespace they used so later commands find it again.
See [Configuration](./docs/ldx.md#configuration).

## Documentation

- [**Getting Started Guide**](./docs/guides/getting-started.md)
- [**Securing Your Workflow**](./docs/guides/securing-workflow.md)
- [**AI Agent Setup**](./docs/guides/ai-agent-setup.md)
- [**CLI Reference (`ldx`)**](./docs/ldx.md)

### Tool Reference
- **Security**: [cvescan](./docs/reference/security/cvescan.md), [touchid](./docs/reference/security/touchid.md), [vault](./docs/reference/security/vault.md)
- **Infrastructure**: [tls](./docs/reference/infrastructure/tls.md), [cert-manager](./docs/reference/infrastructure/cert-manager.md), [redis](./docs/reference/infrastructure/redis.md), [postgres](./docs/reference/infrastructure/postgres.md)
- **Observability**: [otel](./docs/reference/observability/otel.md)
- **Identity**: [authelia](./docs/reference/identity/authelia.md)
- **AI**: [agentgateway](./docs/reference/ai/agentgateway.md), [opencode](./docs/reference/ai/opencode.md), [skill](./docs/reference/ai/skill.md)

All scripts are designed to be idempotent, meaning you can run them multiple times without causing errors. Each
capability also includes an `uninstall` command to cleanly remove all resources.

## Recommended: AI-Assisted Development Toolkit

The prerequisites above cover the `ldx` scripts themselves. For the AI-assisted side of my local workflow, these are
the tools I keep installed on every machine - and most of them are just a `brew` command away:

```bash
brew install opencode ripgrep imagemagick gitleaks
brew install --cask openchamber bruno ghidra
```

- **[OpenCode](https://opencode.ai)** - an AI coding agent for the terminal; the engine behind most of my agentic
  workflows.
- **[OpenChamber](https://openchamber.dev)** - a polished desktop and web interface for OpenCode, with a built-in
  terminal, file browser, notes, and reusable actions right next to the chat.
- **[ripgrep](https://github.com/BurntSushi/ripgrep)** - extremely fast code search; the backbone of how agents explore
  a codebase.
- **[ImageMagick](https://imagemagick.org)** - quick image conversion, resizing, and annotation from the command line;
  handy when agents generate or compare screenshots.
- **[Bruno](https://www.usebruno.com)** - a lightweight, Git-friendly API client for testing and documenting local
  services; a nice companion to the `ldx` stacks.
- **Reverse engineering with AI** - [REA](https://github.com/morluto/rea) gives your coding agent structured,
  evidence-backed access to native binaries, powered by [Hopper](https://hopperapp.com/)
  and [Ghidra](https://ghidra-sre.org/). REA installs via a `curl` script and Ghidra via `brew install --cask ghidra`(it
  runs on the same JDK you already installed for `ldx tls keystore`); Hopper is a paid app.
- **Secure your `git push` with hooks** - [gitleaks](https://github.com/gitleaks/gitleaks) catches secrets before they
  leave your machine. Wire it into a `pre-push` hook - directly or through a hook manager
  like [lefthook](https://github.com/evilmartians/lefthook) - so credentials never reach a remote. For biometric
  gating, `ldx touchid` installs a Touch ID-only `pre-push` hook into `$HOME/.config/git/hooks`.
