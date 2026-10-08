# ============================================================
# 06-CONEXOES: sockets TCP de entrada e saida para a topologia.
# Mesmo formato de saida do payload Unix. Diferenca a favor: o Windows
# informa o PID de TODA conexao, entao a saida tambem traz o processo.
# ============================================================
Emit-Meta

if ($AMOSTRAS -eq $null)  { $AMOSTRAS = 3 }
if ($INTERVALO -eq $null) { $INTERVALO = 10 }
# Tetos por host, agora vindos do ambiente com os mesmos valores por omissao:
# num ambiente com gateways, o teto fixo descartava dezenas de milhares de
# arestas e so a linha "truncado_entrada" do resumo o denunciava.
$MAX_EDGE = if ($env:TOPO_MAX_EDGE) { [int]$env:TOPO_MAX_EDGE } else { 1200 }
$LIMIAR_FANIN = if ($env:TOPO_LIMIAR_FANIN) { [int]$env:TOPO_LIMIAR_FANIN } else { 150 }
$EFEMERA = 49152            # faixa dinamica padrao do Windows 2008+

# ---------- identidade do no ----------
foreach ($c in (Wmi 'Win32_NetworkAdapterConfiguration' 'IPEnabled=True')) {
    foreach ($ip in @($c.IPAddress)) {
        if ($ip -match '^\d+\.\d+\.\d+\.\d+$' -and $ip -notmatch '^(127\.|169\.254\.|0\.0\.0\.0)') {
            Emit 'conexao' 'ip_local' ('if' + $c.Index) $ip
        }
    }
}
$hf = Join-Path $env:windir 'System32\drivers\etc\hosts'
$n = 0
foreach ($l in @(Get-Content $hf -ErrorAction SilentlyContinue)) {
    $t = ($l -replace '#.*$', '').Trim()
    if ($t -match '^(\d+\.\d+\.\d+\.\d+)\s+(.+)$' -and $matches[1] -notmatch '^127\.') {
        Emit 'conexao' 'hosts_file' $matches[1] ($matches[2] -replace '\s+', ' ')
        $n++; if ($n -ge 300) { break }
    }
}

# ---------- nome de servico por porta (o Windows tambem tem o arquivo services) ----------
$SVC = @{}
foreach ($l in @(Get-Content (Join-Path $env:windir 'System32\drivers\etc\services') -ErrorAction SilentlyContinue)) {
    if ($l -match '^\s*([A-Za-z0-9._-]+)\s+(\d+)/tcp') { if (-not $SVC.ContainsKey($matches[2])) { $SVC[$matches[2]] = $matches[1] } }
}

# ---------- PID -> processo (svchost ganha o nome do servico) ----------
$PROC = @{}
foreach ($p in @(Get-Process -ErrorAction SilentlyContinue)) { $PROC[[string]$p.Id] = $p.ProcessName }
foreach ($s in (Wmi 'Win32_Service' 'State="Running"')) {
    $k = [string]$s.ProcessId
    if ($PROC.ContainsKey($k) -and $PROC[$k] -eq 'svchost') { $PROC[$k] = 'svchost(' + $s.Name + ')' }
}

# ---------- snapshots ----------
$MAPA_ESTADO = @{
    'LISTEN' = 'LISTEN'; 'LISTENING' = 'LISTEN'; 'ESCUTANDO' = 'LISTEN'; 'ESCUCHANDO' = 'LISTEN';
    'ESTABLISHED' = 'ESTABLISHED'; 'ESTABELECIDA' = 'ESTABLISHED'; 'ESTABELECIDO' = 'ESTABLISHED';
    'ESTABLECIDO' = 'ESTABLISHED'; 'HERGESTELLT' = 'ESTABLISHED';
    'TIMEWAIT' = 'TIME_WAIT'; 'TIME_WAIT' = 'TIME_WAIT'; 'CLOSEWAIT' = 'CLOSE_WAIT'; 'CLOSE_WAIT' = 'CLOSE_WAIT';
    'SYNSENT' = 'SYN_SENT'; 'SYN_SENT' = 'SYN_SENT'; 'FINWAIT1' = 'FIN_WAIT_1'; 'FIN_WAIT_1' = 'FIN_WAIT_1';
    'FINWAIT2' = 'FIN_WAIT_2'; 'FIN_WAIT_2' = 'FIN_WAIT_2'; 'LASTACK' = 'LAST_ACK'; 'LAST_ACK' = 'LAST_ACK';
    'CLOSING' = 'CLOSING'
}
$USA_NET = Tem-Comando 'Get-NetTCPConnection'
$FONTE = if ($USA_NET) { 'Get-NetTCPConnection' } else { 'netstat' }
$REG = New-Object System.Collections.ArrayList

