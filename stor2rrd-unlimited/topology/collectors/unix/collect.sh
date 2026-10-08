#!/bin/sh
# collect.sh v3.2 - Runner de coleta multiplataforma (AIX / Linux / Solaris) via bastion
# Executa um payload POSIX sh em N hosts em paralelo e consolida a saida em CSV.
#
# Uso: ./collect.sh -p payload.sh -o saida.csv [-l hosts.txt] [-j 8] [-t 15] [-T 180]
#
# v2: timeout DURO por host, progresso em tempo real, resultados preservados
#     mesmo se interrompido com Ctrl-C.
# v3: multiplos IPs por host (col 2..N), motivo de falha classificado, fallback
#     para sudo sem -n e para sudo com requiretty.
# v3.2: Windows detectado por TTL (65-128) nao e coletado; checagem de identidade
#       (alvo x hostname real); classificacao de erro sem diferenca de caixa.

set -u

HOSTS="servidores_running_aix_linux.txt"
PAYLOAD=""
OUT=""
JOBS=8
CTIMEOUT=15
XTIMEOUT=180
SSH_USER="${SSH_USER:-netuss}"
KEEP=0

usage() {
  echo "uso: $0 -p payload.sh -o saida.csv [-l hosts.txt] [-j jobs] [-t timeout_conexao] [-T timeout_host] [-k]" >&2
  echo "  -k  preserva o diretorio de trabalho para diagnostico" >&2
  exit 2
}

while getopts "p:o:l:j:t:T:u:kh" opt; do
  case "$opt" in
    p) PAYLOAD="$OPTARG" ;;
    o) OUT="$OPTARG" ;;
    l) HOSTS="$OPTARG" ;;
    j) JOBS="$OPTARG" ;;
    t) CTIMEOUT="$OPTARG" ;;
    T) XTIMEOUT="$OPTARG" ;;
    u) SSH_USER="$OPTARG" ;;
    k) KEEP=1 ;;
    *) usage ;;
  esac
done

[ -n "$PAYLOAD" ] || usage
[ -n "$OUT" ] || usage
[ -r "$PAYLOAD" ] || { echo "[FALHA] payload nao legivel: $PAYLOAD" >&2; exit 1; }
[ -r "$HOSTS" ]   || { echo "[FALHA] lista de hosts nao legivel: $HOSTS" >&2; exit 1; }

# Workdir ao lado do output, nome deterministico: sobrevive a Ctrl-C
WORKDIR="${OUT%.csv}.work"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR/out" "$WORKDIR/err" || exit 1

# Os ajustes TOPO_* sao lidos pelo corpo do payload, que corre no host remoto
# por "ssh ... sudo -n /bin/sh -s". Nem o ssh (sem AcceptEnv) nem o sudo levam o
# ambiente daqui para la, portanto defini-los na linha de comando nao chegava a
# lado nenhum - a coleta continuava com os valores por omissao e nada dizia.
# Vao escritos no inicio do proprio payload, que e o unico que viaja.
PRELUDIO=""
for _v in TOPO_MAX_EDGE TOPO_LIMIAR_FANIN; do
  eval "_val=\${$_v:-}"
  [ -n "$_val" ] || continue
  case "$_val" in
    ""|*[!0-9]*) echo "[FALHA] $_v deve ser um inteiro: $_val" >&2; exit 1 ;;
  esac
  PRELUDIO="$PRELUDIO$_v=$_val; export $_v
"
done
if [ -n "$PRELUDIO" ]; then
  _orig="$PAYLOAD"
  PAYLOAD="$WORKDIR/payload.sh"
  { sed -n '1p' "$_orig"; printf '%s' "$PRELUDIO"; sed '1d' "$_orig"; } \
    > "$PAYLOAD" || exit 1
  echo "[INFO] ajustes no payload: $(printf '%s' "$PRELUDIO" | tr '\n' ' ')"
fi

