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
      echo "Usage: $(basename "$0") [--target <folder>] [--full] [--force] [--dry-run]"
      echo "  --target, -t <folder>  Specify a custom directory to scan (can be repeated)"
      echo "  --full                 Force a complete vulnerability scan (bypasses change detection)"
      echo "  --force                Bypass directory fingerprint change check"
      echo "  --dry-run              Perform binary checks and list target scan folders without executing scan"
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

  "$PYTHON_BIN" - "$json_file" "$html_file" "$ts" "$mode" "$targets_str" << 'PYEOF'
import json, sys, os, html

json_file = sys.argv[1]
html_file = sys.argv[2]
timestamp = sys.argv[3]
scan_mode = sys.argv[4]
target_dirs = [t.strip() for t in sys.argv[5].split(',') if t.strip()]

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
    if os.path.isabs(raw_path) and os.path.exists(raw_path):
        return os.path.abspath(raw_path)
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

rows_html = []
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
    
    rows_html.append(f"""
    <tr data-severity-weight="{group['max_weight']}">
      <td data-sort-val="{group['max_weight']}"><span class="badge {badge_cls}">{sev}</span></td>
      <td data-sort-val="{safe_pkg}"><strong>{safe_pkg}</strong></td>
      <td data-sort-val="{safe_ver}"><code>{safe_ver}</code></td>
      <td data-sort-val="{fix_str}"><code>{fix_str}</code></td>
      <td data-sort-val="{cve_count}">
        <div class="cve-container">
          <span class="cve-count-pill">{cve_count} CVE{"s" if cve_count > 1 else ""}</span>
          <div class="cve-tags">{cve_tags_html}</div>
        </div>
      </td>
      <td data-sort-val="{safe_type}"><span class="type-tag">{safe_type}</span></td>
      <td data-sort-val="{safe_path}">
        <div class="path-container">
          <span class="path-text" id="path-val-{idx}">{safe_path}</span>
          <button class="copy-btn" onclick="copyToClipboard('path-val-{idx}', this)">Copy Path</button>
        </div>
      </td>
    </tr>
    """)

table_body = "\n".join(rows_html) if rows_html else "<tr><td colspan='7' style='text-align:center; padding: 24px; color: #8b949e;'>No vulnerabilities detected in scanned directories. 🎉</td></tr>"

