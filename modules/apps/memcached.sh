# =============================================================================
# Plugin: Memcached
# =============================================================================
register_plugin memcached "Memcached"

app_memcached_detect() {
  svc_active memcached || proc_up memcached
}

app_memcached_analyze() {
  if is_cmd memcached-tool; then
    runsh "Stats" "memcached-tool 127.0.0.1:11211 stats 2>/dev/null || true"
  elif is_cmd nc; then
    runsh "Stats (via nc)" "printf 'stats\r\nquit\r\n' | nc -w2 127.0.0.1 11211 2>/dev/null || true"
  else
    warn "No memcached-tool/nc available to query stats"
    return
  fi

  local hits misses
  hits=$(capture "printf 'stats\r\nquit\r\n' | nc -w2 127.0.0.1 11211 2>/dev/null | awk '/get_hits/{print \$3}'")
  misses=$(capture "printf 'stats\r\nquit\r\n' | nc -w2 127.0.0.1 11211 2>/dev/null | awk '/get_misses/{print \$3}'")
  if [[ "$hits" =~ ^[0-9]+$ && "$misses" =~ ^[0-9]+$ ]] && (( hits + misses > 0 )); then
    local hr=$(( hits * 100 / (hits + misses) ))
    (( hr < 80 )) && finding LOW memcached.generic "Memcached hit rate low" "${hr}% (hits=${hits}, misses=${misses})"
  fi
}
