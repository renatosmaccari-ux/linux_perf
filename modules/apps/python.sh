# =============================================================================
# Plugin: Python WSGI/ASGI (gunicorn, uvicorn, uwsgi, celery)
# =============================================================================
register_plugin python "Python (WSGI/ASGI)"

app_python_detect() {
  pgrep -fa "gunicorn|uvicorn|uwsgi|celery" &>/dev/null
}

app_python_analyze() {
  is_cmd python3 && run "Python version" python3 --version

  sub "Processes"
  ps aux | grep -E "[g]unicorn|[u]vicorn|[u]wsgi|[c]elery" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "RSS per process"
  while IFS= read -r pid; do
    [[ -f "/proc/$pid/status" ]] || continue
    local rss cmd
    rss=$(awk '/VmRSS/{print $2,$3}' "/proc/$pid/status")
    cmd=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-90)
    echo "PID $pid  RSS: $rss  |  $cmd" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  done < <(pgrep -f "gunicorn|uvicorn|uwsgi|celery" 2>/dev/null || true)

  sub "Gunicorn workers"
  pgrep -f gunicorn &>/dev/null && runsh "gunicorn pids" "pgrep -fa gunicorn"

  sub "Listening ports"
  is_cmd ss && runsh "ss python" "ss -tlnp 2>/dev/null | grep -E 'python|gunicorn|uvicorn' || true"

  local workers
  workers=$(pgrep -fc "gunicorn: worker" 2>/dev/null || echo 0)
  local ncores; ncores=$(nproc)
  [[ "$workers" =~ ^[0-9]+$ ]] && (( workers == 1 && ncores > 2 )) && \
    finding LOW python.generic "Single Gunicorn worker on a multi-core host" "1 worker on ${ncores} cores — CPU-bound requests will not use additional cores"
}
