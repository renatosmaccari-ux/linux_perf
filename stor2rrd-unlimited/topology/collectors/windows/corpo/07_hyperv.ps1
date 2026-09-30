# ============================================================
# 07-HYPERV: host Hyper-V, cluster de failover e VMs hospedadas.
# Usa WMI direto: root\virtualization\v2 (2012+) ou root\virtualization
# (2008/2008 R2). O modulo Hyper-V (Get-VM) nao existe no 2008.
# O nome e os IPs do convidado vem do KVP (integration services).
# Saida alinhada ao modelo do mapa: host de virtualizacao hospeda VMs.
# ============================================================
Emit-Meta

if (-not (Get-Service -Name 'vmms' -ErrorAction SilentlyContinue)) {
    Emit 'hyperv' 'host' 'papel' 'nao e host Hyper-V'
    return
}

$NS = 'root\virtualization\v2'
if (@(Wmi '__Namespace' "Name='v2'" 'root\virtualization').Count -eq 0) { $NS = 'root\virtualization' }
Emit 'hyperv' 'host' 'papel' 'host Hyper-V'
Emit 'hyperv' 'host' 'namespace_wmi' $NS
Emit 'hyperv' 'host' 'versao' $OS.Caption
Emit 'hyperv' 'host' 'modelo' ([string]$CS.Manufacturer + ' ' + [string]$CS.Model)
Emit 'hyperv' 'host' 'serial' (@(Wmi 'Win32_BIOS')[0].SerialNumber)
$cores = 0; foreach ($p in (Wmi 'Win32_Processor')) { $cores += [int]$p.NumberOfCores }
Emit 'hyperv' 'host' 'cores' $cores
Emit 'hyperv' 'host' 'mem_gb' ([math]::Round([double]$CS.TotalPhysicalMemory / 1GB))

# ---------- cluster de failover ----------
$CLUSTER = ''
if ((Get-Service -Name 'ClusSvc' -ErrorAction SilentlyContinue).Status -eq 'Running') {
    $cl = @(Wmi 'MSCluster_Cluster' '' 'root\MSCluster')[0]
    $CLUSTER = $cl.Name
    Emit 'hyperv' 'cluster' 'nome' $CLUSTER
    Emit 'hyperv' 'cluster' 'nos' ((@(Wmi 'MSCluster_Node' '' 'root\MSCluster') | ForEach-Object { $_.Name + '(' + $_.State + ')' }) -join ' ')
    $csv = @(Wmi 'MSCluster_ClusterSharedVolume' '' 'root\MSCluster')
    if ($csv.Count -gt 0) { Emit 'hyperv' 'cluster' 'csv_qtd' $csv.Count }
}

# ---------- switches virtuais ----------
foreach ($sw in (Wmi 'Msvm_VirtualEthernetSwitch' '' $NS)) { Emit 'hyperv' 'switch' $sw.ElementName $sw.Name }
if ($NS -eq 'root\virtualization') {
    foreach ($sw in (Wmi 'Msvm_VirtualSwitch' '' $NS)) { Emit 'hyperv' 'switch' $sw.ElementName $sw.Name }
}

# ---------- VMs ----------
$ESTADO = @{ '2' = 'Running'; '3' = 'Off'; '6' = 'Saved'; '9' = 'Paused'; '10' = 'Starting';
             '32768' = 'Paused'; '32769' = 'Saved'; '32770' = 'Starting'; '32773' = 'Saving'; '32776' = 'Pausing' }
# O host tambem e um Msvm_ComputerSystem: as VMs sao as que tem GUID no Name
$VMS = @(Wmi 'Msvm_ComputerSystem' '' $NS | Where-Object { $_.Name -match '^[0-9A-Fa-f]{8}-' })
Emit 'hyperv' 'host' 'vms_qtd' $VMS.Count
$rodando = 0