html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>cvescan Vulnerability Report</title>
  <style>
    :root {{
      --bg-color: #0d1117;
      --card-bg: #161b22;
      --border-color: #30363d;
      --text-color: #c9d1d9;
      --text-dim: #8b949e;
      --accent-blue: #58a6ff;
      --critical-color: #f85149;
      --high-color: #ff7b72;
      --medium-color: #d29922;
      --low-color: #3fb950;
    }}
    body {{
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
      background-color: var(--bg-color);
      color: var(--text-color);
      margin: 0;
      padding: 24px;
    }}
    .container {{
      max-width: 1400px;
      margin: 0 auto;
    }}
    .header {{
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding-bottom: 16px;
      border-bottom: 1px solid var(--border-color);
      margin-bottom: 24px;
    }}
    h1 {{
      font-size: 24px;
      margin: 0;
      color: #fff;
    }}
    .meta-tag {{
      font-size: 13px;
      color: var(--text-dim);
    }}
    .stats-grid {{
      display: grid;
      grid-template-columns: repeat(4, 1fr);
      gap: 16px;
      margin-bottom: 24px;
    }}
    .stat-card {{
      background-color: var(--card-bg);
      border: 1px solid var(--border-color);
      border-radius: 8px;
      padding: 16px;
    }}
    .stat-card .label {{
      font-size: 12px;
      text-transform: uppercase;
      letter-spacing: 0.5px;
      color: var(--text-dim);
    }}
    .stat-card .value {{
      font-size: 28px;
      font-weight: 700;
      margin-top: 8px;
    }}
    .search-bar {{
      margin-bottom: 16px;
    }}
    .search-input {{
      width: 100%;
      box-sizing: border-box;
      padding: 10px 14px;
      background-color: var(--card-bg);
      border: 1px solid var(--border-color);
      border-radius: 6px;
      color: #fff;
      font-size: 14px;
    }}
    table {{
      width: 100%;
      border-collapse: collapse;
      background-color: var(--card-bg);
      border: 1px solid var(--border-color);
      border-radius: 8px;
      overflow: hidden;
    }}
    th, td {{
      padding: 12px 16px;
      text-align: left;
      border-bottom: 1px solid var(--border-color);
      font-size: 13px;
    }}
    th {{
      background-color: #21262d;
      color: var(--text-dim);
      font-weight: 600;
      text-transform: uppercase;
      font-size: 11px;
      letter-spacing: 0.5px;
      cursor: pointer;
      user-select: none;
    }}
    th:hover {{
      background-color: #30363d;
      color: #fff;
    }}
    .sort-icon {{
      margin-left: 6px;
      opacity: 0.5;
    }}
    .badge {{
      display: inline-block;
      padding: 3px 8px;
      border-radius: 12px;
      font-size: 11px;
      font-weight: 700;
      text-transform: uppercase;
    }}
    .badge-critical {{ background: rgba(248, 81, 73, 0.2); color: var(--critical-color); border: 1px solid var(--critical-color); }}
    .badge-high {{ background: rgba(255, 123, 114, 0.2); color: var(--high-color); border: 1px solid var(--high-color); }}
    .badge-medium {{ background: rgba(210, 153, 34, 0.2); color: var(--medium-color); border: 1px solid var(--medium-color); }}
    .badge-low {{ background: rgba(63, 185, 80, 0.2); color: var(--low-color); border: 1px solid var(--low-color); }}
    
    .cve-container {{
      display: flex;
      flex-direction: column;
      gap: 6px;
    }}
    .cve-count-pill {{
      font-size: 11px;
      font-weight: 600;
      color: var(--text-dim);
    }}
    .cve-tags {{
      display: flex;
      flex-wrap: wrap;
      gap: 6px;
    }}
    .cve-tag {{
      font-size: 11px;
      padding: 2px 6px;
      border-radius: 4px;
      font-family: ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace;
      text-decoration: none;
    }}
    .cve-critical {{ background: rgba(248, 81, 73, 0.15); color: var(--critical-color); border: 1px solid rgba(248, 81, 73, 0.4); }}
    .cve-high {{ background: rgba(255, 123, 114, 0.15); color: var(--high-color); border: 1px solid rgba(255, 123, 114, 0.4); }}
    .cve-medium {{ background: rgba(210, 153, 34, 0.15); color: var(--medium-color); border: 1px solid rgba(210, 153, 34, 0.4); }}
    .cve-low {{ background: rgba(63, 185, 80, 0.15); color: var(--low-color); border: 1px solid rgba(63, 185, 80, 0.4); }}
    
    .path-container {{
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
    }}
    .path-text {{
      font-family: ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace;
      font-size: 12px;
      color: var(--text-color);
      word-break: break-all;
      line-height: 1.4;
    }}
    .copy-btn {{
      flex-shrink: 0;
      background: #21262d;
      color: var(--text-color);
      border: 1px solid var(--border-color);
      border-radius: 6px;
      padding: 4px 8px;
      font-size: 11px;
      cursor: pointer;
      transition: background 0.15s ease-in-out;
    }}
    .copy-btn:hover {{
      background: #30363d;
      color: #fff;
    }}
    .copy-btn.copied {{
      background: #238636;
      color: #fff;
      border-color: #2e9d42;
    }}
    code {{
      font-family: ui-monospace, SFMono-Regular, SF Mono, Menlo, Consolas, monospace;
      background: rgba(110, 118, 129, 0.2);
      padding: 2px 6px;
      border-radius: 4px;
    }}
    a {{ color: var(--accent-blue); text-decoration: none; }}
    a:hover {{ text-decoration: underline; }}
    .type-tag {{ color: var(--text-dim); font-size: 12px; }}
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <div>
        <h1>🛡️ cvescan Vulnerability Report</h1>
        <div class="meta-tag">Execution: {timestamp} &bull; Mode: {scan_mode}</div>
      </div>
    </div>
    
    <div class="stats-grid">
      <div class="stat-card">
        <div class="label">Total Affected Packages</div>
        <div class="value" style="color: #fff;">{len(grouped)}</div>
      </div>
      <div class="stat-card">
        <div class="label">Critical</div>
        <div class="value" style="color: var(--critical-color);">{crit_count}</div>
      </div>
      <div class="stat-card">
        <div class="label">High</div>
        <div class="value" style="color: var(--high-color);">{high_count}</div>
      </div>
      <div class="stat-card">
        <div class="label">Medium / Low</div>
        <div class="value" style="color: var(--medium-color);">{med_count + low_count}</div>
      </div>
    </div>

    <div class="search-bar">
      <input type="text" id="searchInput" class="search-input" placeholder="Search vulnerabilities by package, CVE ID, or path..." onkeyup="filterTable()">
    </div>

    <table id="vulnTable">
      <thead>
        <tr>
          <th onclick="sortTable(0, 'number')">Severity <span class="sort-icon">↕</span></th>
          <th onclick="sortTable(1, 'string')">Package <span class="sort-icon">↕</span></th>
          <th onclick="sortTable(2, 'string')">Installed <span class="sort-icon">↕</span></th>
          <th onclick="sortTable(3, 'string')">Fixed In <span class="sort-icon">↕</span></th>
          <th onclick="sortTable(4, 'number')">Vulnerabilities <span class="sort-icon">↕</span></th>
          <th onclick="sortTable(5, 'string')">Type <span class="sort-icon">↕</span></th>
          <th onclick="sortTable(6, 'string')">Location Path <span class="sort-icon">↕</span></th>
        </tr>
      </thead>
      <tbody>
        {table_body}
      </tbody>
    </table>
  </div>

  <script>
    function filterTable() {{
      const input = document.getElementById('searchInput').value.toLowerCase();
      const rows = document.querySelectorAll('#vulnTable tbody tr');
      rows.forEach(row => {{
        const text = row.textContent.toLowerCase();
        row.style.display = text.includes(input) ? '' : 'none';
      }});
    }}

    function copyToClipboard(elementId, btn) {{
      const text = document.getElementById(elementId).innerText;
      navigator.clipboard.writeText(text).then(() => {{
        const origText = btn.innerText;
        btn.innerText = 'Copied!';
        btn.classList.add('copied');
        setTimeout(() => {{
          btn.innerText = origText;
          btn.classList.remove('copied');
        }}, 2000);
      }}).catch(err => {{
        console.error('Failed to copy: ', err);
      }});
    }}

    let sortDirections = {{}};
    function sortTable(colIndex, type) {{
      const table = document.getElementById('vulnTable');
      const tbody = table.querySelector('tbody');
      const rows = Array.from(tbody.querySelectorAll('tr'));
      
      const currentDir = sortDirections[colIndex] === 'asc' ? 'desc' : 'asc';
      sortDirections[colIndex] = currentDir;
      
      rows.sort((a, b) => {{
        let aVal = a.children[colIndex].getAttribute('data-sort-val') || a.children[colIndex].innerText.trim();
        let bVal = b.children[colIndex].getAttribute('data-sort-val') || b.children[colIndex].innerText.trim();
        
        if (type === 'number') {{
          aVal = parseFloat(aVal) || 0;
          bVal = parseFloat(bVal) || 0;
          return currentDir === 'asc' ? aVal - bVal : bVal - aVal;
        }} else {{
          return currentDir === 'asc' 
            ? aVal.localeCompare(bVal, undefined, {{numeric: true, sensitivity: 'base'}}) 
            : bVal.localeCompare(aVal, undefined, {{numeric: true, sensitivity: 'base'}});
        }}
      }});

      rows.forEach(row => tbody.appendChild(row));

      // Update sort icons
      const headers = table.querySelectorAll('th');
      headers.forEach((th, idx) => {{
        const icon = th.querySelector('.sort-icon');
        if (idx === colIndex) {{
          icon.innerText = currentDir === 'asc' ? '▲' : '▼';
        }} else {{
          icon.innerText = '↕';
        }}
      }});
    }}
  </script>
</body>
</html>
"""

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
