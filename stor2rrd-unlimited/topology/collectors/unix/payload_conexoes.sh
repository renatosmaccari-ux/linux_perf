#!/bin/sh
# GERADO POR montar_payloads.sh - NAO EDITE AQUI.
# Fonte: lib.sh + corpo/06_conexoes.sh
# Gerado em: 2026-10-08 18:50:11
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
# 06-CONEXOES: sockets TCP de entrada e saida (topologia)
# Plataformas: AIX / Linux / Solaris. SOMENTE LEITURA, sem DNS no host.
# ============================================================

AMOSTRAS="${2:-3}"      # numero de snapshots de netstat/ss
INTERVALO="${3:-10}"    # segundos entre snapshots
# Tetos por host. Fixos, o operador nao tinha como levanta-los sem editar o
# script em cada servidor: num ambiente com gateways e balanceadores, tres hosts
# sozinhos perderam 27 mil arestas na coleta, e isso so aparecia na linha
# "truncado_entrada" do resumo. Agora vem do ambiente, com os mesmos valores por
# omissao: TOPO_MAX_EDGE=6000 sh collect.sh ...
MAX_EDGE="${TOPO_MAX_EDGE:-1200}"      # teto de arestas por direcao (ordenadas por sessoes)
LIMIAR_FANIN="${TOPO_LIMIAR_FANIN:-150}"  # acima disso, clientes de uma porta sao resumidos por rede /24
MAX_HOSTS=300           # teto de linhas de /etc/hosts exportadas
RMSOCK_AIX=0            # 1 = mapeia processo dos LISTEN no AIX via rmsock (ver EXECUTAR)
PFILES_SOL=0            # 1 = mapeia processo dos LISTEN no Solaris via pfiles (ver EXECUTAR)

# --- janela de amostragem nunca pode estourar o timeout do collect.sh ---
JANELA=$(( (AMOSTRAS - 1) * INTERVALO ))
LIMITE=$(( XT - 60 ))
[ "$LIMITE" -lt 30 ] && LIMITE=30
while [ "$JANELA" -gt "$LIMITE" ] && [ "$AMOSTRAS" -gt 1 ]; do
  AMOSTRAS=$(( AMOSTRAS - 1 ))
  JANELA=$(( (AMOSTRAS - 1) * INTERVALO ))
done

TMP="${TMPD:-/tmp}/.cx.$$"
SNAP="${TMP}.snap"
PROCMAP="${TMP}.proc"
AGG="${TMP}.agg"
trap 'rm -f ${TMP}.* 2>/dev/null' 0 1 2 3 15
: > "$SNAP"; : > "$PROCMAP"; : > "$AGG"

if [ "$PLAT" = desconhecido ]; then
  emit conexao resumo erro "plataforma nao suportada: $OSNAME"
  exit 0
fi

# ============================================================
# 1. IPs locais - identidade do no na topologia
# ============================================================
if [ "$PLAT" = linux ] && has ip; then
  run 15 ip -o -4 addr show 2>/dev/null | \
    $AWK '{ split($4,c,"/"); if (c[1] !~ /^127\./ && c[1] != "0.0.0.0") print $2, c[1] }' | \
    while read _if _ip; do
      # docker0/virbr0/br-* nao identificam o host: o mesmo IP aparece em varios
      case "$_if" in docker*|virbr*|br-*|veth*|cni*|flannel*|lo*) continue ;; esac
      emit conexao ip_local "$_if" "$_ip"
    done
else
  run 20 ifconfig -a 2>/dev/null | \
    $AWK '/^[a-zA-Z]/ { i=$1; sub(/:$/,"",i) }
          /inet / { ip=$2; sub(/^addr:/,"",ip)
                    if (ip !~ /^127\./ && ip != "0.0.0.0" && ip != "255.255.255.255") print i, ip }' | \
    while read _if _ip; do
      case "$_if" in docker*|virbr*|br-*|veth*|cni*|flannel*|lo*) continue ;; esac
      emit conexao ip_local "$_if" "$_ip"
    done
fi