foreach ($vm in $VMS) {
    $g = $vm.Name
    $nome = $vm.ElementName
    $est = [string]$vm.EnabledState
    $estNome = if ($ESTADO.ContainsKey($est)) { $ESTADO[$est] } else { 'estado_' + $est }
    if ($estNome -eq 'Running') { $rodando++ }
    Emit 'vm' $nome 'guid'   $g
    Emit 'vm' $nome 'estado' $estNome
    Emit 'vm' $nome 'host'   $env:COMPUTERNAME
    Emit 'vm' $nome 'cluster' $CLUSTER
    if ($vm.OnTimeInMilliseconds -gt 0) { Emit 'vm' $nome 'uptime_h' ([math]::Round([double]$vm.OnTimeInMilliseconds / 3600000)) }

    # configuracao ativa: InstanceID "Microsoft:<GUID>..." (memoria em MB, CPU em VPs)
    $mem = @(Wmi 'Msvm_MemorySettingData' ("InstanceID LIKE 'Microsoft:" + $g + "%'") $NS)
    if ($mem.Count -gt 0) {
        Emit 'vm' $nome 'memoria_mb' $mem[0].VirtualQuantity
        if ($mem[0].DynamicMemoryEnabled) { Emit 'vm' $nome 'memoria_dinamica' ('sim, max ' + $mem[0].Limit + ' MB') }
    }
    $cpu = @(Wmi 'Msvm_ProcessorSettingData' ("InstanceID LIKE 'Microsoft:" + $g + "%'") $NS)
    if ($cpu.Count -gt 0) { Emit 'vm' $nome 'vcpu' $cpu[0].VirtualQuantity }
    $vs = @(Wmi 'Msvm_VirtualSystemSettingData' ("InstanceID LIKE 'Microsoft:" + $g + "%'") $NS)
    if ($vs.Count -gt 0) {
        if ($vs[0].VirtualSystemSubType) { Emit 'vm' $nome 'geracao' ($vs[0].VirtualSystemSubType -replace '^.*SubType:', '') }
        Emit 'vm' $nome 'config_path' $vs[0].ConfigurationDataRoot
    }
    # discos virtuais
    $vhd = @(Wmi 'Msvm_StorageAllocationSettingData' ("InstanceID LIKE 'Microsoft:" + $g + "%'") $NS)
    if ($vhd.Count -eq 0 -and $NS -eq 'root\virtualization') {
        $vhd = @(Wmi 'Msvm_ResourceAllocationSettingData' ("InstanceID LIKE 'Microsoft:" + $g + "%' AND ResourceType=21") $NS)
    }
    $caminhos = @()
    foreach ($d in $vhd) { foreach ($c in @($d.HostResource)) { if ($c) { $caminhos += $c } } }
    if ($caminhos.Count -gt 0) { Emit 'vm' $nome 'discos' ($caminhos -join '; ') }

    # convidado (KVP): FQDN, IPs e SO reais de dentro da VM
    $kvp = @(Wmi 'Msvm_KvpExchangeComponent' ("SystemName='" + $g + "'") $NS)
    if ($kvp.Count -gt 0) {
        foreach ($x in @($kvp[0].GuestIntrinsicExchangeItems)) {
            try {
                $xml = [xml]$x
                $nomeK = ($xml.INSTANCE.PROPERTY | Where-Object { $_.NAME -eq 'Name' }).VALUE
                $dado  = ($xml.INSTANCE.PROPERTY | Where-Object { $_.NAME -eq 'Data' }).VALUE
                switch ($nomeK) {
                    'FullyQualifiedDomainName' { Emit 'vm' $nome 'guest_fqdn' $dado }
                    'NetworkAddressIPv4'       { Emit 'vm' $nome 'guest_ips' ($dado -replace ';', ' ') }
                    'OSName'                   { Emit 'vm' $nome 'guest_os' $dado }
                    'OSVersion'                { Emit 'vm' $nome 'guest_os_versao' $dado }
                }
            } catch {}
        }
    }
}
Emit 'hyperv' 'host' 'vms_rodando' $rodando
