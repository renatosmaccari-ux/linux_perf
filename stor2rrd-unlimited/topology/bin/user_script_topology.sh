#!/bin/sh
#
# user_script_topology.sh - rebuild the dependency map at the end of a
# collection cycle.
#
# LPAR2RRD runs every bin/user_script*.sh at the end of load.sh, so this needs
# no patching of the product to be picked up. STOR2RRD has no such hook and is
# called from load.sh by an inserted line instead.
#
# Order matters: the inventory has to be re-read after the collectors have
# refreshed data/, and the graph built after the inventory.

# Este script vive em <home>/topology/bin/, portanto o home fica dois niveis
# acima - nao um. Com um so, rodado a mao, INPUTDIR virava <home>/topology e
# tudo passava a ser procurado em <home>/topology/topology/: o build gravava
# noutro sitio, a validacao dizia "nao existe" e o log ia para um ficheiro que
# ninguem le. Pela coleta nao se notava, porque o load.sh exporta INPUTDIR.
if [ -z "${INPUTDIR:-}" ]; then
  INPUTDIR=$(cd "$(dirname "$0")/../.." && pwd)
fi
export INPUTDIR

# Dois usuarios rodam este script: o do produto, pela coleta, e o do servidor
# web, pela importacao na GUI. Sem isto cada um cria arquivos que o outro nao
# consegue sobrescrever - foi assim que topologia.json acabou apache:apache e
# a coleta seguinte parou de conseguir regrava-lo. Com umask 002 os arquivos
# nascem gravaveis pelo grupo, e o setgid que o apply.sh poe nos diretorios
# faz esse grupo ser o mesmo para ambos.
umask 002

TOPO="$INPUTDIR/topology"
LOG="$INPUTDIR/logs/topology.log"

# Vai para o banner de cada execucao. Sem isto nao havia como saber, a partir
# do log, qual versao deste gancho correu: uma copia de instalacao que nao
# pegasse deixava o script antigo no lugar e o log parecia o de sempre, so com
# mensagens que a versao nova ja nao emite.
VERSAO="2026-10-08e"

# Nao basta o diretorio existir: dois usuarios rodam este script - o do produto
# pela coleta e o do servidor web pelo CGI de importacao - e o log pertence a um
# so. Testar a escrita de verdade, senao cada importacao despeja
# "Permission denied" no meio da saida e o log nao registra nada.
# o teste vai num subshell: ":" e um builtin especial, e em POSIX sh uma falha
# de redirecionamento num builtin especial encerra o shell - o script morria
# aqui sem dizer nada
if ! ( : >> "$LOG" ) 2>/dev/null; then
  echo "topology: sem escrita em $LOG (rodando como $(id -un));"
  echo "topology: o mapa e montado assim mesmo, mas sem registro. Para corrigir:"
  echo "topology:   touch $LOG && chmod g+w $LOG"
  LOG=/dev/null
fi

# python3 only: the builder reads files with an explicit encoding. The
# inventory extractor still runs on 2.7, but there is no point splitting them.
PY=""
# TOPO_PY permite apontar um python3 fora do PATH (SCL, /opt, ...): basta
# defini-la em etc/.magic, que o load.sh carrega.
for c in ${TOPO_PY:-} python3 /usr/bin/python3 /opt/freeware/bin/python3 \
         /opt/rh/rh-python36/root/usr/bin/python3 python; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)' 2>/dev/null; then
    PY=$c
    break
  fi
done
if [ -z "$PY" ]; then
  # visivel no load.out, nao so no log da topologia: sem isto o grafo fica
  # vazio e nada na tela diz por que
  echo "topology: nenhum python3 encontrado - o mapa de dependencias NAO foi"
  echo "topology: montado e continuara vazio. Instale python3 (yum install -y"
  echo "topology: python3) ou aponte TOPO_PY=/caminho/python3 em etc/.magic"
  # com data: sem ela nao da para saber se a linha e desta coleta ou de meses atras
  echo "$(date '+%Y-%m-%d %H:%M:%S') topology: nenhum python3 encontrado, mapa nao reconstruido" >> "$LOG"
  exit 0            # never fail the collection cycle over this
