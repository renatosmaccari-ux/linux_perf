#!/bin/sh
# ============================================================
# run_all.sh - Orquestra todas as coletas em sequencia
#
#   ./run_all.sh              executa tudo
#   ./run_all.sh -n           piloto: so os 5 primeiros hosts
#   ./run_all.sh -j 12        ajusta paralelismo
#   ./run_all.sh -s storage   executa apenas um payload
#   ./run_all.sh -H           inclui a coleta nas HMCs
#
# Cada payload ja paraleliza internamente entre hosts. Rodar os
# payloads em sequencia evita saturar o bastion e a rede de gerencia.
# ============================================================
set -u

HOSTS="${HOSTS:-servidores_unix.txt}"
JOBS=8
PILOTO=0
SO_UM=""
COM_HMC=0
TS=$(date '+%Y%m%d_%H%M%S')
DEST="coleta_$TS"
# vazio por padrao: informe com HMC_LIST="ip1 ip2" ou -l lista.txt
HMC_LIST="${HMC_LIST:-}"
HMC_USER="${HMC_USER:-hscroot}"

while getopts "nj:s:l:Hh" o; do
  case "$o" in
    n) PILOTO=1 ;;
    j) JOBS="$OPTARG" ;;
    s) SO_UM="$OPTARG" ;;
    l) HOSTS="$OPTARG" ;;
    H) COM_HMC=1 ;;
    *) sed -n '2,14p' "$0"; exit 2 ;;
  esac
done

# --- pre-requisitos ---
for f in collect.sh payload_sistema.sh payload_rede.sh payload_seguranca.sh \
         payload_storage.sh payload_monitoracao.sh payload_conexoes.sh; do
  [ -r "$f" ] || { echo "[FALHA] arquivo ausente: $f" >&2; exit 1; }
done
[ -r "$HOSTS" ] || { echo "[FALHA] lista de hosts ausente: $HOSTS" >&2; exit 1; }
chmod +x collect.sh payload_*.sh 2>/dev/null

mkdir -p "$DEST" || exit 1
LOG="$DEST/execucao.log"

if [ "$PILOTO" -eq 1 ]; then
  awk 'NF && $1 !~ /^#/ {print $1}' "$HOSTS" | head -5 > "$DEST/hosts_piloto.txt"
  HOSTS="$DEST/hosts_piloto.txt"
  echo "[INFO] MODO PILOTO - 5 hosts"
fi

NHOST=$(awk 'NF && $1 !~ /^#/' "$HOSTS" | wc -l | tr -d ' ')
echo "[INFO] destino: $DEST | hosts: $NHOST | jobs: $JOBS" | tee "$LOG"
echo "[INFO] inicio: $(date)" | tee -a "$LOG"

# nome | timeout_exec | jobs_override (0 = usa JOBS)
# nome | timeout_por_host(s) | jobs_override (0 = usa JOBS)
# Solaris alonga storage (zpool/mpathadm/fcinfo) e seguranca (passwd -s por usuario).
TAREFAS="01:sistema:240:0
02:rede:240:0
03:seguranca:360:0
04:storage:480:6
05:monitoracao:300:0
06:conexoes:360:6"

FALHA_GERAL=0
echo "$TAREFAS" | while IFS=: read NUM NOME XT JOV; do
  [ -n "$NOME" ] || continue
  [ -n "$SO_UM" ] && [ "$SO_UM" != "$NOME" ] && continue
  J="$JOBS"; [ "$JOV" -gt 0 ] 2>/dev/null && J="$JOV"
  OUT="$DEST/${NUM}_${NOME}.csv"
  echo "" | tee -a "$LOG"
  echo "===== [$NUM] $NOME (jobs=$J timeout=${XT}s) =====" | tee -a "$LOG"
  ./collect.sh -p "payload_${NOME}.sh" -o "$OUT" -l "$HOSTS" -j "$J" -T "$XT" -k 2>&1 | tee -a "$LOG"
  RC=$?
  [ "$RC" -eq 0 ] || echo "[AVISO] $NOME terminou com falhas parciais (rc=$RC)" | tee -a "$LOG"
done

