#Requires -Version 5.1
<#
.SYNOPSIS
  coletar_windows.ps1 - Inventario de Windows Server 2008..2022 e Hyper-V via WinRM.
  Equivalente ao run_all.sh do kit Unix: mesmos payloads, mesmo esquema de CSV
  (hostname,categoria,item,chave,valor), mesmos arquivos de falha e identidade.

.DESCRIPTION
  Roda num servidor de salto Windows (PowerShell 5.1) com conta que seja
  administradora local dos alvos (grupo de dominio). Por alvo:
    1. pre-checagem em paralelo: DNS, TTL do ping e porta WinRM
       - TTL <= 64 e WinRM fechado  -> Unix/Linux: nao coleta (hosts_unix.csv)
       - hostname nao resolve/nao conecta -> tenta os IPs da lista
    2. Invoke-Command com TODOS os payloads numa unica sessao por host
    3. separa a saida por payload, grava CSVs, falhas, identidade e .zip

.EXAMPLE
  .\coletar_windows.ps1 -Lista .\piloto_windows.txt
  .\coletar_windows.ps1 -Lista .\lista_windows.txt -Paralelo 24
  .\coletar_windows.ps1 -Lista .\lista_hyperv.txt -Payloads sistema,rede,conexoes,hyperv
  .\coletar_windows.ps1 -Lista .\lista_windows.txt -Credencial (Get-Credential)   # alvos por IP
  .\coletar_windows.ps1 -Lista .\piloto_windows.txt -Teste                        # so acesso
#>
param(
    [string]$Lista = '.\lista_windows.txt',
    [string[]]$Payloads = @('sistema', 'rede', 'seguranca', 'storage', 'monitoracao', 'conexoes', 'hyperv'),
    [int]$Paralelo = 16,
    [int]$Timeout = 420,
    [int]$Amostras = 3,
    [int]$Intervalo = 10,
    [System.Management.Automation.PSCredential]$Credencial,
    [switch]$UsarSSL,
    [switch]$SemTTL,
    [switch]$Teste
)