# ============================================================
# 2. /etc/hosts - insumo de resolucao offline no bastion
# ============================================================
[ -r /etc/hosts ] && \
  $AWK '$0 !~ /^[ \t]*#/ && NF>=2 && $1 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $1 !~ /^127\./ {
          n=""; for (i=2;i<=NF;i++) { if ($i ~ /^#/) break; n=n (n==""?"":" ") $i }
          if (n!="") print $1, n
        }' /etc/hosts 2>/dev/null | head -"$MAX_HOSTS" | \
  while read _ip _nm; do emit conexao hosts_file "$_ip" "$_nm"; done

# ============================================================
# 3. Snapshots de sockets TCP
#    Saida normalizada: <amostra> <local_addr> <remote_addr> <estado>
# ============================================================
# A fonte e SONDADA, nao assumida: o ss do RHEL 5 existe em /usr/sbin mas nao
# suporta -4 e devolve vazio sem erro. Escolhe a primeira que realmente produz linhas.
FONTE=""
if [ "$PLAT" = linux ]; then
  if has ss && [ -n "$(run 25 ss -4 -tan 2>/dev/null | sed -n '2p')" ]; then
    FONTE="ss4"
  elif has ss && [ -n "$(run 25 ss -tan 2>/dev/null | sed -n '2p')" ]; then
    FONTE="ss"
  elif has netstat; then
    FONTE="netstat"
  fi
else
  FONTE="netstat"
fi

snapshot() {
  _s="$1"
  case "$PLAT" in
    linux)
      case "$FONTE" in
        ss4) run 40 ss -4 -tan 2>/dev/null | \
               $AWK -v s="$_s" 'NR>1 && NF>=5 { print s, $4, $5, $1 }' ;;
        ss)  run 40 ss -tan 2>/dev/null | \
               $AWK -v s="$_s" 'NR>1 && NF>=5 && $4 !~ /\[/ { print s, $4, $5, $1 }' ;;
        *)   run 40 netstat -tan 2>/dev/null | \
               $AWK -v s="$_s" '$1=="tcp" && NF>=6 { print s, $4, $5, $6 }' ;;
      esac
      ;;
    aix)
      run 40 netstat -an -f inet 2>/dev/null | \
        $AWK -v s="$_s" '$1 ~ /^tcp/ && NF>=5 { st=(NF>=6 ? $6 : "SEM_ESTADO"); print s, $4, $5, st }'
      ;;
    solaris)
      run 40 netstat -an -f inet -P tcp 2>/dev/null | \
        $AWK -v s="$_s" 'NF>=7 && $1 ~ /\.[0-9*]+$/ { print s, $1, $2, $7 }'
      ;;
  esac
}

_i=1
while [ "$_i" -le "$AMOSTRAS" ]; do
  snapshot "$_i" >> "$SNAP"
  [ "$_i" -lt "$AMOSTRAS" ] && sleep "$INTERVALO"
  _i=$(( _i + 1 ))
done

NLIN=$(wc -l < "$SNAP" 2>/dev/null | tr -d ' ')
if [ "${NLIN:-0}" -eq 0 ]; then
  emit conexao resumo erro "netstat/ss nao retornou dados"
  exit 0
fi

# ============================================================
# 4. Mapa porta->processo (apenas Linux por padrao: custo zero e sem risco)
#    Formato: <porta> <processo> <pid> <usuario>
# ============================================================
if [ "$PLAT" = linux ]; then
  if [ "${FONTE#ss}" != "$FONTE" ]; then
    run 30 ss -tlnp 2>/dev/null | $AWK 'NR>1 && NF>=4 {
        a=$4; p=a; sub(/.*:/,"",p)
        nm=""; pid=""
        if (match($0, /\("[^"]+"/)) nm=substr($0, RSTART+2, RLENGTH-3)
        if (match($0, /pid=[0-9]+/)) pid=substr($0, RSTART+4, RLENGTH-4)
        if (p ~ /^[0-9]+$/ && nm != "") print p, nm, (pid==""?"-":pid)
      }' > "${TMP}.pm0" 2>/dev/null
  else
    run 30 netstat -tlnp 2>/dev/null | $AWK '$1=="tcp" && NF>=7 {
        a=$4; p=a; sub(/.*:/,"",p)
        u=$NF; pid=u; nm=u; sub(/\/.*/,"",pid); sub(/^[0-9-]*\//,"",nm)
        if (p ~ /^[0-9]+$/ && nm != "" && nm != "-") print p, nm, (pid ~ /^[0-9]+$/ ? pid : "-")
      }' > "${TMP}.pm0" 2>/dev/null
  fi
  if [ -s "${TMP}.pm0" ]; then
    sort -u "${TMP}.pm0" | while read _p _n _pid; do
      _u="-"
      [ "$_pid" != "-" ] && _u=$(run 5 ps -o user= -p "$_pid" 2>/dev/null | head -1 | tr -d ' ')
      echo "$_p $_n $_pid ${_u:--}"
    done > "$PROCMAP"
  fi
elif [ "$PLAT" = aix ] && [ "$RMSOCK_AIX" -eq 1 ]; then
  run 30 netstat -Aan -f inet 2>/dev/null | $AWK '$NF=="LISTEN" && NF>=6 {
      p=$5; sub(/.*\./,"",p); if (p ~ /^[0-9]+$/) print $1, p }' | sort -u | head -60 | \
  while read _pcb _p; do
    _r=$(run 8 rmsock "$_pcb" tcpcb 2>/dev/null | \
         $AWK '{ if (match($0,/\([^)]+\)/)) nm=substr($0,RSTART+1,RLENGTH-2)
                 for(i=1;i<=NF;i++) if ($i=="proccess"||$i=="process") pid=$(i+1)
                 print (nm==""?"-":nm), (pid==""?"-":pid) }' | head -1)
    [ -n "$_r" ] && echo "$_p $_r -"
  done > "$PROCMAP"