# Col 1 = hostname; demais colunas = IPs alternativos (opcionais). Emite
# "hostname|ip1,ip2,..." para fallback quando o hostname nao resolve ou nao conecta.
awk 'NF && $1 !~ /^#/ {
       h=$1; gsub(/\r/,"",h)
       if (h ~ /^-+$/)                          next
       if (h !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) next
       if (length(h) < 2)                       next
       u=toupper(h)
       if (u=="HOSTNAME"||u=="HOST"||u=="SERVIDOR"||u=="SERVER"||u=="IP") next
       ips=""
       for (i=2; i<=NF; i++) { x=$i; gsub(/[\r,;]/,"",x)
         if (x ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) ips = ips (ips==""?"":",") x }
       print h "|" ips
     }' "$HOSTS" | sort -u > "$WORKDIR/hosts.lst"

BRUTO=$(awk 'NF && $1 !~ /^#/' "$HOSTS" | wc -l | tr -d ' ')
TOTAL=$(wc -l < "$WORKDIR/hosts.lst" | tr -d ' ')
[ "$BRUTO" -ne "$TOTAL" ] && \
  echo "[AVISO] $(( BRUTO - TOTAL )) linha(s) descartada(s) da lista (cabecalho/separador/token invalido)" >&2

# ---- recursos da plataforma (AIX nao tem timeout, xargs -P nem date +%s) ----
if command -v timeout >/dev/null 2>&1; then HAS_TIMEOUT=1; else HAS_TIMEOUT=0; fi
if echo x | xargs -P 2 -I{} true >/dev/null 2>&1; then HAS_XARGSP=1; else HAS_XARGSP=0; fi
if [ "$(date '+%s' 2>/dev/null)" -gt 0 ] 2>/dev/null; then HAS_EPOCH=1; else HAS_EPOCH=0; fi
export HAS_EPOCH
TTL_CHECK="${TTL_CHECK:-1}"; export TTL_CHECK

[ "$HAS_XARGSP" -eq 1 ] || echo "[INFO] xargs -P ausente (AIX): usando paralelismo em sh puro"

echo "[INFO] hosts: $TOTAL | jobs: $JOBS | timeout/host: ${XTIMEOUT}s | payload: $PAYLOAD"
[ "$TTL_CHECK" = "1" ] && echo "[INFO] deteccao de Windows por TTL ativa (TTL_CHECK=0 desativa)"
echo "[INFO] trabalho em: $WORKDIR (progresso: wc -l $WORKDIR/status)"

# ---------- worker ----------
cat > "$WORKDIR/worker.sh" << 'WEOF'
#!/bin/sh
# worker v3. Recebe "hostname|ip1,ip2". Estrategia:
#   1. tenta hostname, depois cada IP, enquanto a falha for de rede/DNS
#   2. sudo sem suporte a -n (sudo < 1.7)   -> repete com "sudo" puro
#   3. sudo com requiretty                  -> envia o payload e executa com ssh -tt
SPEC="$1"; PAYLOAD="$2"; WD="$3"; U="$4"; CT="$5"; XT="$6"; HT="$7"

agora() {
  if [ "${HAS_EPOCH:-0}" = "1" ]; then date '+%s'
  elif command -v perl >/dev/null 2>&1; then perl -e 'print time'
  else echo 0; fi
}

HOST=${SPEC%%|*}
IPS=$(printf '%s' "${SPEC#*|}" | tr ',' ' ')
O="$WD/out/$HOST"; E="$WD/err/$HOST"

# Sem -q: com -q o ssh engole "Connection timed out", "Permission denied" etc. e a
# falha chegava como "ssh_falhou" sem motivo. LogLevel=ERROR mantem so os erros.
SSHOPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
 -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=$CT
 -o ConnectionAttempts=1 -o ServerAliveInterval=10 -o ServerAliveCountMax=3
 -o PreferredAuthentications=publickey"

# Executa "$@" com limite de XT segundos. Os redirecionamentos da chamada valem
# para o comando inteiro (inclusive em background).
limite() {
  if [ "$HT" -eq 1 ]; then timeout -k 10 "$XT" "$@"; return $?; fi
  "$@" &
  _p=$!
  ( sleep "$XT"; kill -TERM "$_p" 2>/dev/null; sleep 5; kill -9 "$_p" 2>/dev/null ) >/dev/null 2>&1 &
  _w=$!
  wait "$_p" 2>/dev/null; _r=$?
  kill -9 "$_w" 2>/dev/null
  case "$_r" in 143|137) _r=124 ;; esac
  return $_r
}

