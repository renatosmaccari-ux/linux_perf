# =============================================================================
# Plugin: MongoDB
# =============================================================================
register_plugin mongodb "MongoDB"

app_mongodb_detect() {
  svc_active mongodb || svc_active mongod || proc_up mongod
}

app_mongodb_analyze() {
  local mongo_bin=""
  is_cmd mongosh && mongo_bin=mongosh
  [[ -z "$mongo_bin" ]] && is_cmd mongo && mongo_bin=mongo

  if [[ -z "$mongo_bin" ]]; then
    warn "mongosh/mongo shell not found — skipping live metrics"
    return
  fi

  runsh "serverStatus (abridged)" "$mongo_bin --eval 'db.serverStatus()' --quiet 2>/dev/null | head -80"
  runsh "db.stats()"              "$mongo_bin --eval 'db.stats()' --quiet 2>/dev/null"
  runsh "Replication status"      "$mongo_bin --eval 'rs.status()' --quiet 2>/dev/null | head -40"

  local conns_current conns_available
  conns_current=$(capture "$mongo_bin --eval 'db.serverStatus().connections.current' --quiet 2>/dev/null")
  conns_available=$(capture "$mongo_bin --eval 'db.serverStatus().connections.available' --quiet 2>/dev/null")
  if [[ "$conns_current" =~ ^[0-9]+$ && "$conns_available" =~ ^[0-9]+$ ]] && (( conns_current + conns_available > 0 )); then
    local pct=$(( conns_current * 100 / (conns_current + conns_available) ))
    (( pct > 80 )) && finding MEDIUM mongodb.generic "MongoDB connection usage high" "current=${conns_current}, available=${conns_available} (${pct}%)"
  fi
}
