#!/bin/sh
# =============================================================================
# verifica-topologia.sh - diz o que da pagina Topologia esta instalado, o que
# falta e por que o grafo pode estar vazio.
#
# Uso, como lpar2rrd (ou stor2rrd):
#     sh verifica-topologia.sh
#     sh verifica-topologia.sh --corrigir     # ajusta permissoes e forca o menu
#
# INPUTDIR=/caminho sh verifica-topologia.sh   se nao for o padrao
# =============================================================================
set -u
CORRIGIR=0
[ "${1:-}" = "--corrigir" ] && CORRIGIR=1

INPUTDIR=${INPUTDIR:-}
if [ -z "$INPUTDIR" ]; then
  for d in /home/lpar2rrd/lpar2rrd /home/stor2rrd/stor2rrd; do
    [ -d "$d/bin" ] && INPUTDIR=$d && break
  done
fi
[ -n "$INPUTDIR" ] && [ -d "$INPUTDIR/bin" ] || {
  echo "nao achei a instalacao. Use: INPUTDIR=/caminho sh $0"; exit 1; }

FALTA=0
ok()    { printf "  [ ok ]  %s\n" "$1"; }
falta() { printf "  [FALTA] %s\n" "$1"; FALTA=$((FALTA+1)); }
aviso() { printf "  [ !! ]  %s\n" "$1"; }

echo "=========================================================="
echo " Topologia em $INPUTDIR"
echo "=========================================================="
echo
echo "-- arquivos --"
for f in html/topologia.html \
         topology/bin/topo-build.py topology/bin/topo-inventory.py \
         topology/bin/topo-db.py topology/bin/lpar2rrd.py \
         topology/bin/user_script_topology.sh \
         topology/cgi/topology_cgi.pl bin/user_script_topology.sh; do
  [ -f "$INPUTDIR/$f" ] && ok "$f" || falta "$f"
done
for d in lpar2rrd-cgi stor2rrd-cgi; do
  [ -d "$INPUTDIR/$d" ] || continue
  [ -f "$INPUTDIR/$d/topology.sh" ] && ok "$d/topology.sh" || falta "$d/topology.sh"
done

echo
echo "-- o grafo tem dados? --"
JS=""
for c in "$INPUTDIR/topology/topologia.json" "$INPUTDIR/html/topologia.json"; do
  [ -f "$c" ] || continue
  JS=$c
  n=$(tr -d ' \n' < "$c" | sed 's/.*"nodes":\[\([^]]*\)\].*/\1/' | tr ',' '\n' | grep -c '"id"' 2>/dev/null)
  tam=$(wc -c < "$c")
  if [ "$tam" -le 40 ]; then
    aviso "$(basename "$(dirname "$c")")/topologia.json: $tam bytes - grafo VAZIO"
  else
    ok "$(basename "$(dirname "$c")")/topologia.json: $tam bytes, ~$n no(s)"
  fi
done
[ -n "$JS" ] || falta "topologia.json (nenhum)"

echo
echo "-- python: os coletores precisam de python3 --"
ACHOU=""
for c in ${TOPO_PY:-} python3 /usr/bin/python3 /opt/freeware/bin/python3 \
         /opt/rh/rh-python36/root/usr/bin/python3 python; do
  command -v "$c" >/dev/null 2>&1 || continue
  v=$("$c" -c 'import sys;print("%d.%d"%sys.version_info[:2])' 2>/dev/null)
  maior=$("$c" -c 'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)' 2>/dev/null && echo sim || echo nao)
  if [ "$maior" = sim ]; then
    CAMINHO=$(command -v "$c")
    ok "$c = $v  em $CAMINHO"; ACHOU=$CAMINHO; break
  else
    aviso "$c = $v  (NAO serve: os scripts exigem 3.x)"
  fi
done
if [ -z "$ACHOU" ]; then
  falta "python3 - e por isto que o grafo fica vazio"
  echo
  echo "        O gancho bin/user_script_topology.sh procura python3, nao acha,"
  echo "        escreve 'no python3 found' em logs/topology.log e sai sem erro"
  echo "        para nao derrubar a coleta. Resultado: a pagina aparece, o grafo"
  echo "        fica em {\"nodes\":[],\"links\":[]}."
  echo
  echo "        Oracle Linux / RHEL 7:   yum install -y python3"
  echo "        se o repositorio nao tiver:  yum install -y rh-python36"
fi


