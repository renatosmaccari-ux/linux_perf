#!/bin/sh
# ============================================================
# nim_check.sh v2 - Verifica os objetos NIM: quais existem de fato, onde vivem
#                   e se ja estao no inventario.
#
# PORTAVEL AIX: sem xargs -P, sem timeout, sem getent, sem ping -w.
# Roda no NIM master (AIX) ou no bastion (Linux).
#
#   sudo ./nim_check.sh -o nim_check.csv                    # usa lsnim -t machines
#   ./nim_check.sh -o nim_check.csv -l lista.txt            # usa lista pronta
#   ./nim_check.sh -o nim_check.csv -k inventario_atual.txt # marca quem ja esta no inventario
#   ./nim_check.sh -o nim_check.csv -d                      # diagnostico: mostra cada etapa
#
# Para cada objeto responde: estado NIM, DNS, ping, SSH e - o dado decisivo -
# o serial do frame e o nome da LPAR vistos de dentro do host.
# ============================================================
set -u
PATH="/usr/sbin:/usr/bin:/sbin:/bin:/usr/local/bin:$PATH"; export PATH

OUT="nim_check.csv"; LISTA=""; CONHECIDOS=""; U="${SSH_USER:-netuss}"; JOBS=8; CT=8; DBG=0

while getopts "o:l:k:u:j:t:dh" o; do
  case "$o" in
    o) OUT="$OPTARG" ;; l) LISTA="$OPTARG" ;; k) CONHECIDOS="$OPTARG" ;;
    u) U="$OPTARG" ;; j) JOBS="$OPTARG" ;; t) CT="$OPTARG" ;; d) DBG=1 ;;
    *) echo "uso: $0 -o saida.csv [-l lista.txt] [-k inventario.txt] [-u user] [-j jobs] [-d]" >&2; exit 2 ;;
  esac
done
dbg() { [ "$DBG" -eq 1 ] && echo "[DEBUG] $*" >&2; return 0; }

# Rodar o script inteiro sob sudo faz o ssh usar as chaves do ROOT, nao as suas.
# A listagem do NIM ja e elevada internamente quando preciso.
if [ "$(id -u)" = "0" ] && [ -n "${SUDO_USER:-}" ]; then
  echo "[AVISO] rodando como root via sudo: o ssh usara as chaves de root, nao de $SUDO_USER." >&2
  echo "        Se as conexoes falharem, rode SEM sudo — a listagem do NIM e elevada sozinha." >&2
  [ "$U" = "netuss" ] && U="$SUDO_USER"
fi

# Workdir unico por execucao: evita colisao com sobra de uma rodada feita
# como root (o AIX nao deixa o usuario comum remover diretorio de outro dono).
WD="${OUT%.csv}.work.$$"
rm -rf "$WD" 2>/dev/null
if ! mkdir -p "$WD/r" 2>/dev/null; then
  echo "[FALHA] nao consegui criar o diretorio de trabalho: $WD" >&2
  echo "        Verifique permissao de escrita em $(pwd)" >&2
  exit 1
fi
if ! : > "$WD/.teste" 2>/dev/null; then
  echo "[FALHA] $WD existe mas nao e gravavel pelo usuario atual." >&2
  echo "        Provavel sobra de execucao com sudo. Remova com:  sudo rm -rf ${OUT%.csv}.work*" >&2
  exit 1
fi
rm -f "$WD/.teste"
# limpa sobras de execucoes anteriores que pertencam a este usuario
for velho in "${OUT%.csv}".work "${OUT%.csv}".work.*; do
  [ "$velho" = "$WD" ] && continue
  [ -d "$velho" ] || continue
  rm -rf "$velho" 2>/dev/null || echo "[AVISO] sobra nao removivel (outro dono): $velho — use sudo rm -rf $velho" >&2
done

# ---------- 1. origem da lista ----------
if [ -n "$LISTA" ] && [ -r "$LISTA" ]; then
  awk 'NF && $1 !~ /^#/ {print $1}' "$LISTA" > "$WD/raw"
  echo "[INFO] lista: $LISTA"
