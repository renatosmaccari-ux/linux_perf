# Coleta de inventário — parque Unix (AIX / Linux / Solaris) — pacote coleta_unix (kit v3.2)

## v3.2 — reexecução das falhas

```sh
./run_all.sh -l alvos_reexecucao.txt -j 6
```

`alvos_reexecucao.txt` traz as falhas ainda pendentes (causa anterior em `alvos_motivos.csv`).

### Novidades do runner (`collect.sh` v3.2)

| Recurso | Comportamento |
|---|---|
| **Detecção de Windows por TTL** | Antes do SSH, faz um `ping`. TTL entre 65 e 128 só pode ter partido de 128 (Windows): o host **não é coletado** e vai para `*_windows.csv` / `hosts_windows.csv`. Linux/AIX partem de 64, Solaris de 255. Sem resposta ao ping, segue a coleta normal. `TTL_CHECK=0 ./run_all.sh ...` desativa |
| **Checagem de identidade** | Compara o alvo com o hostname que o sistema informa. Divergência vai para `identidade_divergente.csv` — DNS/IP levando a outro servidor |
| Classificação sem diferença de caixa | O sudo antigo escreve `Illegal option -n`; o fallback não disparava. Corrigido |
| `conexao_sem_banner` | Porta 22 aceita mas o sshd não responde: tenta o próximo IP |

### Payloads

| Correção | Motivo |
|---|---|
| Teste do diretório temporário grava 256 KB e confere o tamanho | Criar arquivo vazio funciona com o filesystem cheio (só gasta inode); o `nlsnfes40759d03` passou no teste antigo e falhou depois |

### Limitação do TTL

A regra assume o TTL padrão. Um Linux com `net.ipv4.ip_default_ttl=128`, ou um firewall que reescreva o TTL, seria marcado como Windows. A evidência (`ttl=NNN via alvo`) fica registrada para auditoria.

## O que mudou em relação ao kit original

| Mudança | Motivo |
|---|---|
| `lib.sh` v2 reconhece `SunOS` → `PLAT=solaris` | Antes caía em `desconhecido` e o ramo `else` executava lógica Linux (`/sys/class/net`, `/proc/meminfo`) — os 77 Solaris voltavam vazios |
| Seleção explícita de `awk` e `grep` | `/usr/bin/awk` do Solaris é o *oawk*: quebra com `match()` e funções. Agora usa `/usr/xpg4/bin/awk` ou `nawk` |
| Ramo `solaris` nos 5 payloads | Comandos nativos: `ipadm`/`dladm`, `psrinfo`, `zpool`, `fcinfo`, `mpathadm`, `svcs`, `beadm`, `virtinfo`, `zoneadm` |
| Payload `06_conexoes` | Conexões TCP de entrada/saída para a topologia |
| `montar_payloads.sh` | `lib.sh` deixa de ser copiado à mão dentro de cada payload |
| `run_all.sh` com timeouts maiores | `zpool`, `mpathadm` e `fcinfo` são mais lentos que os equivalentes AIX/Linux |
| `crontab -l` sem `-u` fora do Linux | A flag `-u` não existe no Solaris nem no AIX — o job do root vinha vazio |

## Estrutura

```
lib.sh                 preâmbulo portável (PLAT, AWK, GREP, run, emit, helpers)
corpo/01_sistema.sh    → edite AQUI, nunca no payload_*.sh gerado
corpo/02_rede.sh
corpo/03_seguranca.sh
corpo/04_storage.sh
corpo/05_monitoracao.sh
corpo/06_conexoes.sh
montar_payloads.sh     lib.sh + corpo/NN → payload_*.sh (valida com sh -n)
collect.sh             runner paralelo (inalterado)
run_all.sh             orquestra os 6 payloads
hmc_collect.sh         coleta nas HMCs (inalterado)
nim_check.sh           (inalterado)
```

Depois de editar `lib.sh` ou qualquer `corpo/*.sh`:

```sh
./montar_payloads.sh
```

## Execução

```sh
chmod +x *.sh
./run_all.sh -n            # PILOTO: 5 hosts, valida sudo -n antes de escalar
./run_all.sh               # completo, 776 hosts
./run_all.sh -j 12         # aumenta paralelismo
./run_all.sh -s conexoes   # só um payload (reexecução)
./run_all.sh -H            # completo + HMCs
```

### Tetos da coleta de conexões

`06_conexoes` emite no máximo `MAX_EDGE` arestas por direção e por host, as de
mais sessões, e acima de `LIMIAR_FANIN` clientes numa porta passa a resumir por
rede /24. Num parque com gateways e balanceadores o teto é atingido: o resumo
traz `truncado_entrada` com quantas ficaram de fora.

