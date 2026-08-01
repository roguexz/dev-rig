#!/usr/bin/env bash
set -euo pipefail

log_info() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
log_warn() { echo -e "\033[1;33m[WARN]\033[0m $1"; }

log_info "Running post-install hook for skill '${SKILL_NAME:-playwright-cli}'..."

CONFIG_DIR="${HOME}/.config/playwright-cli"
CACHE_DIR="${HOME}/.cache/playwright-cli"
CONFIG_FILE="${CONFIG_DIR}/cli.config.json"
ZPROFILE="${HOME}/.zprofile"

# 1. Create cache directory
mkdir -p "$CACHE_DIR"
log_info "Ensured cache directory exists: ${CACHE_DIR}"

# 2. Create config directory and cli.config.json
mkdir -p "$CONFIG_DIR"
cat <<EOF > "$CONFIG_FILE"
{
    "browser": {
        "isolated": false,
        "userDataDir": "${CACHE_DIR}"
    }
}
EOF
log_info "Created config file: ${CONFIG_FILE}"

# 3. Locate Microsoft Edge executable in /Applications or ~/Applications
EDGE_SYS_EXE="/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
EDGE_USER_EXE="${HOME}/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"
EDGE_EXE=""

if [ -f "$EDGE_SYS_EXE" ]; then
    EDGE_EXE="$EDGE_SYS_EXE"
    log_info "Found Microsoft Edge executable at '${EDGE_EXE}'"
elif [ -f "$EDGE_USER_EXE" ]; then
    EDGE_EXE="$EDGE_USER_EXE"
    log_info "Found Microsoft Edge executable at '${EDGE_EXE}'"
else
    log_warn "Microsoft Edge executable binary was not found in /Applications or ~/Applications."
fi

# 4. Update ~/.zprofile with environment variables
touch "$ZPROFILE"

if grep -q "PLAYWRIGHT_MCP_CONFIG" "$ZPROFILE"; then
    log_info "PLAYWRIGHT_MCP_CONFIG is already present in ${ZPROFILE}."
    if [ -n "$EDGE_EXE" ] && ! grep -q "PLAYWRIGHT_MCP_EXECUTABLE_PATH" "$ZPROFILE"; then
        log_info "Appending PLAYWRIGHT_MCP_EXECUTABLE_PATH to ${ZPROFILE}..."
        echo "export PLAYWRIGHT_MCP_EXECUTABLE_PATH=\"${EDGE_EXE}\"" >> "$ZPROFILE"
    fi
else
    log_info "Adding PLAYWRIGHT_MCP environment variables to ${ZPROFILE}..."
    cat <<EOF >> "$ZPROFILE"

# Added by ldx skill: playwright-cli
export PLAYWRIGHT_MCP_CONFIG=\$HOME/.config/playwright-cli/cli.config.json
export PLAYWRIGHT_MCP_BROWSER=msedge
EOF
    if [ -n "$EDGE_EXE" ]; then
        echo "export PLAYWRIGHT_MCP_EXECUTABLE_PATH=\"${EDGE_EXE}\"" >> "$ZPROFILE"
    fi
    log_info "Updated ${ZPROFILE}"
fi

log_info "Post-install hook completed successfully for '${SKILL_NAME:-playwright-cli}'."
