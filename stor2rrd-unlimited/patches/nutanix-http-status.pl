# xoruxfork: dizer o codigo HTTP em vez de despejar a pagina de erro.
#
# As tres restCall gravavam Dumper( $response->content ) sem o status, de modo
# que um 401 do Prism virava um bloco de HTML do Tomcat repetido uma vez por
# chamada - dezenas de linhas no error.log-nutanix para esconder um unico fato,
# que e o codigo da resposta. Sem ele nao da para separar "senha errada" (401)
# de "usuario sem papel" (403) de "endereco e um Prism Central" (404).
# O teste de conexao da GUI (nutanix-apitest.pl) le estas duas: sem elas ele so
# consegue dizer "No clusters reached", seja qual for o motivo real.
our $ultimo_codigo = 0;
our $ultimo_motivo = "";

sub resumo_http {
  my ( $url, $response ) = @_;

  $ultimo_codigo = $response->code;
  $ultimo_motivo = $response->message;

  my $txt = "ERROR: Can't handle request (" . $url . "): HTTP " . $response->code . " " . $response->message;

  my $wa = $response->header("WWW-Authenticate");
  $txt .= " [WWW-Authenticate: $wa]" if $wa;

  my $corpo = $response->content;
  if ( defined $corpo && length $corpo ) {
    if ( $corpo =~ /<html/i ) {
      # pagina de erro do container: so o titulo interessa
      my ($t) = $corpo =~ m{<title[^>]*>(.*?)</title>}is;
      $corpo = defined $t ? $t : "(resposta HTML)";
    }
    $corpo =~ s/\s+/ /g;
    $corpo =~ s/^\s+|\s+$//g;
    $corpo = substr( $corpo, 0, 200 ) . "..." if length($corpo) > 200;
    $txt .= " - $corpo" if length $corpo;
  }

  # 401 repetido a cada coleta costuma ser conta bloqueada, nao senha trocada
  $txt .= " | 401 em todas as chamadas: confira senha, papel do usuario no "
        . "Prism (minimo Viewer) e se a conta nao esta bloqueada por tentativas"
    if $response->code == 401;
  $txt .= " | 403: autenticou mas falta papel atribuido ao usuario no Prism"
    if $response->code == 403;

  return $txt;
}

