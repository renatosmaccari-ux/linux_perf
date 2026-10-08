# xoruxfork: chamar o metodo, em vez de imprimir "->status_line" literal.
#
# Em Perl, "$obj->metodo" dentro de aspas duplas NAO chama o metodo: interpola
# $obj (que estampa HTTP::Response=HASH(0x...)) e deixa "->metodo" como texto.
# O produto faz isso em 19 pontos, todos em caminho de erro - justamente onde a
# mensagem importa. No log do cliente aparecia
#   ERROR naperf.pl: Request error: HTTP::Response=HASH(0x2aaab0d8)->status_line
# ou seja, o codigo HTTP que diria se foi 401, 403, 500 ou timeout nunca chegou
# a ser lido. @{[ ... ]} avalia a expressao dentro da string.
#
# So mexe em ->nome_de_metodo. ->{chave} e ->[indice] interpolam normalmente e
# ficam intactos, assim como ->metodo(args), que precisa de revisao humana.
use strict;
use warnings;

my $ABRE = '@' . '{' . '[ ';
my $FECHA = ' ]' . '}';

sub corrige_string {
    my ($s) = @_;
    my $n = 0;
    $n += ( $s =~ s/(\$[a-zA-Z_]\w*)->([a-z_]\w*)(?![\w({\[])/$ABRE$1->$2$FECHA/g );
    return ( $s, $n );
}

my ($arquivo) = @ARGV;
open( my $in, "<", $arquivo ) or die "nao li $arquivo: $!\n";
my @linhas = <$in>;
close($in);

my $trocas = 0;
for my $l (@linhas) {
    next if $l =~ /^\s*#/;      # comentario
    next if $l =~ /\Q$ABRE\E/;  # ja corrigido
    my $saida = '';
    my $resto = $l;
    # percorre a linha pegando cada string de aspas duplas
    while ( $resto =~ /\G(.*?)"((?:[^"\\]|\\.)*)"/gcs ) {
        my ( $antes, $corpo ) = ( $1, $2 );
        my ( $novo, $n ) = corrige_string($corpo);
        $trocas += $n;
        $saida .= $antes . '"' . $novo . '"';
    }
    $saida .= substr( $resto, pos($resto) // 0 );
    $l = $saida;
}

if ($trocas) {
    open( my $out, ">", "$arquivo.xoruxfork-novo" ) or die "nao escrevi: $!\n";
    print {$out} @linhas;
    close($out);
    rename( "$arquivo.xoruxfork-novo", $arquivo ) or die "nao substitui: $!\n";
}
print "$trocas\n";
