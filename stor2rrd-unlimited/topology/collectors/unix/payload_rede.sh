#!/bin/sh
# GERADO POR montar_payloads.sh - NAO EDITE AQUI.
# Fonte: lib.sh + corpo/02_rede.sh
# Gerado em: 2026-10-08 18:50:10
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
# 02-REDE: interfaces, IPs, VLAN, rotas, DNS, classificacao de rede
# Atende: 1d (parte que existe no SO)
# ============================================================

if [ "$PLAT" = aix ]; then
  for i in $(run 20 ifconfig -l 2>/dev/null); do
    [ "$i" = "lo0" ] && continue
    _if=$(run 10 ifconfig "$i" 2>/dev/null)
    _ip=$(printf '%s\n' "$_if" | awk '/inet /{print $2; exit}')
    _mk=$(printf '%s\n' "$_if" | awk '/inet /{print $4; exit}')
    _st=$(printf '%s\n' "$_if" | awk 'NR==1{if(index($0,"UP"))print "up"; else print "down"}')
    emit rede "$i" ip       "$_ip"
    emit rede "$i" netmask  "$_mk"
    emit rede "$i" prefixo  "$( [ -n "$_mk" ] && printf '/%s' "$(hex2cidr "$_mk")" )"
    emit rede "$i" cidr     "$( [ -n "$_ip" ] && [ -n "$_mk" ] && printf '%s/%s' "$_ip" "$(hex2cidr "$_mk")" )"
    emit rede "$i" estado   "$_st"
    emit rede "$i" mtu      "$(printf '%s\n' "$_if" | sed -n '1s/.*mtu \([0-9]*\).*/\1/p')"
    case "$i" in
      en*|et*)
        _e=$(echo "$i" | sed 's/^en/ent/;s/^et/ent/')
        emit rede "$i" adaptador   "$_e"
        emit rede "$i" mac         "$(run 15 entstat -d "$_e" 2>/dev/null | awk -F': ' '/Hardware Address/{print $2; exit}')"
        _es=$(run 20 entstat -d "$_e" 2>/dev/null)
        emit rede "$i" velocidade  "$(printf '%s\n' "$_es" | awk -F': ' '/Media Speed Running/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
        emit rede "$i" port_vlan_id "$(printf '%s\n' "$_es" | awk -F': ' '/Port VLAN ID/{gsub(/[ \t]/,"",$2); print $2; exit}')"
        emit rede "$i" vlan_tags_ext "$(printf '%s\n' "$_es" | awk -F': ' '/VLAN Tag IDs|Switch ID/{gsub(/^[ \t]+/,"",$2); printf "%s ", $2}')"
        emit rede "$i" vlan_tag    "$(run 15 lsattr -El "$_e" -a vlan_tag_id 2>/dev/null | awk '{print $2}')"
        emit rede "$i" tipo_virt   "$(run 15 lsdev -Cl "$_e" 2>/dev/null | sed 's/.*  //')"
        ;;
    esac
  done
  emit rede rota gateway_default "$(run 15 netstat -rn 2>/dev/null | awk '$1=="default"{print $2; exit}')"
  # Somente rotas de REDE: descarta host, broadcast, loopback e rotas locais
  run 15 netstat -rn 2>/dev/null | \
    awk '$1!="default" && $1 ~ /^[0-9]/ && $3 ~ /^U/ && $3 !~ /H/ && $1 !~ /^127/ && $1 ~ /\// {print $1"|"$2}' | \
    while IFS='|' read d g; do emit rede rota_rede "$d" "$g"; done
