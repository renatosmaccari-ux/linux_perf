# Coleta de inventário — Windows Server 2008 R2 a 2022 e Hyper-V

Equivalente Windows do kit Unix: **mesmos payloads e mesmo esquema de CSV**
(`hostname,categoria,item,chave,valor`). A saída entra direto no pipeline de
topologia já existente (`mapa_conexoes.py`, `preparar_topologia.py`,
`integrar_lpar2rrd.py -w`).

## Arquitetura

| Item | Unix | Windows |
|---|---|---|
| Origem | bastion Linux, usuário `netuss` | servidor de salto Windows, PowerShell 5.1 |
| Transporte | SSH + `sudo -n` | WinRM (`Invoke-Command`), porta 5985 ou 5986 |
| Permissão | sudo sem senha | conta de domínio no grupo **Administradores** local dos alvos |
| Runner | `run_all.sh` + `collect.sh` | `coletar_windows.ps1` |
| Payloads | `lib.sh` + `corpo/*.sh` | `lib.ps1` + `corpo/*.ps1` |
| Detecção do "outro" SO | TTL 65–128 → Windows, não coleta | TTL ≤ 64 com WinRM fechado → Unix, não coleta |

Os payloads rodam **no alvo** e são compatíveis com **PowerShell 2.0** (Server 2008 R2
sem atualização). O orquestrador roda no servidor de salto e exige 5.1.

## Estrutura

```
coletar_windows.ps1        orquestrador
lib.ps1                    funções comuns dos payloads (Emit, WMI, registro)
corpo/01_sistema.ps1       SO, hardware, virtualização, papéis, aplicações, patches
corpo/02_rede.ps1          interfaces, rotas, DNS, NTP, teaming, portas em escuta
corpo/03_seguranca.ps1     contas locais, administradores, política, firewall, RDP, EDR
corpo/04_storage.ps1       discos, volumes, WWPN de HBA, MPIO, iSCSI, shares, discos de cluster
corpo/05_monitoracao.ps1   agentes, serviços, contas de serviço, tarefas, SNMP, eventos
corpo/06_conexoes.ps1      conexões TCP de entrada/saída (mesmo formato do Unix)
corpo/07_hyperv.ps1        host Hyper-V, cluster de failover e VMs
lista_windows.txt          1.018 alvos (2008 R2 a 2022, ativos, on-premises)
lista_hyperv.txt           42 hosts Hyper-V físicos
lista_windows_cloud.txt    39 Windows em AWS/Azure
piloto_windows.txt         1 host por versão + 3 hosts Hyper-V (2016, 2019, 2022)
fora_do_escopo.csv         93: Windows 2003, OFF, phase-out, DR
```

## Pré-requisitos

| Requisito | Como verificar / habilitar |
|---|---|
| WinRM nos alvos | Padrão ligado no 2012+. No 2008 R2: `winrm quickconfig` (ou GPO) |
| Porta 5985 do salto até os alvos | Firewall de rede e Windows Firewall (regra "Windows Remote Management") |
| Conta administradora local | Grupo de domínio no grupo Administradores dos servidores |
| Alvo por IP (hostname não resolve) | `-Credencial` + IP no `TrustedHosts` do salto, ou HTTPS (`-UsarSSL`) |

Alvo por IP não usa Kerberos. O script separa esses hosts num lote próprio e **não os executa
sem `-Credencial`**, registrando o motivo em vez de falhar silenciosamente.

## Execução

```powershell
Set-ExecutionPolicy -Scope Process Bypass
cd C:\coleta_windows

.\coletar_windows.ps1 -Lista .\piloto_windows.txt -Teste      # 1. só acesso: WinRM + admin + versão do PS
.\coletar_windows.ps1 -Lista .\piloto_windows.txt             # 2. piloto completo (9 hosts)
.\coletar_windows.ps1 -Lista .\lista_hyperv.txt               # 3. hosts Hyper-V
.\coletar_windows.ps1 -Lista .\lista_windows.txt -Paralelo 24 # 4. parque completo
```

