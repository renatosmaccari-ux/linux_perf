#
# topology_cgi.pl - feed the dependency map with spreadsheets and CSV files.
#
# Whatever is dropped here becomes the baseline the map is drawn from:
# location, environment, function, cluster and IP per host. The collectors and
# the product's own inventory supply the rest.
#
# Uploads are data, never code: the name is reduced to a basename from a
# strict character set, the extension must be one of three, and the content is
# only ever read by the builder.

use strict;
use warnings;

use File::Basename;

my $basedir = $ENV{INPUTDIR} ||= "/home/lpar2rrd/lpar2rrd";
my $perl    = $ENV{PERL} || "perl";
my $topodir = "$basedir/topology";
my $updir   = "$topodir/uploads";
my $logfile = "$basedir/logs/topology.log";

my $MAX_BYTES = 64 * 1024 * 1024;
my %OK_EXT = ( csv => 1, txt => 1, xlsx => 1, xls => 1 );

my $self = $ENV{SCRIPT_NAME} || "topology.sh";

# ------------------------------------------------------------------ helpers
sub esc {
  my $s = defined $_[0] ? $_[0] : "";
  $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g;
  $s =~ s/"/&quot;/g; $s =~ s/'/&#39;/g;
  return $s;
}

# The uploaded name is attacker-controlled. Keep a basename, then keep only
# characters that cannot traverse or surprise the shell.
sub safe_name {
  my $n = basename( defined $_[0] ? $_[0] : "" );
  $n =~ s/[^A-Za-z0-9._-]/_/g;
  $n =~ s/^\.+//;
  return "" if $n eq "" || length($n) > 120;
  my ($ext) = $n =~ /\.([A-Za-z0-9]+)$/;
  return "" unless $ext && $OK_EXT{ lc $ext };
  return $n;
}

sub param_of {
  my $want = shift;
  my $q = $ENV{QUERY_STRING} || "";
  for my $pair ( split /&/, $q ) {
    my ( $k, $v ) = split /=/, $pair, 2;
    next unless defined $k && $k eq $want;
    $v = "" unless defined $v;
    $v =~ tr/+/ /;
    $v =~ s/%([0-9A-Fa-f]{2})/chr(hex($1))/ge;
    return $v;
  }
  return "";
}

sub listed {
  my @out;
  if ( opendir( my $dh, $updir ) ) {
    for my $f ( sort readdir($dh) ) {
      next if $f =~ /^\./;
      my $p = "$updir/$f";
      next unless -f $p;
      my @st = stat($p);
      push @out, { name => $f, size => $st[7], mtime => scalar localtime( $st[9] ) };
    }
    closedir($dh);
  }
  return @out;
}

sub tail_log {
  return "" unless -r $logfile;
  open( my $fh, "<", $logfile ) or return "";
  my @l = <$fh>;
  close($fh);
  @l = splice( @l, -25 ) if @l > 25;
  return join( "", @l );
}

# ------------------------------------------------------------------ actions
my @msg;

mkdir $topodir unless -d $topodir;
mkdir $updir   unless -d $updir;

if ( defined $ENV{CONTENT_TYPE} && $ENV{CONTENT_TYPE} =~ /multipart\/form-data/ ) {
  require CGI;
  my $cgi  = CGI->new;
  my $name = safe_name( scalar $cgi->param('arquivo') );
  my $fh   = $cgi->upload('arquivo');

  if ( !$fh ) {
    push @msg, [ "erro", "Nenhum arquivo recebido." ];
  }
  elsif ( !$name ) {
    push @msg, [ "erro", "Nome ou extensao nao aceitos. Use .csv, .txt, .xls ou .xlsx." ];
  }
  else {
    my $dest = "$updir/$name";
    if ( open( my $out, ">", "$dest.parcial" ) ) {
      binmode $out;
      binmode $fh;
      my ( $buf, $total ) = ( "", 0 );
      my $estourou = 0;
      while ( my $n = read( $fh, $buf, 65536 ) ) {
        $total += $n;
        if ( $total > $MAX_BYTES ) { $estourou = 1; last }
        print $out $buf;
      }
      close($out);
      if ($estourou) {
        unlink "$dest.parcial";
        push @msg, [ "erro", "Arquivo maior que " . int( $MAX_BYTES / 1048576 ) . " MB." ];
      }
      elsif ( $total == 0 ) {
        unlink "$dest.parcial";
        push @msg, [ "erro", "Arquivo vazio." ];
      }
      else {
        rename( "$dest.parcial", $dest );
        chmod 0664, $dest;
        push @msg, [ "ok", "Recebido: $name (" . int( $total / 1024 ) . " KB)." ];
      }
    }
    else {
      push @msg, [ "erro", "Sem permissao de escrita em topology/uploads." ];
    }
  }
}

my $cmd = param_of("cmd");

if ( $cmd eq "remover" ) {
  my $alvo = safe_name( param_of("f") );
  if ( $alvo && -f "$updir/$alvo" ) {
    unlink "$updir/$alvo";
    push @msg, [ "ok", "Removido: $alvo." ];
  }
  else {
    push @msg, [ "erro", "Arquivo nao encontrado." ];
  }
}

