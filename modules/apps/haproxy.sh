# =============================================================================
# Plugin: HAProxy (load balancer)
# =============================================================================
register_plugin haproxy "HAProxy"

app_haproxy_detect() {
  svc_active haproxy || proc_up haproxy
}

app_haproxy_analyze() {
  is_cmd haproxy && run "Version" haproxy -v

  sub "Stats via admin socket"
  local sock
  sock=$(first_existing /var/run/haproxy/admin.sock /var/run/haproxy.sock /run/haproxy/admin.sock || true)
  if is_cmd socat && [[ -n "$sock" && -S "$sock" ]]; then
    runsh "info"  "echo 'show info' | socat '$sock' stdio"
    runsh "stats" "echo 'show stat' | socat '$sock' stdio"
  else
    finding LOW haproxy.socket "HAProxy admin socket not accessible" "No 'stats socket' found/reachable (checked common paths, requires socat)"
  fi
}
