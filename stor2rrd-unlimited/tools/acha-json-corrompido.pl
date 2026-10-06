#!/usr/bin/perl
#
# acha-json-corrompido.pl - encontra JSON truncado na arvore de dados do
# LPAR2RRD/STOR2RRD e, com --apply, tira cada um do caminho para que a proxima
# coleta regrave o arquivo inteiro.
#
# Para que serve: Xorux_lib::write_json() grava num tempfile em /tmp e usa
# File::Copy::copy() para o destino. copy() nao e atomica - trunca o destino e
# vai transmitindo - de modo que um leitor concorrente ou uma escrita
# interrompida deixa o arquivo cortado no meio. Quem le depois falha com
# "unexpected end of string ... character offset N" e o dispositivo inteiro sai
# da coleta sem nenhum aviso na GUI.
#
# A causa esta corrigida no pacote (apply.sh --fix-vendor-bugs reescreve
# write_json para gravar num irmao e trocar por rename, que e atomico). Este
# script e para limpar os arquivos que ja estao corrompidos.
#
# Uso:
#   perl -I<inputdir>/lib bin/acha-json-corrompido.pl [--apply] [diretorio]
#
# Sem --apply apenas relata. O diretorio padrao e <inputdir>/data.

use strict;
use warnings;
use JSON;
use File::Find;

my $apply = 0;
my @resto;
for (@ARGV) { $_ eq "--apply" ? ( $apply = 1 ) : push( @resto, $_ ) }

my $raiz = $resto[0];
if ( !defined $raiz ) {
    my $base = $ENV{INPUTDIR} || $ENV{BASEDIR};
    $raiz = defined $base ? "$base/data" : "data";
}
die "diretorio nao encontrado: $raiz\n" unless -d $raiz;

my $json = JSON->new->utf8->allow_nonref;
my ( $vistos, @ruins, @vazios ) = (0);

find(
    {   no_chdir => 1,
        wanted   => sub {
            my $f = $File::Find::name;
            return unless -f $f && $f =~ /\.json\z/;
            return if $f =~ /\.(CORROMPIDO|xoruxfork-tmp)/;
            $vistos++;

            my $tam = -s $f;
            if ( !$tam ) { push @vazios, $f; return }

            open( my $fh, "<", $f ) or do {
                push @ruins, [ $f, $tam, "nao consegui abrir: $!" ];
                return;
            };
            my $bruto = do { local $/; <$fh> };
            close($fh);

            if ( !eval { $json->decode($bruto); 1 } ) {
                my $erro = $@;
                $erro =~ s/\s+at \S+ line \d+\.?\s*\z//;
                $erro =~ s/\s+/ /g;
                push @ruins, [ $f, $tam, $erro ];
            }
        },
    },
    $raiz
);

printf "%d arquivos .json examinados em %s\n\n", $vistos, $raiz;

if ( !@ruins && !@vazios ) { print "nenhum JSON corrompido\n"; exit 0 }

if (@vazios) {
    print scalar(@vazios), " arquivo(s) de tamanho zero:\n";
    print "  $_\n" for @vazios;
    print "\n";
}

if (@ruins) {
    print scalar(@ruins), " arquivo(s) que nao decodificam:\n";
    for my $r (@ruins) {
        printf "  %s\n     %d bytes", $r->[0], $r->[1];

        # fim de bloco e assinatura de escrita interrompida, nao de JSON invalido
        printf " (= %d x 4096, fim de bloco: escrita interrompida)", $r->[1] / 4096
            if $r->[1] && $r->[1] % 4096 == 0;
        print "\n     $r->[2]\n";
    }
    print "\n";
}

my @alvos = ( @vazios, map { $_->[0] } @ruins );

if ( !$apply ) {
    print scalar(@alvos), " arquivo(s) seriam renomeados para .CORROMPIDO-<data>.\n";
    print "A proxima coleta regrava cada um. Repita com --apply.\n";
    exit 0;
}

my @t = localtime();
my $selo = sprintf( "%04d%02d%02d_%02d%02d%02d", $t[5] + 1900, $t[4] + 1, @t[ 3, 2, 1, 0 ] );
my $movidos = 0;
for my $f (@alvos) {
    if ( rename( $f, "$f.CORROMPIDO-$selo" ) ) { $movidos++ }
    else                                       { warn "nao consegui renomear $f: $!\n" }
}
printf "%d de %d arquivo(s) tirados do caminho.\n", $movidos, scalar(@alvos);
print "Rode a coleta (bin/load.sh) para que sejam regravados.\n";
