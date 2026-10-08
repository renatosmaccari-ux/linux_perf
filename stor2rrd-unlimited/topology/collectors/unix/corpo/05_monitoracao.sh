# ============================================================
# 05-MONITORACAO E BACKUP: agentes, servidores, usuarios de integracao
# Atende: 3, 6 (o que existe no lado do cliente), 1f (SMTP local)
# ============================================================

# --- BMC PATROL / TrueSight ---
_pd=""
for d in /opt/bmc/Patrol3 /opt/bmc/patrol/Patrol3 /usr/local/bmc/Patrol3 /opt/bmc; do
  [ -d "$d" ] && _pd="$d" && break
done
if [ -n "$_pd" ]; then
  emit monitoracao patrol diretorio "$_pd"
  emit monitoracao patrol agente_ativo "$(pcount 'PatrolAgent')"
  emit monitoracao patrol versao "$(run 20 find "$_pd" -name 'PatrolAgent' -type f 2>/dev/null | head -1)"
  for f in "$_pd"/*/config/*.cfg "$_pd"/config/*.cfg; do
    [ -r "$f" ] || continue
    emit monitoracao patrol console "$(grep -Ei 'AgentSetup/consoleHostPort|AgentSetup/accessControlList|AgentSetup/integration' "$f" 2>/dev/null | tr '\n' ';' | cut -c1-300)"
  done
  emit monitoracao patrol porta "$(run 15 ps -ef 2>/dev/null | awk '/[P]atrolAgent/{for(i=1;i<=NF;i++) if($i=="-p") print $(i+1)}')"
  emit monitoracao patrol usuario_processo "$(run 15 ps -ef 2>/dev/null | awk '/[P]atrolAgent/{print $1; exit}')"
  emit monitoracao patrol kms "$(run 20 ls "$_pd"/*/lib/knowledge 2>/dev/null | tr '\n' ' ' | cut -c1-300)"
fi

# --- Outros agentes de monitoracao ---
for p in zabbix_agentd zabbix_agent2 xagt nrpe nagios collectd telegraf node_exporter \
         oneagent dynatrace kagent ITM ITMAgent cma nimbus nimsoft snmpd; do
  _n=$(run 10 ps -ef 2>/dev/null | grep -c "[${p%${p#?}}]${p#?}")
  [ "${_n:-0}" -gt 0 ] && emit monitoracao agente "$p" "processos=$_n"
done
for _sc in /etc/snmp/snmpd.conf /etc/snmpdv3.conf /etc/snmpd.conf \
           /etc/net-snmp/snmp/snmpd.conf /etc/sma/snmp/snmpd.conf; do
  [ -r "$_sc" ] || continue
  emit monitoracao snmp arquivo "$_sc"
  emit monitoracao snmp comunidades_qtd "$(grep -Ec '^(com2sec|rocommunity|rwcommunity|community)' "$_sc" 2>/dev/null)"
  emit monitoracao snmp trap_destino "$(awk '/^(trapsink|trap2sink|informsink|trap)/{print $2}' "$_sc" 2>/dev/null | sort -u | tr '\n' ' ')"
done

# --- BACKUP: IBM Spectrum Protect / TSM ---
for f in /usr/tivoli/tsm/client/ba/bin/dsm.sys /opt/tivoli/tsm/client/ba/bin/dsm.sys \
         /usr/tivoli/tsm/client/ba/bin64/dsm.sys /opt/tivoli/tsm/client/ba/bin64/dsm.sys; do
  [ -r "$f" ] || continue
  emit backup tsm arquivo_config "$f"
  # Diretivas do dsm.sys sao case-insensitive e podem vir indentadas
  emit backup tsm servidor   "$(awk 'tolower($1)=="tcpserveraddress"{print $2}' "$f" 2>/dev/null | sort -u | tr '\n' ' ')"
  emit backup tsm porta      "$(awk 'tolower($1)=="tcpport"{print $2}' "$f" 2>/dev/null | sort -u | tr '\n' ' ')"
  emit backup tsm nodename   "$(awk 'tolower($1)=="nodename"{print $2}' "$f" 2>/dev/null | sort -u | tr '\n' ' ')"
  emit backup tsm servername "$(awk 'tolower($1)=="servername"{print $2}' "$f" 2>/dev/null | tr '\n' ' ')"
  emit backup tsm passwordaccess "$(awk 'tolower($1)=="passwordaccess"{print $2}' "$f" 2>/dev/null | sort -u | tr '\n' ' ')"
  emit backup tsm schedmode  "$(awk 'tolower($1)=="schedmode"{print $2}' "$f" 2>/dev/null | sort -u | tr '\n' ' ')"
  emit backup tsm exclude_qtd "$(grep -Eci '^[ \t]*(exclude|include)' "$f" 2>/dev/null)"
done
emit backup tsm scheduler_ativo "$(pcount 'dsmcad|dsmc[ ]+sched')"
emit backup tsm processos "$(pcount 'dsmc|dsmcad|dsmswitch')"
has dsmc && emit backup tsm versao_cliente "$(run 30 dsmc -version 2>/dev/null | awk '/Version/{print $0; exit}' | cut -c1-80)"

