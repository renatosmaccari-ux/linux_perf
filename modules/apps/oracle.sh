# =============================================================================
# Plugin: Oracle Database
#
# Best-effort, read-only. Process/listener/alert-log checks work regardless
# of access; SQL*Plus checks additionally require sqlplus in ORACLE_HOME and
# either running as the Oracle OS user or `sudo -u "$ORACLE_OS_USER"` access
# (mirrors the PG_USER pattern used by the PostgreSQL plugin) — OS-authenticated
# "/ as sysdba", no password ever handled by this script.
# =============================================================================
register_plugin oracle "Oracle Database"

app_oracle_detect() {
  pgrep -f 'ora_pmon_' &>/dev/null
}

_ora_sids() {
  pgrep -fa 'ora_pmon_' 2>/dev/null | sed -E 's#.*ora_pmon_##' | awk '{print $1}' | sort -u
}

_ora_home_for_sid() {
  local sid="$1" home pid
  home=$(awk -F: -v s="$sid" '$1==s && $0 !~ /^#/ {print $2; exit}' /etc/oratab 2>/dev/null)
  if [[ -z "$home" ]]; then
    pid=$(pgrep -f "ora_pmon_${sid}" | head -1)
    [[ -n "$pid" ]] && home=$(readlink -f "/proc/$pid/cwd" 2>/dev/null | sed -E 's#/dbs$##')
  fi
  echo "$home"
}

# _ora_sql SID ORACLE_HOME "sql text" — OS-authenticated SYSDBA, read-only.
_ora_sql() {
  local sid="$1" home="$2" sql="$3"
  is_cmd sudo || return 1
  sudo -n -u "$ORACLE_OS_USER" bash -c "
    export ORACLE_SID='$sid' ORACLE_HOME='$home' PATH=\"$home/bin:\$PATH\" LD_LIBRARY_PATH=\"$home/lib\"
    sqlplus -s /nolog <<'SQLEOF'
set heading off feedback off pagesize 0 linesize 400 trimspool on verify off
connect / as sysdba
$sql
exit
SQLEOF
  " 2>/dev/null
}

