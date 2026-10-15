#!/bin/sh
#
# coleta-automatica.sh - coleta nos servidores, importa no grafo e reconstroi o mapa.
#
# Junta o que era manual em tres passos:
#   1. collectors/unix/run_all.sh    coleta nos servidores por SSH
#   2. importacao                    publica os CSV em topology/facts/coleta-auto
#   3. user_script_topology.sh       reconstroi e publica o mapa
#
# Uso:
#   coleta-automatica.sh               coleta, importa e reconstroi
#   coleta-automatica.sh -i [DIR]      so importa uma coleta ja feita: a mais
#                                      recente em collectors/unix, ou DIR
#   coleta-automatica.sh -p            piloto: coleta 5 hosts e NAO importa
#   coleta-automatica.sh -s            estado da ultima execucao
#   coleta-automatica.sh -c            imprime a linha de agendamento (cron)
#
# Ajustes, por ambiente ou em topology/coleta.conf (sh, lido se existir):
#   COLETA_HOSTS     lista de servidores        (collectors/unix/servidores_unix.txt)
#   COLETA_JOBS      paralelismo do run_all     (8)
#   COLETA_LIMITE    teto de duracao em segundos (14400)
#   COLETA_MIN_PCT   so importa se ao menos este % dos hosts esperados respondeu (70)
#   COLETA_GUARDAR   quantas coletas manter em disco                              (3)
#   TOPO_MAX_EDGE    teto de conexoes por host e direcao                        (6000)
#   TOPO_LIMIAR_FANIN, SSH_USER           repassados ao coletor
#
# O mapa anterior so e trocado por uma coleta que passou na validacao: uma
# noite em que o SSH caiu nao esvazia o grafo.

set -u
umask 002
PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export PATH

# o script vive em <home>/topology/bin, o home fica dois niveis acima
if [ -z "${INPUTDIR:-}" ]; then
  INPUTDIR=$(cd "$(dirname "$0")/../.." && pwd)
fi
case "$INPUTDIR" in
  *[!A-Za-z0-9_./-]*) echo "coleta-auto: caminho com caracteres nao suportados: $INPUTDIR" >&2; exit 2 ;;
esac
export INPUTDIR

TOPO="$INPUTDIR/topology"
KIT="${TOPO_KIT:-$TOPO/collectors/unix}"
FACTS="$TOPO/facts"
DESTINO="$FACTS/coleta-auto"           # symlink para a versao em uso
VERSOES="$FACTS/coleta.d"
STATUS="$FACTS/coleta-auto.status"
LOG="$INPUTDIR/logs/topology-coleta.log"
HOOK="$TOPO/bin/user_script_topology.sh"
LOCK="$INPUTDIR/tmp/coleta-auto.lock"
CABECALHO="hostname,categoria,item,chave,valor"

CONF="${COLETA_CONF:-$TOPO/coleta.conf}"
# shellcheck disable=SC1090
[ -r "$CONF" ] && . "$CONF"

: "${COLETA_HOSTS:=$KIT/servidores_unix.txt}"
: "${COLETA_JOBS:=8}"
: "${COLETA_LIMITE:=14400}"
: "${COLETA_MIN_PCT:=70}"
: "${COLETA_GUARDAR:=3}"
: "${TOPO_MAX_EDGE:=6000}"
export TOPO_MAX_EDGE
[ -n "${TOPO_LIMIAR_FANIN:-}" ] && export TOPO_LIMIAR_FANIN

log() {
  { printf '%s coleta-auto: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; } 2>/dev/null
  printf 'coleta-auto: %s\n' "$*"
}

# ----------------------------------------------------------------- opcoes
MODO=completo
while getopts "ipsch" o; do
  case "$o" in
    i) MODO=importar ;;
    p) MODO=piloto ;;
    s) MODO=estado ;;
    c) MODO=cron ;;
    *) sed -n '2,31p' "$0"; exit 2 ;;
  esac
done
shift $((OPTIND - 1))
DIR_ARG="${1:-}"

