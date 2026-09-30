#!/bin/sh
# GERADO POR montar_payloads.sh - NAO EDITE AQUI.
# Fonte: lib.sh + corpo/03_seguranca.sh
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
# 03-SEGURANCA: usuarios, permissoes, politica de senha, SSH
# Atende: 1e, 4. NUNCA coleta hash nem senha.
# ============================================================

if [ "$PLAT" = aix ]; then
  # Usuarios locais: id, grupos, admin, shell, conta bloqueada, expiracao
  for u in $(run 30 lsuser -a id ALL 2>/dev/null | awk '{print $1}'); do
    _a=$(run 10 lsuser -a id pgrp groups admin account_locked shell login su expires "$u" 2>/dev/null)
    for k in id pgrp groups admin account_locked shell login su expires; do
      emit usuario "$u" "$k" "$(printf '%s' "$_a" | tr ' ' '\n' | awk -F= -v k="$k" '$1==k{print $2}')"
    done
    _lu=$(run 10 lssec -f /etc/security/passwd -s "$u" -a lastupdate 2>/dev/null | awk -F= '{print $2}')
    emit usuario "$u" ultima_troca_epoch "$_lu"
    emit usuario "$u" ultima_troca_senha "$(epoch2iso "$_lu")"
  done
  # Politica de senha - default e por usuario privilegiado
  for k in maxage minage histsize minlen minalpha minother maxrepeats \
           pwdwarntime loginretries histexpire dictionlist; do
    emit politica_senha default "$k" "$(run 10 lssec -f /etc/security/user -s default -a "$k" 2>/dev/null | awk -F= '{print $2}')"
    emit politica_senha root    "$k" "$(run 10 lssec -f /etc/security/user -s root    -a "$k" 2>/dev/null | awk -F= '{print $2}')"
  done
  # AIX expressa maxage/minage/pwdwarntime em SEMANAS. Converter para dias.
  for _s in default root; do
    for _k in maxage minage; do
      _w=$(run 10 lssec -f /etc/security/user -s "$_s" -a "$_k" 2>/dev/null | awk -F= '{print $2}')
      [ -n "$_w" ] && emit politica_senha "$_s" "${_k}_dias" "$(printf '%s' "$_w" | awk '{print $1*7}')"
    done
  done
  emit politica_senha sistema unidade_nativa "semanas (maxage/minage)"
  emit politica_senha sistema modo "AIX /etc/security/user"
  # Membros de grupos privilegiados
  for g in system security sudo staff; do
    emit grupo_privilegiado "$g" membros "$(run 10 lsgroup -a users "$g" 2>/dev/null | sed 's/.*users=//')"
  done
  emit seguranca aixpert nivel "$(run 20 aixpert -c 2>/dev/null | head -1)"
  emit seguranca rbac  habilitado "$(run 10 lsattr -El sys0 -a enhanced_RBAC 2>/dev/null | awk '{print $2}')"
  emit seguranca trustchk status "$(run 30 trustchk -n ALL 2>/dev/null | wc -l | tr -d ' ')"
