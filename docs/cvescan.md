# System-Wide Automated Vulnerability Scanner (`cvescan`)

The `cvescan` module configures a system-wide daily vulnerability scanner on macOS using Anchore **Grype**, macOS **LaunchDaemon** (`launchd`), and **terminal-notifier**.

---

## Capabilities & Features

- **Anchore Grype Scanner Engine:**
  - Natively indexes and scans compiled `.jar` files in Gradle/Maven caches (`~/.gradle/caches/`), Python packages inside `uv tool` app bundles (`~/.local/share/uv/tools/`), macOS applications (`/Applications`), and project repositories (`/Users/.../code`).
- **Daily Scheduled Scans:** Scheduled via `launchd` (`/Library/LaunchDaemons/com.system.cvescan.plist`) to execute daily at 02:00 AM.
- **Sleep & Power Catch-Up:** Uses `<key>RunAtLoad</key><true/>` to automatically run missed scans when your Mac wakes up or boots.
- **Fast Fingerprint Change Detection:** Calculates directory `mtime` metadata fingerprints across target directories before invoking Grype. If no application or dependency files have changed, the scan completes in **under 1 second**.
- **Monthly Deep Scan:** Automatically performs a complete vulnerability scan on the 1st of every month (or if >30 days have passed), bypassing fingerprint caches.
- **Desktop Notifications:** Sends macOS desktop alerts via `terminal-notifier` on scan completion (`⚠️ Alert` vs `✅ Clean`). Clicking notification opens log.
- **Rolling Log History:** Retains the last 3 scan execution logs and JSON reports in `/var/log/cvescan/` (or `~/.cache/cvescan/` in user mode).
- **User-Space & Root Protection:** Automatically falls back to `~/.cache/cvescan/` when run as a regular non-root user.

---

## Prerequisites

Before installing `cvescan`, ensure the following tools are installed:

```bash
# 1. Anchore Grype Vulnerability Scanner
brew install grype

# 2. macOS Desktop Notification Utility (Optional, but recommended)
brew install terminal-notifier
```

---

## Installation & Setup

### Automated CLI Installation (Recommended)

Run the following command from the repository:

```bash
sudo ldx cvescan install
```

**What this command does:**
1. Copies `cvescan/cvescan.sh` to `/usr/local/bin/cvescan.sh` (`root:wheel`, `755`).
2. Copies `cvescan/com.system.cvescan.plist` to `/Library/LaunchDaemons/com.system.cvescan.plist` (`root:wheel`, `644`).
3. Installs default configuration to `/usr/local/etc/cvescan.conf` if not already present.
4. Registers and bootstraps the daemon into the macOS system domain (`launchctl bootstrap system`).

---

## CLI Management

The `ldx cvescan` tool provides full lifecycle management:

### Check Status & Dry-Run Verification
```bash
# Display service status, state JSON, and binary paths
ldx cvescan status

# Perform a dry-run check (verifies binaries, lists target scan folders & exclusions)
ldx cvescan dry-run

# Perform a dry-run check on a specific folder without running Grype
ldx cvescan dry-run -t /Users/rogue/code/my-project
```

### Trigger Manual Scan & Target Specific Folders
```bash
# Trigger standard quick scan (uses default /Applications and /Users)
ldx cvescan trigger

# Scan a specific custom target folder
ldx cvescan trigger --target /Users/rogue/code/my-project

# Scan multiple specific target folders
ldx cvescan trigger -t /Applications -t /Users/rogue/projects

# Force a full deep scan (bypasses change detection)
ldx cvescan trigger --full
```

### View Scan Logs & HTML Visual Reports
```bash
# Open the interactive visual HTML report in your default browser
ldx cvescan report

# Open report from previous run #2 or #3
ldx cvescan report --run 2

# View formatted text log in terminal
ldx cvescan logs
ldx cvescan logs --run 2
```

### View Configuration
```bash
ldx cvescan config
```

### Uninstall
```bash
sudo ldx cvescan uninstall
```

---

## Configuration (`/usr/local/etc/cvescan.conf`)

You can customize scanner behavior by editing `/usr/local/etc/cvescan.conf`:

```bash
# Target directories to scan
SCAN_TARGETS=("/Applications" "/Users")

# Severities to report
SEVERITIES="CRITICAL,HIGH"

# Maximum number of scan runs to retain
MAX_LOG_HISTORY=3

# Number of days between mandatory full scans
FULL_SCAN_INTERVAL_DAYS=30

# Exclude patterns to optimize scan speed
EXCLUDE_PATTERNS=(
  "*/Library/Caches/*"
  "*/.cache/*"
  "*/Library/Containers/*"
  "*/.docker/*"
  "*/.colima/*"
  "*/node_modules/*"
  "*/.git/*"
)
```

---

## System vs User-Space Log Locations

- **System Daemon Mode (`sudo` / `launchctl`):**  
  - Log Directory: `/var/log/cvescan/`
  - Scan Log: `/var/log/cvescan/grype_scan_1.log`
  - State File: `/var/log/cvescan/state.json`

- **Standalone User Mode (Non-root standalone execution):**  
  - If `/var/log/cvescan` is not writable, the script automatically falls back to user space: `~/.cache/cvescan/` (e.g. `~/.cache/cvescan/grype_scan_1.log` & `~/.cache/cvescan/state.json`).
  - Supports path expansion for tilde paths (`~/.gradle/caches/`, etc.).