Para levantar os tetos sem editar nada:

```sh
TOPO_MAX_EDGE=6000 ./run_all.sh -s conexoes
TOPO_MAX_EDGE=6000 TOPO_LIMIAR_FANIN=400 ./run_all.sh -s conexoes
```

O `collect.sh` escreve esses valores no início do payload antes de o enviar —
nem o `ssh` nem o `sudo` levam o ambiente daqui para o host remoto, portanto
exportá-los não bastaria. Sem as variáveis, valem 1200 e 150, como antes.

Quantas arestas foram descartadas na última coleta:

```sh
grep -h "conexao,resumo,truncado" coleta_*/06_conexoes.csv | sort -u
```

Piloto obrigatório com pelo menos um host de cada família:

```sh
printf '%s\n' hostAIX hostLinux hostSolaris > piloto.txt
./run_all.sh -n -l piloto.txt
```

Saída em `coleta_AAAAMMDD_HHMMSS/`:

```
01_sistema.csv   03_seguranca.csv   05_monitoracao.csv   00_consolidado.csv
02_rede.csv      04_storage.csv     06_conexoes.csv      07_hmc.csv (com -H)
*_falhas.csv     execucao.log       hosts_com_falha.txt  coleta_*.tar.gz
```

Esquema único em todos: `hostname,categoria,item,chave,valor`.

### Tempo estimado (776 hosts)

| Payload | Timeout/host | Jobs | Estimativa |
|---|---|---|---|
| 01 sistema | 240s | 8 | ~25 min |
| 02 rede | 240s | 8 | ~20 min |
| 03 segurança | 360s | 8 | ~45 min |
| 04 storage | 480s | 6 | ~60 min |
| 05 monitoração | 300s | 8 | ~30 min |
| 06 conexões | 360s | 6 | ~100 min |

Total sequencial: **~4,5 h**. Os payloads rodam em sequência de propósito — cada um já abre 6-8 sessões SSH.

## Cobertura por plataforma

| Área | AIX | Linux | Solaris |
|---|---|---|---|
| SO / versão | `oslevel -s/-r`, `bootinfo` | `/etc/os-release`, `uname` | `/etc/release`, `pkg info entire`, `isainfo`, `beadm` |
| Frame / serial | `lsattr sys0`, `lsmcode` | `/proc/device-tree` | `prtconf -b`, `smbios`, `prtdiag` |
| Virtualização | LPAR (`uname -L`, `lparstat -i`) | lparcfg | LDOM (`virtinfo`), zonas (`zoneadm`) |
| CPU / memória | `lparstat`, `smtctl`, `lsattr realmem` | `/proc/cpuinfo`, `/proc/meminfo` | `psrinfo -p`, `prtconf`, `swap -l` |
| Rede | `ifconfig`, `entstat`, `netstat -rn` | `/sys/class/net`, `ip route` | `ipadm`, `dladm` (phys/vlan/aggr), `ipmpstat`, `netstat -rn` |
| Usuários | `lsuser`, `lssec` | `/etc/passwd`, `chage` | `/etc/passwd`, `passwd -sa`, `/etc/user_attr` (RBAC) |
| Política de senha | `/etc/security/user` (semanas) | `login.defs` + PAM | `/etc/default/passwd` (semanas), `policy.conf` |
| Storage | `lspv`, `lsvg`, `lspath`, `fcstat` | `lsblk`, `multipath`, LVM, `fc_host` | `zpool`/`zfs`, `mpathadm`, `fcinfo`, `iostat -En`, `metastat` |
| NFS export | `/etc/exports` | `/etc/exports` | `/etc/dfs/sharetab` + `dfstab` |
| Serviços | `lssrc -a` | `systemctl` | `svcs` (+ falhos e em manutenção) |
| Imagem local | `mksysb`, `sysdumpdev` | — | `beadm list`, snapshots ZFS, `dumpadm` |
| Conexões TCP | `netstat -an -f inet` | `ss -4 -tan` | `netstat -an -f inet -P tcp` |

Campos que a coleta não alcança em nenhuma plataforma continuam como consulta manual:
garantia no portal do fabricante, classificação PRD/BKP das sub-redes, VLAN das portas
físicas, datacenter, alertas configurados no TrueSight, retenção no Spectrum Protect.

## Solaris: domínio lógico x zona

A coleta identifica sozinha onde está na pilha de virtualização e ajusta o que coleta.
`meta,host,zona` e `meta,host,zona_tipo` vão em **todos** os payloads; a classificação
completa sai em `lpar,virt,escopo` no payload de sistema.