# modo padrao: payload pelo stdin
modo_padrao() {
  limite ssh $SSHOPTS "$U@$ALVO" "sudo -n /bin/sh -s $XT" < "$PAYLOAD" > "$O" 2> "$E"
}
# sudo antigo, sem a opcao -n. Sem tty, um sudo que pedisse senha falha na hora
# ("no tty present"), entao nao ha risco de travar esperando senha.
modo_sem_n() {
  limite ssh $SSHOPTS "$U@$ALVO" "sudo /bin/sh -s $XT" < "$PAYLOAD" > "$O" 2> "$E"
}
# requiretty: o stdin vira o terminal, entao o payload nao pode ir por ele.
# Envia para um arquivo remoto (em diretorio gravavel) e executa com -tt.
modo_tty() {
  limite ssh $SSHOPTS "$U@$ALVO" \
    'd=""; for c in /tmp /var/tmp "$HOME"; do if [ -d "$c" ] && ( : > "$c/.inv_t.$$" ) 2>/dev/null; then rm -f "$c/.inv_t.$$"; d="$c"; break; fi; done; [ -n "$d" ] || exit 7; f="$d/.inv_payload.$$.sh"; cat > "$f" && chmod 600 "$f" && echo "$f"' \
    < "$PAYLOAD" > "$O.caminho" 2> "$E" || return $?
  _f=$(head -1 "$O.caminho" | tr -d '\r'); rm -f "$O.caminho"
  [ -n "$_f" ] || return 1
  _s="sudo -n"; [ "${SEM_N:-0}" -eq 1 ] && _s="sudo"
  limite ssh -tt $SSHOPTS "$U@$ALVO" \
    "$_s /bin/sh $_f $XT 2>$_f.err; r=\$?; rm -f $_f $_f.err; exit \$r" \
    < /dev/null > "$O.bruto" 2>> "$E"
  _r=$?
  # O pty entrega \r\n e pode trazer o "lecture" do sudo: mantem so o CSV
  tr -d '\r' < "$O.bruto" | awk 'f || $0=="categoria,item,chave,valor" {f=1; print}' > "$O"
  rm -f "$O.bruto"
  return $_r
}

# Traduz o stderr num motivo acionavel
classificar() {
  # minusculas: o sudo antigo escreve "Illegal option", o novo "illegal option"
  _m=$(tr -d '\r' < "$E" 2>/dev/null | tr '\n' ' ' | tr 'A-Z' 'a-z')
  case "$1" in 124|137) echo "timeout_execucao"; return ;; esac
  case "$_m" in
    *"could not resolve"*|*"name or service not known"*|*"nodename nor servname"*|*"not known"*|*"temporary failure in name resolution"*) echo "dns_nao_resolve" ;;
    *"banner exchange"*)                                              echo "conexao_sem_banner" ;;
    *"connection timed out"*|*"operation timed out"*|*"timed out"*)   echo "conexao_timeout" ;;
    *"connection refused"*)                                           echo "conexao_recusada" ;;
    *"no route to host"*|*"network is unreachable"*|*"unreachable"*)  echo "sem_rota" ;;
    *"host key verification failed"*|*"remote host identification"*) echo "host_key" ;;
    *"expired"*|*"change your password"*|*"password change required"*) echo "conta_expirada" ;;
    *"permission denied"*|*"authentication failed"*|*"too many authentication"*) echo "chave_recusada" ;;
    *"illegal option"*|*"invalid option"*|*"unknown option"*)          echo "sudo_sem_n" ;;
    *"must have a tty"*|*"requiretty"*|*"a terminal is required"*)     echo "sudo_requiretty" ;;
    *"password is required"*|*"no tty present"*|*"askpass"*)          echo "sudo_pede_senha" ;;
    *"not in the sudoers"*|*"not allowed to execute"*|*"may not run sudo"*) echo "sudo_sem_permissao" ;;
    *"read-only file system"*)                                        echo "tmp_somente_leitura" ;;
    *"no space left"*)                                                echo "tmp_sem_espaco" ;;
    *"exchange_identification"*|*"connection closed"*|*"connection reset"*|*"kex_exchange"*) echo "conexao_encerrada" ;;
    *)  case "$1" in 255) echo "ssh_falhou" ;; 0) echo "sem_dados" ;; *) echo "rc_$1" ;; esac ;;
  esac
}

