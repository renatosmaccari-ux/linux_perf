# ============================================================
# 03-SEGURANCA: contas locais, administradores, politica de senha,
# firewall, RDP, SMBv1, UAC, protecao de endpoint
# ============================================================
Emit-Meta

# ---------- contas locais (em DC as contas sao de dominio: so resumo) ----------
if ($EH_DC) {
    Emit 'usuario' 'dominio' 'observacao' 'controlador de dominio: contas locais nao se aplicam'
} else {
    $filtro = "LocalAccount=True"
    foreach ($u in (Wmi 'Win32_UserAccount' $filtro)) {
        Emit 'usuario' $u.Name 'sid'              $u.SID
        Emit 'usuario' $u.Name 'bloqueada'        $(if ($u.Disabled) { 'sim' } else { 'nao' })
        Emit 'usuario' $u.Name 'travada'          $(if ($u.Lockout) { 'sim' } else { 'nao' })
        Emit 'usuario' $u.Name 'senha_expira'     $(if ($u.PasswordExpires) { 'sim' } else { 'never' })
        Emit 'usuario' $u.Name 'senha_obrigatoria' $(if ($u.PasswordRequired) { 'sim' } else { 'nao' })
        Emit 'usuario' $u.Name 'descricao'        $u.Description
    }
}

