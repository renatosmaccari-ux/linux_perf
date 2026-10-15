# ============================================================
# lib.ps1 - preambulo comum dos payloads Windows
# Executado REMOTAMENTE via WinRM (Invoke-Command) como administrador local.
# Compativel com Windows PowerShell 2.0 (Server 2008/2008 R2) ate 5.1 (2022):
#   sem Get-CimInstance, sem objetos customizados do PS3+, sem hashtable ordenada, sem -in/-notin,
#   sem ConvertTo-Json, sem construtor estatico do PS5. Saida: linhas "categoria,item,chave,valor",
#   o mesmo esquema dos payloads Unix.
# Textos localizados (pt-BR, es-ES) sao evitados: politica via secedit,
# firewall e NTP via registro, grupos por SID, estados TCP normalizados.
# ============================================================
$ErrorActionPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'

function Esc([string]$s) {
    if ($s -eq $null) { return '' }
    $s = ($s -replace "[`r`n]+", ' ').Trim()
    if ($s -match '[,"]') { return '"' + ($s -replace '"', '""') + '"' }
    return $s
}

function Emit($c, $i, $k, $v) {
    if ($v -eq $null) { return }
    $t = [string]$v
    if ($t.Trim() -eq '') { return }
    Write-Output ((Esc $c) + ',' + (Esc $i) + ',' + (Esc $k) + ',' + (Esc $t))
}

function Wmi([string]$classe, [string]$filtro = '', [string]$ns = 'root\cimv2') {
    try {
        if ($filtro) { return @(Get-WmiObject -Class $classe -Filter $filtro -Namespace $ns -ErrorAction Stop) }
        return @(Get-WmiObject -Class $classe -Namespace $ns -ErrorAction Stop)
    } catch { return @() }
}

function RegVal([string]$caminho, [string]$nome) {
    try { return (Get-ItemProperty -Path $caminho -Name $nome -ErrorAction Stop).$nome } catch { return $null }
}

function WmiData($valor) {
    # datas WMI (20240101120000.000000-180) -> ISO
    if (-not $valor) { return '' }
    try { return ([Management.ManagementDateTimeConverter]::ToDateTime($valor)).ToString('yyyy-MM-dd HH:mm') } catch { return '' }
}

function Mask2Cidr([string]$m) {
    if (-not $m) { return '' }
    $n = 0
    foreach ($o in $m.Split('.')) {
        $b = [Convert]::ToString([int]$o, 2)
        $n += ($b.ToCharArray() | Where-Object { $_ -eq '1' }).Count
    }
    return $n
}

function Tem-Comando([string]$nome) {
    return [bool](Get-Command $nome -ErrorAction SilentlyContinue)
}

# Contexto do host, lido uma vez
$OS = @(Wmi 'Win32_OperatingSystem')[0]
$CS = @(Wmi 'Win32_ComputerSystem')[0]
$PAPEL = [int]$CS.DomainRole            # 0/1 estacao, 2/3 servidor, 4/5 controlador de dominio
$EH_DC = ($PAPEL -ge 4)

function Emit-Meta {
    Emit 'meta' 'host' 'plataforma' 'windows'
    Emit 'meta' 'host' 'distro' $OS.Caption
    Emit 'meta' 'host' 'versao' $OS.Version
    Emit 'meta' 'host' 'build' $OS.BuildNumber
    Emit 'meta' 'host' 'service_pack' $OS.CSDVersion
    Emit 'meta' 'host' 'hostname_so' $env:COMPUTERNAME
    Emit 'meta' 'host' 'dominio' $CS.Domain
    Emit 'meta' 'host' 'coleta_utc' ((Get-Date).ToUniversalTime().ToString('s') + 'Z')
    Emit 'meta' 'host' 'ps_versao' ($PSVersionTable.PSVersion.ToString())
    Emit 'meta' 'host' 'idioma' $OS.OSLanguage
}
