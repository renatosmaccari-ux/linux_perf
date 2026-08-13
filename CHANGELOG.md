# Changelog

## 1.0.0 — 2026-08-13

Reescrita completa e modularização do coletor original `server-perf-analysis.sh`
em um framework distro-agnóstico, orientado a plugins e somente leitura.

### Adicionado
- Detecção de família de distribuição (RHEL/SUSE/Debian e derivados) via
  `/etc/os-release`, sem hard-code de um único SO (`lib/os_detect.sh`).
- Motor central de *findings* com severidade, categoria, recomendação e
  referência a boas práticas de fornecedor (`lib/core.sh`, `lib/kb.sh`).
- Arquitetura de plugins para aplicações (`modules/apps/*.sh`): novos produtos
  não exigem alteração no motor principal.
- Novos coletores de sistema: postura de patch/segurança (SELinux/AppArmor,
  firewall, atualizações pendentes, sincronização de horário, reboot pendente),
  limites de kernel dedicados, THP, NUMA.
- Novos plugins de aplicação: Varnish, Memcached, Kafka, .NET, Podman,
  Kubernetes (além dos já existentes: NGINX, Apache, HAProxy, MySQL/MariaDB,
  PostgreSQL, Redis, MongoDB, Elasticsearch, RabbitMQ, Node.js, PHP-FPM,
  Python, Java, Docker).
- Levantamento genérico de serviços/portas para qualquer processo não coberto
  por um plugin dedicado.
- Gerador de relatório HTML executivo, autocontido, com modo claro/escuro,
  health score, filtro por severidade e apêndice com as coletas brutas
  (`report/generate_html.sh`).
- Saída por módulo (`OUTPUT_DIR/modules/<nome>.txt`) além do log consolidado.

### Alterado
- `set -e` removido do orquestrador e do gerador de HTML: o comportamento de
  `set -e` do Bash é inconsistente em funções/loops com `&&`/`while read`
  (ver *Bash manual*, seção do builtin `set`), o que podia encerrar a coleta
  silenciosamente no meio da execução. A resiliência agora vem de checagens
  explícitas (`run`/`runsh` engolem falhas de comando individual e seguem em
  frente).
- Verificação de root deixou de ser obrigatória — vira aviso, para permitir
  coleta parcial sem privilégio elevado.