# ---------- Administradores locais pelo SID (nome do grupo e localizado) ----------
$adm = @(Wmi 'Win32_Group' "SID='S-1-5-32-544'")[0]
if ($adm) {
    $membros = @()
    $q = "GroupComponent=""Win32_Group.Domain='" + $adm.Domain + "',Name='" + $adm.Name + "'"""
    foreach ($gu in (Wmi 'Win32_GroupUser' $q)) {
        if ($gu.PartComponent -match 'Domain="([^"]+)",Name="([^"]+)"') { $membros += ($matches[1] + '\' + $matches[2]) }
    }
    Emit 'grupo_privilegiado' 'administradores' 'nome_local' $adm.Name
    Emit 'grupo_privilegiado' 'administradores' 'membros' ($membros -join ' ')
    Emit 'grupo_privilegiado' 'administradores' 'qtd' $membros.Count
}
$rdpg = @(Wmi 'Win32_Group' "SID='S-1-5-32-555'")[0]
if ($rdpg) {
    $m = @()
    $q = "GroupComponent=""Win32_Group.Domain='" + $rdpg.Domain + "',Name='" + $rdpg.Name + "'"""
    foreach ($gu in (Wmi 'Win32_GroupUser' $q)) {
        if ($gu.PartComponent -match 'Domain="([^"]+)",Name="([^"]+)"') { $m += ($matches[1] + '\' + $matches[2]) }
    }
    Emit 'grupo_privilegiado' 'remote_desktop_users' 'membros' ($m -join ' ')
}

# ---------- politica de senha e bloqueio (secedit: chaves nao localizadas) ----------
$cfg = Join-Path $env:TEMP ('inv_secpol_' + $PID + '.inf')
$null = & secedit /export /cfg $cfg /areas SECURITYPOLICY /quiet 2>$null
if (Test-Path $cfg) {
    $mapa = @{
        'MinimumPasswordAge' = 'min_dias'; 'MaximumPasswordAge' = 'max_dias';
        'MinimumPasswordLength' = 'tamanho_minimo'; 'PasswordComplexity' = 'complexidade';
        'PasswordHistorySize' = 'historico'; 'LockoutBadCount' = 'tentativas_bloqueio';
        'LockoutDuration' = 'bloqueio_minutos'; 'ResetLockoutCount' = 'janela_minutos';
        'ClearTextPassword' = 'reversivel'; 'EnableGuestAccount' = 'convidado_ativo';
        'EnableAdminAccount' = 'administrador_ativo'
    }
    foreach ($l in (Get-Content $cfg)) {
        if ($l -match '^\s*(\w+)\s*=\s*(.+?)\s*$' -and $mapa.ContainsKey($matches[1])) {
            Emit 'politica_senha' 'local' $mapa[$matches[1]] $matches[2]
        }
    }
    Remove-Item $cfg -Force -ErrorAction SilentlyContinue
}
Emit 'politica_senha' 'sistema' 'modo' $(if ($CS.PartOfDomain) { 'dominio (GPO prevalece sobre a local)' } else { 'local' })

# ---------- firewall por perfil (registro; GPO prevalece) ----------
$base = 'HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy'
$gpo = 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall'
foreach ($p in @(@('DomainProfile', 'dominio'), @('StandardProfile', 'privado'), @('PublicProfile', 'publico'))) {
    $v = RegVal ($gpo + '\' + $p[0]) 'EnableFirewall'
    $origem = 'gpo'
    if ($v -eq $null) { $v = RegVal ($base + '\' + $p[0]) 'EnableFirewall'; $origem = 'local' }
    if ($v -ne $null) { Emit 'seguranca' 'firewall' $p[1] ($(if ($v -eq 1) { 'ativo' } else { 'inativo' }) + ' (' + $origem + ')') }
}

# ---------- acesso remoto e endurecimento ----------
$ts = 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server'
$deny = RegVal $ts 'fDenyTSConnections'
Emit 'seguranca' 'rdp' 'habilitado' $(if ($deny -eq 0) { 'sim' } elseif ($deny -eq 1) { 'nao' } else { '' })
Emit 'seguranca' 'rdp' 'nla' $(if ((RegVal ($ts + '\WinStations\RDP-Tcp') 'UserAuthentication') -eq 1) { 'sim' } else { 'nao' })
Emit 'seguranca' 'rdp' 'porta' (RegVal ($ts + '\WinStations\RDP-Tcp') 'PortNumber')
$smb1 = RegVal 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'SMB1'
Emit 'seguranca' 'smb' 'smb1_servidor' $(if ($smb1 -eq 0) { 'desabilitado' } else { 'habilitado ou padrao do SO' })
Emit 'seguranca' 'uac' 'enable_lua' (RegVal 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' 'EnableLUA')
Emit 'seguranca' 'winrm' 'servico' ([string](Get-Service WinRM).Status)
Emit 'seguranca' 'ntlm' 'lm_compat' (RegVal 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' 'LmCompatibilityLevel')

# ---------- protecao de endpoint: pelos servicos (SecurityCenter2 nao existe em servidor) ----------
$av = @{
    'WinDefend' = 'Microsoft Defender'; 'Sense' = 'Defender for Endpoint'; 'CSFalconService' = 'CrowdStrike Falcon';
    'SepMasterService' = 'Symantec Endpoint'; 'McAfeeFramework' = 'McAfee/Trellix'; 'masvc' = 'McAfee/Trellix';
    'ntrtscan' = 'Trend Micro OfficeScan'; 'ds_agent' = 'Trend Micro Deep Security'; 'SentinelAgent' = 'SentinelOne';
    'CylanceSvc' = 'Cylance'; 'ekrn' = 'ESET'; 'KAVFS' = 'Kaspersky'; 'CbDefense' = 'Carbon Black'; 'Tanium Client' = 'Tanium'
}
foreach ($k in $av.Keys) {
    $s = Get-Service -Name $k -ErrorAction SilentlyContinue
    if ($s) { Emit 'seguranca' 'endpoint' $av[$k] ([string]$s.Status) }
}

# ---------- ultimos logons interativos (evento 4624 e caro; usa perfis carregados) ----------
$perfis = @(Wmi 'Win32_UserProfile' 'Special=False')
foreach ($p in ($perfis | Sort-Object LastUseTime -Descending | Select-Object -First 10)) {
    Emit 'acesso' 'perfil' ($p.LocalPath -replace '^.*\\', '') (WmiData $p.LastUseTime)
}