if [ "$MODO" = estado ]; then
  if [ -r "$STATUS" ]; then
    cat "$STATUS"
  else
    echo "nenhuma execucao registrada ($STATUS)"
  fi
  exit 0
fi

if [ "$MODO" = cron ]; then
  eu=$(id -un)
  cat <<CRON
# /etc/cron.d/xorux-topologia - coleta noturna e importacao no grafo.
# Fora do minuto :00, que o ciclo de coleta do produto ja disputa.
# O usuario abaixo precisa ter a chave SSH sem senha de ${SSH_USER:-netuss}:
# e o mesmo que hoje roda ./run_all.sh a mao.
37 1 * * * $eu $TOPO/bin/coleta-automatica.sh >/dev/null 2>&1
CRON
  exit 0
fi

# ------------------------------------------------------------------ trava
pega_trava() {
  mkdir -p "$INPUTDIR/tmp" 2>/dev/null
  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid"
    return 0
  fi
  outro=$(cat "$LOCK/pid" 2>/dev/null)
  # kill -0 falha com EPERM quando o dono e outro usuario: /proc desempata
  if [ -n "$outro" ] && { kill -0 "$outro" 2>/dev/null || [ -d "/proc/$outro" ]; }; then
    return 1
  fi
  log "trava orfa (pid ${outro:-desconhecido}), removendo"
  rm -rf "${LOCK:?}"
  if mkdir "$LOCK" 2>/dev/null; then
    echo $$ > "$LOCK/pid"
    return 0
  fi
  return 1
}

if ! pega_trava; then
  log "outra execucao em andamento (pid $(cat "$LOCK/pid" 2>/dev/null)), saindo"
  exit 0
fi
trap 'rm -rf "${LOCK:?}"' EXIT
trap 'log "interrompido"; exit 130' INT TERM

# a saida do run_all tem uma linha por host e por coleta: sem teto, o log cresce
# sem parar. Mantem o fim, que e o que se consulta.
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG" 2>/dev/null || echo 0)" -gt 20971520 ]; then
  tail -n 50000 "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG" 2>/dev/null
fi

INICIO=$(date +%s)

# o estado e escrito sempre, de uma vez e por arquivo temporario: o CGI e o
# verifica-topologia.sh o leem enquanto isto ainda pode estar rodando
grava_estado() {
  # $1 resultado  $2 coleta  $3 hosts_ok  $4 esperados  $5 arquivos  $6 mapa  $7 detalhe
  mkdir -p "$FACTS" 2>/dev/null
  _t="$STATUS.$$"
  {
    echo "quando=$(date '+%Y-%m-%d %H:%M:%S')"
    echo "resultado=$1"
    echo "modo=$MODO"
    echo "coleta=$2"
    echo "hosts_ok=$3"
    echo "hosts_esperados=$4"
    echo "arquivos=$5"
    echo "mapa=$6"
    echo "duracao_s=$(( $(date +%s) - INICIO ))"
    echo "detalhe=$7"
  } > "$_t" 2>/dev/null && mv -f "$_t" "$STATUS" 2>/dev/null
}

lista_coletas() {
  ( cd "$KIT" && ls -dt coleta_[0-9]*_[0-9]*/ 2>/dev/null | sed 's|/$||' )
}

# So nomes que o proprio run_all gera. Roda tambem quando a coleta e rejeitada:
# sem isso, uma semana de noites ruins enchia o disco com coletas que nunca
# chegaram a ser importadas.
retencao_kit() {
  lista_coletas | tail -n +$((COLETA_GUARDAR + 1)) | while read -r c; do
    [ -n "$c" ] || continue
    rm -rf "${KIT:?}/$c" "${KIT:?}/$c.tar" "${KIT:?}/$c.tar.gz"
  done
}

falha() {
  log "FALHA: $1"
  [ "$MODO" = completo ] && retencao_kit
  grava_estado falha "${2:-}" "${3:-0}" "${4:-0}" 0 nao_alterado "$1"
  exit 1
}

