# =============================================================================
# Plugin: Apache HTTP Server (httpd / apache2)
# =============================================================================
register_plugin apache "Apache HTTP Server"

app_apache_detect() {
  svc_active apache2 || svc_active httpd || proc_up httpd || proc_up apache2
}

app_apache_analyze() {
  local bin; is_cmd apache2 && bin=apache2 || bin=httpd
  run "Version"    "$bin" -v
  run "Config test" "$bin" -t
  runsh "MPM"      "$bin -V 2>/dev/null | grep -E 'MPM|Server version'"
  runsh "Modules"  "$bin -M 2>/dev/null | head -30"

  sub "server-status"
  if curl -sf --max-time 3 "http://127.0.0.1/server-status?auto" &>/dev/null; then
    runsh "server-status" "curl -s 'http://127.0.0.1/server-status?auto'"
  else
    finding LOW apache.status "server-status not reachable" "mod_status endpoint not exposed on 127.0.0.1"
  fi

  sub "Error log — last ${LOG_TAIL_LINES} lines"
  local elog="/var/log/apache2/error.log"
  [[ ! -f "$elog" ]] && elog="/var/log/httpd/error_log"
  if [[ -f "$elog" ]]; then
    tail -n "$LOG_TAIL_LINES" "$elog" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  else
    warn "Apache error log not found"
  fi
}