app_oracle_analyze() {
  local sids; sids=$(_ora_sids)
  if [[ -z "$sids" ]]; then
    warn "No ora_pmon_<SID> process found"
    return
  fi

  sub "Instances detected"
  echo "$sids" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
  runsh "oratab" "grep -Ev '^#|^$' /etc/oratab 2>/dev/null || echo '/etc/oratab not readable'"

  sub "Listener (host-level)"
  if pgrep -f 'tnslsnr' &>/dev/null; then
    log "tnslsnr process running"
    is_cmd lsnrctl && runsh "lsnrctl status" "lsnrctl status 2>/dev/null | head -40"
  else
    finding HIGH oracle.listener "Oracle Listener not running" "No tnslsnr process found on host"
  fi

  local sid
  for sid in $sids; do
    sub "Instance: $sid"
    local home; home=$(_ora_home_for_sid "$sid")
    log "ORACLE_HOME (resolved): ${home:-unknown}"
    runsh "Background processes" "ps -eo pid,etime,cmd | grep -E \"ora_(pmon|smon|dbwr|lgwr|ckpt|arc[0-9]?)[0-9]?_${sid}\\$\" | grep -v grep"

    if [[ -n "$home" && -x "$home/bin/sqlplus" ]]; then
      sub "Instance status (v\$instance)"
      local inst
      inst=$(_ora_sql "$sid" "$home" "SELECT instance_name||' | '||status||' | '||version||' | '||database_status FROM v\$instance;")
      if [[ -n "$inst" && "$inst" != *ORA-* && "$inst" != *"ERROR"* && "$inst" != *"not found"* ]]; then
        echo "$inst" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

        sub "Buffer cache hit ratio"
        local hr
        hr=$(_ora_sql "$sid" "$home" "SELECT ROUND((1-(a.value/(b.value+c.value)))*100,2) FROM v\$sysstat a, v\$sysstat b, v\$sysstat c WHERE a.name='physical reads' AND b.name='db block gets' AND c.name='consistent gets';" | tr -d '[:space:]')
        [[ "$hr" =~ ^[0-9.]+$ ]] && {
          log "Buffer cache hit ratio: ${hr}%"
          awk "BEGIN{exit !($hr < 90)}" && finding MEDIUM oracle.buffer_cache "Buffer cache hit ratio low" "${hr}%"
        }

        sub "Tablespace usage (top 15 by % used)"
        _ora_sql "$sid" "$home" "
          SELECT d.tablespace_name||' | '||ROUND(d.mb,1)||'MB total | '||ROUND(NVL(f.mb,0),1)||'MB free | '||ROUND((1-NVL(f.mb,0)/d.mb)*100,1)||'% used'
          FROM (SELECT tablespace_name, SUM(bytes)/1024/1024 mb FROM dba_data_files GROUP BY tablespace_name) d
          LEFT JOIN (SELECT tablespace_name, SUM(bytes)/1024/1024 mb FROM dba_free_space GROUP BY tablespace_name) f
            ON d.tablespace_name=f.tablespace_name
          ORDER BY (1-NVL(f.mb,0)/d.mb) DESC FETCH FIRST 15 ROWS ONLY;" \
          | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
        local full_ts
        full_ts=$(_ora_sql "$sid" "$home" "
          SELECT COUNT(*) FROM (
            SELECT d.tablespace_name, (1-NVL(f.mb,0)/d.mb)*100 pct_used
            FROM (SELECT tablespace_name, SUM(bytes)/1024/1024 mb FROM dba_data_files GROUP BY tablespace_name) d
            LEFT JOIN (SELECT tablespace_name, SUM(bytes)/1024/1024 mb FROM dba_free_space GROUP BY tablespace_name) f
              ON d.tablespace_name=f.tablespace_name
          ) WHERE pct_used > 90;" | tr -d '[:space:]')
        [[ "$full_ts" =~ ^[0-9]+$ ]] && (( full_ts > 0 )) && \
          finding HIGH oracle.tablespace "Tablespace(s) above 90% used" "$full_ts tablespace(s) — see table above"

        sub "Session usage"
        local cur_sess max_sess
        cur_sess=$(_ora_sql "$sid" "$home" "SELECT COUNT(*) FROM v\$session;" | tr -d '[:space:]')
        max_sess=$(_ora_sql "$sid" "$home" "SELECT value FROM v\$parameter WHERE name='sessions';" | tr -d '[:space:]')
        log "Sessions: ${cur_sess:-?}/${max_sess:-?}"
        if [[ "$cur_sess" =~ ^[0-9]+$ && "$max_sess" =~ ^[0-9]+$ ]] && (( max_sess > 0 )); then
          local spct=$(( cur_sess * 100 / max_sess ))
          (( spct > 80 )) && finding MEDIUM oracle.sessions "Session usage high" "${cur_sess}/${max_sess} (${spct}%)"
        fi

        sub "Invalid objects"
        local invalid
        invalid=$(_ora_sql "$sid" "$home" "SELECT COUNT(*) FROM dba_objects WHERE status='INVALID';" | tr -d '[:space:]')
        log "Invalid objects: ${invalid:-0}"
        [[ "$invalid" =~ ^[0-9]+$ ]] && (( invalid > 0 )) && \
          finding LOW oracle.invalid_objects "Invalid objects present" "$invalid object(s) with STATUS=INVALID"

        sub "Top wait events"
        _ora_sql "$sid" "$home" "
          SELECT * FROM (
            SELECT event||' | '||total_waits||' waits | '||ROUND(time_waited_micro/1000000,1)||'s'
            FROM v\$system_event WHERE wait_class != 'Idle' ORDER BY time_waited_micro DESC
          ) FETCH FIRST 10 ROWS ONLY;" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

        sub "Redo log switches (last 24h)"
        local switches
        switches=$(_ora_sql "$sid" "$home" "SELECT COUNT(*) FROM v\$log_history WHERE first_time > SYSDATE-1;" | tr -d '[:space:]')
        log "Redo switches (24h): ${switches:-0}"
        [[ "$switches" =~ ^[0-9]+$ ]] && (( switches > 48 )) && \
          finding LOW oracle.redo_switches "Frequent redo log switching" "$switches switches in the last 24h (>1 every 30min)"
      else
        warn "SQL*Plus SYSDBA connect failed for $sid (as OS user '$ORACLE_OS_USER') — set ORACLE_OS_USER or grant passwordless sudo for deeper checks; showing OS-level data only"
      fi
    else
      warn "sqlplus not found under ORACLE_HOME for $sid — showing OS-level data only"
    fi

    sub "Alert log — last ${LOG_TAIL_LINES} lines"
    local obase alert_log
    if [[ -n "$home" && -x "$home/bin/orabase" ]]; then
      obase=$(sudo -n -u "$ORACLE_OS_USER" "$home/bin/orabase" 2>/dev/null)
    fi
    if [[ -n "$obase" ]]; then
      alert_log=$(find "$obase/diag/rdbms" -maxdepth 3 -iname "alert_${sid}.log" 2>/dev/null | head -1)
    fi
    if [[ -n "$alert_log" && -r "$alert_log" ]]; then
      tail -n "$LOG_TAIL_LINES" "$alert_log" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
      local oracnt; oracnt=$(grep -cE 'ORA-[0-9]+' "$alert_log" 2>/dev/null || echo 0)
      (( oracnt > 0 )) && finding MEDIUM oracle.alert_log "ORA- errors present in alert log" "$oracnt occurrence(s) in $(basename "$alert_log") (last $LOG_TAIL_LINES lines scanned)"
    else
      warn "Alert log for $sid not found/readable (needs ORACLE_OS_USER read access)"
    fi
  done
}
