#!/bin/sh
# =============================================================================
# coleta-diagnostico.sh - varre as instalacoes LPAR2RRD e STOR2RRD desta
# maquina e empacota o que e preciso para diagnosticar problemas de coleta.
#
# Rode como root, para enxergar as duas arvores e os cron de ambos os usuarios:
#     sh coleta-diagnostico.sh
#
# Opcoes:
#     -d /caminho/da/arvore   acrescenta uma instalacao que a busca nao achou
#     -l 400                  linhas de log por arquivo (padrao 300)
#     -o /outro/destino       diretorio de saida (padrao /tmp)
#     -a                      anonimiza hostnames e IPs (veja AVISO abaixo)
#
# O QUE E REMOVIDO antes de empacotar, sempre:
#   - toda chave de hosts.json cujo nome contenha pass/secret/token/key/cred;
#   - linhas de configuracao e de log com esses mesmos termos;
#   - cabecalhos Authorization e strings "user = " de curl.
#   O arquivo REDACAO.txt lista quantas substituicoes houve em cada arquivo.
#
# AVISO: mesmo redigido, o pacote contem nomes de host, enderecos IP e nomes de
# instancias do seu ambiente. Trate-o como material interno: nao o anexe a um
# repositorio publico. Com -a os nomes e IPs viram rotulos estaveis (host001,
# ip001) - o diagnostico continua possivel, mas voce perde a leitura direta.
# =============================================================================

set -u
LINHAS=300
DESTINO=/tmp
EXTRA=""
ANON=0

while [ $# -gt 0 ]; do
  case $1 in
    -d) EXTRA="$EXTRA $2"; shift 2 ;;
    -l) LINHAS=$2; shift 2 ;;
    -o) DESTINO=$2; shift 2 ;;
    -a) ANON=1; shift ;;
    -h|--help) sed -n '3,28p' "$0"; exit 0 ;;
    *) echo "opcao desconhecida: $1" >&2; exit 2 ;;
  esac
done

AGORA=$(date +%Y%m%d_%H%M%S)
EU=$(id -un)
SAIDA="$DESTINO/xorux-diag-$(hostname -s 2>/dev/null || hostname)-$AGORA"
mkdir -p "$SAIDA" || { echo "nao consegui criar $SAIDA" >&2; exit 1; }
chmod 700 "$SAIDA"
REL="$SAIDA/00-RESUMO.txt"
RED="$SAIDA/REDACAO.txt"
: > "$RED"

diz() { echo "$@" | tee -a "$REL"; }

diz "coleta-diagnostico - $(date)"
diz "maquina : $(hostname 2>/dev/null)"
diz "usuario : $EU$( [ "$EU" = root ] || echo '   <-- nao e root: cron e arquivos de outro usuario podem faltar' )"
diz "sistema : $(uname -srm 2>/dev/null)"
[ -f /etc/os-release ] && diz "distro  : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-?}")"
diz ""

# --------------------------------------------------------- achar instalacoes
acha_arvores() {
  # 1. homes dos usuarios tipicos   2. caminhos comuns   3. processos em curso
  {
    for u in lpar2rrd stor2rrd xormon; do
      h=$(getent passwd "$u" 2>/dev/null | cut -d: -f6)
      [ -n "${h:-}" ] && { echo "$h/lpar2rrd"; echo "$h/stor2rrd"; echo "$h"; }
    done
    echo /home/lpar2rrd/lpar2rrd; echo /home/stor2rrd/stor2rrd
    echo /opt/lpar2rrd; echo /opt/stor2rrd
    ps -eo args 2>/dev/null | sed -n 's|.*\([/A-Za-z0-9_.-]*\)/bin/\(lpar2rrd\|stor2rrd\)[a-z_-]*\.pl.*|\1|p'
    ps -eo args 2>/dev/null | grep -oE '(/[A-Za-z0-9_.-]+)+/load(_[a-z0-9]+)?\.sh' | sed 's|/load.*||'
    echo "$EXTRA" | tr ' ' '\n'
  } | sed '/^$/d' | sort -u | while read -r d; do
    # uma arvore de verdade tem bin/ e um load.sh
    [ -d "$d/bin" ] && [ -f "$d/load.sh" ] && echo "$d"
  done | sort -u
}

