#!/usr/bin/env bash
# =============================================================================
# linux-perf-analyzer.sh — Distro-agnostic Linux Server Performance &
#                           Application-Aware Analysis (read-only)
# =============================================================================
# Supports RHEL/CentOS/Rocky/Alma/Fedora, SUSE/openSUSE, Debian/Ubuntu and
# derivatives. Performs ONLY read-only data collection — it never changes
# configuration, restarts services, installs packages, or writes anywhere
# outside its own OUTPUT_DIR.
#
# Usage:
#   sudo bash bin/linux-perf-analyzer.sh
#   sudo OUTPUT_DIR=/var/reports bash bin/linux-perf-analyzer.sh
#   sudo MYSQL_PASS=secret PG_USER=postgres bash bin/linux-perf-analyzer.sh
#
# Environment variables:
#   OUTPUT_DIR            Output directory   (default: /tmp/linux-perf-<ts>)
#   LOG_TAIL_LINES         Lines from logs    (default: 200)
#   MYSQL_USER             MySQL user         (default: root)
#   MYSQL_PASS             MySQL password     (default: empty / socket auth)
#   PG_USER                PostgreSQL OS user (default: postgres)
#   SLOW_QUERY_THRESHOLD   MySQL slow query   (default: 1 second, informational)
#   ORACLE_OS_USER         OS user for SQL*Plus "/ as sysdba" via passwordless
#                          sudo (default: oracle). No DB password is ever used.
#                          SAP HANA/NetWeaver instance admin users (<sid>adm)
#                          are derived automatically per detected instance.
# =============================================================================

set -uo pipefail
IFS=$'\n\t'
# NOTE: deliberately NOT using `set -e`. This tool must survive one bad
# collector and still produce a report; individual commands already guard
# their own failures (run()/runsh() append `|| true`). `set -e` combined
# with bash's well-known inconsistencies around functions, `&&` lists and
# while-read loops (see Bash manual, "The Set Builtin") makes partial,
# silent aborts far more likely than the explicit guards below.

# ─── PATHS ───────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &>/dev/null && pwd)"
readonly SCRIPT_DIR REPO_ROOT
readonly LIB_DIR="$REPO_ROOT/lib"
MODULES_DIR="$REPO_ROOT/modules"
readonly MODULES_DIR
readonly REPORT_GEN="$REPO_ROOT/report/generate_html.sh"

# ─── CONFIG ──────────────────────────────────────────────────────────────────
readonly SCRIPT_VERSION="1.1.0"
readonly TS=$(date +"%Y%m%d_%H%M%S")
readonly HOST_=$(hostname -f 2>/dev/null || hostname)
OUTPUT_DIR="${OUTPUT_DIR:-/tmp/linux-perf-${TS}}"
readonly OUTPUT_DIR
readonly LOG_TAIL_LINES="${LOG_TAIL_LINES:-200}"
readonly MYSQL_USER="${MYSQL_USER:-root}"
readonly MYSQL_PASS="${MYSQL_PASS:-}"
readonly PG_USER="${PG_USER:-postgres}"
readonly SLOW_QUERY_THRESHOLD="${SLOW_QUERY_THRESHOLD:-1}"
readonly ORACLE_OS_USER="${ORACLE_OS_USER:-oracle}"

# shellcheck source=lib/core.sh
source "$LIB_DIR/core.sh"
# shellcheck source=lib/os_detect.sh
source "$LIB_DIR/os_detect.sh"
# shellcheck source=lib/kb.sh
source "$LIB_DIR/kb.sh"

# ─── SYSTEM MODULES (order matters for report readability) ─────────────────
# shellcheck source=modules/00-os-kernel.sh
source "$MODULES_DIR/00-os-kernel.sh"
# shellcheck source=modules/01-cpu.sh
source "$MODULES_DIR/01-cpu.sh"
# shellcheck source=modules/02-memory.sh
source "$MODULES_DIR/02-memory.sh"
# shellcheck source=modules/03-storage.sh
source "$MODULES_DIR/03-storage.sh"
# shellcheck source=modules/04-network.sh
source "$MODULES_DIR/04-network.sh"
# shellcheck source=modules/05-processes.sh
source "$MODULES_DIR/05-processes.sh"
# shellcheck source=modules/06-kernel-limits.sh
source "$MODULES_DIR/06-kernel-limits.sh"
# shellcheck source=modules/10-detect-stack.sh
source "$MODULES_DIR/10-detect-stack.sh"

