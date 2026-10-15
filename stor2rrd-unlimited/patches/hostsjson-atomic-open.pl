    # xoruxfork: validar o payload ANTES de abrir o arquivo.
    #
    # open(">") trunca hosts.json no ato, e so depois vinha o
    # decode_json( $PAR{acl} ) abaixo. Um payload invalido - requisicao
    # truncada, parametro perdido - fazia o decode morrer com o arquivo ja
    # zerado, levando toda a configuracao de dispositivos com ele. E a origem
    # dos hosts.json.CORROMPIDO que aparecem nestas instalacoes.
    my $cfg_novo = eval { decode_json( $PAR{acl} ) };
    if ( !$cfg_novo || ref($cfg_novo) ne "HASH" || !$cfg_novo->{platforms} ) {
      print "{ \"status\" : \"fail\", \"msg\" : \"<div>Invalid configuration payload, hosts.json was left untouched.</div>\" }";
      exit;
    }

    # ... e gravar numa copia irma, trocada por rename() no fim: atomico, de
    # modo que o CGI e os coletores nunca leem um hosts.json pela metade.
    my $hosts_tmp = "$cfgdir/.hosts.json.xoruxfork-tmp.$$";
    if ( open( my $CFG, ">", $hosts_tmp ) ) {
      my $cfg = $cfg_novo;
