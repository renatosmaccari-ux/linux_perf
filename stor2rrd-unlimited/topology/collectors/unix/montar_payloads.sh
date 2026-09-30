#!/bin/sh
# ============================================================
# montar_payloads.sh - Gera os payload_*.sh self-contained
#
# Cada payload = lib.sh (preambulo portavel) + corpo/NN_nome.sh
# Mantem o contrato do kit: um unico arquivo enviado por stdin ao
# "sudo -n /bin/sh -s", sem dependencia remota.
#
# Rode sempre que editar lib.sh ou qualquer corpo. Valida com sh -n.
# ============================================================
set -u

cd "$(dirname "$0")" || exit 1
[ -r lib.sh ] || { echo "[FALHA] lib.sh ausente" >&2; exit 1; }
[ -d corpo ]  || { echo "[FALHA] diretorio corpo/ ausente" >&2; exit 1; }

ERROS=0
for c in corpo/*.sh; do
  [ -r "$c" ] || continue
  NOME=$(basename "$c" .sh | sed 's/^[0-9]*_//')
  OUT="payload_${NOME}.sh"
  {
    echo "#!/bin/sh"
    echo "# GERADO POR montar_payloads.sh - NAO EDITE AQUI."
    echo "# Fonte: lib.sh + $c"
    echo "# Gerado em: $(date '+%Y-%m-%d %H:%M:%S')"
    sed '1{/^#!/d;}' lib.sh
    echo ""
    cat "$c"
  } > "$OUT"
  chmod +x "$OUT"
  if sh -n "$OUT" 2>/tmp/.mp.$$; then
    printf '[OK]    %-28s %5s linhas\n' "$OUT" "$(wc -l < "$OUT" | tr -d ' ')"
  else
    printf '[FALHA] %-28s %s\n' "$OUT" "$(cat /tmp/.mp.$$)"
    ERROS=$((ERROS + 1))
  fi
  rm -f /tmp/.mp.$$
done

echo ""
if [ "$ERROS" -eq 0 ]; then
  echo "[RESUMO] todos os payloads validados com sh -n"
else
  echo "[RESUMO] $ERROS payload(s) com erro de sintaxe" >&2
  exit 1
fi
