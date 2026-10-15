#!/bin/sh
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