else
  # Deteccao do lsnim sem depender de "command -v": no AIX o binario costuma
  # ser executavel so por root, e command -v devolve falso para o usuario comum.
  LSNIM=""
  for c in lsnim /usr/sbin/lsnim /usr/lpp/bos.sysmgt/nim/methods/lsnim; do
    if [ -x "$c" ] || [ -f "$c" ] || command -v "$c" >/dev/null 2>&1; then LSNIM="$c"; break; fi
  done
  if [ -z "$LSNIM" ]; then
    echo "[FALHA] lsnim nao encontrado e nenhuma lista informada." >&2
    echo "        Gere a lista e use -l:" >&2
    echo "          sudo lsnim -t standalone | awk '{print \$1}' > nim.txt" >&2
    echo "          ./nim_check.sh -o nim_check.csv -l nim.txt -k inventario.txt" >&2
    rm -rf "$WD"; exit 1
  fi
  dbg "lsnim em: $LSNIM"

  # Tenta as combinacoes na ordem que mais funciona em campo.
  # "machines" e CLASSE; o TIPO e standalone. Nem toda versao aceita -c.
  USADO=""
  for arg in "-t standalone" "-c machines" "-t diskless" "-t dataless"; do
    for pfx in "" "sudo -n"; do
      $pfx $LSNIM $arg > "$WD/lsnim.out" 2>"$WD/lsnim.err"
      dbg "[$pfx $LSNIM $arg] -> $(wc -l < "$WD/lsnim.out" | tr -d ' ') linhas"
      if [ -s "$WD/lsnim.out" ]; then
        USADO="$pfx $LSNIM $arg"
        cat "$WD/lsnim.out" >> "$WD/raw.all"
        break
      fi
    done
    [ -n "$USADO" ] && [ "$arg" = "-c machines" ] && break
  done
  if [ ! -s "$WD/raw.all" ]; then
    echo "[FALHA] nao consegui listar os objetos NIM." >&2
    [ -s "$WD/lsnim.err" ] && { echo "        ultimo stderr:" >&2; sed 's/^/        /' "$WD/lsnim.err" >&2; }
    echo "        Se 'sudo lsnim -t standalone' funciona no seu shell, gere a lista e use -l:" >&2
    echo "          sudo lsnim -t standalone | awk '{print \$1}' > nim.txt" >&2
    echo "          ./nim_check.sh -o nim_check.csv -l nim.txt -k inventario.txt" >&2
    rm -rf "$WD"; exit 1
  fi
  awk '{print $1}' "$WD/raw.all" > "$WD/raw"
  echo "[INFO] lista obtida de: $USADO ($(wc -l < "$WD/raw" | tr -d ' ') linhas)"
fi

# limpeza: descarta 'master', cabecalhos e tokens invalidos. sort -u sem -f
# (o -f combinado com -u nao e confiavel em todo sort; a dedup case-insensitive
#  e feita depois, em awk).
awk '{ h=$1
       if (h=="" || h=="master" || h=="machines") next
       if (h !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/) next
       k=tolower(h); if (!(k in seen)) { seen[k]=1; print h }
     }' "$WD/raw" > "$WD/objs"
TOT=$(wc -l < "$WD/objs" | tr -d ' ')
dbg "apos limpeza: $TOT objetos"
if [ "$TOT" -eq 0 ]; then
  echo "[FALHA] lista vazia apos limpeza. Primeiras linhas do que foi lido:" >&2
  head -5 "$WD/raw" | sed 's/^/        /' >&2
  exit 1
fi