elif [ "$PLAT" = solaris ]; then
  # Usuarios locais: passwd/shadow existem, mas o aging vem de passwd -s.
  # "passwd -sa" e lido UMA vez: chamar passwd -s por usuario custa 2 forks cada
  # e estoura o timeout em hosts com centenas de contas locais.
  _PW="$TMPD/.sec.pw.$$"; _GR="$TMPD/.sec.gr.$$"
  run 40 passwd -sa > "$_PW" 2>/dev/null
  $AWK -F: 'NF>=4 && $4!=""{n=split($4,m,","); for(i=1;i<=n;i++) print m[i], $1}' \
      /etc/group > "$_GR" 2>/dev/null
  $AWK -F: '{print $1"|"$3"|"$4"|"$7}' /etc/passwd 2>/dev/null | while IFS='|' read u uid gid sh; do
    emit usuario "$u" uid   "$uid"
    emit usuario "$u" gid   "$gid"
    emit usuario "$u" shell "$sh"
    emit usuario "$u" grupos "$($AWK -v u="$u" '$1==u{printf "%s ", $2}' "$_GR" 2>/dev/null)"
    # passwd -s: usuario estado(PS/LK/NP/UN) data_ultima_troca min max warn
    _ps=$($AWK -v u="$u" '$1==u{print; exit}' "$_PW" 2>/dev/null)
    emit usuario "$u" status_senha      "$(printf '%s\n' "$_ps" | $AWK '{print $2; exit}')"
    emit usuario "$u" ultima_troca_senha "$(printf '%s\n' "$_ps" | $AWK '{print $3; exit}')"
    emit usuario "$u" min_dias          "$(printf '%s\n' "$_ps" | $AWK '{print $4; exit}')"
    emit usuario "$u" max_dias          "$(printf '%s\n' "$_ps" | $AWK '{print $5; exit}')"
    emit usuario "$u" aviso_dias        "$(printf '%s\n' "$_ps" | $AWK '{print $6; exit}')"
    # LK = locked, NP = sem senha. Le apenas o 1o caractere do campo 2 do shadow.
    emit usuario "$u" bloqueada "$($AWK -F: -v u="$u" '$1==u{ if (substr($2,1,1)=="*" || substr($2,1,2)=="LK" || substr($2,1,1)=="!") print "sim"; else print "nao" }' /etc/shadow 2>/dev/null)"
    # RBAC: perfis e roles atribuidos
    emit usuario "$u" rbac_attr "$($AWK -F: -v u="$u" '$1==u{print $5}' /etc/user_attr 2>/dev/null | cut -c1-200)"
  done
  # Politica de senha: /etc/default/passwd. MAXWEEKS/MINWEEKS/WARNWEEKS em SEMANAS.
  for k in MAXWEEKS MINWEEKS WARNWEEKS PASSLENGTH HISTORY MINDIFF MINALPHA MINDIGIT \
           MINSPECIAL MINLOWER MINUPPER MAXREPEATS WHITESPACE DICTIONDBDIR NAMECHECK; do
    emit politica_senha default "$k" "$($AWK -F= -v k="$k" '$0 !~ /^#/ && $1==k{print $2; exit}' /etc/default/passwd 2>/dev/null)"
  done
  for k in MAXWEEKS MINWEEKS WARNWEEKS; do
    _w=$($AWK -F= -v k="$k" '$0 !~ /^#/ && $1==k{print $2; exit}' /etc/default/passwd 2>/dev/null)
    [ -n "$_w" ] && emit politica_senha default "${k}_dias" "$(sem2dias "$_w")"
  done
  emit politica_senha sistema unidade_nativa "semanas (MAXWEEKS/MINWEEKS/WARNWEEKS)"
  emit politica_senha sistema modo "Solaris /etc/default/passwd + PAM"
  emit politica_senha sistema algoritmo "$($AWK -F= '/^CRYPT_DEFAULT/{print $2; exit}' /etc/security/policy.conf 2>/dev/null)"
  for f in /etc/pam.conf /etc/pam.d/other /etc/pam.d/login; do
    [ -r "$f" ] || continue
    emit politica_senha pam_arquivo "$f" "$($GREP -Ev '^[ \t]*#' "$f" 2>/dev/null | $GREP -Ei 'pam_authtok|history|pam_unix_auth|retry' | tr '\n' ';' | cut -c1-300)"
  done
  # Privilegio: UID 0, roles e perfis administrativos
  emit grupo_privilegiado root_uid0 membros "$($AWK -F: '$3==0{printf "%s ", $1}' /etc/passwd 2>/dev/null)"
  emit grupo_privilegiado root_grp  membros "$($AWK -F: '$1=="root"{print $4}' /etc/group 2>/dev/null)"
  emit grupo_privilegiado sysadmin  membros "$($AWK -F: '$1=="sysadmin"{print $4}' /etc/group 2>/dev/null)"
  emit grupo_privilegiado roles     definidas "$($AWK -F: '$0 ~ /type=role/{printf "%s ", $1}' /etc/user_attr 2>/dev/null)"
  emit grupo_privilegiado perfis    primary_admin "$($AWK -F: '$5 ~ /Primary Administrator|System Administrator/{printf "%s ", $1}' /etc/user_attr 2>/dev/null)"
  emit seguranca rbac  habilitado "sim (RBAC nativo)"
  emit seguranca policy priv_limit "$($AWK -F= '/^PRIV_(LIMIT|DEFAULT)/{printf "%s;", $0}' /etc/security/policy.conf 2>/dev/null | cut -c1-200)"
  emit seguranca bart  manifesto  "$( [ -d /var/bart ] && echo presente )"
  emit seguranca zona  seguranca  "$(run 10 zonename 2>/dev/null)"
  rm -f "$_PW" "$_GR" 2>/dev/null
