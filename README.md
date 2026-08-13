# linux-perf-analyzer

Ferramenta de **coleta e análise de performance** para servidores Linux, agnóstica de
distribuição, modular e **somente leitura** (read-only). Detecta automaticamente a
aplicação/stack em execução (web servers, bancos de dados, cache, filas, containers,
orquestradores, runtimes de aplicação) e gera um **relatório HTML gerencial**, com
pontos de melhoria, riscos e observações, referenciados às boas práticas dos
principais fornecedores de mercado.

## Princípios de projeto

- **Zero alterações no ambiente.** O script apenas lê `/proc`, `/sys`, executa
  comandos de leitura (`SHOW STATUS`, `INFO`, `SELECT`, `ss`, `df`, `docker ps`,
  `kubectl get`, etc.) e grava seus próprios artefatos dentro de `OUTPUT_DIR`. Nenhum
  módulo reinicia serviços, altera configuração, instala pacotes ou modifica
  parâmetros de kernel.
- **Agnóstico de distribuição.** Detecta a família da distro (`rhel`, `suse`,
  `debian`) a partir de `/etc/os-release` (`ID`/`ID_LIKE`) e adapta caminhos/gerenciador
  de pacotes (`dnf`/`yum`, `zypper`, `apt`) sem hard-code de um único SO. Testado em
  RHEL/CentOS/Rocky/Alma/Fedora, SUSE/openSUSE e Debian/Ubuntu e derivados.
- **Modular.** Cada coleta é uma unidade independente (`modules/*.sh` para o sistema,
  `modules/apps/*.sh` para aplicações) que grava sua própria saída bruta em
  `OUTPUT_DIR/modules/<nome>.txt`, além de alimentar um mecanismo central de
  *findings*.
- **Extensível por plugin.** Suportar um novo produto é criar um novo arquivo em
  `modules/apps/`, sem tocar no motor principal — ele é carregado automaticamente.
- **Rastreável às boas práticas.** Todo *finding* referencia uma recomendação e uma
  fonte (documentação oficial do fornecedor/projeto) definida em `lib/kb.sh`.

## O que é coletado

### Sistema (sempre executado)
CPU, memória/swap/THP, disco (uso, inodes, I/O), rede (interfaces, rotas, sockets,
`TIME_WAIT`), processos (top CPU/mem, zombies, OOM-killer, FDs abertos), limites de
kernel (`file-nr`, `ulimit`, `pid_max`), postura de segurança e patching
(SELinux/AppArmor, firewall, atualizações pendentes, sincronização de horário, reboot
pendente).

### Aplicações (detectadas automaticamente)
| Categoria | Produtos |
|---|---|
| Web / Proxy | NGINX, Apache HTTPD, HAProxy, Varnish |
| Banco de dados | MySQL/MariaDB, PostgreSQL, MongoDB |
| Cache / Chave-valor | Redis, Memcached |
| Busca/Analytics | Elasticsearch / OpenSearch |
| Mensageria | RabbitMQ, Apache Kafka |
| Runtimes de aplicação | Node.js, PHP-FPM, Python (Gunicorn/uWSGI/Uvicorn/Celery), Java/JVM, .NET |
| Containers/Orquestração | Docker, Podman, Kubernetes |

Serviços não cobertos por um plugin dedicado ainda aparecem no relatório através de
um levantamento genérico de serviços `systemd` ativos e portas em escuta — nada fica
"invisível" só por não ter um analisador específico.

## Uso

```bash
# Coleta completa (recomendado rodar como root para dados completos)
sudo bash bin/linux-perf-analyzer.sh

# Diretório de saída customizado
sudo OUTPUT_DIR=/var/reports/srv01 bash bin/linux-perf-analyzer.sh

# Credenciais de banco (opcional — sem elas, os módulos de DB reportam "sem acesso"
# e seguem para o próximo módulo; nada trava a execução)
sudo MYSQL_USER=readonly MYSQL_PASS=*** PG_USER=postgres bash bin/linux-perf-analyzer.sh
```

Sem privilégio de root o script roda mesmo assim (aviso de coleta parcial); no
entanto vários comandos (logs restritos, `docker`, contagem completa de `lsof`,
autenticação local do PostgreSQL) precisam de root para retornar dado completo.

### Variáveis de ambiente

| Variável | Padrão | Descrição |
|---|---|---|
| `OUTPUT_DIR` | `/tmp/linux-perf-<timestamp>` | Diretório de saída |
| `LOG_TAIL_LINES` | `200` | Linhas lidas do fim de cada log |
| `MYSQL_USER` / `MYSQL_PASS` | `root` / vazio | Credenciais MySQL/MariaDB (leitura) |
| `PG_USER` | `postgres` | Usuário de SO usado para `psql` |
| `SLOW_QUERY_THRESHOLD` | `1` | Threshold informativo (segundos) para slow query log |

## Saída gerada

```
OUTPUT_DIR/
├── report.html          # Relatório executivo (abrir no navegador)
├── summary.md            # Resumo em Markdown
├── full_report.txt       # Log consolidado de toda a coleta
├── findings.dat           # Base de findings (consumida pelo gerador de HTML)
├── stack.dat               # Stack de aplicações detectada
└── modules/
    ├── 00-os-kernel.txt
    ├── 01-cpu.txt
    ├── 02-memory.txt
    ├── 03-storage.txt
    ├── 04-network.txt
    ├── 05-processes.txt
    ├── 06-kernel-limits.txt
    ├── 10-detect-stack.txt
    └── app-<nome>.txt     # Um arquivo por aplicação detectada
```

O `report.html` é **autocontido** (CSS/JS inline, sem CDN), com modo claro/escuro
automático, resumo executivo com contagem por severidade, health score (0-100),
tabela de findings filtrável por severidade, stack detectada, apêndice com links
para os arquivos brutos e a lista de referências usadas.

## Arquitetura

```
bin/linux-perf-analyzer.sh   # Orquestrador principal
lib/
  core.sh                    # Logging, execução (run/runsh), motor de findings
  os_detect.sh                # Detecção de família de distro / gerenciador de pacotes
  kb.sh                        # Base de conhecimento: categoria/recomendação/referência
modules/
  00-os-kernel.sh .. 06-kernel-limits.sh   # Coletores de sistema
  10-detect-stack.sh          # Detecção de stack + dispatcher de plugins
  apps/*.sh                    # Um plugin por aplicação (register_plugin + detect/analyze)
report/
  generate_html.sh            # Gera report.html a partir de findings.dat/stack.dat
```

### Adicionando suporte a um novo produto

Crie `modules/apps/meuproduto.sh`:

```bash
register_plugin meuproduto "Meu Produto"

app_meuproduto_detect() {
  svc_active meuproduto || proc_up meuproduto
}

app_meuproduto_analyze() {
  run "Versão" meuproduto --version
  # ... coletas somente leitura ...
  # findings usam a base de conhecimento (lib/kb.sh) ou finding_raw para texto ad-hoc
  finding_raw MEDIUM "Categoria" "Título do achado" "Detalhe" "Recomendação" "Referência"
}
```

Nenhuma outra alteração é necessária — o arquivo é carregado automaticamente por
`modules/10-detect-stack.sh`.

### Motor de findings

Cada achado tem: severidade (`CRITICAL`/`HIGH`/`MEDIUM`/`LOW`/`INFO`), categoria,
módulo de origem, título, detalhe, recomendação e referência. O *health score* do
relatório é `100 - 20×críticos - 10×altos - 5×médios - 2×baixos` (mínimo 0).

## Licença

MIT — veja [LICENSE](LICENSE).
