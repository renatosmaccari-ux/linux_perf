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

INPUTDIR=${INPUTDIR:-$(cd "$(dirname "$0")/.." && pwd)}
export INPUTDIR

TOPO="$INPUTDIR/topology"
LOG="$INPUTDIR/logs/topology.log"
[ -d "$INPUTDIR/logs" ] || LOG=/dev/null

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
  echo "topology: nenhum python3 encontrado, mapa nao reconstruido" >> "$LOG"
  exit 0            # never fail the collection cycle over this
fi

mkdir -p "$TOPO/facts/conexoes" "$TOPO/uploads" 2>/dev/null

{
  echo "=== topology $(date) ==="
  "$PY" "$TOPO/bin/topo-inventory.py" 2>&1
  "$PY" "$TOPO/bin/topo-build.py" "$TOPO" "$TOPO/topologia.json" 2>&1
} >> "$LOG" 2>&1

# publish only a graph that parsed, so a failed run leaves the last good map
if [ -s "$TOPO/topologia.json" ] && \
   "$PY" -c 'import json,sys; json.load(open(sys.argv[1]))' "$TOPO/topologia.json" 2>/dev/null
then
  for d in "$INPUTDIR/html" "$INPUTDIR/www" "$WEBDIR"; do
    [ -n "$d" ] && [ -d "$d" ] && cp -p "$TOPO/topologia.json" "$d/topologia.json" 2>/dev/null
  done
  echo "topology: map published ($(date))" >> "$LOG"
else
  echo "topology: build produced no valid JSON, keeping the previous map" >> "$LOG"
fi

exit 0
