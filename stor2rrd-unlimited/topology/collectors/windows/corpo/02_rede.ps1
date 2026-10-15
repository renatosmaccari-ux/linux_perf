# ============================================================
# 02-REDE: interfaces, IPs, gateway, rotas, DNS, NTP, teaming e portas
# ============================================================
Emit-Meta

$ADS = @{}
foreach ($a in (Wmi 'Win32_NetworkAdapter' 'PhysicalAdapter=True OR NetConnectionID IS NOT NULL')) { $ADS[[string]$a.Index] = $a }

foreach ($c in (Wmi 'Win32_NetworkAdapterConfiguration' 'IPEnabled=True')) {
    $a = $ADS[[string]$c.Index]
    $nome = if ($a -and $a.NetConnectionID) { $a.NetConnectionID } else { 'if' + $c.Index }
    $ips = @($c.IPAddress | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    $mks = @($c.IPSubnet  | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' })
    for ($j = 0; $j -lt $ips.Count; $j++) {
        $sufixo = if ($j -gt 0) { ':' + $j } else { '' }
        Emit 'rede' ($nome + $sufixo) 'ip' $ips[$j]
        if ($j -lt $mks.Count) {
            Emit 'rede' ($nome + $sufixo) 'netmask' $mks[$j]
            Emit 'rede' ($nome + $sufixo) 'cidr' ($ips[$j] + '/' + (Mask2Cidr $mks[$j]))
        }
    }
    Emit 'rede' $nome 'mac'      $c.MACAddress
    Emit 'rede' $nome 'gateway'  (@($c.DefaultIPGateway) -join ' ')
    Emit 'rede' $nome 'dhcp'     $(if ($c.DHCPEnabled) { 'sim' } else { 'nao' })
    Emit 'rede' $nome 'dns'      (@($c.DNSServerSearchOrder) -join ' ')
    Emit 'rede' $nome 'sufixo_dns' $c.DNSDomain
    if ($a) {
        Emit 'rede' $nome 'adaptador' $a.Name
        if ($a.Speed) { Emit 'rede' $nome 'velocidade' ([string]([math]::Round([double]$a.Speed / 1000000)) + ' Mb/s') }
    }
}

# Default gateway consolidado (mesma chave usada no Unix)
$gw = @(Wmi 'Win32_IP4RouteTable' "Destination='0.0.0.0'")
if ($gw.Count -gt 0) { Emit 'rede' 'rota' 'gateway_default' $gw[0].NextHop }
foreach ($r in (Wmi 'Win32_IP4RouteTable')) {
    if ($r.Destination -eq '0.0.0.0' -or $r.Destination -match '^(127\.|224\.|255\.)') { continue }
    if ($r.Mask -eq '255.255.255.255') { continue }
    $gwr = if ($r.NextHop -eq '0.0.0.0') { 'direto' } else { $r.NextHop }
    Emit 'rede' 'rota_estatica' ($r.Destination + '/' + (Mask2Cidr $r.Mask)) $gwr
}

# Teaming (2012+: LBFO)
if (Tem-Comando 'Get-NetLbfoTeam') {
    foreach ($t in @(Get-NetLbfoTeam)) {
        Emit 'rede' $t.Name 'team_modo' ([string]$t.TeamingMode + '/' + [string]$t.LoadBalancingAlgorithm)
        Emit 'rede' $t.Name 'team_membros' (@($t.Members) -join ' ')
    }
}

# DNS e NTP (registro: nao depende do idioma do w32tm)
$dns = @()
foreach ($c in (Wmi 'Win32_NetworkAdapterConfiguration' 'IPEnabled=True')) { $dns += @($c.DNSServerSearchOrder) }
Emit 'rede' 'dns' 'servidores' ((@($dns | Where-Object { $_ } | Sort-Object -Unique)) -join ' ')
$w32 = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters'
Emit 'rede' 'ntp' 'tipo' (RegVal $w32 'Type')
Emit 'rede' 'ntp' 'servidores' ((([string](RegVal $w32 'NtpServer')) -replace ',0x[0-9a-f]+', '') -replace '\s+', ' ')

# Portas TCP em escuta (evidencia de servicos expostos)
$portas = @()
if (Tem-Comando 'Get-NetTCPConnection') {
    $portas = @(Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | ForEach-Object { $_.LocalPort })
} else {
    foreach ($l in @(netstat -ano -p tcp)) {
        $f = @($l.Trim() -split '\s+')
        # escuta = endereco remoto 0.0.0.0:0, independente do idioma da palavra de estado
        if ($f.Count -ge 4 -and $f[0] -eq 'TCP' -and $f[2] -match ':0$') { $portas += ($f[1] -split ':')[-1] }
    }
}
foreach ($p in @($portas | Sort-Object { [int]$_ } -Unique)) { Emit 'rede' 'portas' 'listen_tcp' $p }
