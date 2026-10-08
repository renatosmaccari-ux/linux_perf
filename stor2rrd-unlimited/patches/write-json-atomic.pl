sub write_json {
  my $path     = shift;
  my $hash_ref = shift;
  my $json     = JSON->new->utf8;

  if ( ref($hash_ref) ne "HASH" && ref($hash_ref) ne "ARRAY" ) {
    warn( "Hash ref or array ref expected (path:$path), got: \"$hash_ref\" (Ref:" . ref($hash_ref) . ") in " . __FILE__ . ":" . __LINE__ . "\n" );
    return 0;
  }
  if ( $ENV{JSON_PRETTY} ) {
    $json->pretty( [1] );
  }

  # xoruxfork: gravacao atomica.
  #
  # A versao original escrevia num tempfile em /tmp (File::Temp) e levava o
  # resultado ao destino com File::Copy::copy(). copy() nao e atomica: ela
  # trunca o destino e vai transmitindo. Duas consequencias reais:
  #
  #   1. quem abrir o arquivo durante a copia le JSON cortado. Foi o que
  #      aconteceu com data/OracleDB/<alias>/configuration/conf.json, que
  #      falhou o parse em "unexpected end of string ... character offset
  #      303104" - 303104 e exatamente 74 x 4096, fim de bloco, nao fim de
  #      JSON - e tirou a instancia inteira da coleta.
  #   2. se a escrita falha no meio (disco cheio, por exemplo) o destino fica
  #      truncado em definitivo. O retorno de copy() nao era verificado e
  #      write_json devolvia 1 de qualquer maneira, de modo que o chamador
  #      registrava sucesso sobre um arquivo corrompido.
  #
  # Aqui o conteudo vai para um arquivo irmao, no mesmo diretorio do destino,
  # e so entra em cena por rename(), atomico no mesmo filesystem: um leitor ve
  # a versao anterior inteira ou a nova inteira, nunca um meio. O tempfile em
  # /tmp foi o motivo pelo qual o autor original nao podia usar rename (/tmp
  # costuma ser outro filesystem); gravar no diretorio de destino resolve isso
  # e tambem elimina os restos em /tmp que o comentario dele mencionava.
  my $encoded = $json->encode($hash_ref);
  my ( $dir, $base ) = $path =~ m{^(.*)/([^/]+)$} ? ( $1, $2 ) : ( ".", $path );
  my $tmp = "$dir/.$base.xoruxfork-tmp.$$";

  my @st = stat($path);

  open( my $FH, '>', $tmp )
    or error( "Couldn't open file $tmp $! " . __FILE__ . ':' . __LINE__ ) && return 0;
  binmode($FH);

  unless ( print {$FH} $encoded ) {
    my $err = $!;
    close($FH);
    unlink($tmp);
    error( "Couldn't write $tmp $err " . __FILE__ . ':' . __LINE__ );
    return 0;
  }

  # close() e onde o disco cheio costuma aparecer: o print entrega ao buffer
  unless ( close($FH) ) {
    my $err = $!;
    unlink($tmp);
    error( "Couldn't flush $tmp $err " . __FILE__ . ':' . __LINE__ );
    return 0;
  }

  my $gravado = -s $tmp;
  if ( !defined $gravado || $gravado != length($encoded) ) {
    my $tam = defined $gravado ? $gravado : "undef";
    unlink($tmp);
    error( "Short write on $tmp ($tam of " . length($encoded) . " bytes), $path left untouched " . __FILE__ . ':' . __LINE__ );
    return 0;
  }

  # rename() troca o inode, entao o modo do destino anterior nao sobrevive
  # sozinho - e o servidor web precisa continuar lendo estes arquivos.
  if (@st) {
    chmod( $st[2] & 07777, $tmp );
    chown( -1, $st[5], $tmp );    # grupo, quando somos membro dele
  }
  else {
    chmod( 0666 & ~umask(), $tmp );
  }

  unless ( rename( $tmp, $path ) ) {
    my $err = $!;
    unlink($tmp);
    error( "Couldn't replace $path $err " . __FILE__ . ':' . __LINE__ );
    return 0;
  }

  return 1;
}