INI=$(agora)

# Deteccao de Windows pelo TTL do ping. TTL inicial: Linux/AIX 64, Windows 128,
# Solaris e equipamentos de rede 255. Como o TTL so diminui no caminho, um valor
# entre 65 e 128 so pode ter partido de 128 -> Windows. Sem resposta ao ping, segue.
if [ "${TTL_CHECK:-1}" = "1" ]; then
  TTL=""; TTLALVO=""
  for ALVO in "$HOST" $IPS; do
    if [ "$HT" -eq 1 ]; then
      _pg=$(timeout 6 ping -c 1 -W 2 "$ALVO" 2>/dev/null || timeout 6 ping -c 1 "$ALVO" 2>/dev/null)
    else
      _pg=$(ping -c 1 -W 2 "$ALVO" 2>/dev/null || ping -c 1 "$ALVO" 2>/dev/null)
    fi
    TTL=$(printf '%s\n' "$_pg" | sed -n 's/.*[Tt][Tt][Ll]=\([0-9][0-9]*\).*/\1/p' | head -1)
    [ -n "$TTL" ] && { TTLALVO="$ALVO"; break; }
  done
  if [ -n "$TTL" ] && [ "$TTL" -gt 64 ] && [ "$TTL" -le 128 ]; then
    DUR=$(( $(agora) - INI )); [ "$DUR" -ge 0 ] 2>/dev/null || DUR=0
    echo "$HOST|WINDOWS|ttl=$TTL via $TTLALVO|$DUR|ttl" >> "$WD/status"
    echo "[WINDOWS] $HOST ttl=$TTL ($TTLALVO) - nao coletado" >&2
    exit 0
  fi
fi

VIA=""; MODO="padrao"; RC=1; CLS=""; TENTOU=""
for ALVO in "$HOST" $IPS; do
  TENTOU="$TENTOU $ALVO"
  [ "$ALVO" = "$HOST" ] && VIA="hostname" || VIA="ip:$ALVO"
  : > "$E"
  MODO="padrao"; modo_padrao; RC=$?
  [ "$RC" -eq 0 ] && [ -s "$O" ] && break
  CLS=$(classificar "$RC")
  case "$CLS" in
    dns_nao_resolve|conexao_timeout|conexao_sem_banner|conexao_recusada|sem_rota|conexao_encerrada)
      continue ;;                                   # tenta o proximo endereco
    sudo_sem_n)
      MODO="sem_n"; : > "$E"; modo_sem_n; RC=$?
      [ "$RC" -eq 0 ] && [ -s "$O" ] && break
      CLS=$(classificar "$RC")
      if [ "$CLS" = sudo_requiretty ]; then
        MODO="tty_sem_n"; : > "$E"; SEM_N=1 modo_tty; RC=$?
      fi
      break ;;
    sudo_requiretty)
      MODO="tty"; : > "$E"; modo_tty; RC=$?
      break ;;
    *) break ;;
  esac
done

FIM=$(agora)
DUR=$(( FIM - INI )); [ "$DUR" -ge 0 ] 2>/dev/null || DUR=0
[ "$MODO" = padrao ] || VIA="$VIA;$MODO"

if [ "$RC" -ne 0 ] || [ ! -s "$O" ]; then
  CLS=$(classificar "$RC")
  MSG=$(grep -v '^[[:space:]]*$' "$E" 2>/dev/null | head -1 | tr -d '\r' | tr ',' ' ' | cut -c1-110)
  REASON="$CLS"
  [ -n "$MSG" ] && REASON="$REASON: $MSG"
  [ "$TENTOU" != " $HOST" ] && REASON="$REASON [tentou:$TENTOU]"
  echo "$HOST|ERRO|$REASON|$DUR|$VIA" >> "$WD/status"
  echo "[FALHA] $HOST (${DUR}s) $REASON" >&2
