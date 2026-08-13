# =============================================================================
# Module 01 — CPU (read-only)
# =============================================================================
mod_cpu() {
  CURRENT_MODULE_LABEL="CPU"
  module_begin "01-cpu"
  section "2 · CPU"

  runsh "Model"            "grep -m1 'model name' /proc/cpuinfo | cut -d: -f2 | xargs || echo unknown"
  run "Physical cores"     nproc --all
  run "Logical cores"      nproc
  runsh "NUMA nodes"       "ls -d /sys/devices/system/node/node* 2>/dev/null | wc -l || echo 1"
  run "Load (proc)"        cat /proc/loadavg

  if is_cmd mpstat; then
    run "CPU usage (1s sample)" mpstat -P ALL 1 1
  else
    runsh "CPU usage (top snapshot)" "top -bn1 | head -8"
  fi

  runsh "Top runnable-queue / context switches (vmstat)" "vmstat 1 3 2>/dev/null || true"

  local load1 ncores load_pct
  load1=$(awk '{print $1}' /proc/loadavg)
  ncores=$(nproc)
  load_pct=$(awk "BEGIN{printf \"%.0f\", ($load1/$ncores)*100}")
  if (( load_pct > 90 )); then
    finding HIGH sys.cpu_load "CPU load critical" "1-min load ${load1} on ${ncores} cores (${load_pct}%)"
  elif (( load_pct > 80 )); then
    finding MEDIUM sys.cpu_load "CPU load high" "1-min load ${load1} on ${ncores} cores (${load_pct}%)"
  else
    log "CPU load normal: ${load_pct}% (load=${load1}, cores=${ncores})"
  fi
}