elif [ "$PLAT" = solaris ]; then
  # Enderecos IP (ipadm e a fonte autoritativa no Solaris 11).
  # Em zona shared-IP o ipadm existe mas nao devolve nada: sonda antes de decidir.
  _IPADM=""
  has ipadm && _IPADM=$(run 20 ipadm show-addr -p -o ADDROBJ,TYPE,STATE,ADDR 2>/dev/null)
  if [ -n "$_IPADM" ]; then
    printf '%s\n' "$_IPADM" | \
      while IFS=: read ao tp st ad; do
        [ -n "$ao" ] || continue
        _i=$(printf '%s' "$ao" | sed 's|/.*||')
        case "$_i" in lo0) continue ;; esac
        emit rede "$_i" ip_cidr    "$ad"
        emit rede "$_i" addrobj    "$ao"
        emit rede "$_i" tipo_addr  "$tp"
        emit rede "$_i" estado     "$st"
      done
  else
    run 20 ifconfig -a 2>/dev/null | $AWK '/^[a-z]/{i=$1; sub(/:$/,"",i)} /inet /{if ($2 !~ /^127\./) print i"|"$2"|"$4}' | \
      while IFS='|' read i ip mk; do
        emit rede "$i" ip "$ip"; emit rede "$i" netmask "$mk"
        emit rede "$i" prefixo "/$(hex2cidr "$mk")"
        emit rede "$i" cidr "$ip/$(hex2cidr "$mk")"
      done
  fi
  # Camada de enlace: so a global enxerga os links fisicos
  if [ "$ZONA_TIPO" != global ]; then
    emit rede escopo aviso "zona nao-global: dladm/enlace fisico visivel apenas na global"
  fi
  # Camada de enlace: MAC, velocidade, estado, driver
  run 25 dladm show-phys -p -o LINK,MEDIA,STATE,SPEED,DUPLEX,DEVICE 2>/dev/null | \
    while IFS=: read lk md st sp dx dv; do
      [ -n "$lk" ] || continue
      emit rede "$lk" midia      "$md"
      emit rede "$lk" estado_link "$st"
      emit rede "$lk" velocidade "$sp"
      emit rede "$lk" duplex     "$dx"
      emit rede "$lk" adaptador  "$dv"
    done
  run 20 dladm show-phys -m -p -o LINK,ADDRESS 2>/dev/null | \
    while IFS=: read lk ad; do [ -n "$lk" ] && emit rede "$lk" mac "$ad"; done
  run 20 dladm show-vlan -p -o LINK,VID,OVER 2>/dev/null | \
    while IFS=: read lk vid ov; do
      [ -n "$lk" ] || continue
      emit rede "$lk" vlan_tag "$vid"; emit rede "$lk" vlan_sobre "$ov"
    done
  run 20 dladm show-aggr -p -o LINK,POLICY,LACPACTIVITY 2>/dev/null | \
    while IFS=: read lk po la; do
      [ -n "$lk" ] || continue
      emit rede "$lk" aggr_politica "$po"; emit rede "$lk" aggr_lacp "$la"
      emit rede "$lk" aggr_portas "$(run 15 dladm show-aggr -x -p -o PORT "$lk" 2>/dev/null | tr '\n' ' ')"
    done
  run 20 dladm show-link -p -o LINK,CLASS,MTU 2>/dev/null | \
    while IFS=: read lk cl mt; do
      [ -n "$lk" ] || continue
      emit rede "$lk" classe "$cl"; emit rede "$lk" mtu "$mt"
    done
  # IPMP (alta disponibilidade de rede, comum no parque Solaris)
  run 20 ipmpstat -g -P -o GROUP,STATE,INTERFACES 2>/dev/null | \
    while IFS=: read g st ifs; do [ -n "$g" ] && emit rede ipmp "$g" "$st ($ifs)"; done
  emit rede rota gateway_default "$(run 15 netstat -rn -f inet 2>/dev/null | $AWK '$1=="default"{print $2; exit}')"
  run 15 netstat -rn -f inet 2>/dev/null | \
    $AWK '$1!="default" && $1 ~ /^[0-9]/ && $1 !~ /^127/ && NF>=2 {print $1"|"$2}' | \
    while IFS='|' read d g; do emit rede rota_rede "$d" "$g"; done