else
  echo "$HOST|OK||$DUR|$VIA" >> "$WD/status"
  echo "[OK] $HOST (${DUR}s) via $VIA" >&2
fi
WEOF
chmod +x "$WORKDIR/worker.sh"

# ---------- monitor de progresso ----------
: > "$WORKDIR/status"
(
  while [ -f "$WORKDIR/.rodando" ]; do
    sleep 30
    [ -f "$WORKDIR/.rodando" ] || break
    D=$(wc -l < "$WORKDIR/status" 2>/dev/null | tr -d ' ')
    P=$(ps -ef 2>/dev/null | grep "[B]atchMode=yes" | grep -c "$SSH_USER@")
    echo "[PROGRESSO] $D/$TOTAL concluidos | $P conexoes ativas" >&2
  done
) &
MONPID=$!
touch "$WORKDIR/.rodando"

trap 'rm -f "$WORKDIR/.rodando"; kill $MONPID 2>/dev/null; echo "" >&2; echo "[AVISO] interrompido - resultados parciais preservados em $WORKDIR" >&2' INT TERM

# ---------- execucao paralela ----------
if [ "$HAS_XARGSP" -eq 1 ]; then
  xargs -P "$JOBS" -I{} "$WORKDIR/worker.sh" {} "$PAYLOAD" "$WORKDIR" "$SSH_USER" \
        "$CTIMEOUT" "$XTIMEOUT" "$HAS_TIMEOUT" < "$WORKDIR/hosts.lst"
else
  # Paralelismo em sh puro, para AIX. O "< /dev/null" e o descritor 9 impedem
  # que o ssh do worker consuma o stdin do laco e engula o resto da lista.
  ATIVOS=0; FEITOS=0
  exec 9< "$WORKDIR/hosts.lst"
  while read LINHA <&9; do
    [ -n "$LINHA" ] || continue
    "$WORKDIR/worker.sh" "$LINHA" "$PAYLOAD" "$WORKDIR" "$SSH_USER" \
        "$CTIMEOUT" "$XTIMEOUT" "$HAS_TIMEOUT" < /dev/null &
    ATIVOS=$((ATIVOS+1))
    if [ "$ATIVOS" -ge "$JOBS" ]; then
      wait
      FEITOS=$((FEITOS+ATIVOS)); ATIVOS=0
      echo "[PROGRESSO] $FEITOS/$TOTAL concluidos" >&2
    fi
  done
  exec 9<&-
  wait
fi

PRONTOS=$(ls "$WORKDIR/out" 2>/dev/null | wc -l | tr -d ' ')
_NWP=$(awk -F'|' '$2=="WINDOWS"' "$WORKDIR/status" 2>/dev/null | wc -l | tr -d ' ')
if [ "$PRONTOS" -lt $(( TOTAL - _NWP )) ]; then
  echo "[AVISO] $PRONTOS de $TOTAL hosts produziram arquivo de saida." >&2
fi

rm -f "$WORKDIR/.rodando"
kill $MONPID 2>/dev/null
trap - INT TERM