# O verificador roda no seu shell; o gancho roda pelo cron, com PATH minimo e
# sem os perfis carregados. Nao basta existir python3: o gancho tem de achar.
if [ -n "$ACHOU" ]; then
  echo
  echo "-- o gancho INSTALADO acha este python3? --"
  G="$INPUTDIR/topology/bin/user_script_topology.sh"
  if [ -f "$G" ]; then
    if grep -q "TOPO_PY" "$G"; then
      ok "o gancho aceita TOPO_PY (versao nova)"
    else
      aviso "gancho antigo: nao aceita TOPO_PY nem procura o caminho do SCL"
    fi
    # a lista literal de candidatos do gancho instalado
    CAND=$(sed -n 's/^for c in \(.*\); do$/\1/p;s/^for c in \(.*\) \\$/\1/p' "$G" | head -1)
    echo "         candidatos do gancho: ${CAND:-?}"
    ENCONTRA=nao
    for c in $CAND; do
      case $c in '"'"'${TOPO_PY:-}'"'"'|'"'"'$'"'"'*) continue ;; esac
      command -v "$c" >/dev/null 2>&1 || continue
      "$c" -c '"'"'import sys;sys.exit(0 if sys.version_info[0]>=3 else 1)'"'"' 2>/dev/null \
        && { ENCONTRA=$(command -v "$c"); break; }
    done
    if [ "$ENCONTRA" = nao ]; then
      falta "o gancho NAO acha python3 com estes candidatos"
      echo "          python3 esta em: $ACHOU"
      echo "          Resolva com TOPO_PY em etc/.magic, que o load.sh carrega:"
      printf "            printf '%%s\\\\n' 'TOPO_PY=%s' 'export TOPO_PY' >> %s\n" \
             "$ACHOU" "$INPUTDIR/etc/.magic"
      grep -q "TOPO_PY" "$G" || \
        echo "          ATENCAO: este gancho nao le TOPO_PY - atualize o pacote primeiro"
    else
      ok "o gancho acharia $ENCONTRA"
      echo "         entao o log abaixo e de ANTES desta instalacao;"
      echo "         rode ./load.sh e confira de novo"
    fi
  fi
fi

echo
echo "-- o gancho roda na coleta? --"
if [ -f "$INPUTDIR/load.sh" ] && grep -q "user_script" "$INPUTDIR/load.sh"; then
  ok "load.sh roda bin/user_script*.sh"
else
  falta "load.sh nao roda os user_script*.sh"
fi
for f in "$INPUTDIR/bin/user_script_topology.sh" "$INPUTDIR/topology/bin/user_script_topology.sh"; do
  [ -f "$f" ] || continue
  [ -x "$f" ] && ok "$(echo "$f" | sed "s|$INPUTDIR/||") executavel" \
              || { falta "$(echo "$f" | sed "s|$INPUTDIR/||") NAO executavel"
                   [ "$CORRIGIR" = 1 ] && chmod +x "$f" && echo "          -> corrigido"; }
done

echo
echo "-- menu --"
M="$INPUTDIR/tmp/menu.txt"
if [ -f "$M" ]; then
  if grep -q "topologia.html" "$M"; then
    ok "tmp/menu.txt tem a entrada Topologia"
  else
    falta "tmp/menu.txt sem a entrada - o menu e de antes do update"
    if [ "$CORRIGIR" = 1 ]; then
      rm -f "$M" "$M-tmp" && echo "          -> apagado; o proximo load.sh o regenera"
    else
      echo "          rm -f $M   e rode ./load.sh"
    fi
  fi
else
  aviso "tmp/menu.txt ausente - sera gerado no proximo load.sh"
fi
I="$INPUTDIR/bin/install-html.sh"
[ -f "$I" ] && { grep -q "xoruxfork topology" "$I" && ok "install-html.sh registra a pagina" \
                                                   || falta "install-html.sh sem o registro da pagina"; }

echo
echo "-- o servidor web alcanca? --"
for d in "$INPUTDIR/www" "$INPUTDIR/html"; do
  [ -d "$d" ] || continue
  [ -f "$d/topologia.html" ] && ok "$(basename "$d")/topologia.html publicado" \
                             || aviso "$(basename "$d")/topologia.html ausente"
done
if [ -d "$INPUTDIR/topology" ]; then
  modo=$(ls -ld "$INPUTDIR/topology" | cut -c1-10)
  case $modo in
    *r*x*r*x*) ok "topology/ legivel pelo grupo ($modo)" ;;
    *) falta "topology/ sem leitura de grupo ($modo) - o CGI roda como apache"
       [ "$CORRIGIR" = 1 ] && chmod -R g+rX "$INPUTDIR/topology" && echo "          -> corrigido" ;;
  esac
  for sub in uploads facts; do
    [ -d "$INPUTDIR/topology/$sub" ] || {
      aviso "topology/$sub ausente (a importacao de planilhas precisa dele)"
      [ "$CORRIGIR" = 1 ] && mkdir -p "$INPUTDIR/topology/$sub" && chmod 775 "$INPUTDIR/topology/$sub" \
        && echo "          -> criado"
      continue; }
    w=$(ls -ld "$INPUTDIR/topology/$sub" | cut -c6)
    [ "$w" = "w" ] && ok "topology/$sub gravavel pelo grupo" \
                   || { falta "topology/$sub nao gravavel pelo grupo"
                        [ "$CORRIGIR" = 1 ] && chmod g+w "$INPUTDIR/topology/$sub" && echo "          -> corrigido"; }
  done
fi

echo
echo "-- ultima execucao --"
L="$INPUTDIR/logs/topology.log"
if [ -f "$L" ]; then
  echo "  $L:"
  tail -6 "$L" | sed 's/^/    /'
else
  aviso "logs/topology.log ausente - o gancho nunca rodou"
fi

echo
echo "=========================================================="
if [ "$FALTA" -eq 0 ]; then
  echo " nada faltando"
else
  echo " $FALTA item(ns) faltando"
  [ "$CORRIGIR" = 0 ] && echo " Para o que e automatico:  sh $0 --corrigir"
fi
echo "=========================================================="