elif [ "$PLAT" = solaris ] && [ "$PFILES_SOL" -eq 1 ]; then
  run 20 ps -eo pid= 2>/dev/null | head -400 | while read _pid; do
    run 5 pfiles "$_pid" 2>/dev/null | $AWK -v pid="$_pid" '
      /sockname: AF_INET/ { p=$NF; if (p ~ /^[0-9]+$/) print p, "pid" pid, pid, "-" }'
  done | sort -u > "$PROCMAP"
fi

# ============================================================
# 5. Agregacao: LISTEN, entrada, saida
# ============================================================
SERVFILE=/etc/services
[ -r "$SERVFILE" ] || SERVFILE=/dev/null

$AWK -v servfile="$SERVFILE" -v procfile="$PROCMAP" -v agg="$AGG" -v limiar="$LIMIAR_FANIN" '
function ipof(a,  p) { p = match(a, /[.:][0-9*]+$/); return (p ? substr(a, 1, p-1) : a) }
function ptof(a,  p) { p = match(a, /[.:][0-9*]+$/); return (p ? substr(a, p+1)   : "") }
function norm(s) {
  s = toupper(s); gsub(/-/, "_", s)
  if (s == "ESTAB") s = "ESTABLISHED"
  if (s == "FIN_WAIT1") s = "FIN_WAIT_1"
  if (s == "FIN_WAIT2") s = "FIN_WAIT_2"
  return s
}
function priv(p) { return (p ~ /^[0-9]+$/ && p+0 < 1024) }

