    if ( !defined $hash{$item} || $hash{$item} eq '' ) {    #|| ! isdigit( $hash{$item} )
      $value = 'U';
      push @xoruxfork_sem_dado, $item;                      # xoruxfork: anotar o que faltou
    }
    else {
      $value = $hash{$item};
    }
    $update_string .= "$value:";
  }
  $update_string = substr( $update_string, 0, -1 );
  print "\n$update_string\n";

  # xoruxfork: dizer o que ficou sem dado, e de onde ele deveria vir.
  #
  # Um datasource sem valor vira "U" aqui sem deixar rastro. No grafico isso
  # aparece como -nan e nada na interface diz por que. A causa mais comum nao e
  # falha de coleta: e o usuario de monitoracao sem SELECT na view de origem,
  # que devolve ORA-00942 e nenhuma linha. Nomear a view transforma um -nan
  # inexplicado num GRANT a pedir ao DBA.
  if (@xoruxfork_sem_dado) {
    my %origem = (
      'log_capacity' => 'V$LOG',
      'controlfiles' => 'V$CONTROLFILE',
      'recoverysize' => 'V$RECOVERY_FILE_DEST',
      'recoveryused' => 'V$RECOVERY_FILE_DEST',
      'used'         => 'DBA_DATA_FILES',
      'free'         => 'DBA_FREE_SPACE',
      'tempfiles'    => 'DBA_TEMP_FILES',
    );
    my @det = map { $origem{$_} ? "$_ (" . $origem{$_} . ")" : $_ } @xoruxfork_sem_dado;
    print "oracleDB-json2rrd.pl : $type"
        . ( defined $alias ? " $alias" : "" )
        . " sem dado para: " . join( ", ", @det ) . " -> gravado U, grafico mostra -nan\n";
    print "oracleDB-json2rrd.pl : se a origem e uma view V\$, confira o GRANT SELECT "
        . "do usuario de monitoracao (ORA-00942 no log da coleta)\n"
      if grep { $origem{$_} && $origem{$_} =~ /^V\$/ } @xoruxfork_sem_dado;
  }
