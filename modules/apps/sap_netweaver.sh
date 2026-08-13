# =============================================================================
# Plugin: SAP NetWeaver (ABAP / Java Application Server)
#
# Best-effort, read-only. Process/profile checks work regardless of access;
# `sapcontrol` status calls additionally require running as (or
# `sudo -n -u <sid>adm` to) the instance's OS admin user — this script never
# requests, handles or stores an SAP logon password.
# =============================================================================
register_plugin sap_netweaver "SAP NetWeaver"

app_sap_netweaver_detect() {
  pgrep -f 'disp\+work' &>/dev/null || pgrep -f 'jcontrol' &>/dev/null || \
    pgrep -f 'jstart' &>/dev/null || [[ -r /usr/sap/sapservices ]]
}

# Discover registered instances as "SID:INSTANCE:NR:PATH" from sapservices,
# falling back to parsing running process paths if the file is unreadable.
_nw_instances() {
  if [[ -r /usr/sap/sapservices ]]; then
    grep -oE '/usr/sap/[A-Za-z0-9]+/[A-Za-z]+[0-9]{2}' /usr/sap/sapservices 2>/dev/null | sort -u
  else
    ps -eo cmd 2>/dev/null | grep -oE '/usr/sap/[A-Za-z0-9]+/[A-Za-z]+[0-9]{2}' | sort -u
  fi | while read -r p; do
    local sid inst nr
    # Path is "/usr/sap/<SID>/<INSTANCE>" — awk -F/ counts the empty field
    # before the leading slash, so SID is $4 and the instance is $5.
    sid=$(echo "$p" | awk -F/ '{print $4}')
    inst=$(echo "$p" | awk -F/ '{print $5}')
    nr=$(echo "$inst" | grep -oE '[0-9]{2}$')
    echo "${sid}:${inst}:${nr}:${p}"
  done
}

app_sap_netweaver_analyze() {
  local instances; instances=$(_nw_instances)
  if [[ -z "$instances" ]]; then
    warn "SAP processes detected but no instance could be resolved from /usr/sap/sapservices or process paths"
    return
  fi

  sub "SAP processes (all instances on host)"
  ps aux | grep -E '[d]isp\+work|[j]control|[j]start|[m]sg_server|[i]gswd|[e]nserver|[e]nrepserver' \
    | tee -a "$REPORT" "$CURRENT_MODULE_FILE"

  if [[ ! -r /usr/sap/sapservices ]]; then
    finding LOW sap.netweaver_sapservices "/usr/sap/sapservices not readable" "Instance list derived from running processes only — sapstartsrv-managed lifecycle could not be cross-checked"
  fi

  while IFS=: read -r sid inst nr path; do
    [[ -z "$sid" ]] && continue
    local sidlc sidadm
    sidlc=$(echo "$sid" | tr 'A-Z' 'a-z')
    sidadm="${sidlc}adm"

    sub "Instance ${sid}/${inst}"
    log "Instance admin OS user (expected): $sidadm"

    local is_abap=0 is_java=0
    [[ -x "${path}/exe/disp+work" || -n "$(pgrep -f "${path}/exe/disp\+work")" ]] && is_abap=1
    [[ -n "$(pgrep -f "${path}/exe/jcontrol")" || -n "$(pgrep -f "${path}/j2ee/cluster/instance.properties")" ]] && is_java=1
    pgrep -f "${path}/work/jstart" &>/dev/null && is_java=1

    if (( is_abap )); then
      local wp_running
      wp_running=$(pgrep -fc "${path}/exe/disp\+work" 2>/dev/null || echo 0)
      log "ABAP work processes running (disp+work): ${wp_running}"
      (( wp_running == 0 )) && finding CRITICAL sap.netweaver_process "No ABAP work processes running" "Instance ${sid}/${inst}: 0 disp+work processes found"

      local profile
      profile=$(find "/usr/sap/${sid}/SYS/profile" -maxdepth 1 -iname "${sid}_${inst}_*" 2>/dev/null | head -1)
      if [[ -n "$profile" && -r "$profile" ]]; then
        sub "Work process configuration (profile)"
        grep -E '^rdisp/wp_no_(dia|btc|upd|upd2|spo|enq)' "$profile" | tee -a "$REPORT" "$CURRENT_MODULE_FILE"
        local configured
        configured=$(grep -E '^rdisp/wp_no_(dia|btc|upd|upd2|spo|enq)' "$profile" | awk -F= '{gsub(/ /,"",$2); s+=$2} END{print s+0}')
        if [[ "$configured" =~ ^[0-9]+$ ]] && (( configured > 0 && wp_running > 0 )); then
          local wp_pct=$(( wp_running * 100 / configured ))
          (( wp_pct < 80 )) && finding MEDIUM sap.netweaver_wp_saturation "Fewer work processes running than configured" \
            "${wp_running}/${configured} configured (${wp_pct}%) — some work processes may have crashed or not started"
        fi

        local icm_port
        icm_port=$(grep -oE 'icm/server_port_0[[:space:]]*=[[:space:]]*PROT=HTTP,PORT=[0-9]+' "$profile" | grep -oE '[0-9]+$')
        if [[ -n "$icm_port" ]]; then
          if curl -sf --max-time 3 "http://localhost:${icm_port}/sap/public/icman/ping" &>/dev/null; then
            log "ICM HTTP ping OK on port ${icm_port}"
          else
            finding MEDIUM sap.netweaver_icm "ICM HTTP admin endpoint not responding" "Instance ${sid}/${inst}, port ${icm_port}"
          fi
        fi
      else
        warn "Instance profile not found/readable under /usr/sap/${sid}/SYS/profile"
      fi
    fi

    if (( is_java )); then
      local jc_running
      jc_running=$(pgrep -fc "${path}/(work/)?j(control|start)" 2>/dev/null || echo 0)
      log "Java server processes running (jcontrol/jstart): ${jc_running}"
      (( jc_running == 0 )) && finding CRITICAL sap.netweaver_process "No Java server processes running" "Instance ${sid}/${inst}: 0 jcontrol/jstart processes found"
    fi

    sub "sapcontrol GetProcessList (best-effort)"
    if [[ -n "$nr" && -x "${path}/exe/sapcontrol" ]] && is_cmd sudo; then
      runsh "sapcontrol -nr $nr -function GetProcessList" \
        "sudo -n -u '$sidadm' '${path}/exe/sapcontrol' -nr '$nr' -function GetProcessList 2>/dev/null || echo 'not accessible (needs passwordless sudo to sidadm)'"
    else
      log "sapcontrol not available or sudo not usable for ${sid}/${inst} — skipped"
    fi
  done <<< "$instances"
}