# ---------- 2. detalhes do NIM ----------
: > "$WD/nimdet"
LS="${LSNIM:-lsnim}"
if [ -n "${LSNIM:-}" ] || command -v lsnim >/dev/null 2>&1; then
  while read n; do
    d=$($LS -l "$n" 2>/dev/null)
    [ -n "$d" ] || d=$(sudo -n $LS -l "$n" 2>/dev/null)
    if [ -z "$d" ]; then echo "$n|ausente|||" >> "$WD/nimdet"; continue; fi
    st=$(echo "$d" | awk -F= '/Mstate/{gsub(/^[ \t]*/,"",$2); print $2; exit}')
    cs=$(echo "$d" | awk -F= '/[ \t]state[ \t]*=/{gsub(/^[ \t]*/,"",$2); print $2; exit}')
    pl=$(echo "$d" | awk -F= '/platform/{gsub(/^[ \t]*/,"",$2); print $2; exit}')
    # if1 = <rede> <hostname da interface> <mac>  -> queremos o hostname
    ip=$(echo "$d" | awk -F= '/if1/{n=split($2,a," "); if(n>=2) print a[2]; exit}')
    echo "$n|${st:-n/d}|${cs:-n/d}|${pl:-n/d}|${ip:-}" >> "$WD/nimdet"
  done < "$WD/objs"
  echo "[INFO] detalhes NIM lidos para $(wc -l < "$WD/nimdet" | tr -d ' ') objetos"
fi

# ---------- 3. worker ----------
cat > "$WD/w.sh" << 'WEOF'
#!/bin/sh
PATH="/usr/sbin:/usr/bin:/sbin:/bin:$PATH"; export PATH
N="$1"; WD="$2"; U="$3"; CT="$4"

# resolucao de nome portavel: host, nslookup ou /etc/hosts
IP=""
if command -v host >/dev/null 2>&1; then
  IP=$(host "$N" 2>/dev/null | awk '/has address|is [0-9]/{for(i=1;i<=NF;i++) if($i ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/){print $i; exit}}')
fi
if [ -z "$IP" ] && command -v nslookup >/dev/null 2>&1; then
  IP=$(nslookup "$N" 2>/dev/null | awk '/^Address/{a=$NF} END{if(a ~ /^[0-9]+\./) print a}')
fi
[ -n "$IP" ] || IP=$(awk -v n="$N" 'tolower($2)==tolower(n) || tolower($3)==tolower(n) {print $1; exit}' /etc/hosts 2>/dev/null)
DNS=sim; [ -n "$IP" ] || { DNS=NAO; IP=""; }

# ping com watchdog proprio (AIX nao tem -w nem o utilitario timeout)
PING=nao
if [ -n "$IP" ]; then
  ( ping -c 1 "$IP" >/dev/null 2>&1 < /dev/null ) &
  PP=$!
  ( sleep 4; kill -9 $PP 2>/dev/null ) >/dev/null 2>&1 &
  WP=$!
  wait $PP 2>/dev/null && PING=sim
  kill -9 $WP 2>/dev/null
fi

SSH=nao; SER=""; MOD=""; LPAR=""; SO=""; HOSTSO=""
if [ "$PING" = sim ]; then
  R=$(ssh -n -q -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ConnectTimeout="$CT" -o ConnectionAttempts=1 \
        "$U@$IP" 'uname -n; uname -M 2>/dev/null; uname -L 2>/dev/null; oslevel -s 2>/dev/null; sudo -n lsattr -El sys0 -a systemid 2>/dev/null' 2>/dev/null)
  if [ -n "$R" ]; then
    SSH=sim
    HOSTSO=$(echo "$R" | sed -n 1p)
    MOD=$(echo "$R"    | sed -n 2p | sed 's/.*,//')   # uname -M traz "IBM,9043-MRX"
    LL=$(echo "$R"     | sed -n 3p)
    SO=$(echo "$R"     | sed -n 4p)
    RAW=$(echo "$R"    | sed -n 5p | awk '{print $2}')
    LPAR=$(echo "$LL"  | cut -d' ' -f2-)
    SER=$(echo "$RAW"  | sed 's/.*,//' | awk '{ if (length($0)>7) print substr($0,length($0)-6); else print $0 }')
  fi
fi
# limpa virgulas e tabs de qualquer campo, para nao quebrar o CSV nem o cut
lim() { echo "$1" | tr ',\t' '; ' | tr -d '\r'; }
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$N" "$IP" "$DNS" "$PING" "$SSH" "$(lim "$SER")" "$(lim "$MOD")" \
  "$(lim "$LPAR")" "$(lim "$SO")" > "$WD/r/$N"
WEOF
chmod +x "$WD/w.sh"