else
  # Usuarios locais com UID e shell.
  # id/chage consultam o NSS (sssd/LDAP). Com diretorio lento, centenas de contas
  # estouravam o timeout do host. Ha um orcamento de tempo: esgotado, o restante
  # das contas e lido direto de /etc/group e /etc/shadow (sem NSS), e isso e
  # registrado em meta,seguranca,modo_rapido. Em host normal nada muda.
  _T0=$(date '+%s' 2>/dev/null); case "$_T0" in ''|*[!0-9]*) _T0=0 ;; esac
  _ORC=$(( ${XT:-300} * 45 / 100 ))
  _RAPIDO=0
  awk -F: '{print $1"|"$3"|"$4"|"$7}' /etc/passwd 2>/dev/null | while IFS='|' read u uid gid sh; do
    if [ "$_RAPIDO" -eq 0 ] && [ "$_T0" -gt 0 ]; then
      _AG=$(date '+%s' 2>/dev/null)
      if [ $(( _AG - _T0 )) -gt "$_ORC" ]; then
        _RAPIDO=1
        emit meta seguranca modo_rapido "orcamento de ${_ORC}s esgotado; a partir de $u sem NSS"
      fi
    fi
    emit usuario "$u" uid   "$uid"
    emit usuario "$u" gid   "$gid"
    emit usuario "$u" shell "$sh"
    if [ "$_RAPIDO" -eq 0 ]; then
      emit usuario "$u" grupos "$(run 10 id -Gn "$u" 2>/dev/null)"
      if has chage; then
        _c=$(run 10 chage -l "$u" 2>/dev/null)
        emit usuario "$u" ultima_troca_senha "$(printf '%s\n' "$_c" | awk -F': ' '/Last password change/{print $2}')"
        emit usuario "$u" senha_expira       "$(printf '%s\n' "$_c" | awk -F': ' '/Password expires/{print $2}')"
        emit usuario "$u" max_dias           "$(printf '%s\n' "$_c" | awk -F': ' '/Maximum number/{print $2}')"
        emit usuario "$u" min_dias           "$(printf '%s\n' "$_c" | awk -F': ' '/Minimum number/{print $2}')"
      fi
    else
      # grupos locais apenas (primario + suplementares de /etc/group)
      emit usuario "$u" grupos "$(awk -F: -v u="$u" -v g="$gid" '
          $3==g {p=$1} {n=split($4,m,","); for(i=1;i<=n;i++) if (m[i]==u) s=s" "$1}
          END {print p s}' /etc/group 2>/dev/null)"
      _sh=$(awk -F: -v u="$u" '$1==u{print $3"|"$4"|"$5; exit}' /etc/shadow 2>/dev/null)
      _lc=$(printf '%s' "$_sh" | cut -d'|' -f1); _mn=$(printf '%s' "$_sh" | cut -d'|' -f2)
      _mx=$(printf '%s' "$_sh" | cut -d'|' -f3)
      case "$_lc" in ''|*[!0-9]*) ;; *)
        emit usuario "$u" ultima_troca_senha "$(epoch2iso $(( _lc * 86400 )))"
        case "$_mx" in ''|*[!0-9]*|99999) emit usuario "$u" senha_expira "never" ;;
          *) emit usuario "$u" senha_expira "$(epoch2iso $(( (_lc + _mx) * 86400 )))" ;; esac ;;
      esac
      emit usuario "$u" max_dias "$_mx"
      emit usuario "$u" min_dias "$_mn"
    fi
    # Conta bloqueada: 2o campo do shadow iniciando com ! ou *
    emit usuario "$u" bloqueada "$(awk -F: -v u="$u" '$1==u{ if ($2 ~ /^[!*]/) print "sim"; else print "nao" }' /etc/shadow 2>/dev/null)"
  done
  # Politica de senha global
  for k in PASS_MAX_DAYS PASS_MIN_DAYS PASS_MIN_LEN PASS_WARN_AGE; do
    emit politica_senha login_defs "$k" "$(awk -v k="$k" '$1==k{print $2; exit}' /etc/login.defs 2>/dev/null)"
  done
  for f in /etc/security/pwquality.conf /etc/pam.d/common-password /etc/pam.d/system-auth; do
    [ -r "$f" ] || continue
    emit politica_senha pam_arquivo "$f" "$(grep -v '^[ \t]*#' "$f" 2>/dev/null | grep -Ei 'pwquality|pwhistory|cracklib|minlen|remember|retry' | tr '\n' ';' | cut -c1-300)"
  done
  emit politica_senha sistema modo "Linux login.defs + PAM"
  # Privilegio
  emit grupo_privilegiado root  membros "$(awk -F: '$3==0{printf "%s ", $1}' /etc/passwd 2>/dev/null)"
  emit grupo_privilegiado wheel membros "$(awk -F: '$1=="wheel"||$1=="sudo"{print $4}' /etc/group 2>/dev/null | tr '\n' ' ')"
  emit seguranca selinux estado "$(run 10 getenforce 2>/dev/null)"
  has aa-status && emit seguranca apparmor perfis "$(run 10 aa-status --profiled 2>/dev/null)"
