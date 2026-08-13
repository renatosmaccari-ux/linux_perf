# =============================================================================
# Module 06 — Kernel / System Limits (read-only)
# =============================================================================
mod_kernel_limits() {
  CURRENT_MODULE_LABEL="Kernel Limits"
  module_begin "06-kernel-limits"
  section "7 · SYSTEM LIMITS"

  runsh "file-nr (open/free/max)" "cat /proc/sys/fs/file-nr"
  runsh "ulimit -n (current shell)" "ulimit -n"
  runsh "ulimit -u (max user processes)" "ulimit -u"

  local used max pct
  read -r used _ max < /proc/sys/fs/file-nr
  if [[ "$used" =~ ^[0-9]+$ && "$max" =~ ^[0-9]+$ ]] && (( max > 0 )); then
    pct=$(( used * 100 / max ))
    (( pct > 80 )) && finding MEDIUM sys.fd_limit "System-wide file descriptor usage high" "${used}/${max} (${pct}%)"
    log "System-wide FD usage: ${used}/${max} (${pct}%)"
  fi

  sub "Per-service resource limits (systemd, sample)"
  if is_cmd systemctl; then
    runsh "Units with LimitNOFILE overrides" \
      "systemctl show '*.service' -p LimitNOFILE 2>/dev/null | grep -v 'LimitNOFILE=18446744073709551615' | head -20 || true"
  fi

  sub "PID limits"
  runsh "kernel.pid_max" "sysctl kernel.pid_max"
  runsh "kernel.threads-max" "sysctl kernel.threads-max"
}
