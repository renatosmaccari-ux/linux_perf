#!/bin/sh
# GERADO POR montar_payloads.sh - NAO EDITE AQUI.
# Fonte: lib.sh + corpo/01_sistema.sh
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
# 01-SISTEMA: SO, capacidade, frame, aplicacao, ambiente
# Atende: 2a, 2b, 2c e complementa 1a/1b
# ============================================================

if [ "$PLAT" = aix ]; then
  emit so versao oslevel_s        "$(run 20 oslevel -s)"
  emit so versao oslevel_r        "$(run 20 oslevel -r)"
  emit so versao uname_vr         "$(uname -v).$(uname -r)"
  emit so versao bos_mp64         "$(run 20 lslpp -Lqc bos.mp64 2>/dev/null | awk -F: 'NR==1{print $3}')"
  emit so kernel bits             "$(run 10 bootinfo -K)"
  emit so kernel modo             "$(run 10 bootinfo -y)"

  emit frame modelo tipo_modelo   "$(run 10 uname -M)"
  _sn=$(run 20 lsattr -El sys0 -a systemid 2>/dev/null | awk '{print $2}')
  emit frame serial frame_serial_raw  "$_sn"
  # HMC reporta 7 caracteres (ex.: 82FAC7X); lsattr traz plant code na frente (IBM,0682FAC7X)
  emit frame serial frame_serial      "$(printf '%s' "$_sn" | sed 's/.*,//' | awk '{print substr($0,length($0)-6)}')"
  emit frame modelo tipo_modelo_curto "$(run 10 uname -M | sed 's/.*,//')"
  _fwr=$(run 20 lsmcode -c 2>/dev/null)
  # ATENCAO: o grep do AIX NAO tem a flag -o. Extracao feita com awk (portavel).
  emit frame firmware nivel_temporario "$(printf '%s\n' "$_fwr" | awk '{for(i=1;i<=NF;i++) if($i=="(t)" && i>1) {print $(i-1); exit}}')"
  emit frame firmware nivel_permanente "$(printf '%s\n' "$_fwr" | awk '{for(i=1;i<=NF;i++) if($i=="(p)" && i>1) {print $(i-1); exit}}')"
  emit frame firmware imagem_boot      "$(printf '%s\n' "$_fwr" | tr 'A-Z' 'a-z' | awk '/temporary/{print "temporary"; f=1; exit} /permanent/{print "permanent"; f=1; exit}')"
  emit frame firmware release          "$(printf '%s\n' "$_fwr" | awk '{for(i=1;i<=NF;i++) if($i ~ /^FW[0-9]+\.[0-9]+/) {print $i; exit}}')"
  emit lpar id      lpar_id       "$(run 10 uname -L | awk '{print $1}')"
  emit lpar id      lpar_nome     "$(run 10 uname -L | cut -d' ' -f2-)"

  _li=$(run 20 lparstat -i)
  for k in "Type" "Mode" "Entitled Capacity" "Online Virtual CPUs" "Maximum Virtual CPUs" \
           "Minimum Virtual CPUs" "Variable Capacity Weight" "Shared Pool ID" "Online Memory" \
           "Maximum Memory" "Minimum Memory" "Memory Mode" "Desired Capacity"; do
    _v=$(printf '%s\n' "$_li" | awk -F: -v k="$k" 'index($1,k)==1{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
    emit cpu lparstat "$(printf '%s' "$k" | tr ' A-Z' '_a-z')" "$_v"
  done

  emit cpu fisico  cores_ativos_frame "$(run 20 lparstat -i 2>/dev/null | awk -F: '/Active Physical CPUs in system/{gsub(/ /,"",$2); print $2}')"
  emit cpu logico  lcpu               "$(run 10 lsdev -Cc processor 2>/dev/null | wc -l | tr -d ' ')"
  _smt=$(run 15 smtctl 2>/dev/null | awk -F'is ' '/SMT threads per physical processor/{gsub(/\.$/,"",$2); print $2; exit}')
  [ -n "$_smt" ] || _smt=$(run 10 lparstat -i 2>/dev/null | awk -F'SMT-' '/^Type/{print $2; exit}')
  emit cpu smt threads "$_smt"
  emit cpu smt estado  "$(run 15 smtctl 2>/dev/null | awk '/SMT is currently/{print $NF; exit}' | tr -d '.')"
  emit mem real    mb                 "$(run 10 lsattr -El sys0 -a realmem 2>/dev/null | awk '{print $2/1024}')"
  emit mem paging  total_mb           "$(run 20 lsps -s 2>/dev/null | awk 'NR==2{gsub(/MB/,"",$1); print $1}')"
  emit mem paging  usado_pct          "$(run 20 lsps -s 2>/dev/null | awk 'NR==2{gsub(/%/,"",$2); print $2}')"

  # disco alocado (rootvg + total)
  _tot=$(run 60 lspv 2>/dev/null | awk '{print $1}' | while read d; do
           getconf DISK_SIZE "/dev/$d" 2>/dev/null || echo 0; done | awk '{s+=$1} END{print s}')
  emit disco alocado total_mb "$_tot"
  emit disco qtd     luns     "$(run 30 lspv 2>/dev/null | wc -l | tr -d ' ')"
  emit disco qtd     vgs      "$(run 20 lsvg 2>/dev/null | wc -l | tr -d ' ')"

  emit so tempo uptime "$(run 10 uptime | sed 's/^ *//')"
  emit so tz    zona   "$(echo "${TZ:-$(awk -F= '/^TZ=/{print $2}' /etc/environment 2>/dev/null)}")"

elif [ "$PLAT" = solaris ]; then
  emit so versao release     "$(head -1 /etc/release 2>/dev/null | sed 's/^[ \t]*//;s/[ \t]*$//')"
  emit so versao uname_vr    "$(uname -v).$(uname -r)"
  _pk=$(run 40 pkg info entire 2>/dev/null)
  emit so versao pkg_entire  "$(printf '%s\n' "$_pk" | $AWK -F': ' '/^[ \t]*Version/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
  emit so versao pkg_branch  "$(printf '%s\n' "$_pk" | $AWK -F': ' '/^[ \t]*Branch/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')"
  emit so kernel bits        "$(run 10 isainfo -b 2>/dev/null)"
  emit so kernel arch        "$(run 10 isainfo -k 2>/dev/null)"
  emit so kernel processador "$(uname -p 2>/dev/null)"
  emit so boot_env ativo     "$(run 20 beadm list -H 2>/dev/null | $AWK -F';' '$3 ~ /N/ || $3 ~ /R/ {print $1";"$3}' | tr '\n' ' ')"

  emit frame modelo tipo_modelo "$(run 20 prtconf -b 2>/dev/null | $AWK -F': ' '/banner-name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  emit frame modelo plataforma  "$(run 10 uname -i 2>/dev/null)"
  _sn=$(run 25 smbios -t SMB_TYPE_SYSTEM 2>/dev/null | $AWK -F': ' '/Serial Number/{gsub(/^[ \t]+/,"",$2); print $2; exit}')
  [ -n "$_sn" ] || _sn=$(run 40 prtdiag 2>/dev/null | $AWK -F': ' '/Serial Number|Chassis Serial/{gsub(/^[ \t]+/,"",$2); print $2; exit}')
  emit frame serial frame_serial "$_sn"

  # ------------------------------------------------------------------
  # Identificacao na pilha de virtualizacao: dominio logico x zona
  #   fisico       -> Solaris direto no hardware (sem LDOM)
  #   ldom-control -> dominio de controle (enxerga todos os LDOMs via ldm)
  #   ldom-servico -> service/io/root domain
  #   ldom-guest   -> dominio hospede
  #   kernel-zone  -> zona de kernel (tem kernel proprio; zonename = global)
  #   zona-nao-global -> zona comum (hardware reportado e o da global)
  # ZONA e ZONA_TIPO vem do lib.sh e ja estao em meta,host,zona*
  # ------------------------------------------------------------------
  emit lpar zona nome "$ZONA"
  emit lpar zona tipo "$ZONA_TIPO"

  _vi=$(run 25 virtinfo -a 2>/dev/null)
  # Fallback: em alguns Solaris 11.3 o "-a" nao retorna nada; virtinfo puro imprime
  # a linha de papel. Se ainda assim vier vazio, registra o motivo em vez de omitir.
  [ -n "$_vi" ] || _vi=$(run 15 virtinfo 2>/dev/null)
  [ -n "$_vi" ] || emit lpar virt virtinfo_status "$( has virtinfo && echo sem_saida || echo comando_ausente )"
  _papel=$(printf '%s\n' "$_vi"  | $AWK -F': ' '/Domain role/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
  _vmtipo=$(printf '%s\n' "$_vi" | $AWK -F': ' '/Virtual Machine Type|VM Type/{gsub(/^[ \t]+|[ \t]+$/,"",$2); print $2; exit}')
  emit lpar virt papel        "$_papel"
  emit lpar virt tipo_vm      "$_vmtipo"
  emit lpar virt dominio      "$(printf '%s\n' "$_vi" | $AWK -F': ' '/Domain name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  emit lpar virt uuid         "$(printf '%s\n' "$_vi" | $AWK -F': ' '/Domain UUID/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  emit lpar virt control_dom  "$(printf '%s\n' "$_vi" | $AWK -F': ' '/Control domain/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
  # Serial do chassi: agrupa todos os dominios/zonas que moram no mesmo servidor
  emit lpar virt chassi_serial "$(printf '%s\n' "$_vi" | $AWK -F': ' '/Chassis serial/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"

  # Classificacao feita no awk: nao depende de tr, de locale nem de pattern de case.
  # Ordem: kernel zone > control > guest > service/io/root. "LDoms guest I/O root"
  # e um guest que tambem faz I/O -- nao e dominio de controle.
  _escopo=$(printf '%s\n' "$_vi" | $AWK -v zt="$ZONA_TIPO" '
    /Domain role/                    { s=$0; sub(/^[^:]*:[ \t]*/,"",s); papel=tolower(s) }
    /Virtual Machine Type|VM Type/   { s=$0; sub(/^[^:]*:[ \t]*/,"",s); vm=tolower(s) }
    END {
      if (zt == "nao-global")            { print "zona-nao-global"; exit }
      t = papel " " vm
      if (t ~ /kernel[ -]*zone/)         print "kernel-zone"
      else if (t ~ /control/)            print "ldom-control"
      else if (t ~ /guest/)              print "ldom-guest"
      else if (t ~ /service|i\/o|root/)  print "ldom-servico"
      else if (papel == "" && vm == "")  print "fisico-ou-indeterminado"
      else                               print "ldom-outro"
    }')
  emit lpar virt escopo "$_escopo"
  # Aviso explicito: impede que o parque some CPU/memoria duas vezes
  case "$_escopo" in
    zona-nao-global) emit lpar virt aviso "cpu/memoria/disco refletem a zona, nao o servidor fisico" ;;
  esac

  # --- Zonas hospedadas (so faz sentido na global) ---
  if [ "$ZONA_TIPO" = global ]; then
    run 30 zoneadm list -cp 2>/dev/null | while IFS=: read _zid _znm _zst _zpt _zuu _zbr _zip _rest; do
      [ -n "$_znm" ] || continue
      [ "$_znm" = global ] && continue
      emit zona "$_znm" estado  "$_zst"
      emit zona "$_znm" brand   "$_zbr"
      emit zona "$_znm" ip_type "$_zip"
      emit zona "$_znm" caminho "$_zpt"
      emit zona "$_znm" uuid    "$_zuu"
    done
    emit lpar zona filhas     "$(run 30 zoneadm list -cp 2>/dev/null | $AWK -F: '$2!="global" && $2!=""{printf "%s(%s) ", $2, $3}')"
    emit lpar zona qtd_filhas "$(run 30 zoneadm list -cp 2>/dev/null | $AWK -F: '$2!="global" && $2!=""' | wc -l | tr -d ' ')"
  fi

  # --- Dominio de controle: inventario dos LDOMs do servidor (equivale ao HMC) ---
  case "$_escopo" in
    ldom-control|ldom-servico)
      run 60 ldm list -p 2>/dev/null | $AWK -F'|' '/^DOMAIN\|/{
          nm=""; st=""; nc=""; mm=""; fl=""; ut=""
          for (i=2; i<=NF; i++) {
            k=$i; sub(/=.*/,"",k); v=$i; sub(/^[^=]*=/,"",v)
            if (k=="name") nm=v; else if (k=="state") st=v
            else if (k=="ncpu") nc=v; else if (k=="mem") mm=v
            else if (k=="flags") fl=v; else if (k=="uptime") ut=v
          }
          if (nm!="") printf "%s|%s|%s|%s|%s\n", nm, st, nc, mm, fl
        }' | while IFS='|' read _dn _ds _dc _dm _df; do
          emit ldom "$_dn" estado    "$_ds"
          emit ldom "$_dn" vcpu      "$_dc"
          emit ldom "$_dn" memoria_b "$_dm"
          emit ldom "$_dn" memoria_mb "$(printf '%s' "$_dm" | $AWK '$1 ~ /^[0-9]+$/{printf "%.0f", $1/1048576}')"
          emit ldom "$_dn" flags     "$_df"
        done
      emit lpar virt ldoms_qtd "$(run 60 ldm list -p 2>/dev/null | grep -c '^DOMAIN|')"
      ;;
  esac

  emit cpu fisico  sockets  "$(run 15 psrinfo -p 2>/dev/null)"
  emit cpu logico  vcpu     "$(run 15 psrinfo 2>/dev/null | wc -l | tr -d ' ')"
  emit cpu logico  online   "$(run 15 psrinfo 2>/dev/null | $AWK '$2=="on-line"' | wc -l | tr -d ' ')"
  emit cpu modelo  nome     "$(run 20 psrinfo -pv 2>/dev/null | $AWK '/MHz|GHz|SPARC|Intel|AMD/{gsub(/^[ \t]+/,""); print; exit}' | cut -c1-90)"
  emit cpu pool    nome     "$(run 15 poolbind -q $$ 2>/dev/null | $AWK -F': ' '{print $2; exit}')"
  emit mem real    mb       "$(run 25 prtconf 2>/dev/null | $AWK -F': ' '/Memory size/{gsub(/[^0-9]/,"",$2); print $2; exit}')"
  _sw=$(run 20 swap -s 2>/dev/null)
  emit mem swap    resumo   "$(printf '%s\n' "$_sw" | cut -c1-140)"
  emit mem swap    total_mb "$(run 20 swap -l 2>/dev/null | $AWK 'NR>1{s+=$4} END{if(s) printf "%.0f", s/2048}')"

  _zp=$(run 40 zpool list -H -o name,size,alloc,free,cap,health 2>/dev/null)
  printf '%s\n' "$_zp" | $AWK 'NF>=6{print $1"|"$2"|"$3"|"$4"|"$5"|"$6}' | \
    while IFS='|' read p t a f c h; do
      emit zpool "$p" tamanho "$t"; emit zpool "$p" alocado "$a"
      emit zpool "$p" livre "$f"; emit zpool "$p" uso_pct "$c"; emit zpool "$p" saude "$h"
    done
  emit disco qtd luns  "$(run 40 iostat -En 2>/dev/null | grep -c 'Soft Errors')"
  emit disco qtd zpools "$(printf '%s\n' "$_zp" | $AWK 'NF>0' | wc -l | tr -d ' ')"

  emit so tempo uptime "$(run 10 uptime 2>/dev/null | sed 's/^ *//')"
  _tz="${TZ:-}"
  [ -n "$_tz" ] || _tz=$($AWK -F= '/^TZ=/{gsub(/"/,"",$2); print $2; exit}' /etc/default/init 2>/dev/null)
  emit so tz    zona   "$_tz"

else
  emit so versao pretty_name "$(awk -F= '/^PRETTY_NAME=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null)"
  emit so versao version_id  "$(awk -F= '/^VERSION_ID=/{gsub(/"/,"",$2); print $2; exit}' /etc/os-release 2>/dev/null)"
  emit so kernel release     "$(uname -r)"
  emit so kernel arch        "$(uname -m)"

  emit frame modelo tipo_modelo "$(cat /proc/device-tree/model 2>/dev/null | tr -d '\000')"
  emit frame serial frame_serial "$(cat /proc/device-tree/system-id 2>/dev/null | tr -d '\000')"
  emit lpar  id     lpar_nome    "$(cat /proc/device-tree/ibm,partition-name 2>/dev/null | tr -d '\000')"

  if [ -r /proc/ppc64/lparcfg ]; then
    for k in partition_entitled_capacity partition_max_entitled_capacity \
             partition_active_processors partition_potential_processors \
             shared_processor_mode capacity_weight pool DesMem MaxMem; do
      _v=$(awk -F= -v k="$k" '$1==k{print $2; exit}' /proc/ppc64/lparcfg 2>/dev/null)
      emit cpu lparcfg "$k" "$_v"
    done
  fi
  emit cpu logico  vcpu    "$(getconf _NPROCESSORS_ONLN 2>/dev/null)"
  emit cpu modelo  nome    "$(awk -F: '/^machine|^cpu[ \t]*:/{gsub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo 2>/dev/null)"
  emit mem real    mb      "$(awk '/^MemTotal:/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)"
  emit mem swap    total_mb "$(awk '/^SwapTotal:/{printf "%.0f", $2/1024}' /proc/meminfo 2>/dev/null)"

  _tot=$(run 60 lsblk -bdno SIZE,TYPE 2>/dev/null | awk '$2=="disk"{s+=$1} END{printf "%.0f", s/1048576}')
  emit disco alocado total_mb "$_tot"
  emit disco qtd     luns     "$(run 30 lsblk -dno TYPE 2>/dev/null | grep -c disk)"
  has vgs && emit disco qtd vgs "$(run 20 vgs --noheadings 2>/dev/null | wc -l | tr -d ' ')"

  emit so tempo uptime "$(run 10 uptime -p 2>/dev/null || uptime)"
  emit so tz    zona   "$(run 10 timedatectl 2>/dev/null | awk -F': ' '/Time zone/{print $2}')"