$ErrorActionPreference = 'Stop'
$BASE = Split-Path -Parent $MyInvocation.MyCommand.Path
$NUM = @{ sistema = '01'; rede = '02'; seguranca = '03'; storage = '04'; monitoracao = '05'; conexoes = '06'; hyperv = '07' }
$PORTA = if ($UsarSSL) { 5986 } else { 5985 }
$DEST = Join-Path $BASE ('coleta_windows_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
New-Item -ItemType Directory -Path $DEST -Force | Out-Null
$LOG = Join-Path $DEST 'execucao.log'
$UTF8 = New-Object System.Text.UTF8Encoding($false)       # CSV sem BOM, como no Unix

function Log([string]$m) {
    $l = '[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $m
    Write-Host $l
    [IO.File]::AppendAllText($LOG, $l + "`r`n", $UTF8)
}
function Gravar([string]$arq, [string[]]$linhas) { [IO.File]::WriteAllLines((Join-Path $DEST $arq), $linhas, $UTF8) }

# ---------------- lista de alvos: "hostname [ip1 ip2 ...]" ----------------
if (-not (Test-Path $Lista)) { throw "lista nao encontrada: $Lista" }
$ALVOS = New-Object System.Collections.ArrayList
foreach ($l in Get-Content $Lista) {
    $t = ($l -replace '#.*$', '').Trim()
    if (-not $t) { continue }
    $f = @($t -split '[\s,;]+')
    if ($f[0] -match '^(hostname|host|servidor|server|ip)$') { continue }
    $ips = @($f | Select-Object -Skip 1 | Where-Object { $_ -match '^\d{1,3}(\.\d{1,3}){3}$' })
    [void]$ALVOS.Add([pscustomobject]@{ Host = $f[0]; Ips = $ips })
}
$ALVOS = @($ALVOS | Sort-Object Host -Unique)
foreach ($p in $Payloads) { if (-not $NUM.ContainsKey($p)) { throw "payload desconhecido: $p" } }
Log "alvos: $($ALVOS.Count) | payloads: $($Payloads -join ',') | paralelo: $Paralelo | timeout/host: ${Timeout}s | WinRM porta $PORTA"

# ---------------- 1. pre-checagem em paralelo (DNS, TTL, porta WinRM) ----------------
$pre = {
    param($alvo, $porta, $semTtl)
    function PortaAberta($h, $p) {
        $c = New-Object Net.Sockets.TcpClient
        try { $ar = $c.BeginConnect($h, $p, $null, $null); $ok = $ar.AsyncWaitHandle.WaitOne(2500) -and $c.Connected; return $ok }
        catch { return $false } finally { $c.Close() }
    }
    function Ttl($h) {
        try { $r = (New-Object Net.NetworkInformation.Ping).Send($h, 1500); if ($r.Status -eq 'Success') { return $r.Options.Ttl } } catch {}
        return $null
    }
    $res = [ordered]@{ Host = $alvo.Host; Destino = ''; Via = ''; Ttl = $null; Estado = ''; Motivo = '' }
    $dns = $true
    try { [void][Net.Dns]::GetHostEntry($alvo.Host) } catch { $dns = $false }
    $cands = @(); if ($dns) { $cands += $alvo.Host }; $cands += $alvo.Ips
    foreach ($c in $cands) {
        if ($res.Ttl -eq $null) { $res.Ttl = Ttl $c }
        if (PortaAberta $c $porta) {
            $res.Destino = $c; $res.Via = $(if ($c -eq $alvo.Host) { 'hostname' } else { 'ip:' + $c }); $res.Estado = 'ok'
            break
        }
    }
    if (-not $res.Estado) {
        if (-not $semTtl -and $res.Ttl -ne $null -and $res.Ttl -le 64) {
            $res.Estado = 'unix'; $res.Motivo = "ttl=$($res.Ttl): Unix/Linux, nao e alvo do kit Windows"
        } elseif (-not $dns -and $alvo.Ips.Count -eq 0) {
            $res.Estado = 'falha'; $res.Motivo = 'dns_nao_resolve'
        } elseif ($res.Ttl -ne $null) {
            $res.Estado = 'falha'; $res.Motivo = "winrm_porta_fechada: responde ao ping (ttl=$($res.Ttl)) mas a porta $porta nao aceita conexao"
        } else {
            $res.Estado = 'falha'; $res.Motivo = "sem_resposta: sem ping e sem porta $porta"
        }
    }
    [pscustomobject]$res
}
$pool = [RunspaceFactory]::CreateRunspacePool(1, [Math]::Max(8, [Math]::Min(64, $Paralelo * 4)))
$pool.Open()
$tarefas = foreach ($a in $ALVOS) {
    $ps = [PowerShell]::Create(); $ps.RunspacePool = $pool
    [void]$ps.AddScript($pre).AddArgument($a).AddArgument($PORTA).AddArgument([bool]$SemTTL)
    [pscustomobject]@{ PS = $ps; H = $ps.BeginInvoke() }
}
$PRE = foreach ($t in $tarefas) { $t.PS.EndInvoke($t.H); $t.PS.Dispose() }
$pool.Close()

$OK = @($PRE | Where-Object { $_.Estado -eq 'ok' })
$UNIX = @($PRE | Where-Object { $_.Estado -eq 'unix' })
$FALHAS = New-Object System.Collections.ArrayList
foreach ($f in ($PRE | Where-Object { $_.Estado -eq 'falha' })) { [void]$FALHAS.Add([pscustomobject]@{ Host = $f.Host; Motivo = $f.Motivo; Via = ''; Payload = '*' }) }
Log "pre-checagem: $($OK.Count) acessiveis | $($UNIX.Count) Unix pelo TTL | $($FALHAS.Count) falhas"
Gravar 'hosts_unix.csv' (@('hostname,evidencia') + @($UNIX | ForEach-Object { $_.Host + ',' + $_.Motivo }))

# ---------------- 2. script remoto: lib + payloads selecionados ----------------
$lib = Get-Content (Join-Path $BASE 'lib.ps1') -Raw -Encoding UTF8
$corpo = New-Object System.Text.StringBuilder
[void]$corpo.AppendLine('param($AMOSTRAS, $INTERVALO)')
[void]$corpo.AppendLine($lib)
foreach ($p in $Payloads) {
    $arq = Get-ChildItem (Join-Path $BASE 'corpo') -Filter ($NUM[$p] + '_*.ps1') | Select-Object -First 1
    [void]$corpo.AppendLine("Write-Output '##PAYLOAD|$p'")
    [void]$corpo.AppendLine('try { & {')
    [void]$corpo.AppendLine((Get-Content $arq.FullName -Raw -Encoding UTF8))
    [void]$corpo.AppendLine("} } catch { Write-Output ('##ERRO|$p|' + (`$_.Exception.Message -replace '[\r\n,]+', ' ')) }")
}
if ($Teste) { $SCRIPT = [scriptblock]::Create('param($a,$b) Write-Output ("##PAYLOAD|teste"); Write-Output ("meta,host,hostname_so," + $env:COMPUTERNAME); Write-Output ("meta,host,ps_versao," + $PSVersionTable.PSVersion)') }
else { $SCRIPT = [scriptblock]::Create($corpo.ToString()) }

# ---------------- 3. execucao remota em paralelo ----------------
$opt = New-PSSessionOption -OpenTimeout 30000 -OperationTimeout ($Timeout * 1000) -CancelTimeout 10000
$SAIDA = @{}
function Classificar([string]$m) {
    $x = $m.ToLower()
    if ($x -match 'access is denied|acesso negado|acceso denegado') { return 'acesso_negado: conta sem administrador local ou sem permissao no WinRM' }
    if ($x -match 'trustedhosts|confi.veis') { return 'trustedhosts: alvo por IP exige TrustedHosts ou HTTPS no servidor de salto' }
    if ($x -match 'kerberos|spn') { return 'kerberos: SPN/nome do alvo; usar FQDN ou -Credencial' }
    if ($x -match 'timed out|tempo limite|timeout|excedeu') { return 'timeout_execucao' }
    if ($x -match 'cannot find the computer|n.o foi poss.vel encontrar|could not be resolved') { return 'dns_nao_resolve' }
    if ($x -match 'winrm cannot complete|cannot connect|n.o pode concluir|n.o . poss.vel conectar') { return 'winrm_inacessivel' }
    return 'erro_winrm'
}

$porDestino = @{}
foreach ($o in $OK) { $porDestino[$o.Destino.ToLower()] = $o }
$lotes = @(
    @{ Nome = 'kerberos'; Alvos = @($OK | Where-Object { $_.Via -eq 'hostname' }) },
    @{ Nome = 'ip';       Alvos = @($OK | Where-Object { $_.Via -like 'ip:*' }) }
)
foreach ($lote in $lotes) {
    if ($lote.Alvos.Count -eq 0) { continue }
    $prm = @{
        ComputerName = @($lote.Alvos | ForEach-Object { $_.Destino }); ScriptBlock = $SCRIPT
        ArgumentList = @($Amostras, $Intervalo); ThrottleLimit = $Paralelo; SessionOption = $opt
        AsJob = $true; Port = $PORTA; ErrorAction = 'SilentlyContinue'
    }
    if ($UsarSSL) { $prm.UseSSL = $true }
    if ($Credencial) { $prm.Credential = $Credencial }
    if ($lote.Nome -eq 'ip') {
        if (-not $Credencial -and -not $UsarSSL) {
            foreach ($a in $lote.Alvos) { [void]$FALHAS.Add([pscustomobject]@{ Host = $a.Host; Via = $a.Via; Payload = '*'
                Motivo = 'hostname_indisponivel: so o IP responde; rode com -Credencial (NTLM) e TrustedHosts, ou -UsarSSL' }) }
            Log "lote por IP ignorado: $($lote.Alvos.Count) host(s) exigem -Credencial"
            continue
        }
        $prm.Authentication = 'Negotiate'
    }
    Log "executando lote $($lote.Nome): $($lote.Alvos.Count) host(s)"
    $job = Invoke-Command @prm
    $limite = (Get-Date).AddSeconds($Timeout * [Math]::Ceiling($lote.Alvos.Count / [double]$Paralelo) + 120)
    while ($job.State -eq 'Running' -and (Get-Date) -lt $limite) {
        $feitos = @($job.ChildJobs | Where-Object { $_.State -ne 'Running' -and $_.State -ne 'NotStarted' }).Count
        Write-Progress -Activity "Coleta Windows ($($lote.Nome))" -Status "$feitos / $($lote.Alvos.Count)" -PercentComplete (100 * $feitos / $lote.Alvos.Count)
        Start-Sleep -Seconds 5
    }
    Write-Progress -Activity 'Coleta Windows' -Completed
    foreach ($cj in $job.ChildJobs) {
        $o = $porDestino[$cj.Location.ToLower()]
        $h = if ($o) { $o.Host } else { $cj.Location }
        if ($cj.State -eq 'Running') {
            Stop-Job $cj
            [void]$FALHAS.Add([pscustomobject]@{ Host = $h; Via = $o.Via; Payload = '*'; Motivo = 'timeout_execucao' })
            continue
        }
        $linhas = @(Receive-Job $cj -ErrorAction SilentlyContinue -ErrorVariable ev | ForEach-Object { [string]$_ })
        if ($cj.State -eq 'Failed' -or ($linhas.Count -eq 0 -and $ev)) {
            $msg = if ($cj.JobStateInfo.Reason) { $cj.JobStateInfo.Reason.Message } else { ($ev | Select-Object -First 1) }
            $msg = ([string]$msg -replace '[\r\n,]+', ' ')
            [void]$FALHAS.Add([pscustomobject]@{ Host = $h; Via = $o.Via; Payload = '*'; Motivo = (Classificar $msg) + ': ' + $msg.Substring(0, [Math]::Min(160, $msg.Length)) })
            continue
        }
        $SAIDA[$h] = @{ Linhas = $linhas; Via = $o.Via }
    }
    Remove-Job $job -Force
}

# ---------------- 4. arquivos por payload (mesmo formato do kit Unix) ----------------
$CAB = 'hostname,categoria,item,chave,valor'
$porPayload = @{}; foreach ($p in $Payloads) { $porPayload[$p] = New-Object System.Collections.ArrayList }
$ident = New-Object System.Collections.ArrayList
foreach ($h in $SAIDA.Keys) {
    $atual = ''
    foreach ($l in $SAIDA[$h].Linhas) {
        if ($l -like '##PAYLOAD|*') { $atual = $l.Substring(10); continue }
        if ($l -like '##ERRO|*') {
            $x = $l.Split('|', 3)
            [void]$FALHAS.Add([pscustomobject]@{ Host = $h; Via = $SAIDA[$h].Via; Payload = $x[1]; Motivo = 'erro_payload: ' + $x[2] })
            continue
        }
        if ($atual -and $porPayload.ContainsKey($atual)) { [void]$porPayload[$atual].Add($h + ',' + $l) }
        if ($l -like 'meta,host,hostname_so,*' -and $atual -eq $Payloads[0]) {
            $real = $l.Substring(22)
            $n1 = ($h -split '\.')[0].ToLower(); $n2 = ($real -split '\.')[0].ToLower()
            if ($n1 -ne $n2) { [void]$ident.Add($h + ',' + $real) }
        }
    }
}
$cons = New-Object System.Collections.ArrayList
[void]$cons.Add('origem,' + $CAB)
foreach ($p in $Payloads) {
    $arq = $NUM[$p] + '_' + $p + '.csv'
    Gravar $arq (@($CAB) + @($porPayload[$p]))
    foreach ($l in $porPayload[$p]) { [void]$cons.Add($arq + ',' + $l) }
    $fl = @('hostname,motivo,duracao_s,via') + @($FALHAS | Where-Object { $_.Payload -eq '*' -or $_.Payload -eq $p } |
          ForEach-Object { $_.Host + ',' + ($_.Motivo -replace ',', ' ') + ',0,' + $_.Via })
    Gravar ($NUM[$p] + '_' + $p + '_falhas.csv') $fl
    $nh = @($porPayload[$p] | ForEach-Object { ($_ -split ',')[0] } | Sort-Object -Unique).Count
    Log ("{0,-12} {1,5} hosts | {2,7} linhas" -f $p, $nh, $porPayload[$p].Count)
}
if (-not $Teste) { Gravar '00_consolidado.csv' $cons }
else {
    # modo teste: so confirma acesso WinRM + administrador e a versao do PowerShell remoto
    $t = @('hostname,hostname_so,ps_versao,via')
    foreach ($h in $SAIDA.Keys) {
        $so = ($SAIDA[$h].Linhas | Where-Object { $_ -like 'meta,host,hostname_so,*' } | Select-Object -First 1) -replace '^meta,host,hostname_so,', ''
        $pv = ($SAIDA[$h].Linhas | Where-Object { $_ -like 'meta,host,ps_versao,*' } | Select-Object -First 1) -replace '^meta,host,ps_versao,', ''
        $t += ($h + ',' + $so + ',' + $pv + ',' + $SAIDA[$h].Via)
    }
    Gravar 'teste_acesso.csv' $t
    Log "teste: $($SAIDA.Count) host(s) com acesso confirmado (teste_acesso.csv)"
}
Gravar 'identidade_divergente.csv' (@('alvo,hostname_real') + @($ident))
Gravar 'hosts_com_falha.txt' @($FALHAS | ForEach-Object { $_.Host } | Sort-Object -Unique)

Log "coletados: $($SAIDA.Count) | falhas: $(@($FALHAS | ForEach-Object { $_.Host } | Sort-Object -Unique).Count) | Unix pelo TTL: $($UNIX.Count)"
if ($ident.Count -gt 0) { Log "AVISO: $($ident.Count) alvo(s) responderam com outro hostname (identidade_divergente.csv)" }
$causas = $FALHAS | ForEach-Object { ($_.Motivo -split ':')[0] } | Group-Object | Sort-Object Count -Descending
foreach ($c in $causas) { Log ("   falha {0,4}  {1}" -f $c.Count, $c.Name) }

$zip = $DEST + '.zip'
Compress-Archive -Path $DEST -DestinationPath $zip -Force
Log "pacote: $zip"
