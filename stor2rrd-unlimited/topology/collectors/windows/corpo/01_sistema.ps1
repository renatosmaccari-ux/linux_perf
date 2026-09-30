# ============================================================
# 01-SISTEMA: SO, hardware, virtualizacao, papeis e aplicacoes
# ============================================================
Emit-Meta

Emit 'so' 'versao' 'caption'      $OS.Caption
Emit 'so' 'versao' 'version'      $OS.Version
Emit 'so' 'versao' 'service_pack' $OS.CSDVersion
Emit 'so' 'kernel' 'arch'         $OS.OSArchitecture
Emit 'so' 'versao' 'instalado_em' (WmiData $OS.InstallDate)
Emit 'so' 'tempo' 'ultimo_boot'   (WmiData $OS.LastBootUpTime)
try {
    $up = (Get-Date) - [Management.ManagementDateTimeConverter]::ToDateTime($OS.LastBootUpTime)
    Emit 'so' 'tempo' 'uptime_dias' ([math]::Round($up.TotalDays, 1))
} catch {}
Emit 'so' 'tz' 'zona' (@(Wmi 'Win32_TimeZone')[0].Caption)
Emit 'so' 'dominio' 'nome' $CS.Domain
Emit 'so' 'dominio' 'papel' @('estacao', 'estacao membro', 'servidor', 'servidor membro', 'controlador de dominio backup', 'controlador de dominio primario')[$PAPEL]
Emit 'so' 'licenca' 'produto_id' $OS.SerialNumber

# ---------- hardware / plataforma ----------
$BIOS = @(Wmi 'Win32_BIOS')[0]
Emit 'frame' 'modelo' 'fabricante'  $CS.Manufacturer
Emit 'frame' 'modelo' 'tipo_modelo' $CS.Model
Emit 'frame' 'serial' 'frame_serial' $BIOS.SerialNumber
Emit 'frame' 'firmware' 'bios'      ($BIOS.SMBIOSBIOSVersion + ' ' + (WmiData $BIOS.ReleaseDate))

# Virtualizacao: o modelo do "hardware" denuncia o hipervisor
$mod = ([string]$CS.Model + ' ' + [string]$CS.Manufacturer).ToLower()
$virt = ''
if ($mod -match 'virtual machine' -and $mod -match 'microsoft') { $virt = 'Hyper-V' }
elseif ($mod -match 'vmware') { $virt = 'VMware' }
elseif ($mod -match 'ahv|nutanix') { $virt = 'Nutanix AHV' }
elseif ($mod -match 'kvm|qemu|red hat|ovirt') { $virt = 'KVM/RHV' }
elseif ($mod -match 'xen') { $virt = 'Xen' }
elseif ($mod -match 'amazon|ec2') { $virt = 'AWS EC2' }
elseif ($mod -match 'google') { $virt = 'GCP' }
Emit 'lpar' 'virt' 'tipo' $(if ($virt) { $virt } else { 'fisico' })
Emit 'lpar' 'virt' 'escopo' $(if ($virt) { 'vm' } else { 'fisico' })

# Convidado Hyper-V sabe em qual host fisico roda (integration services / KVP)
$kvp = 'HKLM:\SOFTWARE\Microsoft\Virtual Machine\Guest\Parameters'
$hostfis = RegVal $kvp 'PhysicalHostNameFullyQualified'
if (-not $hostfis) { $hostfis = RegVal $kvp 'PhysicalHostName' }
Emit 'lpar' 'virt' 'host_fisico' $hostfis
Emit 'lpar' 'virt' 'vm_nome_no_host' (RegVal $kvp 'VirtualMachineName')

# ---------- CPU / memoria ----------
$CPUS = Wmi 'Win32_Processor'
Emit 'cpu' 'fisico' 'sockets' $CPUS.Count
$cores = 0; $logicos = 0
foreach ($p in $CPUS) { $cores += [int]$p.NumberOfCores; $logicos += [int]$p.NumberOfLogicalProcessors }
if ($cores -eq 0) { $logicos = [int]$CS.NumberOfProcessors }       # 2008 sem hotfix nao expoe cores
Emit 'cpu' 'fisico' 'cores' $cores
Emit 'cpu' 'logico' 'vcpu' $(if ($logicos) { $logicos } else { [int]$CS.NumberOfLogicalProcessors })
Emit 'cpu' 'modelo' 'nome' (@($CPUS)[0].Name -replace '\s+', ' ')
Emit 'cpu' 'modelo' 'mhz' (@($CPUS)[0].MaxClockSpeed)
Emit 'mem' 'real' 'mb' ([math]::Round([double]$CS.TotalPhysicalMemory / 1MB))
Emit 'mem' 'livre' 'mb' ([math]::Round([double]$OS.FreePhysicalMemory / 1KB))
$pf = Wmi 'Win32_PageFileUsage'
$pft = 0; foreach ($p in $pf) { $pft += [int]$p.AllocatedBaseSize }
Emit 'mem' 'swap' 'total_mb' $pft