fi

mkdir -p "$TOPO/facts/conexoes" "$TOPO/uploads" 2>/dev/null

{
  echo "=== topology $(date) (gancho $VERSAO) ==="
  "$PY" "$TOPO/bin/topo-inventory.py" 2>&1
  "$PY" "$TOPO/bin/topo-build.py" "$TOPO" "$TOPO/topologia.json" 2>&1
} >> "$LOG" 2>&1

# Publica so um grafo que fez o parse, para uma execucao falha deixar o ultimo
# mapa bom. O motivo da recusa ia para /dev/null, e "build produced no valid
# JSON" nao distingue um JSON corrompido de um arquivo que nao pode ser lido,
# nem de um que nem chegou a ser gravado.
erro_json=""
if [ ! -f "$TOPO/topologia.json" ]; then
  erro_json="$TOPO/topologia.json nao existe - o build nao chegou a grava-lo"
elif [ ! -s "$TOPO/topologia.json" ]; then
  erro_json="$TOPO/topologia.json esta vazio"
else
  # so a mensagem, nao o traceback: a primeira linha de um traceback e
  # "Traceback (most recent call last):", que nao diz nada
  # encoding explicito: topo-build grava com ensure_ascii=False, ou seja UTF-8
  # cru, e open() sem encoding usa o locale. Sob o cron, sem LANG, o locale e
  # POSIX e o codec e ASCII - a leitura morria no primeiro acentuado com
  # UnicodeDecodeError e um mapa perfeitamente valido era recusado todo ciclo.
  erro_json=$("$PY" -c 'import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as f:
        json.load(f)
except Exception as e:
    sys.stderr.write("%s: %s" % (type(e).__name__, e))
' "$TOPO/topologia.json" 2>&1 >/dev/null)
fi

if [ -z "$erro_json" ]; then
  # A pagina busca topologia.json relativo a sua propria URL, ou seja, do
  # diretorio web - nao de topology/. Se esta copia falhar, o mapa novo existe
  # mas ninguem o ve.
  #
  # Ela falha justamente quando mais importa: o CGI de importacao roda como o
  # usuario do servidor web, e html/ pertence ao usuario do produto. Antes isto
  # era "cp ... 2>/dev/null" seguido de "map published" incondicional, de modo
  # que uma importacao dizia ter funcionado e a tela continuava igual.
  publicados=0
  falhas=""
  for d in "$INPUTDIR/html" "$INPUTDIR/www" "$WEBDIR"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    # sem -p: preservar o dono falharia para o usuario do servidor web, e o
    # que interessa e o conteudo
    if cp "$TOPO/topologia.json" "$d/topologia.json" 2>/dev/null; then
      publicados=$((publicados + 1))
    else
      falhas="$falhas $d"
    fi
  done

  if [ -n "$falhas" ]; then
    echo "topology: NAO consegui publicar o mapa em:$falhas"
    echo "topology: o mapa novo esta em $TOPO/topologia.json, mas a pagina le"
    echo "topology: do diretorio web - ela continuara mostrando o anterior."
    echo "topology: quem rodou isto foi $(id -un); para a importacao pela GUI"
    echo "topology: o arquivo precisa ser gravavel pelo usuario do servidor web:"
    for d in $falhas; do
      echo "topology:   chmod g+w $d/topologia.json"
    done
    echo "$(date '+%Y-%m-%d %H:%M:%S') topology: falha ao publicar em$falhas" >> "$LOG"
  fi
  if [ "$publicados" -gt 0 ]; then
    echo "$(date '+%Y-%m-%d %H:%M:%S') topology: mapa publicado em $publicados local(is)" >> "$LOG"
  fi
else
  echo "topology: o mapa novo nao passou na validacao, mantendo o anterior."
  echo "topology:   $erro_json"
  echo "topology: quem rodou isto foi $(id -un)."
  echo "$(date '+%Y-%m-%d %H:%M:%S') topology: recusado - $erro_json" >> "$LOG"
fi

exit 0
