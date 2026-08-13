# =============================================================================
# Plugin: PostgreSQL
# =============================================================================
register_plugin postgresql "PostgreSQL"

_pg_q()        { sudo -u "$PG_USER" psql -tAc "$1" 2>/dev/null; }
_pg_q_pretty() { sudo -u "$PG_USER" psql -c "$1" 2>/dev/null; }

app_postgresql_detect() {
  svc_active postgresql || proc_up postgres
}

app_postgresql_analyze() {
  if ! _pg_q "SELECT 1" &>/dev/null; then
    warn "Cannot connect as OS user '$PG_USER' — set PG_USER env var to a role with psql access"
    return
  fi

  sub "Version"
  _pg_q_pretty "SELECT version();" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Connection states"
  _pg_q_pretty "SELECT count(*), state, wait_event_type, wait_event
    FROM pg_stat_activity GROUP BY state, wait_event_type, wait_event
    ORDER BY count DESC;" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Long-running queries (>5s)"
  _pg_q_pretty "SELECT pid, now() - query_start AS duration, left(query,120) AS query, state
    FROM pg_stat_activity
    WHERE (now() - query_start) > interval '5 seconds' AND state != 'idle'
    ORDER BY duration DESC;" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Database sizes"
  _pg_q_pretty "SELECT datname, pg_size_pretty(pg_database_size(datname))
    FROM pg_database ORDER BY pg_database_size(datname) DESC;" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Table sizes (top 20)"
  _pg_q_pretty "SELECT schemaname, tablename,
    pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS total,
    pg_size_pretty(pg_relation_size(schemaname||'.'||tablename)) AS table_only
    FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema')
    ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 20;" \
    | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Cache hit ratio"
  local hit_pct
  hit_pct=$(_pg_q "SELECT ROUND(sum(heap_blks_hit)*100.0/NULLIF(sum(heap_blks_hit)+sum(heap_blks_read),0),2) FROM pg_statio_user_tables;")
  _pg_q_pretty "SELECT sum(heap_blks_read) AS heap_read, sum(heap_blks_hit) AS heap_hit,
    ROUND(sum(heap_blks_hit)*100.0/NULLIF(sum(heap_blks_hit)+sum(heap_blks_read),0),2) AS hit_pct
    FROM pg_statio_user_tables;" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  if [[ "$hit_pct" =~ ^[0-9.]+$ ]]; then
    awk "BEGIN{exit !($hit_pct < 99)}" && \
      finding MEDIUM postgresql.cache_hit "Shared buffer cache hit ratio low" "${hit_pct}%"
  fi

  sub "Index vs sequential scan ratio (top 20 by seq_scan)"
  _pg_q_pretty "SELECT relname, idx_scan, seq_scan,
    ROUND(idx_scan*100.0/NULLIF(idx_scan+seq_scan,0),2) AS idx_pct
    FROM pg_stat_user_tables ORDER BY seq_scan DESC LIMIT 20;" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  local high_seq
  high_seq=$(_pg_q "SELECT count(*) FROM pg_stat_user_tables WHERE seq_scan > 1000 AND (idx_scan IS NULL OR idx_scan < seq_scan);")
  [[ "$high_seq" =~ ^[0-9]+$ ]] && (( high_seq > 0 )) && \
    finding LOW postgresql.idx_scan "Tables dominated by sequential scans" "$high_seq table(s) with seq_scan > idx_scan and seq_scan > 1000"

  sub "Unused indexes (idx_scan = 0)"
  _pg_q_pretty "SELECT schemaname, relname, indexrelname, idx_scan
    FROM pg_stat_user_indexes WHERE idx_scan = 0
    ORDER BY schemaname, relname;" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Lock waits"
  local blocked
  blocked=$(_pg_q_pretty "SELECT blocked.pid AS blocked_pid, blocked.query AS blocked_query,
    blocker.pid AS blocker_pid, blocker.query AS blocker_query
    FROM pg_stat_activity blocked
    JOIN pg_stat_activity blocker ON blocker.pid = ANY(pg_blocking_pids(blocked.pid))
    WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;")
  echo "$blocked" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  [[ -n "$(echo "$blocked" | tr -d '[:space:]')" ]] && \
    finding HIGH postgresql.locks "Blocking lock chain detected" "See lock waits table for blocked/blocker PIDs"

  sub "Autovacuum activity (top 15 by dead tuples)"
  _pg_q_pretty "SELECT relname, n_dead_tup, n_live_tup, last_autovacuum, last_autoanalyze
    FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 15;" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  local bloated
  bloated=$(_pg_q "SELECT count(*) FROM pg_stat_user_tables WHERE n_dead_tup > GREATEST(n_live_tup,1);")
  [[ "$bloated" =~ ^[0-9]+$ ]] && (( bloated > 0 )) && \
    finding MEDIUM postgresql.autovacuum "Tables with more dead than live tuples" "$bloated table(s) — autovacuum may be lagging"
}