ARVORES=$(acha_arvores)
if [ -z "$ARVORES" ]; then
  diz "NENHUMA instalacao encontrada."
  diz "Indique o caminho: sh $0 -d /caminho/do/lpar2rrd"
  exit 1
fi
diz "instalacoes encontradas:"
for a in $ARVORES; do diz "  $a"; done
diz ""

# ------------------------------------------------------------------ redacao
# O programa de redacao vai para um arquivo proprio: dentro de aspas simples do
# shell nao cabe um apostrofo, e as regras precisam dele para casar valores
# entre aspas simples.
REDIGE_PL="$SAIDA/.redige.pl"
cat > "$REDIGE_PL" <<'FIM_REDIGE'
# le STDIN, grava STDOUT sem segredos, e anota no REDACAO.txt quantos removeu
my $n = 0;
while (<STDIN>) {
  # 1. chave + separador + valor ENTRE ASPAS: consome ate a aspa de fecho, para
  #    que uma senha com espaco nao escape pela metade
  $n += s{((?i:pass(?:word|wd)?|secret|token|api[_-]?key|credential)\w*["']?\s*[=:]\s*)(["'])[^"']*\2}{$1$2<REMOVIDO>$2}g;
  # 2. chave + espaco + valor entre aspas
  $n += s{((?i:pass(?:word|wd)?|secret|token|api[_-]?key|credential)\w*\s+)(["'])[^"']*\2}{$1$2<REMOVIDO>$2}g;
  # 3. chave + separador + valor sem aspas
  $n += s{((?i:pass(?:word|wd)?|secret|token|api[_-]?key|credential)\w*["']?\s*[=:]\s*)([^\s"',;]+)}{$1<REMOVIDO>}g;
  $n += s{(Authorization:\s*\w+\s+)\S+}{$1<REMOVIDO>}gi;
  $n += s{(user\s*=\s*")[^"]*}{$1<REMOVIDO>}g;
  # guarda o usuario e a URL: so a senha sai
  $n += s{(-u\s+)(?!\w+://)(\S+?):\S+}{$1$2:<REMOVIDO>}g;
  print;
}
if ($n) {
  open my $r, ">>", $ENV{RED} or exit 0;
  printf {$r} "%-52s %d substituicao(oes)\n", $ENV{ROT}, $n;
}
FIM_REDIGE

redige() {
  orig=$1; dest=$2; rotulo=$3
  [ -f "$orig" ] || return 1
  ROT="$rotulo" RED="$RED" perl "$REDIGE_PL" < "$orig" > "$dest" 2>/dev/null
}

copia_tail() {
  orig=$1; dest=$2; rotulo=$3
  [ -f "$orig" ] || return 1
  tail -n "$LINHAS" "$orig" > "$dest.bruto" 2>/dev/null || return 1
  redige "$dest.bruto" "$dest" "$rotulo"
  rm -f "$dest.bruto"
}

# ------------------------------------------------------------- por instalacao
N=0
for RAIZ in $ARVORES; do
  N=$((N + 1))
  PROD=LPAR2RRD; [ -d "$RAIZ/stor2rrd-cgi" ] && PROD=STOR2RRD
  DIR="$SAIDA/$(printf '%02d' $N)-$PROD-$(basename "$RAIZ")"
  mkdir -p "$DIR"

  diz "=============================================================="
  diz " $PROD em $RAIZ"
  diz "=============================================================="
  {
    echo "raiz     : $RAIZ"
    echo "produto  : $PROD"
    echo "versao   : $(cat "$RAIZ/version.txt" 2>/dev/null | head -1)"
    echo "dono     : $(ls -ld "$RAIZ" | awk '{print $3":"$4, $1}')"
    echo "tamanho  : $(du -sh "$RAIZ" 2>/dev/null | cut -f1)"
    echo "disco    : $(df -Ph "$RAIZ" 2>/dev/null | tail -1)"
  } > "$DIR/01-instalacao.txt"
  diz "versao $(cat "$RAIZ/version.txt" 2>/dev/null | head -1)   disco: $(df -Ph "$RAIZ" 2>/dev/null | tail -1 | awk '{print $4" livres de "$2" ("$5" usado)"}')"

  # ---- edicao e marcadores
  {
    echo "== switches de edicao =="
    for f in bin/XoruxEdition.pm bin/standard.pl bin/premium.pl; do
      [ -f "$RAIZ/$f" ] && { echo "--- $f ---"; grep -E "^sub (premium|get_lpar_num|lpm|rperf_check)" -A 1 "$RAIZ/$f" 2>/dev/null; }
    done
    echo
    echo "== marcadores html/.X presentes =="
    ls -1 "$RAIZ/html"/.[a-z] 2>/dev/null | sed 's|.*/||' || echo "(nenhum)"
    echo
    echo "== correcoes do fork presentes =="
    for par in "bin/Xorux_lib.pm:gravacao atomica" \
               "bin/host_cfg.pl:validar o payload ANTES" \
               "bin/host_cfg.pl:conferir a escrita" \
               "bin/Nutanix.pm:dizer o codigo HTTP" \
               "bin/nutanix-apitest.pl:dizer por que a conexao falhou" \
               "bin/OracleDBLoadDataModule.pm:dizer o que ficou sem dado" \
               "bin/hmc_rest_api.pl:VIOS collection fallback" \
               "html/jquery/main.js:val.hosts pode nao existir" \
               "html/jquery/main.js:hosts.sh cmd=json"; do
      arq=${par%%:*}; pat=${par#*:}
      if [ -f "$RAIZ/$arq" ]; then
        grep -q "xoruxfork: $pat" "$RAIZ/$arq" 2>/dev/null \
          && echo "  SIM      $arq  ($pat)" || echo "  ausente  $arq  ($pat)"
      else
        echo "  n/a      $arq"
      fi
    done
  } > "$DIR/02-edicao-e-patches.txt" 2>&1

  # ---- configuracao, sem segredos
  mkdir -p "$DIR/03-config"
  for f in etc/lpar2rrd.cfg etc/stor2rrd.cfg etc/.magic etc/alias.cfg; do
    [ -f "$RAIZ/$f" ] && redige "$RAIZ/$f" "$DIR/03-config/$(basename "$f")" "$(basename "$RAIZ")/$f"
  done

  # hosts.json: remove toda chave sensivel, mantendo a estrutura
  for hj in etc/web_config/hosts.json etc/web_config/hosts.json.bak; do
    [ -f "$RAIZ/$hj" ] || continue
    nome=$(echo "$hj" | tr '/' '_')
    PERL5LIB="$RAIZ/lib:$RAIZ/bin${PERL5LIB:+:$PERL5LIB}" \
    ARQ="$RAIZ/$hj" RED="$RED" ROT="$(basename "$RAIZ")/$hj" perl -e '
      use strict; use JSON;
      open(my $f, "<", $ENV{ARQ}) or exit 1;
      my $bruto = do { local $/; <$f> }; close $f;
      my $d = eval { JSON->new->utf8->decode($bruto) };
      if ($@) { print "{ \"ERRO\": \"nao decodifica: $@\", \"bytes\": ", length($bruto), " }\n"; exit 0 }
      my $n = 0;
      my $limpa; $limpa = sub {
        my $x = shift;
        if (ref $x eq "HASH") {
          for my $k (keys %$x) {
            if ($k =~ /(?i:pass|secret|token|key|cred)/) {
              my $v = $x->{$k};
              $x->{$k} = ref($v) ? "<REMOVIDO>" : "<REMOVIDO:" . length($v // "") . " bytes>";
              $n++;
            } else { $limpa->($x->{$k}) }
          }
        } elsif (ref $x eq "ARRAY") { $limpa->($_) for @$x }
      };
      $limpa->($d);
      print JSON->new->utf8->pretty->canonical->encode($d);
      open my $r, ">>", $ENV{RED}; printf {$r} "%-52s %d chave(s) sensivel(is)\n", $ENV{ROT}, $n;
    ' > "$DIR/03-config/$nome" 2>/dev/null
  done

  # ---- integridade dos JSON em data/ e etc/
  PERL5LIB="$RAIZ/lib:$RAIZ/bin${PERL5LIB:+:$PERL5LIB}" \
  RAIZ="$RAIZ" perl -e '
    use strict; use warnings; use JSON; use File::Find;
    my $json = JSON->new->utf8->allow_nonref;
    my ($n, @vazios, @ruins) = (0);
    for my $sub ("data", "etc", "tmp") {
      my $p = "$ENV{RAIZ}/$sub";
      next unless -d $p;
      find({ no_chdir => 1, wanted => sub {
        my $f = $File::Find::name;
        return unless -f $f && $f =~ /\.json\z/;
        return if $f =~ /\.(CORROMPIDO|xoruxfork-tmp)/;
        $n++;
        my $t = -s $f;
        if (!$t) { push @vazios, $f; return }
        open(my $fh, "<", $f) or do { push @ruins, [$f, $t, "nao abriu: $!"]; return };
        my $b = do { local $/; <$fh> }; close $fh;
        if (!eval { $json->decode($b); 1 }) {
          my $e = $@; $e =~ s/\s+at \S+ line \d+\.?\s*\z//; $e =~ s/\s+/ /g;
          push @ruins, [$f, $t, $e];
        }
      }}, $p);
    }
    printf "%d arquivos .json examinados em data/, etc/ e tmp/\n\n", $n;
    printf "%d de tamanho zero\n", scalar @vazios;
    print "   $_\n" for @vazios;
    printf "\n%d que nao decodificam\n", scalar @ruins;
    for my $r (@ruins) {
      printf "   %s\n      %d bytes", $r->[0], $r->[1];
      printf " (= %d x 4096, fim de bloco: escrita interrompida)", $r->[1]/4096
        if $r->[1] && $r->[1] % 4096 == 0;
      print "\n      $r->[2]\n";
    }
    print "\nrenomeados por coleta anterior (.CORROMPIDO):\n";
  ' > "$DIR/04-json-integridade.txt" 2>&1
  find "$RAIZ/data" "$RAIZ/etc" -name "*.CORROMPIDO*" 2>/dev/null | head -100 >> "$DIR/04-json-integridade.txt"
  RUINS=$(grep -cE "^   /" "$DIR/04-json-integridade.txt" 2>/dev/null || echo 0)
  diz "JSON com problema: $(sed -n 's/^\([0-9]*\) que nao decodificam/\1/p' "$DIR/04-json-integridade.txt" | head -1) nao decodificam, $(sed -n 's/^\([0-9]*\) de tamanho zero/\1/p' "$DIR/04-json-integridade.txt" | head -1) vazios"

  # ---- logs
  mkdir -p "$DIR/05-logs"
  for f in "$RAIZ"/logs/*.log "$RAIZ"/logs/error.log-* "$RAIZ"/*.out "$RAIZ"/logs/*.out; do
    [ -f "$f" ] || continue
    copia_tail "$f" "$DIR/05-logs/$(basename "$f")" "$(basename "$RAIZ")/logs/$(basename "$f")"
  done
  for f in /var/tmp/lpar2rrd-realt-error.log /var/tmp/stor2rrd-realt-error.log; do
    [ -f "$f" ] && copia_tail "$f" "$DIR/05-logs/$(basename "$f")" "$(basename "$f")"
  done
  {
    echo "== contagem de erros por tipo, nos logs acima =="
    grep -rhoE "ORA-[0-9]{5}|HTTP (Status )?[0-9]{3}|ERROR[^:]*:|Can't locate [A-Za-z:]+|No such file or directory|Permission denied|Couldn't (open|parse) [a-z]+ file" \
      "$DIR/05-logs" 2>/dev/null | sed 's/  */ /g' | sort | uniq -c | sort -rn | head -40
  } > "$DIR/05-logs/00-erros-mais-frequentes.txt" 2>&1
  diz "erros mais frequentes nos logs:"
  sed -n '2,6p' "$DIR/05-logs/00-erros-mais-frequentes.txt" | sed 's/^/  /' | tee -a "$REL" >/dev/null
  sed -n '2,6p' "$DIR/05-logs/00-erros-mais-frequentes.txt" | sed 's/^/  /'

  # ---- permissoes
  {
    echo "== dono e modo do que importa =="
    for p in . bin etc etc/web_config etc/web_config/hosts.json data html tmp logs load.sh \
             lpar2rrd-cgi stor2rrd-cgi www; do
      [ -e "$RAIZ/$p" ] && ls -ld "$RAIZ/$p" 2>/dev/null
    done
    echo
    echo "== usuario do servidor web e seus grupos =="
    for u in apache www-data nginx httpd; do
      getent passwd "$u" >/dev/null 2>&1 && { printf "%-10s " "$u"; id "$u" 2>/dev/null; }
    done
    echo
    echo "== arquivos nao legiveis pelo grupo em etc/ e data/ (amostra) =="
    find "$RAIZ/etc" "$RAIZ/data" -maxdepth 3 \! -perm -g+r -type f 2>/dev/null | head -20
    echo
    echo "== SELinux =="
    getenforce 2>/dev/null || echo "(getenforce ausente)"
  } > "$DIR/06-permissoes.txt" 2>&1

  # ---- rrd: o que esta parado
  {
    echo "== quantidade de .rrd por plataforma =="
    find "$RAIZ/data" -name "*.rrd" 2>/dev/null \
      | sed "s|$RAIZ/data/||; s|/.*||" | sort | uniq -c | sort -rn | head -40
    echo
    echo "== .rrd de tamanho zero =="
    find "$RAIZ/data" -name "*.rrd" -size 0 2>/dev/null | head -40
    echo
    echo "== .rrd sem atualizacao ha mais de 2 dias (amostra de 60) =="
    find "$RAIZ/data" -name "*.rrd" -mtime +2 2>/dev/null | head -60
    echo
    echo "== total =="
    printf "  rrd no total        : %s\n" "$(find "$RAIZ/data" -name '*.rrd' 2>/dev/null | wc -l)"
    printf "  rrd parados (>2d)   : %s\n" "$(find "$RAIZ/data" -name '*.rrd' -mtime +2 2>/dev/null | wc -l)"
    printf "  rrd com 0 byte      : %s\n" "$(find "$RAIZ/data" -name '*.rrd' -size 0 2>/dev/null | wc -l)"
  } > "$DIR/07-rrd.txt" 2>&1
  diz "rrd: $(find "$RAIZ/data" -name '*.rrd' 2>/dev/null | wc -l) no total, $(find "$RAIZ/data" -name '*.rrd' -mtime +2 2>/dev/null | wc -l) parados ha mais de 2 dias"

  # ---- menu e arvore da GUI
  for f in tmp/menu.txt tmp/menu.json; do
    [ -f "$RAIZ/$f" ] && head -200 "$RAIZ/$f" > "$DIR/08-$(basename "$f")" 2>/dev/null
  done

  diz ""
done

# ----------------------------------------------------------------- ambiente
{
  echo "== cron dos usuarios do produto =="
  for u in lpar2rrd stor2rrd xormon root; do
    getent passwd "$u" >/dev/null 2>&1 || continue
    echo "--- $u ---"
    crontab -u "$u" -l 2>/dev/null || echo "(sem crontab ou sem permissao)"
  done
  echo
  echo "== /etc/cron.d relacionado =="
  grep -rl "lpar2rrd\|stor2rrd" /etc/cron.d /etc/crontab 2>/dev/null | while read -r f; do
    echo "--- $f ---"; cat "$f"
  done
  echo
  echo "== processos do produto agora =="
  ps -eo user,pid,etime,args 2>/dev/null | grep -E "lpar2rrd|stor2rrd" | grep -v grep | head -40
} > "$SAIDA/10-cron-e-processos.txt" 2>&1

{
  echo "== versoes =="
  echo "perl     : $(perl -e 'print $]' 2>/dev/null)"
  echo "rrdtool  : $(rrdtool 2>&1 | head -1)"
  echo "sqlite3  : $(sqlite3 --version 2>/dev/null || echo ausente)"
  echo "curl     : $(curl --version 2>/dev/null | head -1)"
  echo "java     : $(java -version 2>&1 | head -1)"
  echo
  echo "== modulos perl que o produto usa =="
  for m in JSON RRDp LWP LWP::UserAgent XML::Simple DBI DBD::SQLite Date::Parse MIME::Base64 Time::HiRes; do
    printf "  %-20s " "$m"
    perl -M"$m" -e 'print "ok\n"' 2>/dev/null || echo "AUSENTE no perl do sistema"
  done
  echo
  echo "== servidor web =="
  for s in httpd apache2 nginx; do
    command -v "$s" >/dev/null 2>&1 && { "$s" -v 2>&1 | head -1; }
  done
  systemctl is-active httpd apache2 nginx 2>/dev/null
  echo
  echo "== memoria e disco =="
  free -m 2>/dev/null | head -3
  df -Ph 2>/dev/null | head -15
} > "$SAIDA/11-ambiente.txt" 2>&1

# ------------------------------------------------------------- anonimizacao
if [ "$ANON" = "1" ]; then
  diz "anonimizando hostnames e IPs..."
  # o mapa fica FORA de $SAIDA, para nao entrar no pacote
  MAPA="$(dirname "$SAIDA")/MAPA-ANONIMO-$AGORA.txt"
  SAIDA="$SAIDA" MAPA="$MAPA" perl -e '
    use strict; use warnings; use File::Find;
    my (%mapa, $ch, $ci) = ((), 0, 0);
    my @arqs;
    find(sub { push @arqs, $File::Find::name if -f $_ }, $ENV{SAIDA});
    for my $f (@arqs) {
      open(my $i, "<", $f) or next; my $t = do { local $/; <$i> }; close $i;
      $t =~ s{\b(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\b}{
        $mapa{$1} ||= sprintf("ip%03d", ++$ci);
      }ge;
      # nao reanonimizar o que ja foi trocado, nem palavras sem digito ao fim
      $t =~ s{\b([a-z][a-z0-9-]{3,}\d{2,}[a-z0-9]*)\b}{
        my $h = lc $1;
        $h =~ /^(?:host|ip)\d+$/ ? $1 : ( $mapa{$h} ||= sprintf("host%03d", ++$ch) );
      }gei;
      open(my $o, ">", $f) or next; print {$o} $t; close $o;
    }
    open(my $m, ">", $ENV{MAPA}) or die;
    print {$m} "GUARDE ESTE ARQUIVO. Ele traduz o pacote de volta.\n";
    print {$m} "Ele NAO esta dentro do pacote - nao o envie junto.\n\n";
    printf {$m} "%-44s %s\n", $_, $mapa{$_} for sort keys %mapa;
    close $m;
  ' 2>/dev/null
  chmod 600 "$MAPA" 2>/dev/null
  diz "mapa em $MAPA  (fora do pacote - guarde, nao envie)"
  diz "AVISO: com nomes trocados o diagnostico fica mais limitado."
fi

rm -f "$REDIGE_PL"
PACOTE="$SAIDA.tar.gz"
( cd "$(dirname "$SAIDA")" && tar czf "$PACOTE" "$(basename "$SAIDA")" ) 2>/dev/null
chmod 600 "$PACOTE" 2>/dev/null

echo
echo "=============================================================="
echo " pacote : $PACOTE"
echo " tamanho: $(du -h "$PACOTE" 2>/dev/null | cut -f1)"
echo " resumo : $REL"
echo
echo " Confira antes de enviar:"
echo "   tar tzf $PACOTE | head -40"
echo "   grep -ri 'senha\|password' $SAIDA | head"
echo
echo " O pacote contem nomes de host e IPs do seu ambiente."
echo " Material interno: nao anexe a repositorio publico."
echo "=============================================================="
