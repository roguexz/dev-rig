# `ldx skill` Documentation

The `ldx skill` command provides management for Agent Skills bundled with `dev-rig`. Agent Skills are packaged in accordance with the Agent Skills specification and installed into `$HOME/.agents/skills/`.

---

## Directory Structure

```
skills/
└── <skill-name>/
    ├── SKILL.md            # Mandatory YAML frontmatter & markdown instructions
    ├── hooks/              # Optional lifecycle hook scripts
    │   ├── pre-install.sh  # Runs before skill files are installed
    │   ├── post-install.sh # Runs after skill files are installed
    │   ├── pre-uninstall.sh
    │   └── post-uninstall.sh
    └── scripts/            # Supporting scripts and utilities
```

---

## Usage

### 1. List Available Skills
```bash
ldx skill list
```
Displays all bundled skills, installation status (`Installed`, `Linked`, or `Not Installed`), and descriptions.

### 2. Install a Skill
```bash
# Copy installation
ldx skill install cve-auditor

# Symlink installation (useful for development)
ldx skill install cve-auditor --link

# Install all skills
ldx skill install --all
```

### 3. Skill Metadata
```bash
ldx skill info cve-auditor
```

### 4. Uninstall a Skill
```bash
ldx skill uninstall cve-auditor
```

---

## Writing Custom Skill Hooks

Lifecycle scripts receive the following environment variables:

| Variable | Description |
| :--- | :--- |
| `SKILL_NAME` | The folder name of the skill |
| `SKILL_SOURCE_DIR` | Absolute path to source skill folder in `dev-rig` |
| `SKILL_TARGET_DIR` | Absolute path to `$HOME/.agents/skills/<skill-name>` |
| `INSTALL_MODE` | `copy` or `link` |

Example `pre-install.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
echo "[INFO] Verifying Homebrew dependency..."
command -v grype &>/dev/null || brew install grype
```