function Snapshot($s) {
    if ($USA_NET) {
        foreach ($c in @(Get-NetTCPConnection -ErrorAction SilentlyContinue)) {
            if ([string]$c.LocalAddress -notmatch '^\d+\.\d+\.\d+\.\d+$') { continue }
            $e = ([string]$c.State).ToUpper()
            if ($MAPA_ESTADO.ContainsKey($e)) { $e = $MAPA_ESTADO[$e] }
            [void]$REG.Add(@($s, [string]$c.LocalAddress, [int]$c.LocalPort, [string]$c.RemoteAddress, [int]$c.RemotePort, $e, [string]$c.OwningProcess))
        }
    } else {
        foreach ($l in @(netstat -ano -p tcp)) {
            $f = @($l.Trim() -split '\s+')
            if ($f.Count -lt 5 -or $f[0] -ne 'TCP') { continue }
            $la = $f[1]; $ra = $f[2]
            $li = $la.LastIndexOf(':'); $ri = $ra.LastIndexOf(':')
            if ($li -lt 1 -or $ri -lt 1) { continue }
            $lp = $la.Substring($li + 1); $rp = $ra.Substring($ri + 1)
            if ($lp -notmatch '^\d+$' -or $rp -notmatch '^\d+$') { continue }
            # escuta: remoto :0 (a palavra de estado vem traduzida no Windows em portugues)
            $e = if ([int]$rp -eq 0) { 'LISTEN' } else { $f[3].ToUpper() }
            if ($MAPA_ESTADO.ContainsKey($e)) { $e = $MAPA_ESTADO[$e] }
            [void]$REG.Add(@($s, $la.Substring(0, $li), [int]$lp, $ra.Substring(0, $ri), [int]$rp, $e, $f[-1]))
        }
    }
}
for ($s = 1; $s -le $AMOSTRAS; $s++) {
    Snapshot $s
    if ($s -lt $AMOSTRAS) { Start-Sleep -Seconds $INTERVALO }
}

# ---------- agregacao (mesmas regras do payload Unix) ----------
$LIS = @{}; $BIND = @{}
foreach ($r in $REG) { if ($r[5] -eq 'LISTEN') { $LIS[[string]$r[2]] = $r[6]; $BIND[$r[1] + '|' + $r[2]] = $r[6] } }

$VALIDOS = @('ESTABLISHED', 'TIME_WAIT', 'CLOSE_WAIT', 'SYN_SENT', 'FIN_WAIT_1', 'FIN_WAIT_2', 'LAST_ACK', 'CLOSING')
$AG = @{}; $FANIN = @{}; $FANNET = @{}; $VISTO = @{}; $local = 0
foreach ($r in $REG) {
    $sa = $r[0]; $lip = $r[1]; $lp = $r[2]; $rip = $r[3]; $rp = $r[4]; $e = $r[5]; $pidc = $r[6]
    if ($e -eq 'LISTEN') { continue }
    if ($VALIDOS -notcontains $e) { continue }
    if ($rip -eq '0.0.0.0' -or $rp -eq 0) { continue }
    if ($rip -match '^127\.' -or $lip -match '^127\.' -or $rip -eq $lip) { $local++; continue }

    if ($LIS.ContainsKey([string]$lp))          { $dir = 'entrada'; $conf = 'listen';  $porta = $lp }
    elseif ($rp -lt 1024 -and $lp -ge 1024)      { $dir = 'saida';   $conf = 'porta';   $porta = $rp }
    elseif ($lp -ge $EFEMERA -and $rp -lt $EFEMERA) { $dir = 'saida'; $conf = 'efemera'; $porta = $rp }
    elseif ($rp -ge $EFEMERA -and $lp -lt $EFEMERA) { $dir = 'entrada'; $conf = 'efemera'; $porta = $lp }
    else                                          { $dir = 'saida';   $conf = 'assumido'; $porta = $rp }

    $k = $dir + '|' + $rip + '|' + $porta
    if (-not $AG.ContainsKey($k)) {
        $AG[$k] = @{ dir = $dir; rip = $rip; porta = $porta; lip = $lip; ses = 0; amo = 0; est = @(); conf = $conf; proc = '' }
    }
    $a = $AG[$k]
    $tup = $k + '#' + $lip + ':' + $lp + '>' + $rp
    if (-not $VISTO.ContainsKey($tup)) { $VISTO[$tup] = 1; $a['ses'] = $a['ses'] + 1 }
    $ks = $k + '#s' + $sa
    if (-not $VISTO.ContainsKey($ks)) { $VISTO[$ks] = 1; $a['amo'] = $a['amo'] + 1 }
    if ($a['est'] -notcontains $e) { $a['est'] = @($a['est']) + @($e) }
    if ($conf -eq 'listen') { $a['conf'] = 'listen' }
    $pidp = if ($dir -eq 'entrada' -and $LIS.ContainsKey([string]$lp)) { $LIS[[string]$lp] } else { $pidc }
    if (-not $a['proc'] -and $PROC.ContainsKey([string]$pidp)) { $a['proc'] = $PROC[[string]$pidp] }

    if ($dir -eq 'entrada') {
        $kf = [string]$porta + '|' + $rip
        if (-not $VISTO.ContainsKey('f' + $kf)) { $VISTO['f' + $kf] = 1; $FANIN[[string]$porta] = [int]$FANIN[[string]$porta] + 1 }
        $o = $rip.Split('.'); $net = $o[0] + '.' + $o[1] + '.' + $o[2] + '.0/24'
        $kn = [string]$porta + '|' + $net
        if (-not $VISTO.ContainsKey('n' + $kn + '|' + $rip)) { $VISTO['n' + $kn + '|' + $rip] = 1; $FANNET[$kn] = [int]$FANNET[$kn] + 1 }
    }
}