| Parâmetro | Padrão | Uso |
|---|---|---|
| `-Lista` | `lista_windows.txt` | `hostname [ip1 ip2 ...]` |
| `-Payloads` | todos | ex.: `-Payloads sistema,conexoes` |
| `-Paralelo` | 16 | sessões WinRM simultâneas |
| `-Timeout` | 420 s | por host (todos os payloads numa sessão) |
| `-Amostras` / `-Intervalo` | 3 / 10 s | snapshots de conexões |
| `-Credencial` | conta atual | necessária para alvos por IP |
| `-UsarSSL` | não | WinRM HTTPS (5986) |
| `-SemTTL` | não | desliga a detecção de Unix pelo TTL |

Tempo estimado do parque: 1.018 hosts ÷ 16 sessões × ~60 s ≈ **65 min**.

## Saída

`coleta_windows_AAAAMMDD_HHMMSS\` e o `.zip` correspondente:

```
01_sistema.csv ... 07_hyperv.csv   dados (UTF-8 sem BOM, mesmo esquema do Unix)
0N_*_falhas.csv                    falha por host, com a causa
00_consolidado.csv                 tudo junto
hosts_unix.csv                     alvos que o TTL indicou Unix/Linux (não coletados)
identidade_divergente.csv          alvo respondeu com outro hostname
hosts_com_falha.txt · execucao.log
```

Causas de falha classificadas: `dns_nao_resolve`, `winrm_porta_fechada` (responde ao ping,
porta fechada), `sem_resposta`, `acesso_negado`, `kerberos`, `trustedhosts`,
`winrm_inacessivel`, `timeout_execucao`, `erro_payload` (falha isolada num payload: os
demais continuam).

## Como os problemas do Windows foram tratados

| Problema | Tratamento |
|---|---|
| Servidores em **português/espanhol**: `netstat`, `net accounts`, `w32tm`, `netsh` traduzem a saída | Política de senha via `secedit` (chaves fixas); firewall, NTP, RDP e SMBv1 via registro; grupo Administradores pelo **SID** `S-1-5-32-544`; escuta TCP detectada por `remoto :0`, e estados normalizados (ESTABELECIDA, ESCUTANDO, ESTABLECIDO…) |
| `Get-CimInstance`, `Get-NetTCPConnection` e o módulo Hyper-V não existem no 2008 | WMI (`Get-WmiObject`) em tudo; `Get-NetTCPConnection` só quando existe, senão `netstat -ano` |
| `Win32_Product` dispara reconfiguração MSI em todos os pacotes | **Nunca usado**: software instalado vem do registro `Uninstall` |
| Contas de domínio num DC | Em controlador de domínio o inventário de contas locais é pulado |
| Hyper-V 2008 R2 × 2012+ | Namespace `root\virtualization` ou `root\virtualization\v2`, detectado |

## O que o Windows acrescenta à topologia

- **Processo da conexão de saída**: o Windows informa o PID de toda conexão, então a saída
  traz o processo (o Unix só tinha o de escuta). `svchost` aparece com o serviço: `svchost(TermService)`.
- **VM → host físico**: convidado Hyper-V informa o próprio host pelo registro KVP
  (`lpar,virt,host_fisico`). A dependência aparece mesmo que o host não seja coletado.
- **Cluster de failover**: VMs em cluster dependem do **cluster**, não de um nó — mesma
  modelagem do Nutanix. Power off do cluster derruba as VMs; de um nó isolado, não.
- **SQL Server, IIS, Exchange, AD, DNS**: identificados em `01_sistema` (`app,*`).
- **Contas de serviço de domínio**: `servicos,conta_servico` — dependência de AD e risco de senha.

## Integração ao mapa

```sh
python3 mapa_conexoes.py -c '/dados/coleta_*/06_conexoes.csv' '/dados/coleta_windows_*/06_conexoes.csv' ...
python3 integrar_lpar2rrd.py ... -w '/dados/coleta_windows_*'
```

## Validação feita

- Sintaxe dos 9 scripts validada pelo parser do PowerShell.
- Verificação estática de compatibilidade com PowerShell 2.0 nos payloads.
- `06_conexoes` executado com `netstat` simulado em português: estados traduzidos,
  direção, loopback, serviços e hosts conferidos.
- Montagem do script remoto executada: erro num payload é capturado e os demais seguem.
- Integração Hyper-V testada com coleta sintética: cluster → hosts, VM casada pelo FQDN.

**Não testado em Windows real.** Os payloads não rodaram num Windows Server de verdade —
o piloto com `-Teste` e depois completo é obrigatório antes do parque.