else
  for i in $(run 15 ls /sys/class/net 2>/dev/null); do
    [ "$i" = "lo" ] && continue
    _ip=$(run 10 ip -o -4 addr show "$i" 2>/dev/null | awk '{print $4; exit}')
    emit rede "$i" ip_cidr    "$_ip"
    emit rede "$i" estado     "$(cat /sys/class/net/$i/operstate 2>/dev/null)"
    emit rede "$i" mac        "$(cat /sys/class/net/$i/address 2>/dev/null)"
    emit rede "$i" mtu        "$(cat /sys/class/net/$i/mtu 2>/dev/null)"
    emit rede "$i" velocidade "$(cat /sys/class/net/$i/speed 2>/dev/null)"
    [ -f "/proc/net/vlan/$i" ] && \
      emit rede "$i" vlan_tag "$(awk -F'  +' '/VID:/{print $2}' /proc/net/vlan/$i 2>/dev/null | awk '{print $1}')"
    [ -d "/sys/class/net/$i/bonding" ] && \
      emit rede "$i" bond_slaves "$(cat /sys/class/net/$i/bonding/slaves 2>/dev/null)"
    [ -d "/sys/class/net/$i/bonding" ] && \
      emit rede "$i" bond_modo   "$(awk '{print $1}' /sys/class/net/$i/bonding/mode 2>/dev/null)"
  done
  # Posicional falha: "default dev eth0" nao tem gateway em $3. Le por palavra-chave.
  emit rede rota gateway_default "$(run 10 ip route show default 2>/dev/null | \
    $AWK '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}')"
  emit rede rota iface_default "$(run 10 ip route show default 2>/dev/null | \
    $AWK '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')"
  run 10 ip route show 2>/dev/null | $AWK '$1!="default" && NF>2 {
      gw=""; dev=""
      for(i=1;i<=NF;i++){ if($i=="via") gw=$(i+1); if($i=="dev") dev=$(i+1) }
      print $1"|"(gw!="" ? gw : "direto:" dev)
    }' | while IFS='|' read d g; do emit rede rota_estatica "$d" "$g"; done
fi

# DNS / resolucao / dominio
emit rede dns servidores "$(awk '/^nameserver/{printf "%s ", $2}' /etc/resolv.conf 2>/dev/null)"
emit rede dns dominio    "$(awk '/^(domain|search)/{$1=""; print; exit}' /etc/resolv.conf 2>/dev/null | sed 's/^ //')"
emit rede ntp servidores "$($AWK '/^(server|pool|peer)/{printf "%s ", $2}' /etc/ntp.conf /etc/chrony.conf /etc/chrony/chrony.conf /etc/inet/ntp.conf 2>/dev/null)"

# Portas em escuta (evidencia de servicos expostos)
case "$PLAT" in
  solaris)
    run 30 netstat -an -f inet -P tcp 2>/dev/null | \
      $AWK '$NF=="LISTEN" && $1 ~ /\.[0-9]+$/ {p=$1; sub(/.*\./,"",p); print p}' | sort -un | \
      while read p; do emit rede portas listen_tcp "$p"; done
    ;;
  aix)
    run 30 netstat -an -f inet 2>/dev/null | $AWK '/LISTEN/{print $4}' | sed 's/.*\.//' | sort -un | \
      while read p; do emit rede portas listen_tcp "$p"; done
    ;;
  *)
    # Sem filtro de familia: mantem o comportamento original (inclui tcp6)
    if has ss; then
      run 30 ss -ltnH 2>/dev/null | $AWK '{print $4}' | sed 's/.*://' | sort -un | \
        while read p; do emit rede portas listen_tcp "$p"; done
    elif has netstat; then
      run 30 netstat -an 2>/dev/null | $AWK '/LISTEN/{print $4}' | sed 's/.*[.:]//' | sort -un | \
        while read p; do emit rede portas listen_tcp "$p"; done
    fi
    ;;
esac
exit 0