# ---------- consolidacao ----------
HDR=""
for f in "$WORKDIR"/out/*; do
  [ -s "$f" ] || continue
  HDR=$(head -1 "$f"); break
done

if [ -z "$HDR" ]; then
  echo "[FALHA] nenhum host retornou dados" >&2
  echo "hostname,categoria,item,chave,valor" > "$OUT"
else
  echo "hostname,$HDR" > "$OUT"
fi

for f in "$WORKDIR"/out/*; do
  [ -s "$f" ] || continue
  H=$(basename "$f")
  awk -v h="$H" 'NR>1 && NF {print h "," $0}' "$f" >> "$OUT"
done

ERRFILE="${OUT%.csv}_falhas.csv"
echo "hostname,motivo,duracao_s,via" > "$ERRFILE"
awk -F'|' '$2=="ERRO" {print $1 "," $3 "," $4 "," $5}' "$WORKDIR/status" >> "$ERRFILE"

WINFILE="${OUT%.csv}_windows.csv"
echo "hostname,evidencia" > "$WINFILE"
awk -F'|' '$2=="WINDOWS" {print $1 "," $3}' "$WORKDIR/status" >> "$WINFILE"
NWIN=$(awk -F'|' '$2=="WINDOWS"' "$WORKDIR/status" | wc -l | tr -d ' ')

# Identidade: o sistema que respondeu e o alvo pedido? DNS/IP reaproveitado leva a
# outro servidor, e os dados seriam arquivados com o nome errado.
IDFILE="${OUT%.csv}_identidade.csv"
echo "alvo,hostname_real" > "$IDFILE"
for f in "$WORKDIR"/out/*; do
  [ -s "$f" ] || continue
  A=$(basename "$f")
  R=$(awk -F, '$1=="meta" && $3=="hostname_so" {print $4; exit}' "$f")
  [ -n "$R" ] || continue
  a=$(printf '%s' "$A" | tr 'A-Z' 'a-z' | sed 's/\..*//; s/^t[45]-//')
  r=$(printf '%s' "$R" | tr 'A-Z' 'a-z' | sed 's/\..*//; s/^t[45]-//')
  [ "$a" = "$r" ] || echo "$A,$R" >> "$IDFILE"
done
NID=$(( $(wc -l < "$IDFILE" | tr -d ' ') - 1 ))

NOK=$(awk -F'|' '$2=="OK"'   "$WORKDIR/status" | wc -l | tr -d ' ')
NER=$(awk -F'|' '$2=="ERRO"' "$WORKDIR/status" | wc -l | tr -d ' ')
NLIN=$(( $(wc -l < "$OUT" | tr -d ' ') - 1 ))
NIP=$(awk -F'|' '$2=="OK" && $5 ~ /^ip:/' "$WORKDIR/status" | wc -l | tr -d ' ')
LENTO=$(awk -F'|' '{print $4"|"$1}' "$WORKDIR/status" | sort -rn | head -3 | tr '\n' ' ')

echo ""
echo "[RESUMO] hosts OK: $NOK | falhas: $NER | Windows (TTL, nao coletados): $NWIN | linhas no CSV: $NLIN"
[ "$NWIN" -gt 0 ] && echo "[RESUMO] Windows detectados: $WINFILE"
[ "$NID" -gt 0 ] && {
  echo "[AVISO] $NID alvo(s) responderam com OUTRO hostname (DNS/IP leva a outro servidor):"
  tail -n +2 "$IDFILE" | awk -F, '{printf "           %s -> %s\n", $1, $2}'
}
[ "$NIP" -gt 0 ] && {
  echo "[RESUMO] $NIP host(s) coletados via IP (hostname nao resolve ou nao conecta):"
  awk -F'|' '$2=="OK" && $5 ~ /^ip:/ {printf "           %s  (%s)\n", $1, $5}' "$WORKDIR/status"
  awk -F'|' '$2=="OK" && $5 ~ /^ip:/ {print $1}' "$WORKDIR/status" > "${OUT%.csv}_via_ip.txt"
}
NMODO=$(awk -F'|' '$2=="OK" && $5 ~ /;/' "$WORKDIR/status" | wc -l | tr -d ' ')
[ "$NMODO" -gt 0 ] && echo "[RESUMO] $NMODO host(s) coletados com fallback de sudo (sem -n ou requiretty)"
[ "$NER" -gt 0 ] && echo "[RESUMO] falhas por causa:"
awk -F'|' '$2=="ERRO" {split($3,a,":"); print a[1]}' "$WORKDIR/status" | sort | uniq -c | sort -rn |   awk '{printf "           %4d  %s\n", $1, $2}'
echo "[RESUMO] mais lentos (s|host): $LENTO"
echo "[RESUMO] dados:   $OUT"
echo "[RESUMO] falhas:  $ERRFILE"

[ "$KEEP" -eq 1 ] || rm -rf "$WORKDIR"
[ "$NER" -eq 0 ] || exit 3
exit 0
