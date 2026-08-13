# =============================================================================
# Plugin: Node.js
# =============================================================================
register_plugin nodejs "Node.js"

app_nodejs_detect() {
  proc_up node || proc_up nodejs
}

app_nodejs_analyze() {
  is_cmd node && run "Version" node --version
  is_cmd npm  && run "npm version" npm --version

  sub "Processes"
  ps aux | grep -E "[n]ode|[n]odejs" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "RSS per process"
  while IFS= read -r pid; do
    [[ -f "/proc/$pid/status" ]] || continue
    local rss cmd
    rss=$(awk '/VmRSS/{print $2,$3}' "/proc/$pid/status")
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-90)
    echo "PID $pid  RSS: $rss  |  $cmd" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  done < <(pgrep -x node 2>/dev/null || pgrep -x nodejs 2>/dev/null || true)

  sub "PM2"
  if is_cmd pm2; then
    run "pm2 list" pm2 list
  else
    log "PM2 not installed"
  fi

  sub "Listening ports"
  is_cmd ss && runsh "ss node" "ss -tlnp 2>/dev/null | grep node || true"
}
