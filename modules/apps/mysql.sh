# =============================================================================
# Plugin: MySQL / MariaDB
# =============================================================================
register_plugin mysql "MySQL/MariaDB"

_mysql_q() {
  if [[ -n "$MYSQL_PASS" ]]; then
    mysql -u"$MYSQL_USER" -p"$MYSQL_PASS" --batch -e "$1" 2>/dev/null
  else
    mysql -u"$MYSQL_USER" --batch -e "$1" 2>/dev/null
  fi
}

app_mysql_detect() {
  svc_active mysql || svc_active mysqld || svc_active mariadb || proc_up mysqld
}

app_mysql_analyze() {
  if ! _mysql_q "SELECT 1" &>/dev/null; then
    warn "Cannot connect to MySQL/MariaDB — set MYSQL_USER / MYSQL_PASS env vars (read-only account recommended)"
    return
  fi

  sub "Version"
  _mysql_q "SELECT VERSION();" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Global status (key vars)"
  _mysql_q "SHOW GLOBAL STATUS WHERE Variable_name IN (
    'Threads_connected','Threads_running','Max_used_connections',
    'Questions','Slow_queries','Aborted_clients','Aborted_connects',
    'Innodb_buffer_pool_reads','Innodb_buffer_pool_read_requests',
    'Innodb_row_lock_waits','Innodb_row_lock_time_avg',
    'Com_select','Com_insert','Com_update','Com_delete',
    'Created_tmp_disk_tables','Handler_read_rnd_next',
    'Table_locks_waited','Bytes_sent','Bytes_received'
  );" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Config (key variables)"
  _mysql_q "SHOW VARIABLES WHERE Variable_name IN (
    'max_connections','innodb_buffer_pool_size','innodb_log_file_size',
    'innodb_flush_log_at_trx_commit','sync_binlog','slow_query_log',
    'long_query_time','innodb_io_capacity','tmp_table_size',
    'max_heap_table_size','thread_cache_size','table_open_cache',
    'open_files_limit'
  );" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Buffer pool hit rate"
  local reads req hitrate
  reads=$(_mysql_q "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_reads';" | awk 'NR==2{print $2}')
  req=$(_mysql_q "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool_read_requests';" | awk 'NR==2{print $2}')
  if [[ "$reads" =~ ^[0-9]+$ && "$req" =~ ^[0-9]+$ ]] && (( req > 0 )); then
    hitrate=$(awk "BEGIN{printf \"%.2f\", 100 - ($reads/$req*100)}")
    log "InnoDB buffer pool hit rate: ${hitrate}%"
    awk "BEGIN{exit !($hitrate < 99)}" && \
      finding MEDIUM mysql.buffer_pool "InnoDB buffer pool hit rate low" "${hitrate}% (reads=${reads}, requests=${req})"
  fi

  sub "Active processlist"
  _mysql_q "SHOW FULL PROCESSLIST;" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Table sizes (top 20)"
  _mysql_q "SELECT table_schema AS db, table_name,
    ROUND(data_length/1024/1024,2) AS data_mb,
    ROUND(index_length/1024/1024,2) AS index_mb, table_rows
    FROM information_schema.tables
    WHERE table_schema NOT IN ('information_schema','performance_schema','mysql','sys')
    ORDER BY (data_length+index_length) DESC LIMIT 20;" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "InnoDB engine status (abridged)"
  _mysql_q "SHOW ENGINE INNODB STATUS\G" \
    | grep -A5 -E "TRANSACTIONS|BUFFER POOL AND MEMORY|SEMAPHORES|LATEST DETECTED DEADLOCK" \
    | head -80 | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  sub "Slow query log"
  local slog
  slog=$(_mysql_q "SHOW VARIABLES LIKE 'slow_query_log_file';" | awk 'NR==2{print $2}')
  local slog_on
  slog_on=$(_mysql_q "SHOW VARIABLES LIKE 'slow_query_log';" | awk 'NR==2{print $2}')
  if [[ "$slog_on" == "OFF" ]]; then
    finding LOW mysql.slowlog "Slow query log disabled" "slow_query_log=OFF"
  elif [[ -f "$slog" ]]; then
    tail -n 100 "$slog" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  fi

  sub "Connection saturation"
  local conns maxconns pct
  conns=$(_mysql_q "SHOW GLOBAL STATUS LIKE 'Threads_connected';" | awk 'NR==2{print $2}')
  maxconns=$(_mysql_q "SHOW VARIABLES LIKE 'max_connections';" | awk 'NR==2{print $2}')
  if [[ "$conns" =~ ^[0-9]+$ && "$maxconns" =~ ^[0-9]+$ ]] && (( maxconns > 0 )); then
    pct=$(( conns * 100 / maxconns ))
    (( pct > 80 )) && finding MEDIUM mysql.connections "MySQL connection usage high" "${conns}/${maxconns} (${pct}%)"
  fi
}