function NomeSvc($p) { $x = [string]$p; if ($SVC.ContainsKey($x)) { return $SVC[$x] } return '-' }

# ---------- emissao ----------
$listen = @($BIND.Keys | Sort-Object)
foreach ($b in $listen) {
    $porta = ($b -split '\|')[1]; $pidl = $BIND[$b]
    $pn = if ($PROC.ContainsKey([string]$pidl)) { $PROC[[string]$pidl] } else { '-' }
    Emit 'conexao' 'listen' $b ((NomeSvc $porta) + '|' + $pn + '|' + $pidl + '|-')
}
Emit 'conexao' 'resumo' 'total_listen' $listen.Count

foreach ($dir in @('entrada', 'saida')) {
    $itens = @($AG.Values | Where-Object { $_.dir -eq $dir } | Sort-Object { $_.ses } -Descending)
    $i = 0
    foreach ($a in $itens) {
        if ($i -ge $MAX_EDGE) { break }
        $proc = if ($a.proc) { $a.proc } else { '-' }
        Emit 'conexao' $dir ($a.rip + '|' + $a.porta) ((NomeSvc $a.porta) + '|' + $a.lip + '|' + $a.ses + '|' + $a.amo + '|' + ($a.est -join '+') + '|' + $proc + '|' + $a.conf)
        $i++
    }
    Emit 'conexao' 'resumo' ('total_' + $dir) $itens.Count
    if ($itens.Count -gt $MAX_EDGE) { Emit 'conexao' 'resumo' ('truncado_' + $dir) ($itens.Count - $MAX_EDGE) }
}
foreach ($p in @($FANIN.Keys)) { Emit 'conexao' 'fanin' $p ((NomeSvc $p) + '|' + $FANIN[$p]) }
foreach ($kn in @($FANNET.Keys)) {
    $p = ($kn -split '\|')[0]
    if ([int]$FANIN[$p] -gt $LIMIAR_FANIN) {
        $net = ($kn -split '\|')[1]
        Emit 'conexao' 'fanin_rede' ($net + '|' + $p) ((NomeSvc $p) + '|' + $FANNET[$kn])
    }
}
Emit 'conexao' 'resumo' 'limiar_fanin' $LIMIAR_FANIN
Emit 'conexao' 'resumo' 'max_edge' $MAX_EDGE
Emit 'conexao' 'resumo' 'amostras' $AMOSTRAS
Emit 'conexao' 'resumo' 'intervalo_s' $INTERVALO
Emit 'conexao' 'resumo' 'fonte' $FONTE
Emit 'conexao' 'resumo' 'linhas_snapshot' $REG.Count
Emit 'conexao' 'resumo' 'loopback_descartadas' $local
Emit 'conexao' 'resumo' 'ipv6' 'nao_coletado'