# --- NetBackup ---
[ -d /usr/openv/netbackup ] && {
  emit backup netbackup diretorio /usr/openv/netbackup
  emit backup netbackup servidores "$(awk '/^SERVER/{print $3}' /usr/openv/netbackup/bp.conf 2>/dev/null | tr '\n' ' ')"
  emit backup netbackup client_name "$(awk '/^CLIENT_NAME/{print $3}' /usr/openv/netbackup/bp.conf 2>/dev/null)"
  emit backup netbackup versao "$(cat /usr/openv/netbackup/bin/version 2>/dev/null | head -1)"
  emit backup netbackup daemons "$(pcount 'bpcd|vnetd|nbdisco')"
}
# --- Commvault ---
[ -d /opt/commvault ] || [ -d /opt/simpana ] && {
  emit backup commvault diretorio "$( [ -d /opt/commvault ] && echo /opt/commvault || echo /opt/simpana )"
  emit backup commvault processos "$(pcount 'cvd|CvMountd|ClMgrS')"
}
# --- Data Domain / DDBoost ---
has ddboost && emit backup ddboost presente sim
run 20 mount 2>/dev/null | grep -Ei 'datadomain|/ddvar|ddboost' | head -3 | \
  while read l; do emit backup ddboost mount "$l"; done
# --- Rubrik / Veeam / Networker ---
[ -d /opt/nsr ] && emit backup networker diretorio /opt/nsr
[ -d /opt/nsr ] && emit backup networker servidor "$(cat /nsr/res/servers 2>/dev/null | tr '\n' ' ')"
[ "$(pcount 'rubrik')" -gt 0 ] 2>/dev/null && emit backup rubrik agente ativo
[ "$(pcount 'veeam')"  -gt 0 ] 2>/dev/null && emit backup veeam  agente ativo

# --- Imagem local: boot environment/ZFS (Solaris), mksysb (AIX) ---
if [ "$PLAT" = solaris ]; then
  emit backup boot_env lista "$(run 25 beadm list -H 2>/dev/null | $AWK -F';' '{printf "%s(%s);", $1, $3}' | cut -c1-300)"
  emit backup zfs snapshots_qtd "$(run 40 zfs list -H -t snapshot 2>/dev/null | wc -l | tr -d ' ')"
  emit backup zfs snapshots_recentes "$(run 40 zfs list -H -o name,creation -t snapshot -s creation 2>/dev/null | tail -3 | tr '\n' ';' | cut -c1-240)"
  emit backup ufsdump evidencia "$(run 20 ls -t /backup /var/backup 2>/dev/null | head -3 | tr '\n' ' ')"
  emit backup sap brtools "$( [ -x /usr/sap/*/SYS/exe/run/brbackup ] && echo presente )"
  emit backup dumpadm dispositivo "$(run 15 dumpadm 2>/dev/null | $AWK -F': ' '/Dump device/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
fi

if [ "$PLAT" = aix ]; then
  emit backup mksysb ultima_imagem "$(run 20 ls -t /mksysb /backup /images 2>/dev/null | head -3 | tr '\n' ' ')"
  emit backup sap brtools "$( [ -x /usr/sap/*/SYS/exe/run/brbackup ] && echo presente )"
  emit backup sysdumpdev dispositivo "$(run 15 sysdumpdev -l 2>/dev/null | awk '/primary/{print $2}')"
fi

# --- SMTP local (relay) ---
for f in /etc/mail/sendmail.cf /etc/postfix/main.cf /etc/ssmtp/ssmtp.conf /etc/mail.rc; do
  [ -r "$f" ] || continue
  emit smtp arquivo "$f" "$(grep -Ei '^DS|^relayhost|^mailhub|^smtp[ ]*=' "$f" 2>/dev/null | tr '\n' ';' | cut -c1-200)"
  emit smtp relay    "$f" "$(grep -E '^DS' "$f" 2>/dev/null | sed 's/^DS//' | head -1)"
done
emit smtp daemon ativo "$(pcount 'sendmail|postfix/master')"

# --- Cron: janelas de backup e jobs de monitoracao ---
# O crontab do Solaris/AIX nao aceita -u: a sintaxe e "crontab -l <usuario>"
for u in root; do
  if [ "$PLAT" = linux ]; then
    _cj=$(run 15 crontab -l -u "$u" 2>/dev/null)
  else
    _cj=$(run 15 crontab -l "$u" 2>/dev/null)
  fi
  emit cron "$u" jobs "$(printf '%s\n' "$_cj" | $GREP -Ev '^[ \t]*#|^[ \t]*$' | tr '\n' ';' | cut -c1-600)"
done
[ -d /var/spool/cron/crontabs ] && emit cron sistema crontabs "$(ls /var/spool/cron/crontabs 2>/dev/null | tr '\n' ' ')"
[ -d /etc/cron.d ] && emit cron sistema cron_d "$(ls /etc/cron.d 2>/dev/null | tr '\n' ' ')"

# --- Servicos ativos (evidencia geral de integracoes) ---
if [ "$PLAT" = aix ]; then
  emit servicos ativos lssrc "$(run 20 lssrc -a 2>/dev/null | $AWK '$NF=="active"{printf "%s ", $1}' | cut -c1-500)"
elif [ "$PLAT" = solaris ]; then
  emit servicos ativos smf "$(run 25 svcs -H -o STATE,FMRI 2>/dev/null | $AWK '$1=="online"{printf "%s ", $2}' | cut -c1-800)"
  emit servicos falhos  smf "$(run 25 svcs -xH 2>/dev/null | $AWK '/svc:/{printf "%s ", $1}' | cut -c1-400)"
  emit servicos manutencao smf "$(run 25 svcs -H -o STATE,FMRI 2>/dev/null | $AWK '$1=="maintenance"{printf "%s ", $2}' | cut -c1-400)"
else
  has systemctl && emit servicos ativos systemd "$(run 20 systemctl list-units --type=service --state=running --no-legend --no-pager 2>/dev/null | awk '{printf "%s ", $1}' | cut -c1-800)"
fi
exit 0
