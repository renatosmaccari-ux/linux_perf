# =============================================================================
# Module 05 — Processes (read-only)
# =============================================================================
mod_processes() {
  CURRENT_MODULE_LABEL="Processes"
  module_begin "05-processes"
  section "6 · PROCESS ANALYSIS"

  sub "Top CPU"
  runsh "ps (cpu, top 16)" "ps aux --sort=-%cpu -ww | head -16"

  sub "Top Memory"
  runsh "ps (mem)" "ps aux --sort=-%mem -ww | head -16"

  sub "Process Tree"
  is_cmd pstree && runsh "pstree" "pstree -p | head -60"

  sub "Zombie Processes"
  local z
  z=$(ps aux | awk '$8=="Z"' | wc -l)
  if (( z > 0 )); then
    finding MEDIUM sys.zombie "Zombie processes present" "$z zombie process(es)"
    ps aux | awk 'NR==1 || $8=="Z"' | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  else
    log "No zombie processes found"
  fi

  sub "OOM-killer events (dmesg)"
  local oom_hits
  oom_hits=$(capture "dmesg 2>/dev/null | grep -icE 'oom|out of memory|killed process'")
  runsh "OOM kills" "dmesg 2>/dev/null | grep -iE 'oom|out of memory|killed process' | tail -30 || echo 'dmesg unavailable or no OOM events'"
  [[ "$oom_hits" =~ ^[0-9]+$ ]] && (( oom_hits > 0 )) && \
    finding HIGH sys.oom "OOM-killer activity detected" "$oom_hits matching dmesg lines"

  sub "Open file descriptors (top 10 processes)"
  runsh "lsof count" "lsof 2>/dev/null | awk '{print \$1}' | sort | uniq -c | sort -rn | head -10 || echo 'lsof unavailable'"
}