fi

# sudoers (regras, sem senhas)
for f in /etc/sudoers /opt/csw/etc/sudoers /usr/local/etc/sudoers; do
  [ -r "$f" ] && emit sudo regra "$f" "$(grep -v '^[ \t]*#' "$f" 2>/dev/null | grep -v '^[ \t]*$' | grep -Ei 'ALL|NOPASSWD' | tr '\n' ';' | cut -c1-400)"
done
if [ -d /etc/sudoers.d ]; then
  for f in /etc/sudoers.d/*; do
    [ -r "$f" ] || continue
    emit sudo regra "$f" "$(grep -v '^[ \t]*#' "$f" 2>/dev/null | grep -v '^[ \t]*$' | tr '\n' ';' | cut -c1-400)"
  done
fi

# SSH hardening
for k in PermitRootLogin PasswordAuthentication PubkeyAuthentication Protocol \
         MaxAuthTries ClientAliveInterval Ciphers MACs KexAlgorithms X11Forwarding; do
  emit ssh sshd_config "$k" "$(awk -v k="$k" 'tolower($1)==tolower(k){$1=""; print; exit}' /etc/ssh/sshd_config 2>/dev/null | sed 's/^ //')"
done
emit ssh versao servidor "$(run 10 sshd -V 2>&1 | head -1; run 10 ssh -V 2>&1 | head -1)"
[ "$PLAT" = solaris ] && emit ssh servico estado "$(run 15 svcs -H -o STATE ssh 2>/dev/null)"

# Ultimos logins (evidencia de contas em uso real)
emit auditoria last_logins amostra "$(run 20 last 2>/dev/null | head -15 | awk '{print $1}' | sort -u | tr '\n' ' ')"
exit 0
