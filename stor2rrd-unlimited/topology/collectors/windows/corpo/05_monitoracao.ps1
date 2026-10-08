# ============================================================
# 05-MONITORACAO: agentes (monitoracao, backup, seguranca), servicos,
# tarefas agendadas, SNMP, SMTP e erros recentes no log
# ============================================================
Emit-Meta

# Agentes conhecidos, pelo nome do servico (independe de idioma)
$agentes = @{
    'Zabbix Agent' = 'zabbix'; 'Zabbix Agent 2' = 'zabbix';
    'HealthService' = 'scom'; 'PatrolAgent' = 'patrol'; 'BMCPatrolAgent' = 'patrol';
    'dsmcad' = 'tsm'; 'TSM Client Acceptor' = 'tsm'; 'TSM Client Scheduler' = 'tsm';
    'NetBackup Client Service' = 'netbackup'; 'bpinetd' = 'netbackup';
    'VeeamTransportSvc' = 'veeam'; 'VeeamDeploySvc' = 'veeam'; 'GxCVD(Instance001)' = 'commvault';
    'DatadogAgent' = 'datadog'; 'SplunkForwarder' = 'splunk'; 'nscp' = 'nsclient';
    'ccmexec' = 'sccm'; 'W3SVC' = 'iis'; 'SNMP' = 'snmp'; 'MSSQLSERVER' = 'sqlserver';
    'lpar2rrd-agent' = 'lpar2rrd'; 'AmazonSSMAgent' = 'aws_ssm'; 'WindowsAzureGuestAgent' = 'azure_agent';
    'VMTools' = 'vmware_tools'; 'vmicheartbeat' = 'hyperv_integration'; 'Nutanix Guest Agent' = 'nutanix_ngt'
}
$svcs = @(Wmi 'Win32_Service')
$porNome = @{}
foreach ($s in $svcs) { $porNome[$s.Name] = $s }
foreach ($k in $agentes.Keys) {
    if ($porNome.ContainsKey($k)) {
        Emit 'monitoracao' 'agente' ($agentes[$k] + ':' + $k) ([string]$porNome[$k].State)
    }
}
# Instancias nomeadas de SQL Server
foreach ($s in ($svcs | Where-Object { $_.Name -match '^MSSQL\$' })) { Emit 'monitoracao' 'agente' ('sqlserver:' + $s.Name) ([string]$s.State) }

# Servicos automaticos: rodando e parados (parado + automatico = problema)
$auto = @($svcs | Where-Object { $_.StartMode -eq 'Auto' })
$rodando = @($auto | Where-Object { $_.State -eq 'Running' } | ForEach-Object { $_.Name } | Sort-Object)
$parados = @($auto | Where-Object { $_.State -ne 'Running' } | ForEach-Object { $_.Name } | Sort-Object)
Emit 'servicos' 'ativos' 'windows' (($rodando -join ' '))
Emit 'servicos' 'automaticos_parados' 'windows' (($parados -join ' '))
# Servicos de terceiros rodando com conta de dominio (dependencia de AD e risco de senha)
foreach ($s in ($svcs | Where-Object { $_.StartName -and $_.StartName -notmatch '^(LocalSystem|NT AUTHORITY|NT Service|\.\\|LocalService|NetworkService)' })) {
    Emit 'servicos' 'conta_servico' $s.Name $s.StartName
}

# Tarefas agendadas fora do \Microsoft\ (CSV do schtasks: cabecalho localizado, colunas fixas)
$tar = @(& schtasks.exe /query /fo csv /nh 2>$null)
$proprias = @()
foreach ($l in $tar) {
    $c = @($l -split '","')
    if ($c.Count -ge 1) {
        $nome = $c[0].Trim('"')
        if ($nome -and $nome -notmatch '^\\Microsoft\\' -and $proprias -notcontains $nome) { $proprias += $nome }
    }
}
Emit 'cron' 'tarefas' 'qtd' $proprias.Count
$i = 0
foreach ($t in $proprias) { if ($i -ge 80) { break }; Emit 'cron' 'tarefa' ([string]$i) $t; $i++ }

# SNMP: comunidades e gerentes permitidos
$snmp = 'HKLM:\SYSTEM\CurrentControlSet\Services\SNMP\Parameters'
if (Test-Path $snmp) {
    $com = @()
    try { $com = @((Get-Item ($snmp + '\ValidCommunities') -ErrorAction Stop).GetValueNames()) } catch {}
    Emit 'monitoracao' 'snmp' 'comunidades_qtd' $com.Count
    $ger = @()
    try { $k = Get-Item ($snmp + '\PermittedManagers') -ErrorAction Stop; foreach ($n in $k.GetValueNames()) { $ger += $k.GetValue($n) } } catch {}
    Emit 'monitoracao' 'snmp' 'gerentes' ($ger -join ' ')
}

# Erros de sistema nas ultimas 24h (limitado: evita varrer logs grandes)
try {
    $ev = @(Get-EventLog -LogName System -EntryType Error -After (Get-Date).AddHours(-24) -Newest 500 -ErrorAction Stop)
    Emit 'monitoracao' 'eventos' 'erros_sistema_24h' $ev.Count
    $top = $ev | Group-Object Source | Sort-Object Count -Descending | Select-Object -First 5
    Emit 'monitoracao' 'eventos' 'fontes_mais_frequentes' ((@($top) | ForEach-Object { $_.Name + '(' + $_.Count + ')' }) -join ' ')
} catch {}

# Backup nativo do Windows
if (Tem-Comando 'wbadmin.exe') {
    $wb = @(& wbadmin.exe get versions 2>$null | Where-Object { $_ -match '\d{1,2}/\d{1,2}/\d{4}' })
    if ($wb.Count -gt 0) { Emit 'backup' 'wbadmin' 'versoes' $wb.Count }
}