FILENAME == servfile {
  if ($0 ~ /^[ \t]*#/ || NF < 2) next
  split($2, a, "/")
  if (a[2] == "tcp" && !(a[1] in svc)) svc[a[1]] = $1
  next
}
FILENAME == procfile { if (NF >= 2) { pnm[$1] = $2; ppid[$1] = (NF>=3?$3:"-"); pusr[$1] = (NF>=4?$4:"-") } next }

{
  s = $1; la = $2; ra = $3; st = norm($4)
  lip = ipof(la); lp = ptof(la); rip = ipof(ra); rp = ptof(ra)
  if (lp == "" || lp !~ /^[0-9]+$/) next
  if (st == "LISTEN") { lis[lp] = 1; bindk = lip "|" lp; blist[bindk] = 1; next }
  if (st !~ /^(ESTABLISHED|TIME_WAIT|CLOSE_WAIT|SYN_SENT|FIN_WAIT_1|FIN_WAIT_2|LAST_ACK|CLOSING)$/) next
  if (rip == "" || rip == "*" || rip == "0.0.0.0" || rp !~ /^[0-9]+$/ || rp+0 == 0) next
  if (rip ~ /^127\./ || lip ~ /^127\./ || rip == lip) { loc++; next }
  n++
  A_s[n]=s; A_lip[n]=lip; A_lp[n]=lp; A_rip[n]=rip; A_rp[n]=rp; A_st[n]=st
}

END {
  for (i = 1; i <= n; i++) {
    lp = A_lp[i]; rp = A_rp[i]; rip = A_rip[i]; lip = A_lip[i]; st = A_st[i]
    if (lp in lis)                       { dir="entrada"; conf="listen"; porta=lp }
    else if (priv(rp) && !priv(lp))      { dir="saida";   conf="porta";  porta=rp }
    else if (lp+0 >= 32768 && rp+0 < 32768) { dir="saida"; conf="efemera"; porta=rp }
    else if (rp+0 >= 32768 && lp+0 < 32768) { dir="entrada"; conf="efemera"; porta=lp }
    else                                 { dir="saida";   conf="assumido"; porta=rp }

    if (dir == "entrada") {
      # Fan-in: quantos clientes distintos por porta, e por rede /24.
      # Um servidor web com 15 mil clientes nao cabe (nem interessa) aresta a aresta.
      if (!((porta SUBSEP rip) in vip)) { vip[porta, rip] = 1; fanin[porta]++ }
      split(rip, o, "."); net = o[1] "." o[2] "." o[3] ".0/24"
      if (!((porta SUBSEP net SUBSEP rip) in vnet)) { vnet[porta, net, rip] = 1; fannet[porta, net]++ }
    }
    k = dir SUBSEP rip SUBSEP porta
    tup = lip ":" lp ">" rip ":" rp
    if (!((k SUBSEP tup) in vt)) { vt[k, tup] = 1; ses[k]++ }
    if (!((k SUBSEP A_s[i]) in vs)) { vs[k, A_s[i]] = 1; amo[k]++ }
    if (!((k SUBSEP st) in ve)) { ve[k, st] = 1; est[k] = est[k] (est[k]==""?"":"+") st }
    dk[k] = dir; rk[k] = rip; pk[k] = porta; ipl[k] = lip
    if (!(k in cfk) || conf == "listen") cfk[k] = conf
  }

  for (k in dk) {
    dir = dk[k]; porta = pk[k]
    sv = (porta in svc) ? svc[porta] : "-"
    if (dir == "entrada") { pr = (porta in pnm) ? pnm[porta] : "-" } else { pr = "-" }
    printf "%d\t%s\t%s|%s\t%s|%s|%d|%d|%s|%s|%s\n", \
      ses[k], dir, rk[k], porta, sv, ipl[k], ses[k], amo[k], est[k], pr, cfk[k] >> agg
  }
  # Resumo de fan-in: sempre emitido, mesmo quando a lista de arestas e truncada
  for (p in fanin) {
    sv = (p in svc) ? svc[p] : "-"
    printf "%d\t%s\t%s\t%s|%d\n", fanin[p], "fanin", p, sv, fanin[p] >> agg
  }
  for (kk in fannet) {
    split(kk, aa, SUBSEP); p = aa[1]; net = aa[2]
    if (fanin[p] + 0 <= limiar) continue
    sv = (p in svc) ? svc[p] : "-"
    printf "%d\t%s\t%s|%s\t%s|%d\n", fannet[p, net], "fanin_rede", net, p, sv, fannet[p, net] >> agg
  }
  for (b in blist) {
    split(b, p2, "|"); porta = p2[2]
    sv = (porta in svc) ? svc[porta] : "-"
    printf "%d\t%s\t%s\t%s|%s|%s|%s\n", 999999, "listen", b, sv, \
      ((porta in pnm) ? pnm[porta] : "-"), ((porta in ppid) ? ppid[porta] : "-"), \
      ((porta in pusr) ? pusr[porta] : "-") >> agg
  }
}' "$SERVFILE" "$PROCMAP" "$SNAP" 2>/dev/null

# ============================================================
# 6. Emissao (ordenada por sessoes, truncada em MAX_EDGE por direcao)
# ============================================================
TAB=$(printf '\t')
for _d in listen entrada saida fanin fanin_rede; do
  _f="${TMP}.${_d}"
  $AWK -F"$TAB" -v d="$_d" '$2==d' "$AGG" 2>/dev/null | sort -rn > "$_f"
  _tot=$(wc -l < "$_f" 2>/dev/null | tr -d ' ')
  head -"$MAX_EDGE" "$_f" 2>/dev/null | while IFS="$TAB" read _n _dd _k _v; do
    emit conexao "$_dd" "$_k" "$_v"
  done
  emit conexao resumo "total_$_d" "${_tot:-0}"
  [ "${_tot:-0}" -gt "$MAX_EDGE" ] && emit conexao resumo "truncado_$_d" "$(( _tot - MAX_EDGE ))"
done

emit conexao resumo limiar_fanin "$LIMIAR_FANIN"
emit conexao resumo max_edge "$MAX_EDGE"
emit conexao resumo amostras   "$AMOSTRAS"
emit conexao resumo intervalo_s "$INTERVALO"
emit conexao resumo fonte      "${FONTE:-nenhuma}"
emit conexao resumo linhas_snapshot "$NLIN"
emit conexao resumo ipv6 "nao_coletado"

exit 0