# ---------- discos (resumo; detalhe no payload de storage) ----------
$dd = Wmi 'Win32_DiskDrive'
$tot = 0; foreach ($d in $dd) { $tot += [double]$d.Size }
Emit 'disco' 'qtd' 'luns' $dd.Count
Emit 'disco' 'alocado' 'total_mb' ([math]::Round($tot / 1MB))

# ---------- papeis e recursos do Windows (2008+, sem ServerManager) ----------
$feat = Wmi 'Win32_ServerFeature'
if ($feat.Count -gt 0) {
    Emit 'so' 'papeis' 'qtd' $feat.Count
    Emit 'so' 'papeis' 'lista' ((($feat | ForEach-Object { $_.Name }) | Sort-Object) -join '; ')
}

# ---------- aplicacoes: registro (NUNCA Win32_Product: dispara reconfiguracao MSI) ----------
$apps = @()
foreach ($r in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                 'HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall')) {
    foreach ($k in @(Get-ChildItem $r -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty $k.PSPath -ErrorAction SilentlyContinue
        if ($p.DisplayName -and -not $p.SystemComponent -and $p.DisplayName -notmatch '^(Update for|Security Update|Hotfix|KB\d)') {
            $apps += ($p.DisplayName + $(if ($p.DisplayVersion) { ' ' + $p.DisplayVersion } else { '' }))
        }
    }
}
$apps = @($apps | Sort-Object -Unique)
Emit 'app' 'instalados' 'qtd' $apps.Count
$i = 0
foreach ($a in $apps) { if ($i -ge 300) { break }; Emit 'app' 'instalado' ([string]$i) $a; $i++ }

# Evidencias de aplicacao que importam para a topologia
$inst = @()
try { $inst = @((Get-Item 'HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL' -ErrorAction Stop).GetValueNames()) } catch {}
if ($inst.Count -gt 0) { Emit 'app' 'sqlserver' 'instancias' ($inst -join ' ') }
$ora = @($apps | Where-Object { $_ -match 'Oracle.*(Database|Client|Home)' })
if ($ora.Count -gt 0) { Emit 'app' 'oracle' 'produtos' ($ora -join '; ') }
$appcmd = Join-Path $env:windir 'system32\inetsrv\appcmd.exe'
if (Test-Path $appcmd) {
    $sites = @(& $appcmd list site 2>$null)
    Emit 'app' 'iis' 'sites_qtd' $sites.Count
    $i = 0
    foreach ($s in $sites) { if ($i -ge 50) { break }; Emit 'app' 'iis_site' ([string]$i) $s; $i++ }
}
if (Get-Service -Name 'MSExchangeIS' -ErrorAction SilentlyContinue) { Emit 'app' 'exchange' 'presente' 'sim' }
if (Get-Service -Name 'NTDS' -ErrorAction SilentlyContinue) { Emit 'app' 'active_directory' 'dc' 'sim' }
if (Get-Service -Name 'DNS' -ErrorAction SilentlyContinue) { Emit 'app' 'dns_server' 'presente' 'sim' }
if (Get-Service -Name 'vmms' -ErrorAction SilentlyContinue) { Emit 'app' 'hyperv' 'host' 'sim' }
if (Get-Service -Name 'ClusSvc' -ErrorAction SilentlyContinue) {
    $cl = @(Wmi 'MSCluster_Cluster' '' 'root\MSCluster')[0]
    Emit 'app' 'cluster' 'nome' $cl.Name
    Emit 'app' 'cluster' 'nos' ((@(Wmi 'MSCluster_Node' '' 'root\MSCluster') | ForEach-Object { $_.Name }) -join ' ')
}

# ---------- atualizacoes ----------
$hf = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object { $_.InstalledOn })
if ($hf.Count -gt 0) {
    $ult = $hf | Sort-Object InstalledOn -Descending | Select-Object -First 1
    Emit 'so' 'patch' 'ultimo_kb' $ult.HotFixID
    Emit 'so' 'patch' 'ultimo_em' ([datetime]$ult.InstalledOn).ToString('yyyy-MM-dd')
    Emit 'so' 'patch' 'qtd_kb' $hf.Count
}

Emit 'ambiente' 'evidencia' 'lpar_nome' $env:COMPUTERNAME
