# =============================================================================
# Plugin: SAP HANA
#
# Best-effort, read-only. Process/mount checks work regardless of access;
# `HDB info` / system replication status additionally require running as (or
# `sudo -n -u <sid>adm` to) the instance's OS admin user — no DB password is
# ever requested, handled, or stored by this script.
# =============================================================================
register_plugin sap_hana "SAP HANA"

app_sap_hana_detect() {
  pgrep -f 'hdbnameserver' &>/dev/null || pgrep -f 'hdbindexserver' &>/dev/null
}

# Discover running instances as "SID:NR:PATH" from process command lines.
_hana_instances() {
  ps -eo cmd 2>/dev/null | grep -oE '/usr/sap/[A-Za-z0-9]+/HDB[0-9]+' | sort -u \
    | while read -r p; do
        local sid nr
        # Path is "/usr/sap/<SID>/HDB<NR>" — awk -F/ counts the empty field
        # before the leading slash, so SID is $4 and the instance is $5.
        sid=$(echo "$p" | awk -F/ '{print $4}')
        nr=$(echo "$p" | awk -F/ '{print $5}' | sed 's/HDB//')
        echo "${sid}:${nr}:${p}"
      done
}

app_sap_hana_analyze() {
  local instances; instances=$(_hana_instances)
  if [[ -z "$instances" ]]; then
    warn "hdbnameserver/hdbindexserver running but instance path could not be parsed from process list"
    return
  fi

  sub "HANA processes (all instances on host)"
  ps aux | grep -E '[h]dbnameserver|[h]dbindexserver|[h]dbcompileserver|[h]dbpreprocessor|[h]dbwebdispatcher|[h]dbxsengine' \
    | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  while IFS=: read -r sid nr path; do
    [[ -z "$sid" ]] && continue
    local sidlc sidadm
    sidlc=$(echo "$sid" | tr 'A-Z' 'a-z')
    sidadm="${sidlc}adm"

    sub "Instance ${sid} (HDB${nr})"
    log "Instance admin OS user (expected): $sidadm"

    local nameserver_up indexserver_up
    pgrep -f "${path}/exe/hdbnameserver" &>/dev/null && nameserver_up=1 || nameserver_up=0
    pgrep -f "${path}/exe/hdbindexserver" &>/dev/null && indexserver_up=1 || indexserver_up=0
    log "nameserver up=${nameserver_up}, indexserver up=${indexserver_up}"
    if [[ "$nameserver_up" == "0" || "$indexserver_up" == "0" ]]; then
      finding CRITICAL sap.hana_process "Core SAP HANA process not running" \
        "Instance ${sid}/HDB${nr}: nameserver_up=${nameserver_up} indexserver_up=${indexserver_up}"
    fi

    sub "HDB info (landscape/process status)"
    if [[ -x "${path}/HDB" ]] && is_cmd sudo; then
      local hdb_out
      hdb_out=$(sudo -n -u "$sidadm" "${path}/HDB" info 2>/dev/null)
      if [[ -n "$hdb_out" ]]; then
        # HDB info's exact column layout varies by revision, so it is captured
        # verbatim above for manual review rather than pattern-matched here.
        echo "$hdb_out" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
      else
        warn "Could not run 'HDB info' as $sidadm (needs passwordless sudo) — skipping landscape status"
      fi
    else
      warn "HDB script not found or sudo unavailable — skipping landscape status for ${sid}"
    fi

    sub "System replication status (if configured)"
    if [[ -x "${path}/exe/python_support/systemReplicationStatus.py" || -f "${path}/exe/python_support/systemReplicationStatus.py" ]] && is_cmd sudo; then
      runsh "systemReplicationStatus" \
        "sudo -n -u '$sidadm' bash -c 'cd \"$path\" && ./HDBSettings.sh systemReplicationStatus.py' 2>/dev/null | head -40 || echo 'not configured / not accessible'"
    else
      log "System replication tooling not found for ${sid} (standalone instance, or not accessible)"
    fi

    sub "Data / log volume mounts"
    local data_mnt log_mnt
    data_mnt=$(df -h "/hana/data/${sid}" 2>/dev/null | tail -1)
    log_mnt=$(df -h "/hana/log/${sid}" 2>/dev/null | tail -1)
    if [[ -n "$data_mnt" ]]; then
      echo "data: $data_mnt" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
    else
      finding MEDIUM sap.hana_disk "HANA data volume not found at expected path" "/hana/data/${sid} does not exist or is not mounted"
    fi
    if [[ -n "$log_mnt" ]]; then
      echo "log: $log_mnt" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
    else
      finding MEDIUM sap.hana_disk "HANA log volume not found at expected path" "/hana/log/${sid} does not exist or is not mounted"
    fi

    sub "Trace — recent errors (nameserver_alert*.trc, last ${LOG_TAIL_LINES} lines)"
    local trace_dir="${path}/${HOSTNAME:-$(hostname)}/trace"
    if [[ -d "$trace_dir" ]]; then
      find "$trace_dir" -maxdepth 1 -iname "nameserver_alert_*.trc" -newer /proc/1 2>/dev/null | sort | tail -1 | while read -r f; do
        [[ -n "$f" ]] && tail -n "$LOG_TAIL_LINES" "$f" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
      done
    else
      log "Trace directory not found/readable at $trace_dir"
    fi
  done <<< "$instances"
}
