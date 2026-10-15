# ============================================================
# 04-STORAGE: discos, volumes, HBA FC (WWPN), MPIO, iSCSI,
# compartilhamentos e CSV de cluster
# ============================================================
Emit-Meta

foreach ($d in (Wmi 'Win32_DiskDrive')) {
    $n = 'disk' + $d.Index
    Emit 'disco' $n 'modelo'    $d.Model
    Emit 'disco' $n 'tamanho_gb' ([math]::Round([double]$d.Size / 1GB, 1))
    Emit 'disco' $n 'interface' $d.InterfaceType
    Emit 'disco' $n 'serial'    ([string]$d.SerialNumber).Trim()
    Emit 'disco' $n 'particoes' $d.Partitions
}

# Volumes locais (DriveType 3) e pontos de montagem
foreach ($v in (Wmi 'Win32_Volume' 'DriveType=3')) {
    $mp = if ($v.DriveLetter) { $v.DriveLetter } elseif ($v.Name -notmatch '^\\\\\?\\') { $v.Name } else { '' }
    if (-not $mp) { continue }
    Emit 'fs' $mp 'rotulo'    $v.Label
    Emit 'fs' $mp 'tipo'      $v.FileSystem
    Emit 'fs' $mp 'total_mb'  ([math]::Round([double]$v.Capacity / 1MB))
    Emit 'fs' $mp 'livre_mb'  ([math]::Round([double]$v.FreeSpace / 1MB))
    if ($v.Capacity -gt 0) {
        Emit 'fs' $mp 'usado_pct' ([string]([math]::Round(100 - (100 * [double]$v.FreeSpace / [double]$v.Capacity))) + '%')
    }
}

# Unidades de rede mapeadas no contexto de sistema
foreach ($m in (Wmi 'Win32_LogicalDisk' 'DriveType=4')) { Emit 'nfs' $m.DeviceID 'origem' $m.ProviderName }

# HBA Fibre Channel: WWPN pelo WMI do driver (namespace root\WMI)
foreach ($h in (Wmi 'MSFC_FCAdapterHBAAttributes' '' 'root\WMI')) {
    $wwn = ($h.NodeWWN | ForEach-Object { '{0:x2}' -f $_ }) -join ':'
    Emit 'hba' $h.InstanceName 'wwnn'     $wwn
    Emit 'hba' $h.InstanceName 'modelo'   $h.Model
    Emit 'hba' $h.InstanceName 'firmware' $h.FirmwareVersion
    Emit 'hba' $h.InstanceName 'driver'   $h.DriverVersion
}
foreach ($p in (Wmi 'MSFC_FibrePortHBAAttributes' '' 'root\WMI')) {
    $a = $p.Attributes
    if ($a) {
        $wwpn = ($a.PortWWN | ForEach-Object { '{0:x2}' -f $_ }) -join ':'
        Emit 'hba' $p.InstanceName 'wwpn' $wwpn
        Emit 'hba' $p.InstanceName 'estado_porta' $a.PortState
        Emit 'hba' $p.InstanceName 'velocidade' $a.PortSpeed
    }
}

# MPIO
if (Get-Service -Name 'mpio' -ErrorAction SilentlyContinue) {
    Emit 'storage' 'multipath' 'driver' 'Microsoft MPIO'
    $mp = @(& mpclaim.exe -s -d 2>$null)
    $luns = @($mp | Where-Object { $_ -match '^MPIO Disk\d+' })
    Emit 'storage' 'multipath' 'discos' $luns.Count
}

# iSCSI
if ((Get-Service -Name 'MSiSCSI' -ErrorAction SilentlyContinue).Status -eq 'Running') {
    $alvos = @(& iscsicli.exe ListTargets 2>$null | Where-Object { $_ -match '^\s+iqn\.' } | ForEach-Object { $_.Trim() })
    Emit 'iscsi' 'sessoes' 'alvos' ($alvos -join ' ')
    Emit 'iscsi' 'iniciador' 'iqn' (@(Wmi 'MSiSCSIInitiator_MethodClass' '' 'root\WMI')[0].iSCSINodeName)
}

# Compartilhamentos SMB (dependencia: quem monta daqui aparece no payload de conexoes)
foreach ($s in (Wmi 'Win32_Share' 'Type=0')) { Emit 'nfs' 'servidor' ('share:' + $s.Name) $s.Path }

# Volumes compartilhados de cluster (Hyper-V/SQL em cluster)
foreach ($c in (Wmi 'MSCluster_Resource' "Type='Physical Disk'" 'root\MSCluster')) {
    Emit 'storage' 'cluster_disco' $c.Name $c.OwnerNode
}
