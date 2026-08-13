# =============================================================================
# lib/core.sh — logging, execution helpers, findings engine
# Sourced by bin/linux-perf-analyzer.sh. Requires OUTPUT_DIR, HOST_, TS to be
# already exported by the caller.
# =============================================================================

# Unit-separator (0x1F) used as the field delimiter in findings.dat.
# Chosen because it cannot realistically appear in command output that gets
# funneled into a finding's free-text fields.
FS_SEP=$'\x1f'

# ─── COLORS (only on a real TTY) ────────────────────────────────────────────
if [[ -t 1 ]]; then
  R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m'
  C='\033[0;36m' B='\033[1m'    X='\033[0m'
else
  R='' Y='' G='' C='' B='' X=''
fi

# ─── STATE ───────────────────────────────────────────────────────────────────
declare -A DETECTED=()          # DETECTED[appkey]=display_name
declare -a WARNINGS=()
CURRENT_MODULE_FILE="/dev/null" # overwritten by module_begin()

# ─── OUTPUT SCAFFOLDING ──────────────────────────────────────────────────────
init_output() {
  mkdir -p "$OUTPUT_DIR/modules"
  REPORT="$OUTPUT_DIR/full_report.txt"
  SUMMARY="$OUTPUT_DIR/summary.md"
  FINDINGS_DB="$OUTPUT_DIR/findings.dat"
  STACK_DB="$OUTPUT_DIR/stack.dat"
  : > "$REPORT"
  : > "$SUMMARY"
  : > "$FINDINGS_DB"
  : > "$STACK_DB"
}

# module_begin NAME — opens a dedicated per-module raw-output file so every
# collector produces its own artifact in addition to the cumulative report.
module_begin() {
  local name="$1"
  CURRENT_MODULE_FILE="$OUTPUT_DIR/modules/${name}.txt"
  : > "$CURRENT_MODULE_FILE"
}

# ─── PRIMITIVES ──────────────────────────────────────────────────────────────
log()  { echo -e "${C}[INFO]${X}  $*" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"; }
warn() { echo -e "${Y}[WARN]${X}  $*" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"; WARNINGS+=("$*"); }
err()  { echo -e "${R}[ERR]${X}   $*" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"; }

section() {
  local bar; bar=$(printf '═%.0s' {1..70})
  { printf '\n%s\n' "$bar"; echo -e "  ${B}${G}$*${X}"; printf '%s\n' "$bar"; } \
    | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
}

sub() {
  echo -e "\n${B}── $* ──${X}" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
}

# run "label" cmd [args...]  — never fails the pipeline, always read-only.
run() {
  local label="$1"; shift
  echo -e "\n${B}▶ ${label}${X}" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  "$@" 2>&1 | tee -a "$REPORT" "$CURRENT_MODULE_FILE" || true
}

# runsh "label" "shell string" — for pipelines/redirections that need eval.
runsh() {
  local label="$1" cmd="$2"
  echo -e "\n${B}▶ ${label}${X}" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  eval "$cmd" 2>&1 | tee -a "$REPORT" "$CURRENT_MODULE_FILE" || true
}

# capture "shell string" — like runsh but returns the value instead of
# printing it (used for computing thresholds without polluting the report).
capture() { eval "$1" 2>/dev/null || true; }

is_cmd()      { command -v "$1" &>/dev/null; }
svc_active()  { systemctl is-active --quiet "$1" 2>/dev/null; }
proc_up()     { pgrep -fx "$1" &>/dev/null || pgrep -f "$1" &>/dev/null; }

# ─── FINDINGS ENGINE ─────────────────────────────────────────────────────────
# A finding is a single-line, pipe-safe record consumed by report/generate_html.sh
# Fields: SEVERITY | CATEGORY | MODULE | TITLE | DETAIL | RECOMMENDATION | REFERENCE
_sanitize() { printf '%s' "$1" | tr '\n\r' '  ' | tr -d "$FS_SEP"; }

# finding_raw SEVERITY CATEGORY TITLE DETAIL RECOMMENDATION REFERENCE
finding_raw() {
  local sev="$1" cat="$2" title="$3" detail="$4" rec="$5" ref="$6"
  local mod="${CURRENT_MODULE_LABEL:-general}"
  printf '%s\n' \
    "$(_sanitize "$sev")${FS_SEP}$(_sanitize "$cat")${FS_SEP}$(_sanitize "$mod")${FS_SEP}$(_sanitize "$title")${FS_SEP}$(_sanitize "$detail")${FS_SEP}$(_sanitize "$rec")${FS_SEP}$(_sanitize "$ref")" \
    >> "$FINDINGS_DB"
  case "$sev" in
    CRITICAL) err  "[$sev] $title — $detail" ;;
    HIGH|MEDIUM) warn "[$sev] $title — $detail" ;;
    *) log "[$sev] $title — $detail" ;;
  esac
}

# finding SEVERITY KB_KEY TITLE DETAIL — pulls category/recommendation/reference
# from the knowledge base (lib/kb.sh) so wording stays consistent everywhere.
finding() {
  local sev="$1" key="$2" title="$3" detail="$4"
  local cat="${KB_CAT[$key]:-General}"
  local rec="${KB_REC[$key]:-Review this metric against vendor guidance for your workload.}"
  local ref="${KB_REF[$key]:-N/A}"
  finding_raw "$sev" "$cat" "$title" "$detail" "$rec" "$ref"
}

register_app() {
  local key="$1" label="$2"
  DETECTED[$key]="$label"
  echo "$key${FS_SEP}$label" >> "$STACK_DB"
}

# ─── APPLICATION PLUGIN REGISTRY ─────────────────────────────────────────────
# Each file in modules/apps/*.sh calls register_plugin at source time to
# advertise itself, then defines app_<key>_detect() and app_<key>_analyze().
# This is what makes new application support a drop-in file instead of a
# change to the core engine.
declare -a APP_PLUGIN_KEYS=()
declare -A APP_LABELS=()

register_plugin() {
  local key="$1" label="$2"
  APP_PLUGIN_KEYS+=("$key")
  APP_LABELS[$key]="$label"
}

require_readonly_notice() {
  log "This tool performs READ-ONLY collection. It does not modify configuration,"
  log "restart services, install packages, or change kernel/runtime parameters."
}

check_privileges() {
  if [[ $EUID -ne 0 ]]; then
    warn "Not running as root — some collectors (full lsof, docker, restricted logs," \
         "DB local-socket auth) may return partial data. Recommended: sudo bash $0"
  else
    log "Running as root — full collection enabled."
  fi
}