my $subiu = grep { $_->[0] eq "ok" && $_->[1] =~ /^Recebido/ } @msg;

if ( $cmd eq "rebuild" || $subiu ) {
  my $script = "$topodir/bin/user_script_topology.sh";
  if ( -f $script ) {
    # list form: no shell, so nothing here can be interpreted as a command
    local $ENV{INPUTDIR} = $basedir;
    my $rc = system( "/bin/sh", $script );
    push @msg, $rc == 0
      ? [ "ok",   "Mapa reconstruido." ]
      : [ "erro", "A reconstrucao terminou com erro; veja o log abaixo." ];
  }
  else {
    push @msg, [ "erro", "Script de reconstrucao ausente: topology/bin." ];
  }
}

# ------------------------------------------------- answer the graph page
# The map page uploads from inside its own panel and stays where it is, so it
# needs a verdict it can read rather than a whole HTML page.
if ( param_of("fmt") eq "json" ) {
  my $erro = "";
  my $ok   = "";
  for my $m (@msg) {
    $erro = $m->[1] if $m->[0] eq "erro" && !$erro;
    $ok   = $m->[1] if $m->[0] eq "ok";
  }
  my ( $n, $l ) = ( 0, 0 );
  if ( open( my $jh, "<", "$topodir/topologia.json" ) ) {
    local $/;
    my $raw = <$jh>;
    close($jh);
    $n = () = $raw =~ /"id":/g;
    $l = () = $raw =~ /"ev":/g;
  }
  my $texto = $erro || $ok || "Nada a fazer.";
  $texto =~ s/(["\\])/\\$1/g;
  $texto =~ s/[\r\n\t]/ /g;
  print "Content-type: application/json; charset=utf-8\n";
  print "Cache-Control: no-store\n\n";
  printf qq({"ok":%s,"msg":"%s","nos":%d,"ligacoes":%d}\n),
    ( $erro ? "false" : "true" ), $texto, $n, $l;
  exit 0;
}

# --------------------------------------------------------------------- page
my @files = listed();
my $log   = tail_log();

# the map itself, so the page can say whether there is anything to look at
my ( $nos, $ligacoes, $quando ) = ( 0, 0, "" );
if ( -r "$topodir/topologia.json" ) {
  my @st = stat("$topodir/topologia.json");
  $quando = scalar localtime( $st[9] );
  if ( open( my $jh, "<", "$topodir/topologia.json" ) ) {
    local $/;
    my $raw = <$jh>;
    close($jh);
    $nos      = () = $raw =~ /"id":/g;
    $ligacoes = () = $raw =~ /"ev":/g;
  }
}

# O grafo nao le este arquivo: le o topologia.json do diretorio web, para onde
# o mapa e copiado no fim da reconstrucao. Quando essa copia falha, esta pagina
# mostra o mapa novo e o grafo continua no antigo - sem nada dizendo por que os
# numeros nao batem.
my $publicado_nos = -1;
my $publicado_quando = "";
for my $d ( "$basedir/www", "$basedir/html" ) {
  next unless -r "$d/topologia.json";
  my @st = stat("$d/topologia.json");
  $publicado_quando = scalar localtime( $st[9] );
  if ( open( my $ph, "<", "$d/topologia.json" ) ) {
    local $/;
    my $raw = <$ph>;
    close($ph);
    $publicado_nos = () = $raw =~ /"id":/g;
  }
  last;
}

print "Content-type: text/html; charset=utf-8\n\n";
print <<"HEAD";
<!DOCTYPE html>
<html lang="pt-BR"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Topologia: dados</title>
<style>
:root{--fundo:#151A21;--painel:#1C232C;--linha:#2B3542;--texto:#DCE3EA;
      --suave:#8A97A6;--sel:#F2F5F8;--ok:#7CC454;--erro:#E0453C}
\@media (prefers-color-scheme: light){
 :root{--fundo:#F4F6F8;--painel:#FFF;--linha:#D6DDE5;--texto:#1A232C;
       --suave:#5E6B7A;--sel:#0B1F33;--ok:#2E7D32;--erro:#C62828}}
*{box-sizing:border-box}
body{margin:0;padding:24px 16px;background:var(--fundo);color:var(--texto);
     font:14px/1.5 system-ui,-apple-system,"Segoe UI",sans-serif}
.wrap{max-width:860px;margin:0 auto}
h1{font-size:18px;margin:0 0 4px}
.sub{color:var(--suave);font-size:13px;margin:0 0 20px}
.cartao{background:var(--painel);border:1px solid var(--linha);border-radius:10px;
        padding:16px;margin-bottom:16px}
h2{font-size:13px;color:var(--suave);font-weight:500;margin:0 0 12px;
   text-transform:uppercase;letter-spacing:.04em}
table{width:100%;border-collapse:collapse;font-size:13px}
th,td{text-align:left;padding:7px 8px;border-bottom:1px solid var(--linha)}
th{color:var(--suave);font-weight:500}
td.num{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
a{color:inherit}
.btn{display:inline-block;padding:7px 14px;border:1px solid var(--linha);
     border-radius:6px;background:var(--fundo);color:inherit;cursor:pointer;
     text-decoration:none;font:inherit}
.btn:hover{border-color:var(--sel)}
.rem{color:var(--erro);text-decoration:none;font-size:12px}
.msg{padding:9px 12px;border-radius:6px;margin-bottom:10px;font-size:13px;
     border:1px solid var(--linha)}
.msg.ok{border-color:var(--ok)} .msg.erro{border-color:var(--erro)}
input[type=file]{width:100%;padding:9px;background:var(--fundo);
     border:1px dashed var(--linha);border-radius:6px;margin-bottom:12px}
pre{background:var(--fundo);border:1px solid var(--linha);border-radius:6px;
    padding:12px;overflow:auto;font-size:12px;max-height:280px;margin:0}
.kv{display:flex;gap:28px;flex-wrap:wrap;font-size:13px}
.kv div{min-width:110px}
.kv b{display:block;font-size:19px;font-weight:600}
.kv span{color:var(--suave);font-size:12px}
.nota{color:var(--suave);font-size:12.5px;margin:10px 0 0}
code{font-family:ui-monospace,monospace;font-size:12px}
</style></head><body><div class="wrap">
<h1>Topologia: dados</h1>
<p class="sub">Planilhas e CSV que alimentam o mapa de dependencias.</p>
HEAD

for my $m (@msg) {
  printf qq{<div class="msg %s">%s</div>\n}, esc( $m->[0] ), esc( $m->[1] );
}

print <<"ESTADO";
<div class="cartao"><h2>Mapa atual</h2>
<div class="kv">
  <div><b>$nos</b><span>nos</span></div>
  <div><b>$ligacoes</b><span>ligacoes</span></div>
  <div><b>@{[ scalar @files ]}</b><span>arquivos</span></div>
  <div style="min-width:220px"><b style="font-size:13px;font-weight:400">@{[ esc($quando) || "nunca construido" ]}</b><span>ultima construcao</span></div>
</div>
<p class="nota">O mapa tambem e reconstruido sozinho ao fim de cada ciclo de coleta.</p>
@{[ $publicado_nos >= 0 && $publicado_nos != $nos
    ? qq{<div class="msg erro">O grafo esta mostrando um mapa mais antigo: }
      . qq{$publicado_nos no(s), de $publicado_quando. A copia para o diretorio }
      . qq{web nao esta funcionando - veja logs/topology.log.</div>}
    : "" ]}
<p class="nota">O numero acima e o total de nos do arquivo. O cabecalho do grafo
mostra <i>ativos</i>, que desconta servidores de DR, desativados, frames e
desligados: os dois nao coincidem por definicao.</p>
</div>

<div class="cartao"><h2>Enviar arquivo</h2>
<form method="post" enctype="multipart/form-data" action="@{[ esc($self) ]}">
  <input type="file" name="arquivo" accept=".csv,.txt,.xlsx" required>
  <button class="btn" type="submit">Enviar e reconstruir</button>
  <a class="btn" href="@{[ esc($self) ]}?cmd=rebuild">Somente reconstruir</a>
</form>
<p class="nota">Aceita <code>.csv</code>, <code>.txt</code>, <code>.xls</code> e <code>.xlsx</code>, ate @{[ int($MAX_BYTES/1048576) ]} MB.
Colunas reconhecidas, em portugues ou ingles: <code>Hostname</code>, <code>IP Address</code>,
<code>Environment</code>, <code>Location</code>, <code>Function</code>,
<code>Operation Systems</code>, <code>Cluster/Physical Host</code>. As demais sao ignoradas,
e cada aba de uma planilha e lida.</p>
</div>
ESTADO

print qq{<div class="cartao"><h2>Arquivos em uso</h2>\n};
if (@files) {
  print qq{<table><tr><th>Arquivo</th><th class="num">Tamanho</th><th>Enviado em</th><th></th></tr>\n};
  for my $f (@files) {
    printf qq{<tr><td>%s</td><td class="num">%d KB</td><td>%s</td>}
         . qq{<td class="num"><a class="rem" href="%s?cmd=remover&amp;f=%s">remover</a></td></tr>\n},
      esc( $f->{name} ), int( $f->{size} / 1024 ), esc( $f->{mtime} ),
      esc($self), esc( $f->{name} );
  }
  print "</table>\n";
}
else {
  print qq{<p class="nota">Nenhum arquivo ainda. O mapa mostra so o que o }
      . qq{LPAR2RRD/STOR2RRD e os coletores encontraram.</p>\n};
}
print "</div>\n";

if ($log) {
  printf qq{<div class="cartao"><h2>Ultima construcao</h2><pre>%s</pre></div>\n}, esc($log);
}

print "</div></body></html>\n";