# ---------- 4. paralelismo portavel (o xargs do AIX nao tem -P) ----------
echo "[INFO] verificando $TOT objetos, $JOBS em paralelo"
ATIVOS=0; FEITOS=0
exec 9< "$WD/objs"
while read N <&9; do
  # < /dev/null: impede que qualquer comando do worker consuma o stdin do laco
  "$WD/w.sh" "$N" "$WD" "$U" "$CT" < /dev/null &
  ATIVOS=$((ATIVOS+1))
  if [ "$ATIVOS" -ge "$JOBS" ]; then
    wait
    FEITOS=$((FEITOS+ATIVOS)); ATIVOS=0
    echo "[PROGRESSO] $FEITOS/$TOT"
  fi
done
exec 9<&-
wait
echo "[PROGRESSO] $TOT/$TOT concluido"

PRONTOS=$(ls "$WD/r" 2>/dev/null | wc -l | tr -d ' ')
if [ "$PRONTOS" -lt "$TOT" ]; then
  echo "[AVISO] apenas $PRONTOS de $TOT objetos produziram resultado." >&2
  echo "        Rode novamente; se persistir, use -j 1 para isolar o problema." >&2
fi

# ---------- 5. consolidacao ----------
echo "objeto,ip,resolve_dns,ping,ssh,frame_serial,modelo,lpar_nome,oslevel,nim_mstate,nim_state,nim_platform,nim_if1,ja_no_inventario" > "$OUT"
while read N; do
  L=$(cat "$WD/r/$N" 2>/dev/null)
  IP=$(echo "$L"|cut -f2);  DNS=$(echo "$L"|cut -f3); PG=$(echo "$L"|cut -f4)
  SH=$(echo "$L"|cut -f5);  SER=$(echo "$L"|cut -f6); MOD=$(echo "$L"|cut -f7)
  LP=$(echo "$L"|cut -f8);  SO=$(echo "$L"|cut -f9)
  D=$(awk -F'|' -v n="$N" '$1==n{print $2"|"$3"|"$4"|"$5; exit}' "$WD/nimdet")
  cl() { echo "$1" | tr ',' ';' | tr -d '\r'; }
  M1=$(cl "$(echo "$D"|cut -d'|' -f1)"); M2=$(cl "$(echo "$D"|cut -d'|' -f2)")
  M3=$(cl "$(echo "$D"|cut -d'|' -f3)"); M4=$(cl "$(echo "$D"|cut -d'|' -f4)")
  INV=nao
  if [ -n "$CONHECIDOS" ] && [ -r "$CONHECIDOS" ]; then
    awk -v n="$N" 'BEGIN{r=1}
       { s=$1; sub(/_.*$/,"",s)
         if (tolower($1)==tolower(n) || tolower(s)==tolower(n)) r=0 }
       END{exit r}' "$CONHECIDOS" && INV=sim
  fi
  echo "$N,$IP,$DNS,$PG,$SH,$SER,$MOD,$LP,$SO,$M1,$M2,$M3,$M4,$INV" >> "$OUT"
done < "$WD/objs"

c() { awk -F, "NR>1 && $1" "$OUT" | wc -l | tr -d ' '; }
echo ""
echo "[RESUMO] objetos:          $TOT"
echo "[RESUMO] resolvem DNS:     $(c '$3=="sim"')"
echo "[RESUMO] respondem ping:   $(c '$4=="sim"')"
echo "[RESUMO] aceitam SSH:      $(c '$5=="sim"')"
echo "[RESUMO] ja no inventario: $(c '$14=="sim"')"
echo ""
echo "[RESUMO] seriais de frame (serial fora dos ja conhecidos = HMC nao escaneada):"
awk -F, 'NR>1 && $6!="" {print $6"  "$7}' "$OUT" | sort | uniq -c | sort -rn | sed 's/^/           /'
echo ""
echo "[RESUMO] nao respondem ao ping (candidatos a orfao no NIM):"
awk -F, 'NR>1 && $4!="sim" {print $1"  (dns="$3" mstate="$10")"}' "$OUT" | sed 's/^/           /'
echo ""
echo "[RESUMO] arquivo: $OUT"
rm -rf "$WD"
exit 0
