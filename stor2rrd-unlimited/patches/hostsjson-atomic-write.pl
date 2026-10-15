      # xoruxfork: conferir a escrita e so entao substituir o arquivo real.
      # O codigo original nao olhava o retorno de print nem de close: disco
      # cheio gravava um JSON cortado e a GUI dizia "successfully saved".
      my $hosts_enc = $json->encode($cfg);
      my $hosts_ok  = print {$CFG} $hosts_enc;
      $hosts_ok = 0 unless close($CFG);
      my $hosts_tam = -s $hosts_tmp;
      $hosts_ok = 0 unless defined $hosts_tam && $hosts_tam == length($hosts_enc);

      if ( !$hosts_ok ) {
        unlink($hosts_tmp);
        print "{ \"status\" : \"fail\", \"msg\" : \"<div>Could not write hosts.json (check free space and permissions): <span style='color: red'>$!</span><br />The previous configuration was kept.</div>\" }";
        exit;
      }

      # rename() troca o inode: sem isto o modo do arquivo anterior se perde
      # e o servidor web pode ficar sem leitura.
      if ( my @hosts_st = stat("$cfgdir/hosts.json") ) {
        chmod( $hosts_st[2] & 07777, $hosts_tmp );
        chown( -1, $hosts_st[5], $hosts_tmp );
      }
      else {
        chmod( 0664, $hosts_tmp );
      }

      if ( !rename( $hosts_tmp, "$cfgdir/hosts.json" ) ) {
        my $erro = $!;
        unlink($hosts_tmp);
        print "{ \"status\" : \"fail\", \"msg\" : \"<div>Could not replace $cfgdir/hosts.json: <span style='color: red'>$erro</span><br />The previous configuration was kept.</div>\" }";
        exit;
      }
