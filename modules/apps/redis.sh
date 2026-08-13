# =============================================================================
# Plugin: Redis
# =============================================================================
register_plugin redis "Redis"

app_redis_detect() {
  svc_active redis || svc_active redis-server || proc_up redis-server
}

app_redis_analyze() {
  if ! is_cmd redis-cli; then
    warn "redis-cli not found — skipping live metrics"
    return
  fi

  run "INFO server"      redis-cli INFO server
  run "INFO clients"     redis-cli INFO clients
  run "INFO memory"      redis-cli INFO memory
  run "INFO stats"       redis-cli INFO stats
  run "INFO keyspace"    redis-cli INFO keyspace
  run "INFO replication" redis-cli INFO replication
  run "INFO persistence" redis-cli INFO persistence

  sub "Hit rate"
  local hits misses
  hits=$(capture "redis-cli INFO stats 2>/dev/null | awk -F: '/^keyspace_hits/{gsub(/\r/,\"\",\$2); print \$2}'")
  misses=$(capture "redis-cli INFO stats 2>/dev/null | awk -F: '/^keyspace_misses/{gsub(/\r/,\"\",\$2); print \$2}'")
  if [[ "$hits" =~ ^[0-9]+$ && "$misses" =~ ^[0-9]+$ ]]; then
    local total=$(( hits + misses ))
    if (( total > 0 )); then
      local hr=$(( hits * 100 / total ))
      log "Hit rate: ${hr}%"
      (( hr < 80 )) && finding MEDIUM redis.hitrate "Redis hit rate low" "${hr}% (hits=${hits}, misses=${misses})"
    fi
  fi

  local maxmem
  maxmem=$(capture "redis-cli CONFIG GET maxmemory 2>/dev/null | tail -1")
  [[ "$maxmem" == "0" ]] && finding LOW redis.maxmemory "No maxmemory limit configured" "maxmemory=0 (unbounded)"

  sub "Slow log (last 25)"
  runsh "slowlog" "redis-cli SLOWLOG GET 25"

  sub "Big keys (sample scan)"
  redis-cli --bigkeys 2>/dev/null | tail -30 | tee -a "$REPORT" "$CURRENT_MODULE_FILE" || \
    warn "bigkeys scan failed — may require keyspace notifications / large dataset timeout"

  sub "Connected clients"
  runsh "CLIENT LIST count" "redis-cli CLIENT LIST 2>/dev/null | wc -l"
}