generate_summary() {
  CURRENT_MODULE_LABEL="Summary"
  CURRENT_MODULE_FILE="/dev/null"
  section "SUMMARY"

  local now crit high med low info total
  now=$(date)
  crit=$(awk -F"$FS_SEP" '$1=="CRITICAL"' "$FINDINGS_DB" | wc -l)
  high=$(awk -F"$FS_SEP" '$1=="HIGH"'     "$FINDINGS_DB" | wc -l)
  med=$(awk -F"$FS_SEP"  '$1=="MEDIUM"'   "$FINDINGS_DB" | wc -l)
  low=$(awk -F"$FS_SEP"  '$1=="LOW"'      "$FINDINGS_DB" | wc -l)
  info=$(awk -F"$FS_SEP" '$1=="INFO"'     "$FINDINGS_DB" | wc -l)
  total=$(( crit + high + med + low + info ))

  {
    echo "# Server Performance Analysis"
    echo ""
    echo "| Field       | Value |"
    echo "|-------------|-------|"
    echo "| Host        | $HOST_ |"
    echo "| Date        | $now |"
    echo "| OS          | $OS_PRETTY ($OS_FAMILY family) |"
    echo "| Kernel      | $(uname -r) |"
    echo "| Script      | v$SCRIPT_VERSION |"
    echo "| Output dir  | $OUTPUT_DIR |"
    echo ""
    echo "## Detected Stack"
    if [[ ${#DETECTED[@]} -eq 0 ]]; then
      echo "- (none matched by a dedicated plugin — see generic service/port listing)"
    else
      for app in "${!DETECTED[@]}"; do echo "- ${DETECTED[$app]}"; done
    fi
    echo ""
    echo "## Findings ($total total)"
    echo "- Critical: $crit"
    echo "- High: $high"
    echo "- Medium: $med"
    echo "- Low: $low"
    echo "- Info: $info"
    echo ""
    echo "## Output Files"
    find "$OUTPUT_DIR" -maxdepth 2 -type f | sed "s#^$OUTPUT_DIR/#- #"
  } | tee "$SUMMARY" | tee -a "$REPORT" >/dev/null

  echo ""
  echo -e "${G}${B}Collection complete.${X}"
  echo -e "  Full report   : $REPORT"
  echo -e "  Summary (md)  : $SUMMARY"
  echo -e "  Findings      : $total (crit=$crit high=$high med=$med low=$low info=$info)"
  echo -e "  Directory     : $OUTPUT_DIR"
  echo ""
}

main() {
  echo -e "${B}${G}"
  cat <<'EOF'
+==============================================================+
|     LINUX SERVER PERFORMANCE & APPLICATION ANALYSIS          |
|                  (read-only collection)                      |
+==============================================================+
EOF
  echo -e "${X}"
  echo "  Host    : $HOST_"
  echo "  Time    : $(date)"
  echo "  Output  : $OUTPUT_DIR"
  echo ""

  init_output
  detect_os_family
  check_privileges
  require_readonly_notice
  load_app_plugins

  mod_os_kernel
  mod_cpu
  mod_memory
  mod_storage
  mod_network
  mod_processes
  mod_kernel_limits

  detect_apps
  analyze_detected_apps

  generate_summary

  if [[ -x "$REPORT_GEN" ]]; then
    log "Generating executive HTML report..."
    "$REPORT_GEN" "$OUTPUT_DIR" "$HOST_" "$SCRIPT_VERSION" "$OS_PRETTY" "$OS_FAMILY"
    echo -e "  ${G}${B}HTML report  : $OUTPUT_DIR/report.html${X}"
  else
    warn "Report generator not found/executable at $REPORT_GEN"
  fi
}

main "$@"
