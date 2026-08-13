# =============================================================================
# Plugin: NGINX (web server / reverse proxy)
# =============================================================================
register_plugin nginx "NGINX"

app_nginx_detect() {
  svc_active nginx || proc_up nginx || is_cmd nginx
}

app_nginx_analyze() {
  run "Version"           nginx -v
  run "Config test"       nginx -t
  runsh "Workers running" "pgrep -a nginx || true"

  sub "Key config directives"
  runsh "Config grep" \
    "nginx -T 2>/dev/null | grep -Ei '^\s*(worker_processes|worker_connections|keepalive_timeout|gzip|proxy_cache|upstream|server_tokens)' | grep -v '#' | head -40"

  sub "stub_status"
  if curl -sf --max-time 3 http://127.0.0.1/nginx_status &>/dev/null; then
    runsh "nginx_status" "curl -s http://127.0.0.1/nginx_status"
  elif curl -sf --max-time 3 http://127.0.0.1/status &>/dev/null; then
    runsh "status"       "curl -s http://127.0.0.1/status"
  else
    finding LOW nginx.stub_status "stub_status not reachable" "Live connection metrics endpoint not exposed on 127.0.0.1"
  fi

  sub "Connection states"
  if is_cmd ss; then
    runsh "Port 80 ESTAB"  "ss -tn '( dport = :80 or sport = :80 )' 2>/dev/null | grep -c ESTAB || echo 0"
    runsh "Port 443 ESTAB" "ss -tn '( dport = :443 or sport = :443 )' 2>/dev/null | grep -c ESTAB || echo 0"
    runsh "State counts"   "ss -tn 2>/dev/null | awk 'NR>1{print \$1}' | sort | uniq -c | sort -rn"
  fi

  sub "Error log — last ${LOG_TAIL_LINES} lines"
  local elog
  elog=$(capture "nginx -T 2>/dev/null | awk '/error_log/{print \$2}' | tr -d ';' | head -1")
  [[ -z "$elog" ]] && elog="/var/log/nginx/error.log"
  if [[ -f "$elog" ]]; then
    tail -n "$LOG_TAIL_LINES" "$elog" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
    local ecnt; ecnt=$(grep -cE "error|crit|emerg" "$elog" 2>/dev/null || echo 0)
    (( ecnt > 20 )) && finding MEDIUM nginx.errors "Elevated NGINX error log volume" "$ecnt error/crit/emerg lines in $elog"
  else
    warn "Error log not found at $elog"
  fi

  sub "Access log analysis (last 10 000 lines)"
  local alog="/var/log/nginx/access.log"
  if [[ -f "$alog" ]]; then
    runsh "Top 10 IPs"    "tail -n10000 $alog | awk '{print \$1}' | sort | uniq -c | sort -rn | head -10"
    runsh "Top 10 URIs"   "tail -n10000 $alog | awk '{print \$7}' | sort | uniq -c | sort -rn | head -10"
    runsh "HTTP statuses" "tail -n10000 $alog | awk '{print \$9}' | sort | uniq -c | sort -rn"
    runsh "5xx (last 30)" "tail -n10000 $alog | awk '\$9~/^5/' | tail -30"
  else
    warn "Access log not found at $alog"
  fi
}