fi

# --- Aplicacao instalada (identificacao por evidencia no filesystem) ---
# SID SAP = exatamente 3 caracteres, 1a letra alfabetica, tudo maiusculo
if [ -d /usr/sap ]; then
  emit app sap sids "$(ls /usr/sap 2>/dev/null | awk 'length($0)==3 && $0 ~ /^[A-Z][A-Z0-9][A-Z0-9]$/' | tr '\n' ' ')"
  # Instancias realmente em execucao (fonte autoritativa)
  [ -r /usr/sap/sapservices ] && emit app sap instancias \
    "$(awk -F'/usr/sap/' '/sapstartsrv/{split($2,a,"/"); printf "%s/%s ", a[1], a[2]}' /usr/sap/sapservices 2>/dev/null)"
  emit app sap processos_ativos "$(pcount 'sapstartsrv|disp\+work|dw\.sap|jstart')"
fi
[ -x /usr/sap/hostctrl/exe/saphostctrl ] && emit app sap hostagent presente
[ -r /etc/oratab ] && emit app oracle sids "$(awk -F: '!/^#/ && NF>1 && $1 !~ /^[+-]/ {print $1}' /etc/oratab 2>/dev/null | tr '\n' ' ')"
[ -r /etc/oratab ] && emit app oracle grid_asm "$(awk -F: '!/^#/ && $1 ~ /^[+-]/ {print $1}' /etc/oratab 2>/dev/null | tr '\n' ' ')"
[ -r /etc/oratab ] && emit app oracle homes "$(awk -F: '!/^#/ && NF>1 {print $2}' /etc/oratab 2>/dev/null | sort -u | tr '\n' ' ')"
[ -r /var/opt/oracle/oratab ] && emit app oracle sids_var "$(awk -F: '!/^#/ && NF>1 {print $1}' /var/opt/oracle/oratab 2>/dev/null | tr '\n' ' ')"
has db2level && emit app db2 versao "$(run 20 db2level 2>/dev/null | awk -F'"' '/Informational tokens/{print $2}')"
[ -d /opt/IBM/WebSphere ] && emit app websphere presente sim
has nginx  && emit app web nginx  "$(run 10 nginx -v 2>&1 | sed 's/.*\///')"
has httpd  && emit app web apache "$(run 10 httpd -v 2>/dev/null | awk 'NR==1{print $3}')"
has java   && emit app java versao "$(run 20 java -version 2>&1 | awk -F'"' 'NR==1{print $2}')"

# --- Ambiente: NAO inferido. Emite apenas evidencias objetivas. ---
_lname=""
[ "$PLAT" = aix ]   && _lname=$(run 10 uname -L 2>/dev/null | cut -d' ' -f2-)
[ "$PLAT" = linux ] && _lname=$(cat /proc/device-tree/ibm,partition-name 2>/dev/null | tr -d '\000')
[ "$PLAT" = solaris ] && _lname=$(run 10 zonename 2>/dev/null)
[ -n "$_lname" ] || _lname=$(uname -n)
emit ambiente evidencia lpar_nome "$_lname"
case "$_lname" in
  *_*) emit ambiente evidencia sufixo_lpar "$(printf '%s' "$_lname" | sed 's/.*_//')" ;;
esac
# MOTD: apenas linhas com texto real (descarta molduras de asterisco/hifen)
[ -r /etc/motd ] && emit ambiente evidencia motd \
  "$(grep -v '^[ \t]*[*#=_-]*[ \t]*$' /etc/motd 2>/dev/null | sed 's/^[*# \t]*//;s/[*# \t]*$//' | grep -v '^$' | head -2 | tr '\n' ' ' | cut -c1-160)"
exit 0