# --- HMCs: coletor roda NO BASTION (shell da HMC e restrito) ---
if [ "$COM_HMC" -eq 1 ] && [ -z "$SO_UM" ]; then
  echo "" | tee -a "$LOG"
  echo "===== [07] HMC =====" | tee -a "$LOG"
  if [ -r hmc_collect.sh ]; then
    printf '%s\n' $HMC_LIST > "$DEST/hmcs.txt"
    HMC_USER="$HMC_USER" sh ./hmc_collect.sh -o "$DEST/07_hmc.csv" \
      -l "$DEST/hmcs.txt" -u "$HMC_USER" 2>&1 | tee -a "$LOG"
  else
    echo "[FALHA] hmc_collect.sh nao encontrado" | tee -a "$LOG"
  fi
fi

# --- resumo consolidado ---
echo "" | tee -a "$LOG"
echo "===== RESUMO =====" | tee -a "$LOG"
printf '%-22s %10s %10s %10s\n' "ARQUIVO" "LINHAS" "HOSTS_OK" "FALHAS" | tee -a "$LOG"
for f in "$DEST"/*.csv; do
  case "$f" in *_falhas.csv|*_windows.csv|*_identidade.csv) continue ;; esac
  [ -r "$f" ] || continue
  L=$(( $(wc -l < "$f" | tr -d ' ') - 1 ))
  H=$(awk -F, 'NR>1{print $1}' "$f" | sort -u | wc -l | tr -d ' ')
  FF="${f%.csv}_falhas.csv"
  E=0; [ -r "$FF" ] && E=$(( $(wc -l < "$FF" | tr -d ' ') - 1 ))
  printf '%-22s %10s %10s %10s\n' "$(basename "$f")" "$L" "$H" "$E" | tee -a "$LOG"
done

# consolidado unico (mesmo esquema em todos)
CONS="$DEST/00_consolidado.csv"
echo "origem,hostname,categoria,item,chave,valor" > "$CONS"
for f in "$DEST"/0[1-6]_*.csv; do
  case "$f" in *_falhas.csv|*_windows.csv|*_identidade.csv) continue ;; esac
  [ -r "$f" ] || continue
  B=$(basename "$f" .csv)
  awk -v o="$B" 'NR>1 && NF {print o "," $0}' "$f" >> "$CONS"
done
echo "" | tee -a "$LOG"
echo "[INFO] consolidado: $CONS ($(( $(wc -l < "$CONS" | tr -d ' ') - 1 )) linhas)" | tee -a "$LOG"

# hosts que falharam em alguma coleta
UF="$DEST/hosts_com_falha.txt"
cat "$DEST"/*_falhas.csv 2>/dev/null | awk -F, 'NR>1 && $1!="hostname"{print $1}' | sort -u > "$UF"
NF_=$(wc -l < "$UF" | tr -d ' ')
echo "[INFO] hosts com ao menos uma falha: $NF_ (ver $UF)" | tee -a "$LOG"

# Windows detectados por TTL (nao coletados) e alvos que responderam com outro hostname
UW="$DEST/hosts_windows.csv"
echo "hostname,evidencia" > "$UW"
cat "$DEST"/*_windows.csv 2>/dev/null | awk -F, '$1!="hostname" && NF' | sort -u -t, -k1,1 >> "$UW"
NW_=$(( $(wc -l < "$UW" | tr -d ' ') - 1 ))
echo "[INFO] Windows detectados por TTL (nao coletados): $NW_ (ver $UW)" | tee -a "$LOG"
UI="$DEST/identidade_divergente.csv"
echo "alvo,hostname_real" > "$UI"
cat "$DEST"/*_identidade.csv 2>/dev/null | awk -F, '$1!="alvo" && NF' | sort -u >> "$UI"
NI_=$(( $(wc -l < "$UI" | tr -d ' ') - 1 ))
[ "$NI_" -gt 0 ] && echo "[AVISO] $NI_ alvo(s) responderam com outro hostname (ver $UI)" | tee -a "$LOG"
echo "[INFO] fim: $(date)" | tee -a "$LOG"

# pacote para envio
if command -v tar >/dev/null 2>&1; then
  tar cf "${DEST}.tar" "$DEST" 2>/dev/null && \
    { command -v gzip >/dev/null 2>&1 && gzip -f "${DEST}.tar"; }
  echo "[INFO] pacote: ${DEST}.tar${?:+.gz}" | tee -a "$LOG"
fi
exit 0
