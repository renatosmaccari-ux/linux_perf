#!/bin/sh
# GERADO POR montar_payloads.sh - NAO EDITE AQUI.
# Fonte: lib.sh + corpo/05_monitoracao.sh
# Gerado em: 2026-09-22 13:44:01
# ============================================================
# lib.sh v2 - preambulo comum dos payloads (POSIX sh)
# Executado como root via sudo -n. Emite CSV: categoria,item,chave,valor
# Diagnostico SEMPRE em stderr. Nunca assume bash/GNU/proc.
#
# v2: suporte a Solaris (SunOS 5.10/5.11) + selecao explicita de awk/grep.
#     O /usr/bin/awk do Solaris e o oawk: quebra com match(), funcoes e
#     -v em algumas formas. O /usr/bin/grep do Solaris 10 nao tem -E.
# ============================================================
XT="${1:-120}"

# PATH explicito: o sudo/ssh nao-interativo chega com PATH minimo em varias
# plataformas. Sem /usr/sbin e /sbin, comandos essenciais somem silenciosamente
# (ipadm, dladm, zpool, fcinfo, psrinfo, prtconf no Solaris; ip e ifconfig no
# RHEL 4/5/6) e o payload retorna vazio sem nenhum erro.
# /usr/xpg4/bin primeiro: no Solaris garante as versoes POSIX de awk/grep/id.
PATH="/usr/xpg4/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/sbin:/usr/local/bin:/opt/csw/sbin:/opt/csw/bin:$PATH"
export PATH

# Locale C: faixas ("A-Z") e ordenacao dependem da collation do locale. Fora de C,
# tr/sort/grep produzem resultados diferentes por host e a analise fica nao-reprodutivel.
LC_ALL=C; LANG=C; export LC_ALL LANG

OSNAME=$(uname -s 2>/dev/null)
case "$OSNAME" in
  AIX)   PLAT=aix ;;
  Linux) PLAT=linux ;;
  SunOS) PLAT=solaris ;;
  *)     PLAT=desconhecido ;;
esac

# --- awk POSIX: obrigatorio no Solaris, inofensivo nas demais plataformas ---
AWK=awk
for _c in /usr/xpg4/bin/awk /usr/bin/nawk nawk gawk awk; do
  if command -v "$_c" >/dev/null 2>&1; then AWK="$_c"; break; fi
done
# --- grep com ERE: o grep do AIX nao tem \| em BRE; o do Solaris 10 nao tem -E ---
GREP=grep
for _c in /usr/xpg4/bin/grep grep; do
  if command -v "$_c" >/dev/null 2>&1; then GREP="$_c"; break; fi
done

DISTRO=""
case "$PLAT" in
  linux)
    if [ -r /etc/os-release ]; then
      DISTRO=$($AWK -F= '/^ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release)
    elif [ -r /etc/redhat-release ]; then DISTRO=rhel
    elif [ -r /etc/SuSE-release ]; then   DISTRO=sles
    elif [ -r /etc/slackware-version ]; then DISTRO=slackware
    fi
    ;;
  solaris)
    DISTRO=$(head -1 /etc/release 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//')
    [ -n "$DISTRO" ] || DISTRO="SunOS $(uname -r 2>/dev/null)"
    ;;
esac

# Solaris: onde estamos na pilha de virtualizacao. Barato (zonename e /usr/bin) e
# necessario em TODOS os payloads: os dados de hardware de uma zona nao-global
# refletem a zona, nao o servidor fisico, e nao podem ser somados ao parque.
ZONA=""; ZONA_TIPO=""
case "$PLAT" in
  solaris)
    ZONA=$(zonename 2>/dev/null); [ -n "$ZONA" ] || ZONA=global
    if [ "$ZONA" = global ]; then ZONA_TIPO=global; else ZONA_TIPO=nao-global; fi
    ;;
esac

# Diretorio temporario GRAVAVEL. Hosts com /tmp somente leitura ou cheio faziam o
# payload falhar inteiro. Testa escrevendo de fato, nao so com -w.
TMPD=""
for _d in "${TMPDIR:-}" /tmp /var/tmp /dev/shm /usr/tmp "${HOME:-}" /root; do
  [ -n "$_d" ] && [ -d "$_d" ] || continue
  # Criar arquivo VAZIO funciona num filesystem cheio (so gasta inode). E preciso
  # gravar dados de verdade: 256 KB, e conferir o tamanho escrito.
  _t="$_d/.inv_teste.$$"
  if dd if=/dev/zero of="$_t" bs=1024 count=256 >/dev/null 2>&1 && \
     [ "$(wc -c < "$_t" 2>/dev/null | tr -d ' ')" = "262144" ]; then
    rm -f "$_t"; TMPD="$_d"; break
  fi
  rm -f "$_t" 2>/dev/null
