# xoruxfork: dizer por que a conexao falhou.
#
# O teste original so olhava totalEntities: qualquer falha - 401 por senha
# errada, 403 por falta de papel, 404 por apontar para um Prism Central, um
# timeout - saia na GUI como "No clusters reached", e o motivo real ficava
# so no logs/error.log-nutanix, afogado na pagina HTML do Tomcat.
# ( $clusters tambem vinha undef nesse caminho, o que fazia o >= 1 abaixo
#   emitir "Use of uninitialized value in numeric ge". )
if ( ref($clusters) eq "HASH" && ( $clusters->{metadata}{totalEntities} || 0 ) >= 1 ) {
  Xorux_lib::status_json( 1, "Reached " . $clusters->{metadata}{totalEntities} . " clusters" );
}
elsif ( $Nutanix::ultimo_codigo == 401 ) {
  Xorux_lib::status_json( 0,
        "HTTP 401 Unauthorized - o Prism recusou $username. Confira a senha, "
      . "o papel do usuario (minimo Viewer) e se a conta nao esta bloqueada "
      . "por tentativas seguidas." );
}
elsif ( $Nutanix::ultimo_codigo == 403 ) {
  Xorux_lib::status_json( 0,
      "HTTP 403 Forbidden - $username autenticou, mas nao tem papel que permita ler a API." );
}
elsif ( $Nutanix::ultimo_codigo == 404 ) {
  Xorux_lib::status_json( 0,
        "HTTP 404 - a API v1 do Prism Element nao existe neste endereco. "
      . "Se for um Prism Central, cadastre o Prism Element." );
}
elsif ($Nutanix::ultimo_codigo) {
  Xorux_lib::status_json( 0, "HTTP $Nutanix::ultimo_codigo $Nutanix::ultimo_motivo" );
}
else {
  Xorux_lib::status_json( 0, "No clusters reached (sem resposta HTTP, veja logs/error.log-nutanix)" );
}
