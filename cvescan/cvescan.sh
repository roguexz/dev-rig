#!/usr/bin/env bash
#
# cvescan.sh - System-wide automated vulnerability scanner using Anchore Grype
# Installed to: /usr/local/bin/cvescan.sh
# Scheduled by: /Library/LaunchDaemons/com.system.cvescan.plist
#

set -euo pipefail

# Configuration File Location
CONFIG_FILE="/usr/local/etc/cvescan.conf"

# Declare array defaults
declare -a SCAN_TARGETS=()
declare -a EXCLUDE_PATTERNS=()

# Load configuration file if present
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Fallback default values if not specified in config file
LOG_DIR="${LOG_DIR:-/var/log/cvescan}"
STATE_FILE="${LOG_DIR}/state.json"
PID_FILE="/var/run/cvescan.pid"

SEVERITIES="${SEVERITIES:-CRITICAL,HIGH}"
MAX_LOG_HISTORY="${MAX_LOG_HISTORY:-3}"
FULL_SCAN_INTERVAL_DAYS="${FULL_SCAN_INTERVAL_DAYS:-30}"

if [ ${#SCAN_TARGETS[@]} -eq 0 ]; then
  SCAN_TARGETS=("/Applications" "/Users")
fi

if [ ${#EXCLUDE_PATTERNS[@]} -eq 0 ]; then
  EXCLUDE_PATTERNS=(
    "*/Library/Caches/*"
    "*/.cache/*"
    "*/Library/Containers/*"
    "*/.docker/*"
    "*/.colima/*"
    "*/node_modules/*"
    "*/.git/*"
  )
fi

# Flags
IS_FULL_SCAN=false
IS_FORCE=false
IS_DRY_RUN=false
IS_REPORT_ONLY=false
CUSTOM_TARGETS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --full)
      IS_FULL_SCAN=true
      shift 1
      ;;
    --force)
      IS_FORCE=true
      shift 1
      ;;
    --dry-run)
      IS_DRY_RUN=true
      shift 1
      ;;
    --report-only|--regenerate)
      IS_REPORT_ONLY=true
      shift 1
      ;;
    --target|-t)
      if [ -n "${2:-}" ]; then
        CUSTOM_TARGETS+=("$2")
        shift 2
      else
        echo "[ERROR] Option $1 requires a folder path argument."
        exit 1
      fi
      ;;
    --help|-h)
      echo "Usage: $(basename "$0") [--target <folder>] [--full] [--force] [--dry-run] [--regenerate]"
      echo "  --target, -t <folder>  Specify a custom directory to scan (can be repeated)"
      echo "  --full                 Force a complete vulnerability scan (bypasses change detection)"
      echo "  --force                Bypass directory fingerprint change check"
      echo "  --dry-run              Perform binary checks and list target scan folders without executing scan"
      echo "  --regenerate           Regenerate HTML report from existing JSON scan output without re-scanning"
      exit 0
      ;;
    *)
      shift 1
      ;;
  esac
done