done

# Watchdog: mata comando travado (NFS morto, HBA offline, DNS lento)
run() {
  if [ -z "$TMPD" ]; then           # sem disco gravavel: executa sem watchdog
    shift; "$@" 2>/dev/null; return $?
  fi
  _to="$1"; shift
  "$@" >"$TMPD/.run.$$" 2>/dev/null &
  _pid=$!
  ( sleep "$_to"; kill -9 "$_pid" 2>/dev/null ) >/dev/null 2>&1 &
  _wd=$!
  wait "$_pid" 2>/dev/null; _rc=$?
  kill -9 "$_wd" 2>/dev/null
  cat "$TMPD/.run.$$" 2>/dev/null
  rm -f "$TMPD/.run.$$"
  return $_rc
}

has() { command -v "$1" >/dev/null 2>&1; }

# grep com alternancia: sempre ERE, sempre pelo binario selecionado.
gre()  { $GREP -E "$@"; }
grec() { $GREP -Ec "$@"; }

# Conta processos casando ERE, excluindo o proprio grep.
# ATENCAO Solaris: ps -ef trunca a linha de comando em ~80 caracteres.
pcount() { run 15 ps -ef 2>/dev/null | $GREP -Ev 'grep -E|[ /]grep ' | $GREP -Ec "$1"; }

# Netmask hexadecimal (AIX) -> prefixo CIDR
hex2cidr() {
  printf '%s' "$1" | sed 's/^0x//' | $AWK '{
    n=0
    for (i=1; i<=length($0); i++) {
      c=tolower(substr($0,i,1)); v=index("0123456789abcdef",c)-1
      while (v>0) { if (v%2) n++; v=int(v/2) }
    }
    print n
  }'
}

# Epoch -> data ISO (portavel, sem date -d)
epoch2iso() {
  printf '%s' "$1" | $AWK '{
    e=$1; if (e !~ /^[0-9]+$/ || e==0) { print ""; exit }
    d=int(e/86400); y=1970
    while (1) { l=((y%4==0&&y%100!=0)||y%400==0); dy=l?366:365; if (d<dy) break; d-=dy; y++ }
    l=((y%4==0&&y%100!=0)||y%400==0)
    split("31 28 31 30 31 30 31 31 30 31 30 31", m, " "); if (l) m[2]=29
    mo=1; while (d>=m[mo]) { d-=m[mo]; mo++ }
    printf "%04d-%02d-%02d", y, mo, d+1
  }'
}

# Semanas -> dias (AIX e Solaris expressam idade de senha em semanas)
sem2dias() { printf '%s' "$1" | $AWK '$1 ~ /^-?[0-9]+$/ {print $1*7}'; }

# Escape CSV de um campo
_esc() {
  printf '%s' "$1" | tr -d '\r' | $AWK '{
    gsub(/"/,"\"\"");
    if ($0 ~ /[,"]/) printf "\"%s\"", $0; else printf "%s", $0
  }'
}

# Emite uma linha CSV: categoria,item,chave,valor
emit() {
  [ -n "${4:-}" ] || return 0
  printf '%s,' "$(_esc "$1")"
  printf '%s,' "$(_esc "$2")"
  printf '%s,' "$(_esc "$3")"
  printf '%s\n' "$(_esc "$4")"
}

# Cabecalho (o runner prefixa a coluna hostname)
echo "categoria,item,chave,valor"

emit meta host plataforma "$PLAT"
emit meta host distro "${DISTRO:-n/a}"
emit meta host coleta_utc "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)"
emit meta host hostname_so "$(uname -n 2>/dev/null)"
emit meta host awk "$AWK"
emit meta host path "$PATH"
[ "$PLAT" = solaris ] && emit meta host zona "$ZONA"
[ "$PLAT" = solaris ] && emit meta host zona_tipo "$ZONA_TIPO"
emit meta host tmpdir "${TMPD:-nenhum_gravavel}"
emit meta host uname "$(uname -a 2>/dev/null | cut -c1-160)"
# Plataforma nao suportada: os corpos assumem Linux no ramo "else" e gerariam
# dados errados. Sai aqui, com os metadados que identificam o sistema.
if [ "$PLAT" = desconhecido ]; then
  emit meta host erro "plataforma nao suportada: $OSNAME"
  exit 0
fi

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