| `lpar,virt,escopo` | Como é detectado | O que a coleta faz |
|---|---|---|
| `ldom-control` | `virtinfo` diz *Domain role: control* | Coleta também o inventário de **todos os LDOMs** do servidor (`ldm list -p`): nome, estado, vCPU, memória, flags — o equivalente ao HMC Scanner no SPARC |
| `ldom-servico` | role *service / I/O / root* | Idem ao control |
| `ldom-guest` | role *guest* | Hardware do próprio domínio; zonas hospedadas listadas |
| `kernel-zone` | *Virtual Machine Type: kernel zone* | Hardware da KZ (tem kernel próprio) |
| `zona-nao-global` | `zonename` ≠ global | Marca `lpar,virt,aviso`; pula HBA/multipath/dladm com nota explícita |
| `fisico-ou-indeterminado` | `virtinfo` ausente ou sem saída | Solaris direto no hardware |

`lpar,virt,chassi_serial` agrupa todos os domínios e zonas que moram no mesmo servidor
físico — é a chave para montar a hierarquia **chassi → LDOM → zona** na topologia.

Registros produzidos:

```
zona,<nome>,estado|brand|ip_type|caminho|uuid      # zonas vistas pela global
ldom,<nome>,estado|vcpu|memoria_b|memoria_mb|flags # domínios vistos pelo control
lpar,zona,filhas / qtd_filhas
```

**Não some CPU nem memória de host com `escopo=zona-nao-global`**: `prtconf` e `psrinfo`
dentro de uma zona reportam os recursos da global, e o total do parque sairia inflado.
Some apenas `fisico-ou-indeterminado`, `ldom-*` e `kernel-zone`.

Depois da coleta completa, os nomes em `zona,<nome>,*` que não aparecerem como hosts
coletados são zonas fora do baseline — e as globais que hospedam as zonas coletadas
podem não estar na lista. Vale cruzar antes de fechar o inventário.

## Riscos

| Risco | Impacto | Tratamento |
|---|---|---|
| `ps -ef` do Solaris **trunca a linha de comando em ~80 caracteres** | `pcount()` pode não casar processos com caminho longo (agentes em `/opt/...`) | Contagem de agentes no Solaris é indicativa. Confirmar com `svcs` ou `pargs <pid>` onde for decisivo |
| `passwd -sa` lê o aging de todas as contas | Sem ele, seriam 2 forks por usuário e estouro de timeout em hosts com centenas de contas | Já implementado como leitura única em cache |
| `zpool status` e `mpathadm show lu` percorrem todos os dispositivos | Lentidão em hosts com muitas LUNs | Timeout de storage elevado para 480s, `-j 6` |
| `fcinfo`/`mpathadm` travam com HBA offline | Host entra em `timeout_exec` | `run()` com watchdog em todas as chamadas; host aparece em `04_storage_falhas.csv` para reexecução |
| **`format` nunca é usado** | O comando é interativo e pode reescrever o rótulo do disco | Substituído por `iostat -En` (somente leitura) |
| Zonas não-globais têm visão parcial do hardware | `prtconf`, `psrinfo` e `zpool` refletem a zona, não o host físico | `lpar,virt,escopo` classifica cada host e `lpar,virt,aviso` marca os que não podem ser somados; correlação pelo `chassi_serial` |
| `ss` do RHEL 5 existe em `/usr/sbin` mas não suporta `-4` | Conexões vazias sem erro | A fonte é sondada (`ss -4` → `ss` → `netstat`) e registrada em `conexao,resumo,fonte` |
| PATH mínimo no `sudo -n` não-interativo | `/usr/sbin` e `/sbin` ausentes apagam dados silenciosamente | PATH explícito no `lib.sh`; auditável em `meta,host,path` |
| Solaris 10 (se houver) não tem `ipadm`/`beadm`/`pkg` | Campos vazios | Há fallback via `ifconfig -a`; o baseline atual só traz SunOS 5.11 |
| Contas sem `sudo -n` | `sudo_ou_payload` no CSV de falhas | Piloto com uma amostra de cada família antes do parque completo |

## Validações executadas

- `sh -n` limpo nos 6 payloads (checagem embutida no `montar_payloads.sh`).
- Execução real do ramo Linux dos 6 payloads: sem erro, sem travamento.
- Execução do ramo Solaris com `uname` simulado: os 6 payloads completam, sem travamento
  e sem erro de sintaxe de `awk` (a seleção de `nawk` foi exercitada).
- Ramos AIX e Linux dos payloads 01-05 **não foram alterados** — o texto original foi
  extraído dos arquivos do kit e reaproveitado, com o ramo Solaris inserido como `elif`.
