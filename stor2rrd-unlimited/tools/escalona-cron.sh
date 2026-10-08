#!/bin/sh
# =============================================================================
# escalona-cron.sh - espalha os coletores do LPAR2RRD/STOR2RRD pelos minutos.
#
# Por que: a instalacao padrao poe todos os coletores no mesmo minuto. Num
# ambiente real foram 15 processos do LPAR2RRD disparando no minuto :00 e 6 do
# STOR2RRD a cada 5 minutos. Todos gravam JSON pelo mesmo Xorux_lib::write_json,
# que ate a correcao deste fork usava File::Copy::copy() - nao atomica. Um
# leitor que abre o arquivo no meio da copia le JSON cortado.
#
# O efeito ficou visivel na coleta de diagnostico: 10 arquivos de
# tmp/restapi/ que nao decodificam, TODOS com tamanho multiplo exato de 4096
# (1x, 2x, 3x, 5x, 6x) - fim de bloco, nao fim de JSON.
#
# Espalhar o cron reduz a janela de colisao; a write_json atomica do pacote
# fecha o resto. As duas coisas juntas.
#
# Uso, como root:
#     sh escalona-cron.sh              # so mostra o que faria
#     sh escalona-cron.sh --apply      # aplica, com backup
# =============================================================================
set -u
APLICAR=0
[ "${1:-}" = "--apply" ] && APLICAR=1

AGORA=$(date +%Y%m%d_%H%M%S)
BKP=/var/tmp/crontab-backup-$AGORA
mkdir -p "$BKP" || exit 1

for USUARIO in lpar2rrd stor2rrd; do
  getent passwd "$USUARIO" >/dev/null 2>&1 || continue
  crontab -u "$USUARIO" -l > "$BKP/$USUARIO.antes" 2>/dev/null || continue
  [ -s "$BKP/$USUARIO.antes" ] || continue

  echo "=========================================================="
  echo " $USUARIO"
  echo "=========================================================="

  perl -e '
use strict; use warnings;
my ($antes, $depois) = @ARGV;
open(my $i, "<", $antes) or die; my @l = <$i>; close $i;

# Agrupa as linhas de coleta por padrao de minuto. load.sh fica onde esta:
# ele agrega o que os outros coletaram e deve rodar depois deles.
my %grupo;
for my $n (0 .. $#l) {
  next unless $l[$n] =~ m{^\s*([0-9,*/-]+)\s+(\S+\s+\S+\s+\S+\s+\S+)\s+(\S*/load_\w+\.sh)};
  push @{ $grupo{$1} }, $n;
}

my $mudou = 0;
for my $minutos (sort keys %grupo) {
  my @linhas = @{ $grupo{$minutos} };
  next if @linhas < 2;                      # sozinho, nada a espalhar

  my @m = sort { $a <=> $b } split /,/, $minutos;
  next if @m < 1 || $m[0] =~ /\D/;          # */5 e afins: nao mexe
  my $passo = @m > 1 ? $m[1] - $m[0] : 60;  # 20 para 0,20,40; 5 para 0,5,..
  next if $passo < 2;

  printf "  %d coletores no minuto %s (passo %d) -> espalhando\n",
         scalar @linhas, $minutos, $passo;

  # comeca em 1: o minuto 0 fica para load.sh, que agrega o que os outros
  # coletaram e deve rodar sozinho
  printf "     ATENCAO: %d coletores para %d minuto(s) de intervalo - alguns\n"
       . "     continuarao juntos. Considere intervalos diferentes.\n",
         scalar @linhas, $passo if @linhas > $passo - 1;

  my $i = 0;
  for my $n (@linhas) {
    my $off = 1 + ( $i % ( $passo > 1 ? $passo - 1 : 1 ) );
    my $novo = join(",", map { $_ + $off } @m);
    my ($cmd) = $l[$n] =~ m{(\S*/load_\w+\.sh)};
    $cmd =~ s{.*/}{};
    printf "     %-28s %s -> %s\n", $cmd, $minutos, $novo;
    $l[$n] =~ s{^\s*\Q$minutos\E\s}{$novo };
    $mudou++;
    $i++;
  }
}
open(my $o, ">", $depois) or die; print {$o} @l; close $o;
print "  nada a mudar\n" unless $mudou;
exit($mudou ? 0 : 1);
  ' "$BKP/$USUARIO.antes" "$BKP/$USUARIO.depois"
  RC=$?

  if [ $RC -ne 0 ]; then
    rm -f "$BKP/$USUARIO.depois"
    continue
  fi

  # o crontab novo tem de ter o mesmo numero de linhas
  A=$(wc -l < "$BKP/$USUARIO.antes"); D=$(wc -l < "$BKP/$USUARIO.depois")
  if [ "$A" != "$D" ]; then
    echo "  ABORTADO: $A linhas antes, $D depois" >&2
    continue
  fi

  if [ "$APLICAR" = "1" ]; then
    if crontab -u "$USUARIO" "$BKP/$USUARIO.depois"; then
      echo "  aplicado. backup em $BKP/$USUARIO.antes"
    else
      echo "  FALHOU ao instalar; nada mudou" >&2
    fi
  fi
  echo
done

if [ "$APLICAR" = "0" ]; then
  echo "Nada foi alterado. Para aplicar:  sh $0 --apply"
  echo "Os crontabs propostos estao em $BKP/"
else
  echo "Para voltar atras:"
  for u in lpar2rrd stor2rrd; do
    [ -f "$BKP/$u.antes" ] && echo "  crontab -u $u $BKP/$u.antes"
  done
fi