# ----------------------------------------------------- pre-requisitos
[ -d "$KIT" ] || falha "kit de coleta nao encontrado: $KIT"
[ -r "$HOOK" ] || falha "gancho nao encontrado: $HOOK"
if [ "$MODO" != importar ]; then
  [ -r "$KIT/run_all.sh" ] || falha "run_all.sh nao encontrado em $KIT"
  [ -r "$COLETA_HOSTS" ]   || falha "lista de hosts ilegivel: $COLETA_HOSTS"
fi

# ------------------------------------------------------------- coleta
DIR=""
if [ "$MODO" = importar ]; then
  if [ -n "$DIR_ARG" ]; then
    case "$DIR_ARG" in
      /*) DIR="$DIR_ARG" ;;
      *)  DIR="$KIT/$DIR_ARG" ;;
    esac
  else
    nome=$(lista_coletas | head -1)
    [ -n "$nome" ] || falha "nenhuma coleta_* em $KIT para importar"
    DIR="$KIT/$nome"
  fi
  [ -d "$DIR" ] || falha "diretorio de coleta inexistente: $DIR"
  log "importando coleta existente: $DIR"
else
  ANTES=$(lista_coletas)
  ARGS="-j $COLETA_JOBS"
  [ "$MODO" = piloto ] && ARGS="-n $ARGS"
  log "coleta iniciada ($MODO): hosts=$COLETA_HOSTS jobs=$COLETA_JOBS limite=${COLETA_LIMITE}s TOPO_MAX_EDGE=$TOPO_MAX_EDGE"
  # o run_all sai 0 mesmo com falhas, entao o rc so diz algo sobre o teto
  # shellcheck disable=SC2086
  ( cd "$KIT" && HOSTS="$COLETA_HOSTS" timeout -k 30 "$COLETA_LIMITE" sh ./run_all.sh $ARGS ) \
      >> "$LOG" 2>&1
  rc=$?
  [ "$rc" -eq 124 ] && log "AVISO: a coleta passou do teto de ${COLETA_LIMITE}s e foi interrompida; os hosts ja coletados sao aproveitados se bastarem"

  # a coleta nova e a que NAO existia antes: se o run_all morreu cedo, a mais
  # recente em disco e a de ontem, e importa-la como se fosse de hoje seria
  # republicar dados velhos sem aviso
  for nome in $(lista_coletas); do
    if ! printf '%s\n' "$ANTES" | grep -qxF "$nome"; then
      DIR="$KIT/$nome"
      break
    fi
  done
  [ -n "$DIR" ] || falha "o run_all nao criou um diretorio de coleta novo (rc=$rc)"
  log "coleta concluida: $DIR"
fi

if [ "$MODO" = piloto ]; then
  log "piloto concluido; nada foi importado. Resultado em $DIR"
  exit 0
fi

COLETA=$(basename "$DIR")

# ---------------------------------------------------------- validacao
conta_hosts() {
  awk -F, 'NR>1 && $1!="" {print $1}' "$1" 2>/dev/null | sort -u | wc -l | tr -d ' '
}

# hosts que o coletor tinha como alvo: a lista, menos o que o proprio run_all
# descartou por ser Windows (detectado por TTL). A mesma regra de nome do
# collect.sh, senao comentarios e tracos contariam como servidor.
ALVOS=$(awk 'NF && $1 !~ /^#/ && $1 !~ /^-+$/ && $1 ~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/' \
          "$COLETA_HOSTS" 2>/dev/null | wc -l | tr -d ' ')
WIN=0
[ -r "$DIR/hosts_windows.csv" ] && WIN=$(( $(wc -l < "$DIR/hosts_windows.csv" | tr -d ' ') - 1 ))
[ "$WIN" -lt 0 ] && WIN=0
ESPERADOS=$(( ALVOS - WIN ))
[ "$ESPERADOS" -lt 1 ] && ESPERADOS=1

# so entram os seis CSV de coleta. O 00_consolidado repete todos eles, o 07_hmc
# tem outro formato, e *_falhas/*_windows/*_identidade nao sao fatos: qualquer
# um destes viraria no ou duplicaria sessoes no grafo
ARQUIVOS=""
for base in 01_sistema 02_rede 03_seguranca 04_storage 05_monitoracao 06_conexoes; do
  f="$DIR/$base.csv"
  [ -r "$f" ] || { log "aviso: $base.csv ausente em $COLETA"; continue; }
  cab=$(head -1 "$f" | tr -d '\r')
  if [ "$cab" != "$CABECALHO" ]; then
    log "aviso: $base.csv ignorado: cabecalho inesperado ($cab)"
    continue
  fi
  ARQUIVOS="$ARQUIVOS $base"
done
[ -n "$ARQUIVOS" ] || falha "nenhum CSV de coleta valido em $DIR" "$COLETA"
NARQ=$(printf '%s\n' $ARQUIVOS | wc -l | tr -d ' ')

# a base de comparacao e o sistema, que todo host responde; sem ele, o maior
if [ -r "$DIR/01_sistema.csv" ]; then
  HOSTS_OK=$(conta_hosts "$DIR/01_sistema.csv")
else
  HOSTS_OK=0
  for base in $ARQUIVOS; do
    n=$(conta_hosts "$DIR/$base.csv")
    [ "$n" -gt "$HOSTS_OK" ] && HOSTS_OK=$n
  done
fi

if [ $(( HOSTS_OK * 100 )) -lt $(( ESPERADOS * COLETA_MIN_PCT )) ]; then
  falha "so $HOSTS_OK de $ESPERADOS hosts responderam (minimo ${COLETA_MIN_PCT}%): o mapa anterior foi mantido. Veja $DIR/hosts_com_falha.txt" \
        "$COLETA" "$HOSTS_OK" "$ESPERADOS"
fi
log "validacao ok: $HOSTS_OK de $ESPERADOS hosts, $NARQ arquivo(s)"

# --------------------------------------------------------- importacao
mkdir -p "$VERSOES" || falha "nao consegui criar $VERSOES" "$COLETA"
ts=${COLETA#coleta_}
NOVA="$VERSOES/$ts"
[ -e "$NOVA" ] && NOVA="$VERSOES/$ts-r$$"
mkdir -p "$NOVA" || falha "nao consegui criar $NOVA" "$COLETA"

for base in $ARQUIVOS; do
  cp "$DIR/$base.csv" "$NOVA/$base.csv" || { rm -rf "${NOVA:?}"; falha "copia de $base.csv falhou" "$COLETA"; }
done

dono=$(ls -ld "$INPUTDIR" | awk '{print $3}')
grupo=$(ls -ld "$INPUTDIR" | awk '{print $4}')
if [ "$(id -u)" = 0 ]; then
  chown -R "$dono:$grupo" "$NOVA" 2>/dev/null
fi
chmod -R g+rX,o+rX "$NOVA" 2>/dev/null

# o builder le facts/*/*.csv, e o glob atravessa o symlink. Trocar o symlink e
# um unico rename: o builder ve a coleta antiga inteira ou a nova inteira,
# nunca uma pasta pela metade nem um instante sem pasta
if [ -e "$DESTINO" ] && [ ! -L "$DESTINO" ]; then
  rm -rf "${NOVA:?}"
  falha "$DESTINO existe e nao e um link; mova-o para outro nome" "$COLETA"
