#!/bin/sh
# GERADO POR montar_payloads.sh - NAO EDITE AQUI.
# Fonte: lib.sh + corpo/04_storage.sh
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
# 04-STORAGE: LUNs, multipath, WWN, VG/FS, NFS, iSCSI, HBA
# Atende: 1g, 2b (disco), 5
# ============================================================

if [ "$PLAT" = aix ]; then
  # HBA / portas FC
  for a in $(run 20 lsdev -Cc adapter -F name 2>/dev/null | grep '^fcs'); do
    emit hba "$a" wwpn      "$(run 15 lscfg -vpl "$a" 2>/dev/null | awk -F. '/Network Address/{print $NF}')"
    emit hba "$a" descricao "$(run 15 lsdev -Cl "$a" 2>/dev/null | sed 's/^[^ ]*  *[^ ]*  *//')"
    emit hba "$a" firmware  "$(run 15 lscfg -vpl "$a" 2>/dev/null | awk -F. '/ROS Level/{print $NF}')"
    _fs=$(run 25 fcstat "$a" 2>/dev/null)
    _sp=$(printf '%s\n' "$_fs" | awk -F': ' '/Port Speed \(running\)/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
    emit hba "$a" velocidade    "$_sp"
    emit hba "$a" vel_suportada "$(printf '%s\n' "$_fs" | awk -F': ' '/Port Speed \(supported\)/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
    emit hba "$a" estado_porta  "$(printf '%s\n' "$_fs" | awk -F': ' '/Port State/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
    emit hba "$a" fabric_name   "$(printf '%s\n' "$_fs" | awk -F': ' '/Attention Type|Fabric Name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    # Link caido: velocidade 0 com adaptador configurado
    case "$_sp" in 0*|"0 GBIT"*) emit hba "$a" alerta "link_sem_velocidade" ;; esac
  done
  # Discos: tamanho, tipo, paths, LUN id
  _lspv=$(run 40 lspv 2>/dev/null)
  printf '%s\n' "$_lspv" | awk 'NF>=3{print $1"|"$3}' | while IFS='|' read d v; do
    emit disco "$d" vg "$v"
  done
  for d in $(printf '%s\n' "$_lspv" | awk '{print $1}'); do
    emit disco "$d" tamanho_mb "$(run 10 getconf DISK_SIZE "/dev/$d" 2>/dev/null)"
    emit disco "$d" tipo       "$(run 10 lsdev -Cl "$d" 2>/dev/null | sed 's/^[^ ]*  *[^ ]*  *//')"
    emit disco "$d" paths      "$(run 15 lspath -l "$d" 2>/dev/null | grep -c Enabled)"
    emit disco "$d" uniquetype "$(run 10 lsattr -El "$d" -a unique_id 2>/dev/null | awk '{print $2}')"
    emit disco "$d" ww_name    "$(run 10 lsattr -El "$d" -a ww_name 2>/dev/null | awk '{print $2}')"
    emit disco "$d" reserva    "$(run 10 lsattr -El "$d" -a reserve_policy 2>/dev/null | awk '{print $2}')"
    emit disco "$d" algoritmo  "$(run 10 lsattr -El "$d" -a algorithm 2>/dev/null | awk '{print $2}')"
  done
  emit storage multipath driver "$( { has lsmpio && echo AIX_MPIO; } ; run 10 lslpp -Lqc 'SDDPCM*' 2>/dev/null | awk -F: '{print $1}' )"
  # Volume groups e filesystems
  for v in $(run 20 lsvg 2>/dev/null); do
    _s=$(run 20 lsvg "$v" 2>/dev/null)
    emit vg "$v" total_mb  "$(printf '%s\n' "$_s" | awk '/TOTAL PPs/{for(i=1;i<=NF;i++) if($i ~ /\(/) {gsub(/\(/,"",$i); print $i; exit}}')"
    emit vg "$v" livre_mb  "$(printf '%s\n' "$_s" | awk '/FREE PPs/{for(i=1;i<=NF;i++) if($i ~ /\(/) {gsub(/\(/,"",$i); print $i; exit}}')"
    emit vg "$v" pvs       "$(printf '%s\n' "$_s" | awk '/ACTIVE PVs/{print $3; exit}')"
    emit vg "$v" estado    "$(printf '%s\n' "$_s" | awk '/VG STATE/{print $3; exit}')"
  done
  run 30 df -m 2>/dev/null | awk 'NR>1 && $1 !~ /^\/proc/ {print $7"|"$1"|"$2"|"$3"|"$4}' | \
    while IFS='|' read mp dev tot livre pct; do
      emit fs "$mp" dispositivo "$dev"; emit fs "$mp" total_mb "$tot"
      emit fs "$mp" livre_mb "$livre"; emit fs "$mp" usado_pct "$pct"
    done
  # NFS
  run 20 mount 2>/dev/null | awk '$3=="nfs" || $3=="nfs3" || $3=="nfs4" {print $2"|"$1"|"$3}' | \
    while IFS='|' read mp src tp; do emit nfs "$mp" origem "$src"; emit nfs "$mp" versao "$tp"; done