if [ ${#CUSTOM_TARGETS[@]} -gt 0 ]; then
  SCAN_TARGETS=("${CUSTOM_TARGETS[@]}")
  IS_FORCE=true
fi

# Expand tilde in SCAN_TARGETS paths
EXPANDED_TARGETS=()
for target in "${SCAN_TARGETS[@]}"; do
  expanded_path="${target/#\~/$HOME}"
  EXPANDED_TARGETS+=("$expanded_path")
done
SCAN_TARGETS=("${EXPANDED_TARGETS[@]}")

# Ensure log directory exists, falling back to user cache if /var/log/cvescan is not writable
if ! mkdir -p "$LOG_DIR" 2>/dev/null || [ ! -w "$LOG_DIR" ]; then
  if [ -n "${HOME:-}" ] && [ -d "$HOME" ]; then
    LOG_DIR="${HOME}/.cache/cvescan"
  else
    LOG_DIR="${TMPDIR:-/tmp}/cvescan"
  fi
  mkdir -p "$LOG_DIR" 2>/dev/null || true
  STATE_FILE="${LOG_DIR}/state.json"
fi
chmod 755 "$LOG_DIR" 2>/dev/null || true

# --- Process Locking ---
cleanup() {
  if [ "$IS_DRY_RUN" = false ] && [ -n "${PID_FILE:-}" ]; then
    rm -f "$PID_FILE" 2>/dev/null || true
  fi
}

if [ "$IS_DRY_RUN" = false ]; then
  if ! touch "$PID_FILE" 2>/dev/null; then
    PID_FILE="/tmp/cvescan.pid"
  fi

  if [ -f "$PID_FILE" ]; then
    OLD_PID="$(cat "$PID_FILE" 2>/dev/null || echo "")"
    if [ -n "$OLD_PID" ] && kill -0 "$OLD_PID" 2>/dev/null; then
      echo "$(date '+%Y-%m-%d %H:%M:%S') [WARN] Scanner is already running under PID ${OLD_PID}. Exiting." >> "${LOG_DIR}/launchd_out.log" 2>/dev/null || true
      exit 0
    fi
  fi

  echo "$$" > "$PID_FILE" 2>/dev/null || true
  trap cleanup EXIT INT TERM
fi

# --- Binary Path Detection ---
find_binary() {
  local name="$1"
  local paths=("/opt/homebrew/bin/${name}" "/usr/local/bin/${name}" "/usr/bin/${name}")
  for p in "${paths[@]}"; do
    if [ -x "$p" ]; then
      echo "$p"
      return 0
    fi
  done
  if command -v "$name" &>/dev/null; then
    command -v "$name"
    return 0
  fi
  return 1
}

GRYPE_BIN="$(find_binary grype || true)"
NOTIFIER_BIN="$(find_binary terminal-notifier || true)"
PYTHON_BIN="$(find_binary python3 || true)"

if [ -z "$GRYPE_BIN" ]; then
  echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] grype binary not found. Please install it via: brew install grype" | tee -a "${LOG_DIR}/launchd_err.log"
  exit 1
fi

# --- Helper Functions ---
log_message() {
  local msg="$1"
  local timestamp
  timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[${timestamp}] ${msg}"
}

send_notification() {
  local title="$1"
  local message="$2"
  local target_path="${3:-}"

  if [ -n "$NOTIFIER_BIN" ] && [ -x "$NOTIFIER_BIN" ]; then
    local cmd=("$NOTIFIER_BIN" -title "$title" -message "$message")
    if [ -n "$target_path" ]; then
      cmd+=(-open "file://${target_path}")
    fi
    "${cmd[@]}" &>/dev/null || true
  fi
}

cleanup_old_reports() {
  local max="${MAX_LOG_HISTORY:-3}"
  
  # Clean up old timestamped logs beyond max limit
  local log_files=()
  while IFS= read -r f; do
    [ -n "$f" ] && log_files+=("$f")
  done < <(ls -1t "${LOG_DIR}"/grype_scan_20*.log 2>/dev/null || true)

  if [ ${#log_files[@]} -gt "$max" ]; then
    for (( i=max; i<${#log_files[@]}; i++ )); do
      rm -f "${log_files[$i]}" 2>/dev/null || true
    done
  fi

  # Clean up old timestamped JSON reports
  local json_files=()
  while IFS= read -r f; do
    [ -n "$f" ] && json_files+=("$f")
  done < <(ls -1t "${LOG_DIR}"/grype_report_20*.json 2>/dev/null || true)

  if [ ${#json_files[@]} -gt "$max" ]; then
    for (( i=max; i<${#json_files[@]}; i++ )); do
      rm -f "${json_files[$i]}" 2>/dev/null || true
    done
  fi

  # Clean up old timestamped HTML reports
  local html_files=()
  while IFS= read -r f; do
    [ -n "$f" ] && html_files+=("$f")
  done < <(ls -1t "${LOG_DIR}"/grype_report_20*.html 2>/dev/null || true)

  if [ ${#html_files[@]} -gt "$max" ]; then
    for (( i=max; i<${#html_files[@]}; i++ )); do
      rm -f "${html_files[$i]}" 2>/dev/null || true
    done
  fi
}

generate_html_report() {
  local json_file="$1"
  local html_file="$2"
  local ts="$3"
  local mode="$4"
  local targets_str="$5"

  if [ -z "$PYTHON_BIN" ] || [ ! -f "$json_file" ]; then
    return 0
  fi

  "$PYTHON_BIN" - "$json_file" "$html_file" "$ts" "$mode" "$targets_str" "$0" << 'PYEOF'
import json, sys, os, html

json_file = sys.argv[1]
html_file = sys.argv[2]
timestamp = sys.argv[3]
scan_mode = sys.argv[4]
target_dirs = [t.strip() for t in sys.argv[5].split(',') if t.strip()]
script_path = sys.argv[6] if len(sys.argv) > 6 else ''

try:
    with open(json_file, 'r') as f:
        data = json.load(f)
except Exception:
    sys.exit(0)

matches = data.get('matches', [])

SEVERITY_WEIGHTS = {'CRITICAL': 4, 'HIGH': 3, 'MEDIUM': 2, 'LOW': 1, 'UNKNOWN': 0}

def resolve_abs_path(raw_path):
    if not raw_path or raw_path == 'N/A':
        return 'N/A'
    if os.path.isabs(raw_path):
        if os.path.exists(raw_path):
            return os.path.abspath(raw_path)
        clean_rel = raw_path.lstrip('/')
        for tdir in target_dirs:
            cand = os.path.join(tdir, clean_rel)
            if os.path.exists(cand):
                return os.path.abspath(cand)
        return raw_path
    clean_rel = raw_path.lstrip('/')
    for tdir in target_dirs:
        cand = os.path.join(tdir, clean_rel)
        if os.path.exists(cand):
            return os.path.abspath(cand)
    for tdir in target_dirs:
        parent = os.path.dirname(tdir.rstrip('/'))
        cand = os.path.join(parent, clean_rel)
        if os.path.exists(cand):
            return os.path.abspath(cand)
    if target_dirs:
        return os.path.abspath(os.path.join(target_dirs[0], clean_rel))
    return raw_path

# Group vulnerabilities by resolved file location and package
grouped = {}

for m in matches:
    artifact = m.get('artifact', {})
    pkg_name = str(artifact.get('name', 'N/A'))
    pkg_ver = str(artifact.get('version', 'N/A'))
    pkg_type = str(artifact.get('type', 'N/A'))
    
    locs = artifact.get('locations', [])
    raw_loc_path = locs[0].get('path', 'N/A') if locs else 'N/A'
    abs_loc_path = resolve_abs_path(raw_loc_path)
    
    key = (abs_loc_path, pkg_name, pkg_ver)
    
    if key not in grouped:
        grouped[key] = {
            'pkg_name': pkg_name,
            'pkg_ver': pkg_ver,
            'pkg_type': pkg_type,
            'loc_path': abs_loc_path,
            'max_severity': 'UNKNOWN',
            'max_weight': 0,
            'cves': [],
            'fix_versions': set()
        }
        
    group = grouped[key]
    vuln = m.get('vulnerability', {})
    vuln_id = str(vuln.get('id', 'N/A'))
    severity = str(vuln.get('severity', 'Unknown')).upper()
    weight = SEVERITY_WEIGHTS.get(severity, 0)
    
    if weight > group['max_weight']:
        group['max_weight'] = weight
        group['max_severity'] = severity
        
    fix_info = vuln.get('fix', {})
    for fver in fix_info.get('versions', []):
        if fver:
            group['fix_versions'].add(fver)
            
    group['cves'].append({
        'id': vuln_id,
        'severity': severity
    })

crit_count = sum(1 for m in matches if str(m.get('vulnerability', {}).get('severity', '')).upper() == 'CRITICAL')
high_count = sum(1 for m in matches if str(m.get('vulnerability', {}).get('severity', '')).upper() == 'HIGH')
med_count = sum(1 for m in matches if str(m.get('vulnerability', {}).get('severity', '')).upper() == 'MEDIUM')
low_count = sum(1 for m in matches if str(m.get('vulnerability', {}).get('severity', '')).upper() not in ['CRITICAL', 'HIGH', 'MEDIUM'])

groups_html = []
for idx, ((loc_path, pkg_name, pkg_ver), group) in enumerate(grouped.items()):
    sev = group['max_severity']
    badge_cls = f"badge-{sev.lower()}"
    
    fix_str = html.escape(', '.join(sorted(group['fix_versions'])) if group['fix_versions'] else 'N/A')
    
    cve_links = []
    for cve in group['cves']:
        cid = html.escape(cve['id'])
        csev = cve['severity'].lower()
        cve_links.append(f'<a href="https://nvd.nist.gov/vuln/detail/{cid}" target="_blank" class="cve-tag cve-{csev}">{cid}</a>')
    
    cve_tags_html = " ".join(cve_links)
    cve_count = len(group['cves'])
    
    safe_path = html.escape(loc_path)
    safe_pkg = html.escape(pkg_name)
    safe_ver = html.escape(pkg_ver)
    safe_type = html.escape(group['pkg_type'])
    
    groups_html.append(f"""
    <tbody class="vuln-group" data-severity="{group['max_weight']}" data-package="{safe_pkg}" data-installed="{safe_ver}" data-fixed="{fix_str}" data-vulnerabilities="{cve_count}" data-type="{safe_type}" data-location="{safe_path}">
      <tr class="main-row">
        <td><span class="badge {badge_cls}">{sev}</span></td>
        <td><strong>{safe_pkg}</strong></td>
        <td><code>{safe_ver}</code></td>
        <td><code>{fix_str}</code></td>
        <td>
          <div class="cve-container">
            <span class="cve-count-pill">{cve_count} CVE{"s" if cve_count > 1 else ""}</span>
            <div class="cve-tags">{cve_tags_html}</div>
          </div>
        </td>
        <td colspan="2"><span class="type-tag">{safe_type}</span></td>
      </tr>
      <tr class="location-row">
        <td colspan="7">
          <div class="location-container">
            <div class="location-info">
              <svg class="location-icon" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 10c0 7-9 13-9 13s-9-6-9-13a9 9 0 0 1 18 0z"></path><circle cx="12" cy="10" r="3"></circle></svg>
              <span class="location-label">LOCATION</span>
              <span class="location-path" id="path-val-{idx}">{safe_path}</span>
            </div>
            <button class="copy-btn" onclick="copyToClipboard('path-val-{idx}', this)">
              <svg class="copy-icon" viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path></svg>
              <span>Copy Path</span>
            </button>
          </div>
        </td>
      </tr>
    </tbody>
    """)

table_body = "\n".join(groups_html) if groups_html else """
<tbody class="vuln-group">
  <tr>
    <td colspan="7" style="text-align:center; padding: 32px; color: #8b949e;">
      No vulnerabilities detected in scanned directories. 🎉
    </td>
  </tr>
</tbody>
"""

script_dir = os.path.dirname(os.path.abspath(script_path)) if script_path else ''
template_candidates = [
    os.path.join(script_dir, 'report_template.html'),
    '/usr/local/bin/report_template.html',
    '/usr/local/share/ldx/cvescan/report_template.html',
    os.path.expanduser('~/.local/share/ldx/cvescan/report_template.html')
]

template_content = None
for cand in template_candidates:
    if os.path.isfile(cand):
        try:
            with open(cand, 'r') as tf:
                template_content = tf.read()
            break
        except Exception:
            pass

if not template_content:
    sys.exit(0)

html_content = template_content \
    .replace('{{TIMESTAMP}}', html.escape(timestamp)) \
    .replace('{{SCAN_MODE}}', html.escape(scan_mode)) \
    .replace('{{TOTAL_COUNT}}', str(len(grouped))) \
    .replace('{{CRIT_COUNT}}', str(crit_count)) \
    .replace('{{HIGH_COUNT}}', str(high_count)) \
    .replace('{{MED_LOW_COUNT}}', str(med_count + low_count)) \
    .replace('{{TABLE_BODY}}', table_body)

with open(html_file, 'w') as f:
    f.write(html_content)
PYEOF
}

# --- State Management ---
read_state_field() {
  local field="$1"
  if [ -f "$STATE_FILE" ]; then
    grep -o "\"${field}\": *\"[^\"]*\"" "$STATE_FILE" 2>/dev/null | cut -d'"' -f4 || echo ""
  else
    echo ""
  fi
}

write_state() {
  local last_quick="$1"
  local last_full="$2"
  local fp_hash="$3"
  local status="$4"
  local vulns_crit="$5"
  local vulns_high="$6"

  cat <<EOF > "${STATE_FILE}.tmp"
{
  "last_quick_scan_timestamp": "${last_quick}",
  "last_full_scan_timestamp": "${last_full}",
  "last_fingerprint_hash": "${fp_hash}",
  "last_scan_status": "${status}",
  "scanner_engine": "grype",
  "critical_vulnerabilities": ${vulns_crit},
  "high_vulnerabilities": ${vulns_high}
}
EOF
  mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# --- Fast Fingerprint Calculation ---
calculate_fingerprint() {
  local find_args=()
  for pattern in "${EXCLUDE_PATTERNS[@]}"; do
    find_args+=(-path "$pattern" -prune -o)
  done

  local valid_targets=()
  for t in "${SCAN_TARGETS[@]}"; do
    if [ -d "$t" ]; then
      valid_targets+=("$t")
    fi
  done

  if [ ${#valid_targets[@]} -eq 0 ]; then
    echo "empty"
    return 0
  fi

  (find "${valid_targets[@]}" "${find_args[@]}" -maxdepth 3 -exec stat -f "%m %N" {} + 2>/dev/null || true) \
    | shasum -a 256 | awk '{print $1}'
}

# --- Main Logic ---

CURRENT_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
CURRENT_EPOCH="$(date '+%s')"
TS_STAMP="$(date '+%Y%m%d_%H%M%S')"

if [ "$IS_REPORT_ONLY" = true ]; then
  LATEST_JSON="${LOG_DIR}/grype_report_latest.json"
  LATEST_HTML="${LOG_DIR}/grype_report_latest.html"
  if [ ! -f "$LATEST_JSON" ]; then
    log_message "[ERROR] No JSON report found at ${LATEST_JSON} to regenerate HTML report."
    exit 1
  fi
  TARGETS_CSV="$(IFS=,; echo "${SCAN_TARGETS[*]}")"
  log_message "[INFO] Regenerating visual HTML report from ${LATEST_JSON}..."
  generate_html_report "$LATEST_JSON" "$LATEST_HTML" "$CURRENT_TIME" "Report Regenerated" "$TARGETS_CSV"
  log_message "[INFO] HTML report regenerated successfully: ${LATEST_HTML}"
  exit 0
fi

LAST_FULL_TS="$(read_state_field "last_full_scan_timestamp")"
LAST_FP_HASH="$(read_state_field "last_fingerprint_hash")"

# Check if monthly full scan is due
if [ -n "$LAST_FULL_TS" ]; then
  LAST_FULL_EPOCH="$(date -j -f "%Y-%m-%d %H:%M:%S" "$LAST_FULL_TS" "+%s" 2>/dev/null || echo 0)"
  DAYS_SINCE_FULL=$(( (CURRENT_EPOCH - LAST_FULL_EPOCH) / 86400 ))
  if [ "$DAYS_SINCE_FULL" -ge "$FULL_SCAN_INTERVAL_DAYS" ]; then
    IS_FULL_SCAN=true
  fi
else
  IS_FULL_SCAN=true
fi

# Calculate fingerprint
CURRENT_FP_HASH="$(calculate_fingerprint)"

# Dry-run diagnostic verification
if [ "$IS_DRY_RUN" = true ]; then
  echo "================================================================================"
  echo "cvescan Dry-Run Diagnostic Verification (Grype Engine)"
  echo "================================================================================"
  echo ""
  echo "1. Prerequisites & Binary Checks:"
  if [ -n "$GRYPE_BIN" ]; then
    GRYPE_VER="$("$GRYPE_BIN" version 2>/dev/null | grep -i "version" | head -n 1 || echo "installed")"
    echo "   [OK] Grype Binary: ${GRYPE_BIN} (${GRYPE_VER})"
  else
    echo "   [FAIL] Grype Binary: NOT FOUND"
  fi

  if [ -n "$NOTIFIER_BIN" ]; then
    echo "   [OK] Desktop Notifier: ${NOTIFIER_BIN}"
  else
    echo "   [WARN] Desktop Notifier: NOT FOUND (Desktop notifications disabled)"
  fi

  if [ -n "$PYTHON_BIN" ]; then
    echo "   [OK] HTML Report Generator: ${PYTHON_BIN}"
  fi
  echo ""

  echo "2. Configuration & State Paths:"
  echo "   Config File: ${CONFIG_FILE} $( [ -f "$CONFIG_FILE" ] && echo "(LOADED)" || echo "(NOT FOUND - USING DEFAULTS)" )"
  echo "   Log Directory: ${LOG_DIR}"
  echo "   State File: ${STATE_FILE}"
  echo ""

  echo "3. Target Folders to Scan:"
  for t in "${SCAN_TARGETS[@]}"; do
    if [ -d "$t" ]; then
      echo "   - $t (EXISTS)"
    else
      echo "   - $t (NOT FOUND)"
    fi
  done
  echo ""

  echo "4. Excluded Patterns:"
  for pat in "${EXCLUDE_PATTERNS[@]}"; do
    echo "   - $pat"
  done
  echo ""

  echo "5. Execution Plan:"
  echo "   Scan Mode: $( [ "$IS_FULL_SCAN" = true ] && echo "FULL DEEP SCAN" || echo "QUICK INCREMENTAL SCAN" )"
  echo "   Severities: ${SEVERITIES}"
  echo "   Calculated Fingerprint: ${CURRENT_FP_HASH}"
  echo "   Last Saved Fingerprint: ${LAST_FP_HASH:-None}"
  
  if [ "$IS_FULL_SCAN" = false ] && [ "$IS_FORCE" = false ] && [ -n "$LAST_FP_HASH" ] && [ "$CURRENT_FP_HASH" = "$LAST_FP_HASH" ]; then
    echo "   Action on Execution: SKIP SCAN (No changes detected since last scan)"
  else
    echo "   Action on Execution: EXECUTE GRYPE SCAN & GENERATE HTML REPORT"
  fi
  echo ""
  echo "[DRY-RUN COMPLETE] Basic checks passed. No scan was executed and no log files were modified."
  exit 0
fi

# Skip scan if unchanged and not forced/full
if [ "$IS_FULL_SCAN" = false ] && [ "$IS_FORCE" = false ] && [ -n "$LAST_FP_HASH" ] && [ "$CURRENT_FP_HASH" = "$LAST_FP_HASH" ]; then
  log_message "[INFO] No directory changes detected in target paths since last scan. Skipping scan." >> "${LOG_DIR}/launchd_out.log"
  exit 0
fi

CURRENT_LOG="${LOG_DIR}/grype_scan_${TS_STAMP}.log"
CURRENT_JSON="${LOG_DIR}/grype_report_${TS_STAMP}.json"
CURRENT_HTML="${LOG_DIR}/grype_report_${TS_STAMP}.html"

LATEST_LOG="${LOG_DIR}/grype_scan_latest.log"
LATEST_JSON="${LOG_DIR}/grype_report_latest.json"
LATEST_HTML="${LOG_DIR}/grype_report_latest.html"

{
  echo "================================================================================"
  echo "System Vulnerability Scan (Grype)"
  echo "Execution Timestamp: ${CURRENT_TIME}"
  echo "Scan Mode: $( [ "$IS_FULL_SCAN" = true ] && echo "FULL DEEP SCAN" || echo "QUICK INCREMENTAL SCAN" )"
  echo "Targets: ${SCAN_TARGETS[*]}"
  echo "Severities: ${SEVERITIES}"
  echo "Grype Binary: ${GRYPE_BIN}"
  echo "================================================================================"
  echo ""
} > "$CURRENT_LOG"

# Send start notification
SCAN_MODE_DESC="$( [ "$IS_FULL_SCAN" = true ] && echo "Full Deep Scan" || echo "Quick Incremental Scan" )"
send_notification "CVE Scanner Running" "Started ${SCAN_MODE_DESC} using Grype." "$CURRENT_LOG"

VALID_TARGETS=()
for t in "${SCAN_TARGETS[@]}"; do
  if [ -d "$t" ]; then
    VALID_TARGETS+=("$t")
  fi
done

SCAN_SUCCESS=true
CRIT_COUNT=0
HIGH_COUNT=0

RAW_JSON="${LOG_DIR}/grype_raw.json"
rm -f "$RAW_JSON"

for target in "${VALID_TARGETS[@]}"; do
  echo "--- Scanning Target Directory: ${target} ---" >> "$CURRENT_LOG"
  "$GRYPE_BIN" dir:"${target}" -o table >> "$CURRENT_LOG" 2>&1 || SCAN_SUCCESS=false
  
  # Save JSON report for count parsing and HTML generation
  "$GRYPE_BIN" dir:"${target}" -o json > "$RAW_JSON" 2>/dev/null || true
  if [ -f "$RAW_JSON" ] && command -v jq &>/dev/null; then
    target_crit="$(jq '[.matches[]? | select(.vulnerability.severity=="Critical")] | length' "$RAW_JSON" 2>/dev/null || echo 0)"
    target_high="$(jq '[.matches[]? | select(.vulnerability.severity=="High")] | length' "$RAW_JSON" 2>/dev/null || echo 0)"
    CRIT_COUNT=$(( CRIT_COUNT + target_crit ))
    HIGH_COUNT=$(( HIGH_COUNT + target_high ))
  fi
done

cp "$RAW_JSON" "$CURRENT_JSON" 2>/dev/null || echo "{}" > "$CURRENT_JSON"

# Create comma-separated list of target directories for Python path resolution
TARGETS_CSV="$(IFS=,; echo "${VALID_TARGETS[*]}")"

# Generate Visual HTML Report
generate_html_report "$CURRENT_JSON" "$CURRENT_HTML" "$CURRENT_TIME" "$SCAN_MODE_DESC" "$TARGETS_CSV"

# Create/update 'latest' symlinks
ln -sf "$(basename "$CURRENT_LOG")" "$LATEST_LOG" 2>/dev/null || true
ln -sf "$(basename "$CURRENT_JSON")" "$LATEST_JSON" 2>/dev/null || true
ln -sf "$(basename "$CURRENT_HTML")" "$LATEST_HTML" 2>/dev/null || true

# Perform retention cleanup (keep 3 latest timestamped reports)
cleanup_old_reports

END_TIME="$(date '+%Y-%m-%d %H:%M:%S')"
echo "" >> "$CURRENT_LOG"
echo "================================================================================" >> "$CURRENT_LOG"
echo "Scan Completed at: ${END_TIME}" >> "$CURRENT_LOG"
echo "================================================================================" >> "$CURRENT_LOG"

TOTAL_VULNS=$(( CRIT_COUNT + HIGH_COUNT ))

if [ "$TOTAL_VULNS" -gt 0 ]; then
  NOTIF_TITLE="⚠️ CVE Alert Found (Grype)"
  NOTIF_MSG="Found ${CRIT_COUNT} Critical and ${HIGH_COUNT} High vulnerabilities. Click to view report."
else
  NOTIF_TITLE="✅ CVE Scan Clean (Grype)"
  NOTIF_MSG="No Critical or High vulnerabilities detected."
fi

# Send completion notification linked to visual HTML report
send_notification "$NOTIF_TITLE" "$NOTIF_MSG" "$LATEST_HTML"

NEW_FULL_TS="$LAST_FULL_TS"
if [ "$IS_FULL_SCAN" = true ] || [ -z "$NEW_FULL_TS" ]; then
  NEW_FULL_TS="$CURRENT_TIME"
fi

if [ "$SCAN_SUCCESS" = true ]; then
  write_state "$CURRENT_TIME" "$NEW_FULL_TS" "$CURRENT_FP_HASH" "SUCCESS" "$CRIT_COUNT" "$HIGH_COUNT"
else
  write_state "$CURRENT_TIME" "$NEW_FULL_TS" "" "PARTIAL_ERROR" "$CRIT_COUNT" "$HIGH_COUNT"
fi

exit 0