fi
TMPL="$FACTS/.coleta-auto.novo"
rm -f "$TMPL"
ln -s "coleta.d/$(basename "$NOVA")" "$TMPL" || falha "nao consegui criar o link" "$COLETA"
if ! mv -T "$TMPL" "$DESTINO" 2>/dev/null; then
  rm -f "$DESTINO"
  mv "$TMPL" "$DESTINO" || falha "nao consegui publicar $DESTINO" "$COLETA"
fi
[ "$(id -u)" = 0 ] && chown -h "$dono:$grupo" "$DESTINO" 2>/dev/null
log "coleta importada em $DESTINO -> $(readlink "$DESTINO")"

# CSV de coleta subidos pela tela de importacao entram no mapa alem destes:
# as sessoes seriam contadas duas vezes. Avisa, nao apaga - sao do usuario
if [ -d "$TOPO/uploads" ]; then
  for u in "$TOPO"/uploads/*.csv; do
    [ -f "$u" ] || continue
    if head -1 "$u" | tr -d '\r' | grep -q 'categoria,item,chave,valor$'; then
      log "aviso: $u e uma coleta subida pela tela e se soma a esta importacao; remova-o para nao contar as sessoes duas vezes"
    fi
  done
fi

# ------------------------------------------------------ reconstrucao
# O sucesso e confirmado, nao presumido. Procurar so as falhas que o gancho
# sabe anunciar deixava passar o gancho que nem chegou a rodar - sem permissao
# para abri-lo, sem python3 - e o orquestrador registrava "mapa publicado" com o
# mapa de ontem na tela. O gancho escreve "mapa publicado em N local(is)" em
# topology.log quando publica; se essa contagem nao subiu, nao publicou.
TLOG="$INPUTDIR/logs/topology.log"
conta_pub() {
  _n=$(grep -c 'topology: mapa publicado em' "$TLOG" 2>/dev/null)
  echo "${_n:-0}"
}
PUB_ANTES=$(conta_pub)

SAIDA="$INPUTDIR/tmp/coleta-auto.$$.out"
log "reconstruindo o mapa"
if [ "$(id -u)" = 0 ] && [ "$dono" != root ]; then
  ${COLETA_SU:-su} -s /bin/sh "$dono" -c "INPUTDIR='$INPUTDIR' TOPO_ESPERAR=900 sh '$HOOK'" > "$SAIDA" 2>&1
else
  INPUTDIR="$INPUTDIR" TOPO_ESPERAR=900 sh "$HOOK" > "$SAIDA" 2>&1
fi
RC_GANCHO=$?
{ cat "$SAIDA" >> "$LOG"; } 2>/dev/null

if [ "$RC_GANCHO" -ne 0 ]; then
  MAPA=gancho_falhou
elif grep -q "nao passou na validacao" "$SAIDA"; then
  MAPA=recusado
elif grep -q "NAO consegui publicar" "$SAIDA"; then
  MAPA=nao_publicado
elif grep -q "outra reconstrucao em andamento" "$SAIDA"; then
  MAPA=adiado
elif [ "$(conta_pub)" -gt "$PUB_ANTES" ]; then
  MAPA=publicado
else
  MAPA=sem_confirmacao
fi
rm -f "$SAIDA"

# --------------------------------------------------------- retencao
# so nomes que o proprio run_all gera, e nunca a versao em uso
atual=$(readlink "$DESTINO" 2>/dev/null | sed 's|.*/||')
ls -1 "$VERSOES" 2>/dev/null | sort -r | tail -n +$((COLETA_GUARDAR + 1)) | while read -r v; do
  [ "$v" = "$atual" ] && continue
  [ -n "$v" ] && rm -rf "${VERSOES:?}/$v"
done
# importar uma coleta escolhida a mao nao pode apagar coletas: a que o usuario
# apontou pode ser justamente a mais antiga
[ "$MODO" = completo ] && retencao_kit

case "$MAPA" in
  publicado)
    log "concluido: $HOSTS_OK hosts, mapa publicado"
    grava_estado ok "$COLETA" "$HOSTS_OK" "$ESPERADOS" "$NARQ" publicado "" ;;
  *)
    log "AVISO: a importacao foi feita mas o mapa ficou '$MAPA' (rc do gancho: $RC_GANCHO) - veja logs/topology.log e logs/topology-coleta.log"
    grava_estado atencao "$COLETA" "$HOSTS_OK" "$ESPERADOS" "$NARQ" "$MAPA" "o mapa nao foi publicado: $MAPA"
    exit 1 ;;
esac
exit 0
