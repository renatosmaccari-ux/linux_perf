# =============================================================================
# Module 04 — Network (read-only)
# =============================================================================
mod_network() {
  CURRENT_MODULE_LABEL="Network"
  module_begin "04-network"
  section "5 · NETWORK"

  runsh "Interfaces" "ip -br addr show 2>/dev/null || ifconfig -a"
  runsh "Routing"    "ip route show 2>/dev/null || netstat -rn"
  runsh "/proc/net/dev" "column -t < /proc/net/dev"

  if is_cmd ss; then
    run "Socket summary" ss -s
    runsh "ESTABLISHED (top 20 by process)" "ss -tnp 2>/dev/null | head -20"
    local tw; tw=$(capture "ss -tn state time-wait 2>/dev/null | wc -l")
    runsh "TIME_WAIT count" "echo ${tw:-N/A}"
    if [[ "$tw" =~ ^[0-9]+$ ]] && (( tw > 20000 )); then
      finding MEDIUM sys.net_timewait "Very high TIME_WAIT count" "${tw} sockets in TIME_WAIT"
    fi
  elif is_cmd netstat; then
    runsh "Connections" "netstat -tnp 2>/dev/null | head -30"
  fi

  sub "Key sysctl network/vm tunables"
  runsh "sysctl (net/vm)" "sysctl -a 2>/dev/null | grep -E '^(net\.core|net\.ipv4\.tcp|net\.ipv4\.ip_local_port_range|vm\.swappiness|fs\.file-max)' | head -40"
}
