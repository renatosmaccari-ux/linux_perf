# =============================================================================
# Module 02 — Memory & Swap (read-only)
# =============================================================================
mod_memory() {
  CURRENT_MODULE_LABEL="Memory"
  module_begin "02-memory"
  section "3 · MEMORY"

  run "free -h" free -h
  runsh "Key meminfo" "grep -E '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SwapTotal|SwapFree|Dirty|Writeback|HugePages_Total|AnonHugePages)' /proc/meminfo"

  local mem_total mem_avail mem_pct
  mem_total=$(awk '/^MemTotal/{print $2}' /proc/meminfo)
  mem_avail=$(awk '/^MemAvailable/{print $2}' /proc/meminfo)
  mem_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
  if (( mem_pct > 90 )); then
    finding HIGH sys.memory_high "Memory usage critical" "${mem_pct}% used (MemAvailable-based)"
  elif (( mem_pct > 85 )); then
    finding MEDIUM sys.memory_high "Memory usage high" "${mem_pct}% used (MemAvailable-based)"
  else
    log "Memory usage normal: ${mem_pct}% used"
  fi

  sub "Swap"
  runsh "Swap usage"  "swapon --show 2>/dev/null || cat /proc/swaps"
  runsh "Swappiness"  "sysctl vm.swappiness"

  local swap_total swap_free swap_used_pct
  swap_total=$(awk '/^SwapTotal/{print $2}' /proc/meminfo)
  swap_free=$(awk '/^SwapFree/{print $2}' /proc/meminfo)
  if [[ "$swap_total" =~ ^[0-9]+$ ]] && (( swap_total > 0 )); then
    swap_used_pct=$(( (swap_total - swap_free) * 100 / swap_total ))
    (( swap_used_pct > 20 )) && \
      finding MEDIUM sys.swap_high "Swap in active use" "${swap_used_pct}% of swap used"
  fi

  sub "Transparent Huge Pages"
  local thp
  thp=$(capture "cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null" | grep -oP '(?<=\[)[^\]]+')
  if [[ -n "$thp" ]]; then
    log "THP status: $thp"
    [[ "$thp" == "always" ]] && \
      finding LOW sys.thp "THP set to 'always'" "Database workloads on this host may benefit from 'madvise' or disabling THP"
  fi

  sub "Top memory-mapped/cgroup snapshot"
  runsh "cgroup memory (v2, if present)" "find /sys/fs/cgroup -maxdepth 2 -name memory.current 2>/dev/null | head -5 | while read -r f; do echo \"\$f: \$(cat \$f)\"; done"
}