elif [ "$PLAT" = solaris ]; then
  emit storage escopo zona "$ZONA_TIPO"
  if [ "$ZONA_TIPO" != global ]; then
    emit storage escopo aviso "zona nao-global: HBA, multipath e zpool pertencem a global; coletar a global para inventario de SAN"
  fi
  # HBA / portas FC
  for a in $(run 25 fcinfo hba-port 2>/dev/null | $AWK -F': ' '/HBA Port WWN/{gsub(/ /,"",$2); print $2}'); do
    _hp=$(run 20 fcinfo hba-port "$a" 2>/dev/null)
    emit hba "$a" wwpn          "$a"
    emit hba "$a" wwnn          "$(printf '%s\n' "$_hp" | $AWK -F': ' '/Node WWN/{gsub(/ /,"",$2); print $2; exit}')"
    emit hba "$a" estado_porta  "$(printf '%s\n' "$_hp" | $AWK -F': ' '/State/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    emit hba "$a" velocidade    "$(printf '%s\n' "$_hp" | $AWK -F': ' '/Current Speed/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    emit hba "$a" vel_suportada "$(printf '%s\n' "$_hp" | $AWK -F': ' '/Supported Speeds/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    emit hba "$a" modelo        "$(printf '%s\n' "$_hp" | $AWK -F': ' '/Model/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    emit hba "$a" firmware      "$(printf '%s\n' "$_hp" | $AWK -F': ' '/Firmware Version/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    emit hba "$a" driver        "$(printf '%s\n' "$_hp" | $AWK -F': ' '/Driver Name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    emit hba "$a" alvos_remotos "$(run 25 fcinfo remote-port -p "$a" 2>/dev/null | grep -c 'Remote Port WWN')"
  done
  # Multipath (MPxIO / Traffic Manager)
  emit storage multipath driver "$( has mpathadm && echo "Solaris MPxIO (mpathadm)" )"
  for l in $(run 40 mpathadm list lu 2>/dev/null | $AWK '/^[ \t]*\/dev\/rdsk/{gsub(/^[ \t]+/,""); print}'); do
    _lu=$(run 15 mpathadm show lu "$l" 2>/dev/null)
    _d=$(basename "$l" | sed 's/s2$//')
    emit disco "$_d" paths_total  "$(printf '%s\n' "$_lu" | $AWK -F': ' '/Total Path Count/{gsub(/ /,"",$2); print $2; exit}')"
    emit disco "$_d" paths_ativos "$(printf '%s\n' "$_lu" | $AWK -F': ' '/Operational Path Count/{gsub(/ /,"",$2); print $2; exit}')"
    emit disco "$_d" vendor       "$(printf '%s\n' "$_lu" | $AWK -F': ' '/Vendor/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    emit disco "$_d" produto      "$(printf '%s\n' "$_lu" | $AWK -F': ' '/Product/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    emit disco "$_d" politica     "$(printf '%s\n' "$_lu" | $AWK -F': ' '/Load Balance/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  done
  # Discos fisicos: iostat -En nao mexe no rotulo do disco (format NUNCA e usado)
  run 40 iostat -En 2>/dev/null | $AWK '
    /Soft Errors/ {d=$1}
    /Vendor:/ {
      v=""; p=""; sz=""
      for (i=1;i<=NF;i++) {
        if ($i=="Vendor:")   v=$(i+1)
        if ($i=="Product:")  p=$(i+1)
        if ($i=="Size:")     sz=$(i+1)
      }
      if (d!="") { print d"|"v"|"p"|"sz; d="" }
    }' | while IFS='|' read d v p sz; do
      emit disco "$d" vendor "$v"; emit disco "$d" modelo "$p"; emit disco "$d" tamanho "$sz"
    done
  # ZFS: pools, saude, dispositivos e datasets
  run 40 zpool list -H -o name,size,alloc,free,cap,dedup,health,altroot 2>/dev/null | \
    $AWK 'NF>=7{print $1"|"$2"|"$3"|"$4"|"$5"|"$7}' | while IFS='|' read p t a f c h; do
      emit vg "$p" tipo zpool;     emit vg "$p" total "$t"
      emit vg "$p" alocado "$a";   emit vg "$p" livre "$f"
      emit vg "$p" uso_pct "$c";   emit vg "$p" estado "$h"
      emit vg "$p" dispositivos "$(run 25 zpool status "$p" 2>/dev/null | $AWK 'NR>1 && /c[0-9]|mirror|raidz|spare/{gsub(/^[ \t]+/,""); printf "%s;", $1}' | cut -c1-300)"
    done
  run 40 zfs list -H -o name,used,avail,mountpoint -t filesystem 2>/dev/null | \
    $AWK 'NF>=4 && $4!="none" && $4!="legacy"{print $4"|"$1"|"$2"|"$3}' | \
    while IFS='|' read mp ds u a; do
      emit fs "$mp" dispositivo "$ds"; emit fs "$mp" tipo zfs
      emit fs "$mp" usado "$u"; emit fs "$mp" livre "$a"
    done
  # SVM (legado, ainda presente em hosts antigos)
  has metastat && emit storage svm metadevices "$(run 30 metastat -p 2>/dev/null | $AWK '{printf "%s ", $1}' | cut -c1-300)"
  # Filesystems nao-ZFS (UFS, NFS montado)
  run 30 df -k 2>/dev/null | $AWK 'NR>1 && $1 !~ /^(swap|objfs|ctfs|proc|mnttab|fd|sharefs)$/ && NF>=6 {print $6"|"$1"|"$2"|"$4"|"$5}' | \
    while IFS='|' read mp dev tot livre pct; do
      emit fs "$mp" dispositivo "$dev"; emit fs "$mp" total_kb "$tot"
      emit fs "$mp" livre_kb "$livre"; emit fs "$mp" usado_pct "$pct"
    done
  # NFS montado
  run 20 mount -p 2>/dev/null | $AWK '$4=="nfs"{print $3"|"$1"|"$4}' | \
    while IFS='|' read mp src tp; do emit nfs "$mp" origem "$src"; emit nfs "$mp" versao "$tp"; done
  run 20 nfsstat -m 2>/dev/null | $AWK '/^\/.*from/{mp=$1; src=$NF} /vers=/{print mp"|"$0}' | \
    while IFS='|' read mp o; do emit nfs "$mp" opcoes "$(printf '%s' "$o" | cut -c1-160)"; done
  # iSCSI
  has iscsiadm && emit iscsi sessoes alvos "$(run 20 iscsiadm list target 2>/dev/null | $AWK -F': ' '/Target:/{printf "%s ", $2}')"
  has iscsiadm && emit iscsi iniciador iqn "$(run 15 iscsiadm list initiator-node 2>/dev/null | $AWK -F': ' '/Initiator node name/{print $2; exit}')"
else
  # HBA FC
  if [ -d /sys/class/fc_host ]; then
    for a in $(ls /sys/class/fc_host 2>/dev/null); do
      emit hba "$a" wwpn       "$(cat /sys/class/fc_host/$a/port_name 2>/dev/null)"
      emit hba "$a" estado     "$(cat /sys/class/fc_host/$a/port_state 2>/dev/null)"
      emit hba "$a" velocidade "$(cat /sys/class/fc_host/$a/speed 2>/dev/null)"
      emit hba "$a" modelo     "$(cat /sys/class/fc_host/$a/symbolic_name 2>/dev/null | cut -c1-80)"
    done
  fi
  # Multipath
  if has multipath; then
    emit storage multipath driver "device-mapper-multipath"
    run 40 multipath -ll 2>/dev/null | awk '
      /^[a-zA-Z0-9_]+ \(/ {name=$1; wwid=$2; gsub(/[()]/,"",wwid); vendor=""; 
        for(i=3;i<=NF;i++) vendor=vendor" "$i; print "MAP|"name"|"wwid"|"vendor}
      /[0-9]+:[0-9]+:[0-9]+:[0-9]+/ {print "PATH|"name}
    ' | awk -F'|' '$1=="MAP"{m=$2; w=$3; v=$4; c[m]=0; wm[m]=w; vm[m]=v}
                   $1=="PATH"{c[$2]++}
                   END{for(k in c) print k"|"wm[k]"|"vm[k]"|"c[k]}' | \
      while IFS='|' read m w v c; do
        emit disco "$m" wwid "$w"; emit disco "$m" vendor_modelo "$v"; emit disco "$m" paths "$c"
        emit disco "$m" tamanho_mb "$(run 10 lsblk -bdno SIZE "/dev/mapper/$m" 2>/dev/null | awk '{printf "%.0f", $1/1048576}')"
      done
  fi
  # Discos brutos
  run 30 lsblk -dno NAME,SIZE,TYPE,MODEL 2>/dev/null | awk '$3=="disk"{print $1"|"$2"|"$4}' | \
    while IFS='|' read n s m; do emit disco "$n" tamanho "$s"; emit disco "$n" modelo "$m"; done
  # LVM
  if has vgs; then
    run 20 vgs --noheadings --units m -o vg_name,vg_size,vg_free,pv_count 2>/dev/null | \
      while read v t f p; do
        emit vg "$v" total_mb "$t"; emit vg "$v" livre_mb "$f"; emit vg "$v" pvs "$p"
      done
  fi
  run 30 df -PmT 2>/dev/null | awk 'NR>1 && $2 !~ /tmpfs|devtmpfs|overlay/ {print $7"|"$1"|"$2"|"$3"|"$5"|"$6}' | \
    while IFS='|' read mp dev tp tot livre pct; do
      emit fs "$mp" dispositivo "$dev"; emit fs "$mp" tipo "$tp"
      emit fs "$mp" total_mb "$tot"; emit fs "$mp" livre_mb "$livre"; emit fs "$mp" usado_pct "$pct"
    done
  # NFS
  run 20 mount 2>/dev/null | awk '/type nfs/{print $3"|"$1"|"$5}' | \
    while IFS='|' read mp src tp; do emit nfs "$mp" origem "$src"; emit nfs "$mp" versao "$tp"; done
  # iSCSI
  has iscsiadm && emit iscsi sessoes alvos "$(run 20 iscsiadm -m session 2>/dev/null | awk '{print $3}' | tr '\n' ' ')"
  has iscsiadm && emit iscsi iniciador iqn "$(awk -F= '/InitiatorName/{print $2}' /etc/iscsi/initiatorname.iscsi 2>/dev/null)"
fi

# NFS exportado (o host serve NFS?)
[ -r /etc/exports ] && emit nfs servidor exports "$($GREP -Ev '^[ \t]*#|^[ \t]*$' /etc/exports 2>/dev/null | tr '\n' ';' | cut -c1-400)"
[ -r /etc/dfs/sharetab ] && emit nfs servidor sharetab "$($AWK 'NF{printf "%s(%s);", $1, $3}' /etc/dfs/sharetab 2>/dev/null | cut -c1-400)"
[ -r /etc/dfs/dfstab ] && emit nfs servidor dfstab "$($GREP -Ev '^[ \t]*#|^[ \t]*$' /etc/dfs/dfstab 2>/dev/null | tr '\n' ';' | cut -c1-400)"
exit 0
