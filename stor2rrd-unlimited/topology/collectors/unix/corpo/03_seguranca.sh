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
